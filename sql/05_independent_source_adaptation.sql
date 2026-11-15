-- 独立盲法脚本；所有对象只在当前事务会话存在；聚合结果由同目录runner导出。
-- @block setup
BEGIN; -- 开始隔离的临时分析事务。
SET LOCAL statement_timeout = '15min'; -- 每条语句最多十五分钟。
SET LOCAL max_parallel_workers_per_gather = 0; -- 禁止并行扫描外置数据库。
SET LOCAL work_mem = '128MB'; -- 控制单排序或哈希操作内存。
SET LOCAL application_name = 'blind_replication_independent'; -- 标明独立复跑会话。
-- @block base
CREATE TEMP TABLE br_base AS -- 汇总住院与患者信息，暂不做患者去重。
SELECT i.*, a.admission_type, a.discharge_location, a.admittime, a.dischtime, a.deathtime, -- 保留各类时间与纳排字段。
       a.hospital_expire_flag, a.race, p.gender, p.anchor_age, p.anchor_year_group, p.dod, -- 保留基线属性。
       p.anchor_age + EXTRACT(YEAR FROM i.intime)::integer - p.anchor_year AS age, -- 计算本次ICU入住年龄。
       (p.anchor_age + EXTRACT(YEAR FROM i.intime)::integer - p.anchor_year >= 18) AS adult, -- 成人纳入标志。
       a.admission_type NOT IN ('ELECTIVE','SURGICAL SAME DAY ADMISSION') AS nonsurgical, -- 排除择期或当日手术。
       (a.discharge_location IS NOT NULL AND a.dischtime IS NOT NULL AND a.dischtime >= a.admittime -- 验证医院结局信息。
        AND i.outtime IS NOT NULL AND i.outtime >= i.intime -- 验证ICU退出时间。
        AND ((a.hospital_expire_flag=1 AND a.deathtime IS NOT NULL) -- 死亡标志应有死亡时间。
          OR (a.hospital_expire_flag=0 AND a.deathtime IS NULL))) AS valid_outcome -- 存活者不能同时记录院内死亡。
FROM mimiciv_icu.icustays i -- 基本分析粒度是stay。
JOIN mimiciv_hosp.admissions a USING(hadm_id,subject_id) -- 住院信息必须属于同一患者。
JOIN mimiciv_hosp.patients p USING(subject_id); -- 链接患者属性。
CREATE UNIQUE INDEX ON br_base(stay_id); -- 为临时stay连接建立索引。
ANALYZE br_base; -- 更新临时表统计信息。
-- @block code_status_scan
CREATE TEMP TABLE br_code AS -- 原始大表只扫描一次，保留两代治疗限制项目。
SELECT c.stay_id,c.charttime,c.itemid,btrim(c.value) AS value, -- 仅留分析所需字段。
       lower(btrim(c.value)) ~ '(dni|do not intub|comfort|^cmo$)' AS prohibits_imv -- DNR单独不视为DNI。
FROM mimiciv_icu.chartevents c -- 不修改或为永久表建索引。
WHERE c.itemid IN (223758,228687); -- 两代Code Status项目来自当前字典。
CREATE INDEX ON br_code(stay_id,charttime); -- 只索引本会话临时对象。
ANALYZE br_code; -- 供后续范围连接估计使用。
-- @block ventilation
CREATE TEMP TABLE br_vent AS -- 每次入住压缩为一次IMV起点与一个气切标志。
SELECT b.stay_id, MIN(v.starttime) FILTER(WHERE v.ventilation_status='InvasiveVent') AS t_imv, -- 首次有创通气。
       COALESCE(BOOL_OR(v.ventilation_status='Tracheostomy' -- 气切排除窗。
          AND v.starttime BETWEEN b.intime-INTERVAL '6h' AND b.intime+INTERVAL '144h'),false) AS trach -- 无记录不设为气切。
FROM br_base b LEFT JOIN mimiciv_derived.ventilation v USING(stay_id) -- 保留从未通气患者。
GROUP BY b.stay_id; -- 一次stay一行。
CREATE UNIQUE INDEX ON br_vent(stay_id); -- 防止后续连接扩大行数。
-- @block oxygen
CREATE TEMP TABLE br_od AS -- 四列装置统一分类，先处理同时间点重复。
SELECT o.stay_id,o.charttime,MAX(d.device_code) AS device_code, -- 数字越大临床支持优先级越高。
       AVG(o.o2_flow) FILTER(WHERE o.o2_flow BETWEEN 0 AND 25) AS flow, -- 合理流量才参与估算。
       COUNT(*) AS source_rows -- 保存重复程度供聚合质控。
FROM mimiciv_derived.oxygen_delivery o -- 优先利用现有派生表减少原始大表扫描。
CROSS JOIN LATERAL (SELECT MAX(CASE -- 同条记录的四个装置列依次检查。
       WHEN btrim(x) IN ('Tracheostomy tube','Trach mask') THEN 7 -- 气切优先。
       WHEN btrim(x)='Endotracheal tube' THEN 6 -- 气管插管。
       WHEN btrim(x) IN ('Bipap mask','CPAP mask') THEN 5 -- 无创正压通气。
       WHEN btrim(x)='High flow nasal cannula' THEN 4 -- 高流量鼻导管。
       WHEN btrim(x)='Non-rebreather' THEN 3 -- 非重复呼吸面罩。
       WHEN x IS NOT NULL THEN 0 ELSE NULL END) AS device_code -- 其他/缺失不能算合格装置。
       FROM unnest(ARRAY[o.o2_delivery_device_1,o.o2_delivery_device_2,o.o2_delivery_device_3,o.o2_delivery_device_4]) x) d -- 不丢装置2至4。
GROUP BY o.stay_id,o.charttime; -- 同stay同时间只保留一行。
CREATE UNIQUE INDEX ON br_od(stay_id,charttime); -- 支持最近一次装置定位。
ANALYZE br_od; -- 临时表查询规划需要统计信息。
CREATE TEMP TABLE br_fio2 AS -- 同时点FiO2先单位归一再聚合。
SELECT stay_id,charttime,AVG(CASE WHEN fio2 BETWEEN .2 AND 1 THEN fio2*100 -- 小数转百分数。
       WHEN fio2 BETWEEN 21 AND 100 THEN fio2 ELSE NULL END) AS fio2, -- 超范围值保留为缺失。
       COUNT(*) AS source_rows -- 记录派生表是否重复。
FROM mimiciv_derived.ventilator_setting GROUP BY stay_id,charttime; -- 唯一观测时点。
CREATE UNIQUE INDEX ON br_fio2(stay_id,charttime); -- 严格同时间点连接。
ANALYZE br_fio2; -- 更新统计信息。
-- @block eligibility
CREATE TEMP TABLE br_candidate AS -- 先在每个stay找到首次符合呼吸条件的时刻。
SELECT DISTINCT ON (b.stay_id) b.stay_id,o.charttime AS t0,o.device_code, -- 每次入住一条候选时刻。
       COALESCE(f.fio2,CASE WHEN o.device_code=3 AND 21+3*o.flow<=100 THEN 21+3*o.flow END) AS fio2, -- 仅NRB缺FiO2时按流量估算。
       CASE WHEN f.fio2 IS NOT NULL THEN 'observed' ELSE 'NRB_flow_estimate' END AS fio2_source -- 区分直接观察与估算。
FROM br_base b JOIN br_od o USING(stay_id) -- 在本次入住内查装置记录。
LEFT JOIN br_fio2 f USING(stay_id,charttime) -- 装置和FiO2必须同时。
WHERE o.charttime BETWEEN b.intime-INTERVAL '6h' AND b.intime+INTERVAL '24h' -- 入组窗含端点。
  AND o.charttime <= b.outtime AND (b.deathtime IS NULL OR o.charttime<=b.deathtime) -- 不能在离开或死亡之后入组。
  AND o.device_code BETWEEN 3 AND 5 -- 三种合格非侵入装置。
  AND COALESCE(f.fio2,CASE WHEN o.device_code=3 AND 21+3*o.flow<=100 THEN 21+3*o.flow END) BETWEEN 40 AND 100 -- 双条件同时满足。
ORDER BY b.stay_id,o.charttime; -- 首次合格观测是t0。
CREATE UNIQUE INDEX ON br_candidate(stay_id); -- 检查与保障候选stay唯一。
CREATE TEMP TABLE br_flags AS -- 将排除标志集中在一个一对一表。
SELECT b.*,v.t_imv,v.trach,c.t0,c.device_code,c.fio2,c.fio2_source, -- 保留队列时间轴。
       EXISTS(SELECT 1 FROM br_code s WHERE s.stay_id=b.stay_id AND s.prohibits_imv -- 明确限制插管。
           AND s.charttime BETWEEN b.intime-INTERVAL '6h' AND b.intime+INTERVAL '24h') AS limit_imv, -- 预先冻结的早期限制窗。
       (v.t_imv IS NOT NULL AND v.t_imv<=COALESCE(c.t0,b.intime)) AS prior_imv -- 候选时刻前已有IMV。
FROM br_base b LEFT JOIN br_vent v USING(stay_id) LEFT JOIN br_candidate c USING(stay_id); -- 保留所有stay用于流程图。
CREATE TEMP TABLE br_eligible_stays AS -- 先完成各stay纳排。
SELECT * FROM br_flags WHERE adult AND nonsurgical AND valid_outcome -- 人口学与结局完整性。
  AND NOT limit_imv AND NOT trach AND NOT prior_imv AND t0 IS NOT NULL -- 排除临床限制及入组未达标。
  AND (deathtime IS NULL OR deathtime>=t0); -- 防止负的死亡随访时间。
CREATE TEMP TABLE br_cohort AS -- 再取每人的首次合格入住。
SELECT DISTINCT ON (subject_id) *,LEAST(outtime,deathtime,t0+INTERVAL '120h') AS admin_end, -- 行政与死亡截尾。
       LEAST(outtime,deathtime,t0+INTERVAL '120h',t_imv) AS risk_end -- 阈值风险集在IMV终止。
FROM br_eligible_stays ORDER BY subject_id,intime,stay_id; -- 去重的确定性次序。
CREATE UNIQUE INDEX ON br_cohort(stay_id); -- stay唯一。
CREATE UNIQUE INDEX ON br_cohort(subject_id); -- 患者唯一。
ANALYZE br_cohort; -- 小队列供后续限制大表读取范围。
-- @block baseline_vitals
CREATE TEMP TABLE br_vitals AS -- 只保留队列基线前两小时的有效生命体征。
SELECT c.stay_id,v.charttime,AVG(v.spo2) FILTER(WHERE v.spo2>0 AND v.spo2<=100) AS spo2, -- 有效饱和度。
       AVG(v.resp_rate) FILTER(WHERE v.resp_rate>0 AND v.resp_rate<70) AS rr -- 作者范围内的RR。
FROM mimiciv_derived.vitalsign v JOIN br_cohort c USING(stay_id) -- 先限制队列。
WHERE v.charttime BETWEEN c.t0-INTERVAL '2h' AND c.t0 GROUP BY c.stay_id,v.charttime; -- 不取t0之后数据。
CREATE INDEX ON br_vitals(stay_id,charttime); -- 最近非空记录查询索引。
CREATE TEMP TABLE br_dx AS -- ICD精确列表来自固定作者代码。
SELECT c.stay_id, -- 以stay关联同次住院诊断。
       COALESCE(BOOL_OR((d.icd_version=9 AND d.icd_code IN ('496','49121')) -- 原作者COPD的ICD9列表。
          OR (d.icd_version=10 AND d.icd_code IN ('J449','J441','J440','J439'))),false) AS copd, -- 原作者COPD的ICD10列表。
       COALESCE(BOOL_OR((d.icd_version=9 AND d.icd_code IN ('4280','42833','42832','4254','42843')) -- 原作者CHF的ICD9列表。
          OR (d.icd_version=10 AND d.icd_code IN ('I110','I5033','I130','I5023','I255','I5032','I509','I429','I5022','I420'))),false) AS chf, -- 原作者CHF的ICD10列表。
       COALESCE(BOOL_OR((d.icd_version=9 AND d.icd_code LIKE '491%') OR (d.icd_version=10 AND d.icd_code LIKE 'J44%')),false) AS classroom_copd, -- 课堂简化COPD对照。
       COALESCE(BOOL_OR((d.icd_version=9 AND d.icd_code LIKE '428%') OR (d.icd_version=10 AND d.icd_code LIKE 'I50%')),false) AS classroom_chf -- 课堂简化CHF对照。
FROM br_cohort c LEFT JOIN mimiciv_hosp.diagnoses_icd d USING(hadm_id) GROUP BY c.stay_id; -- 多诊断压成一行。
CREATE TEMP TABLE br_table2 AS -- 完成患者基线及随访表，不向文件导出个体行。
SELECT c.*,d.copd,d.chf,d.classroom_copd,d.classroom_chf, -- 两套合并症定义均保留。
       CASE WHEN age<40 THEN '18-39' WHEN age<50 THEN '40-49' WHEN age<60 THEN '50-59' -- 年龄分组。
            WHEN age<70 THEN '60-69' WHEN age<80 THEN '70-79' ELSE '80+' END AS age_group, -- 高龄单列。
       CASE WHEN race LIKE 'WHITE%' THEN 'White' WHEN race LIKE 'BLACK%' THEN 'Black' -- race亚型归并。
            WHEN race LIKE 'ASIAN%' THEN 'Asian' WHEN race LIKE 'HISPANIC%' THEN 'Hispanic' -- 亚裔及拉美裔。
            WHEN race IS NULL OR race IN ('UNKNOWN','UNABLE TO OBTAIN','PATIENT DECLINED TO ANSWER') THEN 'Unknown' ELSE 'Other' END AS race_group, -- 缺失不隐去。
       CASE WHEN first_careunit IN ('Coronary Care Unit (CCU)','Cardiac Vascular Intensive Care Unit (CVICU)') THEN 'Cardiac' -- 心血管ICU。
            WHEN first_careunit IN ('Neuro Intermediate','Neuro Stepdown','Neuro Surgical Intensive Care Unit (Neuro SICU)','Trauma SICU (TSICU)') THEN 'Neuro-trauma' -- 神经创伤ICU。
            ELSE 'Medical-surgical' END AS icu_group, -- 其他归医学外科。
       s.spo2,r.rr, -- 每变量独立取最近非空值。
       CASE WHEN t_imv IS NOT NULL AND t_imv<=admin_end THEN 'IMV' -- 同时刻优先IMV。
            WHEN deathtime IS NOT NULL AND deathtime<=outtime AND deathtime<=t0+INTERVAL '120h' THEN 'Death' -- 第二优先死亡。
            WHEN outtime<=t0+INTERVAL '120h' THEN 'ICU discharge' ELSE 'Administrative120h' END AS event120, -- 其余行政截尾。
       COALESCE(deathtime>=intime AND deathtime<intime+INTERVAL '28d',false) AS death28_hospital, -- 作者对应的院内28日死亡。
       COALESCE(dod>=intime::date AND dod<(intime+INTERVAL '28d')::date,false) AS death28_dod -- 日期级死亡敏感性。
FROM br_cohort c JOIN br_dx d USING(stay_id) -- 合并症一对一联结。
LEFT JOIN LATERAL (SELECT spo2 FROM br_vitals WHERE stay_id=c.stay_id AND spo2 IS NOT NULL ORDER BY charttime DESC LIMIT 1) s ON true -- 取最近有效SpO2。
LEFT JOIN LATERAL (SELECT rr FROM br_vitals WHERE stay_id=c.stay_id AND rr IS NOT NULL ORDER BY charttime DESC LIMIT 1) r ON true; -- 取最近有效RR。
-- @block bloodgas
CREATE TEMP TABLE br_bg AS -- 仅队列风险窗内匹配血气，保留标本用于质控。
SELECT c.stay_id,b.charttime,b.specimen,b.po2,COALESCE(b.fio2,b.fio2_chartevents) AS fio2, -- 血气与监护FiO2优先次序。
       b.pao2fio2ratio AS pf_derived,100*b.po2/NULLIF(COALESCE(b.fio2,b.fio2_chartevents),0) AS pf_recalculated, -- 独立核对PF。
       b.charttime>c.t_imv AS after_imv,b.charttime>c.risk_end AS after_risk, -- 保留风险集违例供聚合分析。
       o.device_code AS current_device,o.charttime AS device_time -- 最近装置及其时间仅留TEMP。
FROM mimiciv_derived.bg b JOIN br_cohort c ON b.hadm_id=c.hadm_id AND b.subject_id=c.subject_id -- 住院及患者双重键。
LEFT JOIN LATERAL (SELECT device_code,charttime FROM br_od WHERE stay_id=c.stay_id -- 同stay最近明确装置。
       AND charttime<=b.charttime AND charttime>=b.charttime-INTERVAL '8h' AND device_code IS NOT NULL -- 不借未来记录。
       ORDER BY charttime DESC LIMIT 1) o ON true -- 八小时内最后一次装置。
WHERE b.charttime BETWEEN c.t0 AND c.admin_end; -- 主候选窗口尚未排除IMV后观测。
CREATE TEMP TABLE br_hits_all AS -- 各敏感性共用的动脉PF候选。
SELECT stay_id,charttime,MIN(pf_derived) AS pf, -- 同时重复血气以最小有效PF判定出现过阈值。
       BOOL_OR(current_device BETWEEN 3 AND 5) AS device_qualified,COUNT(*) AS source_rows -- 当前非侵入氧疗装置要求。
FROM br_bg WHERE specimen='ART.' AND po2>0 AND fio2 BETWEEN 21 AND 100 -- 动脉标本与有效数值。
  AND pf_derived>0 AND pf_derived<150 AND NOT after_risk -- 已插管或已截尾后不进入风险集。
GROUP BY stay_id,charttime; -- 不因重复血气放大分母。
CREATE TEMP TABLE br_pf80 AS -- 主阈值：每人第一次合格装置上的PF<80。
SELECT DISTINCT ON (h.stay_id) h.*,c.t0,c.t_imv,c.admin_end,c.device_code AS baseline_device, -- 首次阈值时间轴。
       COALESCE(c.t_imv BETWEEN h.charttime AND LEAST(h.charttime+INTERVAL '3h',c.admin_end),false) AS imv_3h, -- 结局含3h端点。
       COALESCE(c.t_imv>=h.charttime AND c.t_imv<h.charttime+INTERVAL '3h' AND c.t_imv<=c.admin_end,false) AS imv_strict3h, -- 作者严格3h对照。
       c.admin_end<h.charttime+INTERVAL '3h' AS short_observation -- 窗口未完整者仍保留分母。
FROM br_hits_all h JOIN br_cohort c USING(stay_id) WHERE h.pf<80 AND h.device_qualified -- 主阈值条件。
ORDER BY h.stay_id,h.charttime; -- 确定第一次命中。
-- @block aggregate_flow
SELECT jsonb_build_object('all_stays',COUNT(*), -- 全库ICU stay基数。
'adult',COUNT(*) FILTER(WHERE adult), -- 成人步骤。
'nonsurgical',COUNT(*) FILTER(WHERE adult AND nonsurgical), -- 手术排除后。
'valid_outcome',COUNT(*) FILTER(WHERE adult AND nonsurgical AND valid_outcome), -- 结局完整后。
'no_limit',COUNT(*) FILTER(WHERE adult AND nonsurgical AND valid_outcome AND NOT limit_imv), -- 治疗限制排除后。
'no_trach',COUNT(*) FILTER(WHERE adult AND nonsurgical AND valid_outcome AND NOT limit_imv AND NOT trach), -- 气切排除后。
'no_prior_imv',COUNT(*) FILTER(WHERE adult AND nonsurgical AND valid_outcome AND NOT limit_imv AND NOT trach AND NOT prior_imv), -- 既往IMV排除后。
'eligible_stays',(SELECT COUNT(*) FROM br_eligible_stays),'unique_patients',(SELECT COUNT(*) FROM br_cohort)) AS result -- 最终stay及患者。
FROM br_flags; -- 一行一个stay。
-- @block aggregate_pf80
SELECT jsonb_build_object('met',COUNT(*),'imv_3h',COUNT(*) FILTER(WHERE imv_3h), -- 保留所有达标者作为分母。
'pct_3h',ROUND(100.0*COUNT(*) FILTER(WHERE imv_3h)/NULLIF(COUNT(*),0),4), -- 小数百分比防整数相除。
'imv_strict3h',COUNT(*) FILTER(WHERE imv_strict3h),'short_observation',COUNT(*) FILTER(WHERE short_observation)) AS result -- 边界敏感性。
FROM br_pf80; -- 每患者一条首次达标。
-- @block aggregate_pf80_strata
SELECT baseline_device,COUNT(*) AS met,COUNT(*) FILTER(WHERE imv_3h) AS imv_3h, -- 基线装置分层。
ROUND(100.0*COUNT(*) FILTER(WHERE imv_3h)/NULLIF(COUNT(*),0),4) AS pct FROM br_pf80 GROUP BY baseline_device ORDER BY baseline_device; -- 每层独立分母。
-- @block aggregate_sensitivity
WITH firsts AS (SELECT DISTINCT ON(stay_id) h.*,c.t_imv,c.admin_end FROM br_hits_all h -- 去掉阈值当下装置限制。
JOIN br_cohort c USING(stay_id) WHERE pf<80 ORDER BY stay_id,charttime) -- 只变一项定义。
SELECT 'no_current_device_requirement' AS scenario,COUNT(*) AS met, -- 预设课堂Q4敏感性。
COUNT(*) FILTER(WHERE t_imv BETWEEN charttime AND LEAST(charttime+INTERVAL '3h',admin_end)) AS imv_3h FROM firsts; -- 仍限制风险集。
-- @block aggregate_table2_categorical
SELECT v.variable,v.category,COUNT(*) AS n,ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM br_table2),4) AS pct -- 所有分类按总队列分母。
FROM br_table2 t CROSS JOIN LATERAL (VALUES ('age_group',age_group),('sex',gender::text), -- 年龄性别。
('race',race_group),('year_anchor_group',anchor_year_group),('icu',icu_group), -- 种族年份ICU。
('baseline_device',device_code::text),('fio2_source',fio2_source),('copd_author',copd::text),('chf_author',chf::text), -- 装置来源与作者合并症。
('copd_classroom',classroom_copd::text),('chf_classroom',classroom_chf::text),('event120',event120), -- 课堂定义及竞争结局。
('death28_hospital',death28_hospital::text),('death28_dod',death28_dod::text)) v(variable,category) -- 两种死亡定义。
GROUP BY v.variable,v.category ORDER BY 1,2; -- 聚合后才导出。
-- @block aggregate_table2_continuous
SELECT v.variable,COUNT(*) AS total,COUNT(v.value) AS valid_n, -- 记录缺失而非删全行。
percentile_cont(ARRAY[.25,.5,.75]) WITHIN GROUP(ORDER BY v.value) AS quartiles -- 同一有效分母算四分位。
FROM br_table2 CROSS JOIN LATERAL (VALUES ('SpO2',spo2::double precision),('RR',rr::double precision), -- 基线呼吸变量。
('FiO2',fio2::double precision),('age',age::double precision)) v(variable,value) GROUP BY 1 ORDER BY 1; -- 仅聚合导出。
-- @block aggregate_ever_devices
SELECT o.device_code,COUNT(DISTINCT stay_id) AS n FROM br_od o JOIN br_cohort c USING(stay_id) -- 可多选装置类别。
WHERE o.charttime BETWEEN c.t0 AND c.risk_end AND o.device_code BETWEEN 3 AND 5 GROUP BY 1 ORDER BY 1; -- 只统计风险集期间。
-- @block aggregate_code_audit
SELECT itemid,value,prohibits_imv,COUNT(*) AS records,COUNT(DISTINCT stay_id) AS stays FROM br_code GROUP BY 1,2,3 ORDER BY 1,2; -- 仅导出文本分类的聚合审计。
-- @block aggregate_qc
SELECT jsonb_build_object('cohort_rows',(SELECT COUNT(*) FROM br_cohort),'cohort_stays',(SELECT COUNT(DISTINCT stay_id) FROM br_cohort), -- 防重复。
'cohort_patients',(SELECT COUNT(DISTINCT subject_id) FROM br_cohort),'pf80_rows',(SELECT COUNT(*) FROM br_pf80), -- 患者与阈值粒度。
'pf80_stays',(SELECT COUNT(DISTINCT stay_id) FROM br_pf80),'null_outcome',(SELECT COUNT(*) FROM br_pf80 WHERE imv_3h IS NULL), -- 分母与NULL。
'pf_before_t0',(SELECT COUNT(*) FROM br_pf80 WHERE charttime<t0),'imv_before_pf',(SELECT COUNT(*) FROM br_pf80 WHERE t_imv<charttime), -- 时序验证。
'pf_after_censor',(SELECT COUNT(*) FROM br_pf80 WHERE charttime>admin_end),'bad_baseline_fio2',(SELECT COUNT(*) FROM br_cohort WHERE fio2 NOT BETWEEN 40 AND 100), -- 取值范围。
'bg_pf_mismatch',(SELECT COUNT(*) FROM br_bg WHERE abs(pf_derived-pf_recalculated)>0.00001),'bg_after_imv',(SELECT COUNT(*) FROM br_bg WHERE after_imv), -- 独立重算与风险集。
'od_duplicate_timepoints',(SELECT COUNT(*) FROM br_od WHERE source_rows>1),'fio2_duplicate_timepoints',(SELECT COUNT(*) FROM br_fio2 WHERE source_rows>1), -- 源表重复。
'baseline_future_vitals',(SELECT COUNT(*) FROM br_vitals v JOIN br_cohort c USING(stay_id) WHERE v.charttime>c.t0), -- 防基线泄漏。
'death_discharge_ties',(SELECT COUNT(*) FROM br_cohort WHERE deathtime=outtime),'imv_death_ties',(SELECT COUNT(*) FROM br_cohort WHERE t_imv=deathtime), -- 竞争事件同刻。
'dod_missing',(SELECT COUNT(*) FROM br_cohort WHERE dod IS NULL)) AS result; -- 死亡资料缺失程度。
-- @block aggregate_bg_quality
SELECT COALESCE(specimen,'NULL') AS specimen,COUNT(*) AS records, -- 各标本数量。
COUNT(*) FILTER(WHERE NOT after_risk) AS in_risk, -- 风险集候选。
COUNT(*) FILTER(WHERE pf_derived IS NULL) AS missing_pf,COUNT(*) FILTER(WHERE fio2 NOT BETWEEN 21 AND 100 OR fio2 IS NULL) AS bad_or_missing_fio2, -- PF缺失来源。
COUNT(*) FILTER(WHERE po2>0 AND fio2 BETWEEN 21 AND 100 AND pf_derived<80 AND NOT after_risk) AS low_pf_risk, -- 低PF按标本分层。
COUNT(*) FILTER(WHERE po2>0 AND fio2 BETWEEN 21 AND 100 AND pf_derived<80 AND NOT after_risk AND current_device BETWEEN 3 AND 5) AS low_pf_device_risk -- 加装置条件。
FROM br_bg GROUP BY 1 ORDER BY 1; -- 不输出个体血气。
-- @block aggregate_imv_timing
SELECT COUNT(*) AS pf80,COUNT(*) FILTER(WHERE t_imv=charttime) AS same_time_imv, -- 同时刻歧义单列。
COUNT(*) FILTER(WHERE t_imv=charttime+INTERVAL '3h') AS exact_three_hours, -- 三小时边界。
COUNT(*) FILTER(WHERE imv_3h AND short_observation) AS positive_short_observation FROM br_pf80; -- 早转出对阳性的影响。
-- @block aggregate_entry_availability
SELECT o.device_code,COUNT(DISTINCT o.stay_id) AS device_stays, -- 入组窗出现装置的stay数。
COUNT(DISTINCT o.stay_id) FILTER(WHERE f.fio2 IS NOT NULL) AS samepoint_observed_fio2_stays, -- 同点FiO2可用性。
COUNT(DISTINCT o.stay_id) FILTER(WHERE f.fio2 BETWEEN 40 AND 100) AS samepoint_fio2_ge40_stays, -- 同点实测达标数。
COUNT(DISTINCT o.stay_id) FILTER(WHERE o.device_code=3 AND f.fio2 IS NULL AND 21+3*o.flow BETWEEN 40 AND 100) AS flow_fallback_stays -- 仅NRB估算贡献。
FROM br_od o JOIN br_base b USING(stay_id) LEFT JOIN br_fio2 f USING(stay_id,charttime) -- 仅查临时表解释同点缺失。
WHERE o.charttime BETWEEN b.intime-INTERVAL '6h' AND b.intime+INTERVAL '24h' AND o.device_code BETWEEN 3 AND 5 -- 入组时窗。
GROUP BY 1 ORDER BY 1; -- 各装置不互斥。
-- @block aggregate_additional_qc
SELECT jsonb_build_object('missing_discharge_location',COUNT(*) FILTER(WHERE discharge_location IS NULL), -- 医院结局缺失。
'missing_dischtime',COUNT(*) FILTER(WHERE dischtime IS NULL),'negative_hospital_los',COUNT(*) FILTER(WHERE dischtime<admittime), -- 时间合理性。
'negative_icu_los',COUNT(*) FILTER(WHERE outtime<intime),'death_flag_no_time',COUNT(*) FILTER(WHERE hospital_expire_flag=1 AND deathtime IS NULL), -- 院内死亡矛盾。
'survival_flag_with_death_time',COUNT(*) FILTER(WHERE hospital_expire_flag=0 AND deathtime IS NOT NULL), -- 相反标志矛盾。
'cohort_no_code_status',(SELECT COUNT(*) FROM br_cohort c WHERE NOT EXISTS(SELECT 1 FROM br_code s WHERE s.stay_id=c.stay_id -- 无记录不能当已证实Full code。
AND s.charttime BETWEEN c.intime-INTERVAL '6h' AND c.intime+INTERVAL '24h')), -- 冻结的限制观察窗。
'bg_unknown_current_device',(SELECT COUNT(*) FROM br_bg WHERE current_device IS NULL), -- 当前装置不可判定。
'arterial_lowpf_outside_device',(SELECT COUNT(*) FROM br_bg WHERE specimen='ART.' AND pf_derived>0 AND pf_derived<80 AND NOT after_risk -- 动脉低PF。
AND (current_device IS NULL OR current_device NOT BETWEEN 3 AND 5))) AS result FROM br_base; -- 解释装置敏感性差异。
-- @block finish
ROLLBACK; -- 撤销所有临时对象，不改变任何永久临床表。

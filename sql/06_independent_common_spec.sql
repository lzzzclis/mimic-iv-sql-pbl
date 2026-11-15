-- 第二阶段：共同定义的独立实现；第一轮任何产物均不覆盖。
-- @block setup
BEGIN; -- 所有分析保存在临时事务。
SET LOCAL statement_timeout='15min'; -- 每条语句最多十五分钟。
SET LOCAL max_parallel_workers_per_gather=0; -- 不并行查询数据库。
SET LOCAL work_mem='128MB'; -- 控制单算子内存。
SET LOCAL application_name='common_spec_independent_blind'; -- 标明共同口径独立会话。
-- @block base
CREATE TEMP TABLE cs_base AS -- 原始三层ID及派生年龄连接。
SELECT i.*,a.admission_type,a.discharge_location,a.admittime,a.dischtime,a.deathtime,a.hospital_expire_flag, -- 不按出院/死亡标志追加排除。
a.race,p.gender,p.anchor_age,p.anchor_year_group,d.admission_age AS age, -- 成人用派生住院年龄。
(d.admission_age>=18) AS adult, -- 明确年龄定义。
(a.admission_type NOT IN ('ELECTIVE','SURGICAL SAME DAY ADMISSION')) AS nonsurgical, -- 排除两种手术入院类型。
(a.discharge_location IS NOT NULL AND i.outtime>i.intime) AS base_valid -- 共同定义只需这两项。
FROM mimiciv_icu.icustays i JOIN mimiciv_hosp.admissions a USING(subject_id,hadm_id) -- 同患者同住院连接。
JOIN mimiciv_hosp.patients p USING(subject_id) JOIN mimiciv_derived.icustay_detail d USING(stay_id); -- 取admission_age。
CREATE UNIQUE INDEX ON cs_base(stay_id); -- 确保派生表连接不扩行。
ANALYZE cs_base; -- 为后续查询提供统计信息。
CREATE TEMP TABLE cs_vent AS -- 先按stay确定两种首次通气事件。
SELECT stay_id,MIN(starttime) FILTER(WHERE ventilation_status='InvasiveVent') AS t_imv, -- IMV最早时间。
MIN(starttime) FILTER(WHERE ventilation_status='Tracheostomy') AS t_trach -- 气切最早时间。
FROM mimiciv_derived.ventilation GROUP BY stay_id; -- 未出现者后续LEFT JOIN为NULL。
CREATE UNIQUE INDEX ON cs_vent(stay_id); -- 保证一对一连接。
-- @block oxygen
CREATE TEMP TABLE cs_od AS -- 每条源行独立保留装置及流量。
SELECT o.stay_id,o.charttime,btrim(o.o2_delivery_device_1) AS first_device,o.o2_flow AS flow,d.device_code -- 不平均原始流量。
FROM mimiciv_derived.oxygen_delivery o CROSS JOIN LATERAL(SELECT MAX(CASE -- 四槽综合最高优先级。
WHEN btrim(x) IN ('Tracheostomy tube','Trach mask') THEN 7 -- 气切优先。
WHEN btrim(x)='Endotracheal tube' THEN 6 -- 插管。
WHEN btrim(x) IN ('Bipap mask','CPAP mask') THEN 5 -- NIV。
WHEN btrim(x)='High flow nasal cannula' THEN 4 -- HFNC。
WHEN btrim(x)='Non-rebreather' THEN 3 -- NRB。
WHEN btrim(x)='Nasal cannula' THEN 1 WHEN btrim(x)='None' THEN 0 -- 明确低支持和无装置也覆盖旧记录。
WHEN x IS NOT NULL THEN 2 ELSE NULL END) AS device_code -- 未知非空归其他，四槽全空才NULL。
FROM unnest(ARRAY[o.o2_delivery_device_1,o.o2_delivery_device_2,o.o2_delivery_device_3,o.o2_delivery_device_4]) x) d; -- 逐列处理。
CREATE INDEX ON cs_od(stay_id,charttime DESC,device_code DESC); -- 查前八小时最近非空分类。
ANALYZE cs_od; -- 为最近记录查询提供统计信息。
CREATE TEMP TABLE cs_fio2 AS -- 派生FiO2只接受百分数20至100。
SELECT stay_id,charttime,AVG(fio2) FILTER(WHERE fio2 BETWEEN 20 AND 100) AS fio2 -- 不把小数另乘100。
FROM mimiciv_derived.ventilator_setting GROUP BY stay_id,charttime; -- 同点均值。
CREATE UNIQUE INDEX ON cs_fio2(stay_id,charttime); -- 同点连接不扩行。
ANALYZE cs_fio2; -- 更新临时表统计信息。
-- @block candidates
CREATE TEMP TABLE cs_candidate_rows AS -- 每条候选先做全部动态时间排除。
SELECT b.stay_id,b.subject_id,b.intime,o.charttime AS t0,o.device_code,x.fio2,x.fio2_source,v.t_imv,v.t_trach -- 保留合格候选时间轴。
FROM cs_base b JOIN cs_od o USING(stay_id) LEFT JOIN cs_fio2 f USING(stay_id,charttime) -- 装置和FiO2同点。
LEFT JOIN cs_vent v USING(stay_id) CROSS JOIN LATERAL(SELECT -- 只在规定NRB条件下估算。
COALESCE(f.fio2,CASE WHEN o.device_code=3 AND o.first_device='Non-rebreather' THEN -- 综合分类和首槽均须NRB。
CASE WHEN o.flow>25 AND o.flow<=100 THEN o.flow -- 流量栏误录百分数。
WHEN o.flow>0 AND 21+3*o.flow<=100 THEN 21+3*o.flow END END) AS fio2, -- 其余只用正流量公式。
CASE WHEN f.fio2 IS NOT NULL THEN 'observed' WHEN o.flow>25 AND o.flow<=100 THEN 'NRB_flow_as_percent' ELSE 'NRB_flow_formula' END AS fio2_source) x -- 留估算来源审计。
WHERE b.adult AND b.nonsurgical AND b.base_valid -- 基本人群纳排。
AND o.charttime BETWEEN b.intime-INTERVAL '6h' AND b.intime+INTERVAL '24h' AND o.charttime<=b.outtime -- 含入组窗两端。
AND o.device_code BETWEEN 3 AND 5 AND x.fio2 BETWEEN 40 AND 100 -- 同点双条件。
AND (v.t_imv IS NULL OR v.t_imv>o.charttime+INTERVAL '30min') -- 排除候选后半小时内已IMV。
AND (v.t_trach IS NULL OR v.t_trach>o.charttime+INTERVAL '120h') -- 排除随后120h内气切。
AND LEAST(b.outtime,b.deathtime,o.charttime+INTERVAL '120h')>o.charttime; -- 候选必须有正随访。
CREATE TEMP TABLE cs_candidate AS -- 完成逐候选筛选后才取每stay首次。
SELECT DISTINCT ON(stay_id) * FROM cs_candidate_rows ORDER BY stay_id,t0,device_code DESC,fio2 DESC; -- 同刻取高支持及高FiO2。
CREATE UNIQUE INDEX ON cs_candidate(stay_id); -- 一个stay一条候选。
ANALYZE cs_candidate; -- 限制原始治疗目标记录的匹配范围。
-- @block code_status_scan
CREATE TEMP TABLE cs_code AS -- 原始大表仅扫描一次，且只保留候选stay相关记录。
SELECT c.stay_id,c.charttime,c.itemid,regexp_replace(btrim(c.value),'[[:space:]]+',' ','g') AS value -- 规范连续空白。
FROM mimiciv_icu.chartevents c JOIN cs_candidate k USING(stay_id) -- 只查候选stay。
WHERE c.itemid IN (223758,228687,229784) AND c.charttime<k.intime+INTERVAL '144h'; -- 严格上界、无下界。
CREATE INDEX ON cs_code(stay_id); -- 治疗限制按stay汇总。
CREATE TEMP TABLE cs_code_flags AS -- 确切字符串匹配，禁止关键词扩展。
SELECT stay_id,COUNT(*) AS code_records,BOOL_OR(value IN ('Comfort measures only','DNR / DNI', -- 两种确切限制值。
'DNAR (Do Not Attempt Resuscitation) [DNR] / DNI','DNI (do not intubate)')) AS limit_imv -- 另外两种确切值。
FROM cs_code GROUP BY stay_id; -- 多条状态只取是否曾明确限制。
CREATE UNIQUE INDEX ON cs_code_flags(stay_id); -- 一对一连接。
-- @block cohort
CREATE TEMP TABLE cs_eligible AS -- 排除明确限制后保留合格stay。
SELECT k.*,COALESCE(f.code_records,0) AS code_records FROM cs_candidate k LEFT JOIN cs_code_flags f USING(stay_id) -- 无记录保留并单报。
WHERE NOT COALESCE(f.limit_imv,false); -- 单独DNR没有被列为限制。
CREATE TEMP TABLE cs_cohort AS -- 患者首次合格stay按ICU入住时间选择。
SELECT DISTINCT ON(b.subject_id) b.*,k.t0,k.device_code,k.fio2,k.fio2_source,k.t_imv,k.t_trach,k.code_records, -- 保留全部分析所需字段。
LEAST(b.outtime,b.deathtime,k.t0+INTERVAL '120h') AS admin_end, -- 共同定义行政终点。
LEAST(b.outtime,b.deathtime,k.t0+INTERVAL '120h',k.t_imv) AS risk_end -- 风险集在首次IMV结束。
FROM cs_eligible k JOIN cs_base b USING(stay_id) ORDER BY b.subject_id,b.intime,b.stay_id; -- 不是按t0或一生首次ICU。
CREATE UNIQUE INDEX ON cs_cohort(stay_id); -- 保障stay唯一。
CREATE UNIQUE INDEX ON cs_cohort(subject_id); -- 保障患者唯一。
ANALYZE cs_cohort; -- 大表后续仅对主队列抽取。
-- @block table2
CREATE TEMP TABLE cs_vitals AS -- 先对同刻重复取较大值，再查最后有效记录。
SELECT c.stay_id,v.charttime,MAX(v.spo2) FILTER(WHERE v.spo2>0 AND v.spo2<=100) AS spo2, -- 饱和度有效范围。
MAX(v.resp_rate) FILTER(WHERE v.resp_rate>0 AND v.resp_rate<70) AS rr -- 呼吸频率有效范围。
FROM mimiciv_derived.vitalsign v JOIN cs_cohort c USING(stay_id) -- 主队列基线。
WHERE v.charttime BETWEEN c.t0-INTERVAL '12h' AND c.t0 GROUP BY c.stay_id,v.charttime; -- 不能取未来值。
CREATE INDEX ON cs_vitals(stay_id,charttime DESC); -- 查最后有效记录。
CREATE TEMP TABLE cs_dx AS -- 两种合并症定义各自保留。
SELECT c.stay_id,COALESCE(BOOL_OR((d.icd_version=9 AND d.icd_code IN ('496','49121')) -- 作者COPD列表ICD9。
OR (d.icd_version=10 AND d.icd_code IN ('J449','J441','J440','J439'))),false) AS copd, -- 作者COPD列表ICD10。
COALESCE(BOOL_OR((d.icd_version=9 AND d.icd_code IN ('4280','42833','42832','4254','42843')) -- 作者CHF列表ICD9。
OR (d.icd_version=10 AND d.icd_code IN ('I110','I5033','I130','I5023','I255','I5032','I509','I429','I5022','I420'))),false) AS chf, -- 作者CHF列表ICD10。
COALESCE(BOOL_OR((d.icd_version=9 AND d.icd_code LIKE '491%') OR (d.icd_version=10 AND d.icd_code LIKE 'J44%')),false) AS classroom_copd, -- 课堂COPD前缀。
COALESCE(BOOL_OR((d.icd_version=9 AND d.icd_code LIKE '428%') OR (d.icd_version=10 AND d.icd_code LIKE 'I50%')),false) AS classroom_chf -- 课堂CHF前缀。
FROM cs_cohort c LEFT JOIN mimiciv_hosp.diagnoses_icd d USING(hadm_id) GROUP BY c.stay_id; -- 多诊断压成一行。
CREATE TEMP TABLE cs_table2 AS -- 基线、首次竞争事件及28日指标。
SELECT c.*,d.copd,d.chf,d.classroom_copd,d.classroom_chf,s.spo2,r.rr, -- 各变量独立取最后有效值。
CASE WHEN age<40 THEN '18-39' WHEN age<50 THEN '40-49' WHEN age<60 THEN '50-59' WHEN age<70 THEN '60-69' WHEN age<80 THEN '70-79' ELSE '80+' END AS age_group, -- admission_age年龄组。
CASE WHEN anchor_age<40 THEN '18-39' WHEN anchor_age<50 THEN '40-49' WHEN anchor_age<60 THEN '50-59' WHEN anchor_age<70 THEN '60-69' WHEN anchor_age<80 THEN '70-79' ELSE '80+' END AS anchor_age_group, -- 作者年龄分组对照。
CASE WHEN race LIKE 'WHITE%' THEN 'White' WHEN race LIKE 'BLACK%' THEN 'Black' WHEN race LIKE 'ASIAN%' THEN 'Asian' WHEN race LIKE 'HISPANIC%' THEN 'Hispanic' -- 扩展亚型映射。
WHEN race IS NULL OR btrim(race)='' OR race IN ('UNKNOWN','UNABLE TO OBTAIN','PATIENT DECLINED TO ANSWER') THEN 'Unknown' ELSE 'Other' END AS race_group, -- 缺失单列。
CASE race WHEN 'WHITE' THEN 'White' WHEN 'BLACK/AFRICAN AMERICAN' THEN 'Black' WHEN 'ASIAN' THEN 'Asian' WHEN 'HISPANIC/LATINO' THEN 'Hispanic' -- 原作者精确映射。
WHEN 'AMERICAN INDIAN/ALASKA NATIVE' THEN 'Other' WHEN 'OTHER' THEN 'Other' ELSE 'Unknown' END AS race_author, -- 原作者其余归Unknown。
CASE WHEN first_careunit IN ('Coronary Care Unit (CCU)','Cardiac Vascular Intensive Care Unit (CVICU)') THEN 'Cardiac' -- 心血管ICU。
WHEN first_careunit IN ('Neuro Intermediate','Neuro Stepdown','Neuro Surgical Intensive Care Unit (Neuro SICU)','Trauma SICU (TSICU)') THEN 'Neuro-trauma' ELSE 'Medical-surgical' END AS icu_group, -- 神经创伤及其他。
CASE WHEN deathtime<=LEAST(outtime,t0+INTERVAL '120h') AND (t_imv IS NULL OR deathtime<=t_imv) THEN 'Death' -- 死亡同刻优先IMV。
WHEN t_imv<=admin_end THEN 'IMV' WHEN outtime<=t0+INTERVAL '120h' THEN 'ICU discharge' ELSE 'Administrative120h' END AS event120, -- 其余按优先级分类。
CASE WHEN deathtime<intime THEN NULL WHEN deathtime IS NULL THEN false ELSE deathtime<intime+INTERVAL '28d' END AS death28 -- 负时序明确NULL。
FROM cs_cohort c JOIN cs_dx d USING(stay_id) -- 一次stay一个基线行。
LEFT JOIN LATERAL(SELECT spo2 FROM cs_vitals WHERE stay_id=c.stay_id AND spo2 IS NOT NULL ORDER BY charttime DESC LIMIT 1)s ON true -- 最新有效SpO2。
LEFT JOIN LATERAL(SELECT rr FROM cs_vitals WHERE stay_id=c.stay_id AND rr IS NOT NULL ORDER BY charttime DESC LIMIT 1)r ON true; -- 最新有效RR。
-- @block bloodgas
CREATE TEMP TABLE cs_bg AS -- 行政窗内血气先留TEMP作时序质控。
SELECT c.stay_id,b.charttime,b.specimen,b.po2,COALESCE(b.fio2,b.fio2_chartevents) AS fio2,b.pao2fio2ratio AS pf, -- 主PF直接用派生字段。
100*b.po2/NULLIF(COALESCE(b.fio2,b.fio2_chartevents),0) AS pf_recalculated,c.t0,c.t_imv,c.admin_end, -- 重算仅用于核查。
o.device_code AS current_device -- 前八小时最后非空分类。
FROM mimiciv_derived.bg b JOIN cs_cohort c ON b.subject_id=c.subject_id AND b.hadm_id=c.hadm_id -- 双ID关联。
LEFT JOIN LATERAL(SELECT device_code FROM cs_od WHERE stay_id=c.stay_id AND device_code IS NOT NULL -- 不只查合格装置。
AND charttime BETWEEN b.charttime-INTERVAL '8h' AND b.charttime ORDER BY charttime DESC,device_code DESC LIMIT 1)o ON true -- 同刻优先较高装置。
WHERE b.charttime>=c.t0 AND b.charttime<c.admin_end; -- 行政终点严格不含。
CREATE TEMP TABLE cs_pf80 AS -- 对每stay独立查首次合格血气。
SELECT DISTINCT ON(g.stay_id) g.*,c.device_code AS baseline_device, -- 保留阈值时装置与基线装置。
COALESCE(g.t_imv BETWEEN g.charttime AND g.charttime+INTERVAL '3h' AND g.t_imv<=g.admin_end,false) AS imv_3h, -- 阳性含恰3小时。
COALESCE(g.t_imv>=g.charttime AND g.t_imv<g.charttime+INTERVAL '3h' AND g.t_imv<=g.admin_end,false) AS imv_strict3h -- 严格三小时敏感性。
FROM cs_bg g JOIN cs_cohort c USING(stay_id) WHERE g.specimen='ART.' AND g.po2>0 AND g.fio2 BETWEEN 20 AND 100 -- 动脉及有效FiO2。
AND g.pf>0 AND g.pf<80 AND (g.t_imv IS NULL OR g.charttime<g.t_imv) AND g.current_device BETWEEN 3 AND 5 -- 严格插管前且当前装置合格。
ORDER BY g.stay_id,g.charttime,g.pf; -- 同刻取较低PF。
CREATE UNIQUE INDEX ON cs_pf80(stay_id); -- 每人最多首次达标一次。
-- @block aggregate_flow
SELECT jsonb_build_object('all_icu_stays',(SELECT COUNT(*) FROM mimiciv_icu.icustays),'joined_base',COUNT(*), -- 检查原始与连接行数。
'adult',COUNT(*) FILTER(WHERE adult),'nonsurgical',COUNT(*) FILTER(WHERE adult AND nonsurgical), -- 基础逐层人数。
'base_valid',COUNT(*) FILTER(WHERE adult AND nonsurgical AND base_valid), -- 共同定义基础排除后。
'candidate_rows',(SELECT COUNT(*) FROM cs_candidate_rows),'candidate_stays',(SELECT COUNT(*) FROM cs_candidate), -- 完成逐候选条件后。
'no_limit_stays',(SELECT COUNT(*) FROM cs_eligible),'cohort_patients',(SELECT COUNT(*) FROM cs_cohort), -- 限制排除与患者去重后。
'cohort_no_code_status',(SELECT COUNT(*) FROM cs_cohort WHERE code_records=0)) AS result FROM cs_base; -- 缺治疗限制记录单报。
-- @block aggregate_pf80
SELECT COUNT(*) AS met,COUNT(*) FILTER(WHERE imv_3h) AS imv_3h, -- 主分母完整保留。
ROUND(100.0*COUNT(*) FILTER(WHERE imv_3h)/NULLIF(COUNT(*),0),6) AS pct, -- 百分比保留精度。
COUNT(*) FILTER(WHERE imv_strict3h) AS imv_strict3h,COUNT(*) FILTER(WHERE t_imv=charttime+INTERVAL '3h' AND t_imv<=admin_end) AS imv_exact3h, -- 三小时边界。
COUNT(*) FILTER(WHERE t_imv IS NULL AND admin_end<charttime+INTERVAL '3h') AS never_imv_short3h, -- 完全无IMV且短随访。
COUNT(*) FILTER(WHERE NOT imv_3h AND admin_end<charttime+INTERVAL '3h') AS no_observed_imv_short3h FROM cs_pf80; -- 无阳性且短随访。
-- @block aggregate_pf80_baseline_device
SELECT baseline_device,COUNT(*) AS met,COUNT(*) FILTER(WHERE imv_3h) AS imv_3h, -- 基线装置分层的分母。
ROUND(100.0*COUNT(*) FILTER(WHERE imv_3h)/NULLIF(COUNT(*),0),6) AS pct FROM cs_pf80 GROUP BY 1 ORDER BY 1; -- 与阈值装置分层区分。
-- @block aggregate_pf80_current_device
SELECT current_device,COUNT(*) AS met,COUNT(*) FILTER(WHERE imv_3h) AS imv_3h FROM cs_pf80 GROUP BY 1 ORDER BY 1; -- 阈值当下装置额外分层。
-- @block aggregate_table2_categorical
SELECT v.variable,v.category,COUNT(*) AS n,ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM cs_table2),6) AS pct -- 主队列完整分母。
FROM cs_table2 t CROSS JOIN LATERAL(VALUES('age',age_group),('anchor_age',anchor_age_group),('sex',gender::text), -- 两种年龄与性别。
('race_extended',race_group),('race_author',race_author),('anchor_year_group',anchor_year_group),('icu',icu_group), -- 来源定义对照。
('baseline_device',device_code::text),('fio2_source',fio2_source),('event120',event120),('death28',COALESCE(death28::text,'NULL')), -- 结局NULL不归存活。
('copd_author',copd::text),('chf_author',chf::text),('copd_classroom',classroom_copd::text),('chf_classroom',classroom_chf::text))v(variable,category) -- 合并症定义对照。
GROUP BY 1,2 ORDER BY 1,2; -- 仅输出聚合。
-- @block aggregate_table2_continuous
SELECT v.variable,COUNT(*) AS total,COUNT(v.value) AS observed,COUNT(*)-COUNT(v.value) AS missing, -- 每项单独缺失。
percentile_cont(ARRAY[.25,.5,.75]) WITHIN GROUP(ORDER BY v.value) AS quartiles -- 同一有效分母四分位。
FROM cs_table2 CROSS JOIN LATERAL(VALUES('FiO2',fio2::double precision),('SpO2_12h',spo2::double precision), -- 12小时基线。
('RR_12h',rr::double precision),('admission_age',age::double precision),('anchor_age',anchor_age::double precision))v(variable,value) GROUP BY 1 ORDER BY 1; -- 基线变量。
-- @block aggregate_ever_devices
SELECT o.device_code,COUNT(DISTINCT o.stay_id) AS n FROM cs_od o JOIN cs_cohort c USING(stay_id) -- 三种曾用装置可重叠。
WHERE o.charttime>=c.t0 AND o.charttime<c.risk_end AND o.device_code BETWEEN 3 AND 5 GROUP BY 1 ORDER BY 1; -- 区间右端严格排除。
-- @block aggregate_temporal_sensitivity
SELECT 'main' AS scenario,COUNT(*) AS cohort,COUNT(death28) AS death28_evaluable, -- 主队列时序异常不静默删除。
COUNT(*) FILTER(WHERE death28) AS death28,COUNT(*) FILTER(WHERE death28 IS NULL) AS death28_unknown, -- NULL明确展示。
(SELECT COUNT(*) FROM cs_pf80) AS pf80,(SELECT COUNT(*) FROM cs_pf80 WHERE imv_3h) AS imv_3h FROM cs_table2 -- 全部主结果。
UNION ALL SELECT 'exclude_negative_death_from_selected_cohort',COUNT(*),COUNT(death28),COUNT(*) FILTER(WHERE death28),COUNT(*) FILTER(WHERE death28 IS NULL), -- 仅剔除已选负时序，不替补。
(SELECT COUNT(*) FROM cs_pf80 p JOIN cs_cohort c USING(stay_id) WHERE c.deathtime IS NULL OR c.deathtime>=c.intime), -- 敏感性阈值分母。
(SELECT COUNT(*) FROM cs_pf80 p JOIN cs_cohort c USING(stay_id) WHERE (c.deathtime IS NULL OR c.deathtime>=c.intime) AND p.imv_3h) -- 敏感性分子。
FROM cs_table2 WHERE deathtime IS NULL OR deathtime>=intime; -- 只剔除负时间病例。
-- @block aggregate_event_sensitivity
SELECT event120,COUNT(*) AS main,COUNT(*) FILTER(WHERE deathtime IS NULL OR deathtime>=intime) AS excluding_negative_death -- 首结局敏感性。
FROM cs_table2 GROUP BY 1 ORDER BY 1; -- 四类各自汇总。
-- @block aggregate_code_audit
SELECT itemid,value,COUNT(*) AS records,COUNT(DISTINCT stay_id) AS stays FROM cs_code GROUP BY 1,2 ORDER BY 1,2; -- 候选stay治疗限制文本审计。
-- @block aggregate_qc
SELECT jsonb_build_object('cohort_rows',(SELECT COUNT(*) FROM cs_cohort),'cohort_patients',(SELECT COUNT(DISTINCT subject_id) FROM cs_cohort), -- 防患者重复。
'cohort_stays',(SELECT COUNT(DISTINCT stay_id) FROM cs_cohort),'pf80_rows',(SELECT COUNT(*) FROM cs_pf80), -- 防阈值重复。
'pf80_unique',(SELECT COUNT(DISTINCT stay_id) FROM cs_pf80),'null_outcome',(SELECT COUNT(*) FROM cs_pf80 WHERE imv_3h IS NULL), -- 结局无NULL。
'pf_before_t0',(SELECT COUNT(*) FROM cs_pf80 WHERE charttime<t0),'pf_at_or_after_imv',(SELECT COUNT(*) FROM cs_pf80 WHERE charttime>=t_imv), -- 严格时序。
'pf_at_or_after_admin',(SELECT COUNT(*) FROM cs_pf80 WHERE charttime>=admin_end),'bad_pf_fio2',(SELECT COUNT(*) FROM cs_pf80 WHERE fio2 NOT BETWEEN 20 AND 100), -- 截尾及范围。
'pf_recompute_mismatch',(SELECT COUNT(*) FROM cs_bg WHERE abs(pf-pf_recalculated)>0.00001), -- 派生PF独立核对。
'negative_death_icu',(SELECT COUNT(*) FROM cs_cohort WHERE deathtime<intime),'negative_death_eligibility',(SELECT COUNT(*) FROM cs_cohort WHERE deathtime<t0), -- 两个时间基点不能混淆。
'death_imv_ties',(SELECT COUNT(*) FROM cs_cohort WHERE deathtime=t_imv),'death_discharge_ties',(SELECT COUNT(*) FROM cs_cohort WHERE deathtime=outtime), -- 同刻冲突。
'imv_discharge_ties',(SELECT COUNT(*) FROM cs_cohort WHERE t_imv=outtime),'event_total',(SELECT COUNT(*) FROM cs_table2), -- 完整分母。
'future_vitals',(SELECT COUNT(*) FROM cs_vitals v JOIN cs_cohort c USING(stay_id) WHERE v.charttime>c.t0), -- 防基线未来数据。
'no_code_status',(SELECT COUNT(*) FROM cs_cohort WHERE code_records=0)) AS result; -- 无记录并非Full code。
-- @block aggregate_device_qc
SELECT current_device,COUNT(*) AS arterial_lowpf_records, -- 行政窗内观察动脉低PF记录，不是患者数。
COUNT(*) FILTER(WHERE t_imv IS NULL OR charttime<t_imv) AS before_imv -- 分离插管前后。
FROM cs_bg WHERE specimen='ART.' AND po2>0 AND pf>0 AND pf<80 AND fio2 BETWEEN 20 AND 100 GROUP BY 1 ORDER BY 1; -- 解释装置风险集过滤。
-- @block finish
ROLLBACK; -- 最后撤销全部临时对象和索引，永久数据不变。

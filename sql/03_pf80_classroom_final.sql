-- MIMIC-IV SQL 期末小组作业：PF<80 单阈值教学适配（公开仓库中的课程适配脚本）。
-- 数据：真实 MIMIC-IV 2.2；数据库 mimic4；PostgreSQL 16.15；执行日期 2026-11-15。
-- 来源：课程 PPT 第38–46、52–56页；Yarnell 2023 DOI 10.1164/rccm.202206-1092OC。
-- 作者代码基线：Zenodo v1.0.1 DOI 10.5281/zenodo.6505220；不是完整论文复现。
-- 在新建查询会话中完整执行；仅创建TEMP临时表，末尾ROLLBACK清理，不改永久表。
-- 只打印汇总，不导出患者级ID、事件时间或临床明细。
-- t0=首次装置与FiO2同时满足入组条件的时刻；intime=ICU入住，二者不能混用。
-- t_pf80=入组后在尚未插管的随访内首次记录到动脉PF<80；不要求此前PF>=80。
-- FiO2保存为百分数时PF=100*PaO2/FiO2；PaO2单位mmHg。
-- 课堂同charttime入组、NRB流量估计、阈值装置8h沿用和扩展治疗状态字段均为本地适配。
-- 主分析排除两种Code Status中明确CMO/DNI；仅用作者228687的结果作为敏感性对照。
-- 三小时主结果含恰好3h边界；另报<3h以对照作者R代码；观察不足3h仍留在分母并单报。
-- Q1 字段与字典已在预检文件核对；以下依次完成Q2队列、Q3入组、Q4结局、Q5汇总/基线、Q6质控。
BEGIN; -- 开启事务，把本次临时分析集中在一个会话中。
SET LOCAL statement_timeout = '15min'; -- 每条查询最长15分钟，防止无期限运行。
SET LOCAL max_parallel_workers_per_gather = 0; -- 单线程读取，减少外置盘并发压力。
SET LOCAL application_name = 'mimic-sql-pbl-final'; -- 给本次查询命名，便于查看状态；不含患者信息。


-- Q0/Q1：确认连接与关键字典，只输出数据库/字典信息，不输出患者记录。
SELECT current_database() AS database_name,current_setting('server_version') AS postgresql_version; -- 选择显示或计算的列；每层结果粒度由本层GROUP BY或去重规则决定。
SELECT itemid,label,linksto FROM mimiciv_icu.d_items WHERE itemid IN (223835,226732,223834,223758,228687,229784) ORDER BY itemid; -- 选择显示或计算的列；每层结果粒度由本层GROUP BY或去重规则决定。
SELECT itemid,label,fluid FROM mimiciv_hosp.d_labitems WHERE itemid IN (50816,50820,50821,50818) ORDER BY itemid; -- 选择显示或计算的列；每层结果粒度由本层GROUP BY或去重规则决定。

-- Q2：一行代表一次ICU入住，年龄使用本次住院年龄，而非直接使用anchor_age。
CREATE TEMP TABLE pbl_stays ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_stays；提交时自动清理。
SELECT i.subject_id, i.hadm_id, i.stay_id, i.intime, i.outtime, -- 选取或计算患者编号、住院编号、ICU入住编号、ICU入住时刻、ICU转出时刻。
       i.first_careunit, a.deathtime, a.admission_type, a.discharge_location, -- 保留首次ICU科室、院内死亡时刻、入院类型和出院去向，用于排除与随访。
       d.admission_age, p.gender, a.race, p.anchor_year_group -- 选取或计算本次住院年龄、性别、种族记录、脱敏前参照年代分组。
FROM mimiciv_icu.icustays i -- 指定本层数据来源；别名只在当前查询中有效。
JOIN mimiciv_hosp.admissions a USING (hadm_id, subject_id) -- 按所写编号连接；只保留能匹配的记录，避免跨患者混接。
JOIN mimiciv_hosp.patients p USING (subject_id) -- 按所写编号连接；只保留能匹配的记录，避免跨患者混接。
JOIN mimiciv_derived.icustay_detail d USING (stay_id); -- 按所写编号连接；只保留能匹配的记录，避免跨患者混接。
CREATE UNIQUE INDEX ON pbl_stays(stay_id); -- 为上一张临时表建立唯一索引，同时检查同一键是否重复。
ANALYZE pbl_stays; -- 更新临时表统计信息，帮助数据库选择高效执行方法。

CREATE TEMP TABLE pbl_vent ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_vent；提交时自动清理。
SELECT stay_id, -- 选取或计算ICU入住编号。
       MIN(starttime) FILTER (WHERE ventilation_status='InvasiveVent') AS t_imv, -- 只在指定通气状态内取最早开始时刻；从未发生则为NULL。
       MIN(starttime) FILTER (WHERE ventilation_status='Tracheostomy') AS t_trach -- 只在指定通气状态内取最早开始时刻；从未发生则为NULL。
FROM mimiciv_derived.ventilation GROUP BY stay_id; -- 指定本层数据来源；别名只在当前查询中有效。
CREATE UNIQUE INDEX ON pbl_vent(stay_id); -- 为上一张临时表建立唯一索引，同时检查同一键是否重复。

-- Q3：读取全部4个装置字段；同刻并存时优先级：气切7>有创6>NIV5>HFNC4>NRB3。
CREATE TEMP TABLE pbl_devices ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_devices；提交时自动清理。
SELECT od.stay_id, od.charttime, od.o2_flow, -- 选取或计算ICU入住编号、测量时刻。
       btrim(od.o2_delivery_device_1) AS device1, dc.device_code -- 去除第1装置字段首尾空格，并保留四槽综合分类。
FROM mimiciv_derived.oxygen_delivery od -- 指定本层数据来源；别名只在当前查询中有效。
CROSS JOIN LATERAL ( -- 对当前行的四个装置字段逐一分类。
    SELECT MAX(CASE -- 按分类数值取最高优先级；CASE逐个判断装置。
        WHEN btrim(x) IN ('Tracheostomy tube','Trach mask') THEN 7 -- 气切管或气切面罩编码7，最高优先级。
        WHEN btrim(x)='Endotracheal tube' THEN 6 -- 气管插管编码6，属于有创装置。
        WHEN btrim(x) IN ('Bipap mask','CPAP mask') THEN 5 -- BiPAP或CPAP面罩编码5，为NIV。
        WHEN btrim(x)='High flow nasal cannula' THEN 4 -- 高流量鼻导管编码4，为HFNC。
        WHEN btrim(x)='Non-rebreather' THEN 3 -- 非重复呼吸面罩编码3，为NRB。
        WHEN btrim(x)='Nasal cannula' THEN 1 -- 普通鼻导管编码1，不是合格入组装置。
        WHEN btrim(x)='None' THEN 0 -- 明确无装置编码0，不能沿用为仍在NRB/NIV/HFNC。
        WHEN x IS NOT NULL THEN 2 END) AS device_code -- 其余非空装置归2；全为空则分类仍为空。
    FROM unnest(ARRAY[od.o2_delivery_device_1,od.o2_delivery_device_2, -- 把四个装置字段展开，允许同一时刻检查全部装置。
                     od.o2_delivery_device_3,od.o2_delivery_device_4]) AS u(x) -- 把第3、第4槽也放入数组；x代表当前展开的一个装置值。
) dc; -- 结束当前子查询、函数或临时表定义。
CREATE INDEX ON pbl_devices(stay_id,charttime); -- 建立临时索引，加快按ICU入住和时间查询。
ANALYZE pbl_devices; -- 更新临时表统计信息，帮助数据库选择高效执行方法。

CREATE TEMP TABLE pbl_fio2 ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_fio2；提交时自动清理。
SELECT stay_id, charttime, AVG(fio2) AS fio2_pct -- 在同一次ICU、同一时刻合并FiO2记录，保存百分数。
FROM mimiciv_derived.ventilator_setting -- 指定本层数据来源；别名只在当前查询中有效。
WHERE fio2 BETWEEN 20 AND 100 GROUP BY stay_id,charttime; -- 保留FiO2 20%至100%，然后按ICU入住与时刻分组。
CREATE UNIQUE INDEX ON pbl_fio2(stay_id,charttime); -- 为上一张临时表建立唯一索引，同时检查同一键是否重复。
ANALYZE pbl_fio2; -- 更新临时表统计信息，帮助数据库选择高效执行方法。

-- 入组装置和FiO2必须同一stay_id、同一charttime；这是课堂严格同时点的简化。
-- 仅NRB缺少实测FiO2时可用流量估计；HFNC/NIV的高流量不能这样换算。
CREATE TEMP TABLE pbl_oxygen_candidates ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_oxygen_candidates；提交时自动清理。
SELECT s.*, o.charttime AS t0, o.device_code, v.t_imv, v.t_trach, -- 选取或计算氧疗装置分类、入组时刻、首次有创通气时刻、首次气切时刻、测量时刻。
       COALESCE(f.fio2_pct, -- 按从左到右取首个非空值；这里只按写明的研究规则补默认值。
           CASE WHEN o.device_code=3 AND o.device1='Non-rebreather' -- 只有NRB且第1槽明确为NRB时，才允许用其流量补FiO2。
                THEN CASE WHEN o.o2_flow>25 AND o.o2_flow<=100 THEN o.o2_flow -- 按作者分支，将NRB流量栏中>25至100的值视为误录FiO2百分数。
                          WHEN o.o2_flow>0 AND 21+3*o.o2_flow<=100 -- 其余仅接受正流量且换算FiO2不超过100%的记录。
                          THEN 21+3*o.o2_flow END END) AS fio2_pct, -- 采用FiO2%=21+3×流量(L/min)的近似；有实测时优先实测。
       (f.fio2_pct IS NULL) AS used_flow_estimate -- 标记是否缺少实测；成功入组的这类记录依赖流量估计。
FROM pbl_stays s -- 指定本层数据来源；别名只在当前查询中有效。
JOIN pbl_devices o USING (stay_id) -- 按所写编号连接；只保留能匹配的记录，避免跨患者混接。
LEFT JOIN pbl_fio2 f ON f.stay_id=o.stay_id AND f.charttime=o.charttime -- 左连接，保留左表全部对象；无匹配时右表记为NULL。
LEFT JOIN pbl_vent v ON v.stay_id=s.stay_id -- 左连接，保留左表全部对象；无匹配时右表记为NULL。
WHERE s.admission_age>=18 -- 只纳入本次住院年龄至少18岁的成人。
  AND s.admission_type NOT IN ('ELECTIVE','SURGICAL SAME DAY ADMISSION') -- 排除择期和当日手术住院，不把所有手术患者一概删除。
  AND s.discharge_location IS NOT NULL AND s.outtime>s.intime -- 要求出院去向有记录，且ICU转出晚于入住。
  AND o.charttime BETWEEN s.intime-INTERVAL '6h' AND s.intime+INTERVAL '24h' -- 限制入组观察窗：ICU入住前6小时至后24小时，含两端。
  AND o.charttime<=s.outtime -- 入组记录不能晚于本次ICU转出。
  AND o.device_code IN (3,4,5); -- 只接受NRB、HFNC、NIV三类装置入组。

-- 先判断全部入住是否合格，最后才取每人的首次合格入住，避免提前去重漏人。
CREATE TEMP TABLE pbl_preeligible ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_preeligible；提交时自动清理。
SELECT DISTINCT ON (stay_id) * -- 每次ICU入住只取最早满足所有入组条件的一行。
FROM pbl_oxygen_candidates -- 指定本层数据来源；别名只在当前查询中有效。
WHERE fio2_pct BETWEEN 40 AND 100 -- 逐行保留满足条件的记录；NULL比较不会自动视为真。
  AND (t_imv IS NULL OR t_imv>t0+INTERVAL '30min') -- 排除入组时已插管或入组后30分钟内插管的入住。
  AND (t_trach IS NULL OR t_trach>t0+INTERVAL '120h') -- 排除入组后120小时内已经记录气切的入住。
  AND LEAST(outtime,deathtime,t0+INTERVAL '120h')>t0 -- 还须同时满足这一项条件，不能仅满足前一项。
ORDER BY stay_id,t0,device_code DESC,fio2_pct DESC; -- 明确排序；DISTINCT ON将按此顺序保留每组第一行。
CREATE UNIQUE INDEX ON pbl_preeligible(stay_id); -- 为上一张临时表建立唯一索引，同时检查同一键是否重复。
ANALYZE pbl_preeligible; -- 更新临时表统计信息，帮助数据库选择高效执行方法。

-- 本地没有code_status表；从字典核验的三个原始itemid取数，主分析扩展，作者口径单列。
-- 治疗限制取数会扫描大表，耗时较长；未记录不等于已确认无治疗限制。
CREATE TEMP TABLE pbl_code_records ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_code_records；提交时自动清理。
SELECT c.stay_id,c.itemid, -- 选取或计算ICU入住编号。
       regexp_replace(btrim(c.value),'[[:space:]]+',' ','g') AS code_value -- 先去首尾空白，再把连续空白合成一个空格，统一状态文字。
FROM mimiciv_icu.chartevents c -- 指定本层数据来源；别名只在当前查询中有效。
JOIN pbl_preeligible e ON e.stay_id=c.stay_id -- 按所写编号连接；只保留能匹配的记录，避免跨患者混接。
WHERE c.itemid IN (223758,228687,229784) AND c.charttime<e.intime+INTERVAL '144h'; -- 治疗目标取三个字典条目，时间截止ICU入住后144h；229784在当前库无记录。

CREATE TEMP TABLE pbl_goc ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_goc；提交时自动清理。
SELECT stay_id, -- 选取或计算ICU入住编号。
       COUNT(*) AS code_status_records, -- 计算每次候选ICU所查治疗状态的记录条数，不是患者数。
       COUNT(*) FILTER(WHERE itemid=228687) AS author_code_records, -- 条件计数：只计算满足括号内条件的行，NULL不会自动算阳性。
       BOOL_OR(code_value IN ('Comfort measures only','DNR / DNI', -- CMO或DNR/DNI组合表示记录限制插管；单独DNR不在此排除。
         'DNAR (Do Not Attempt Resuscitation) [DNR] / DNI','DNI (do not intubate)')) AS limits_intubation, -- 主分析也排除明确DNI；单独DNR字符串不在集合中。
       BOOL_OR(itemid=228687 AND code_value IN ('Comfort measures only', -- CMO或DNR/DNI组合表示记录限制插管；单独DNR不在此排除。
         'DNAR (Do Not Attempt Resuscitation) [DNR] / DNI')) AS author_limits_intubation -- 敏感性分析只保留作者228687字段的两个原始排除值。
FROM pbl_code_records GROUP BY stay_id; -- 按ICU入住合并治疗状态，每个stay_id只产生一行判断。
CREATE UNIQUE INDEX ON pbl_goc(stay_id); -- 为上一张临时表建立唯一索引，同时检查同一键是否重复。

-- 对照：完全保留作者只用228687及其两个排除值的口径，其他步骤和主分析相同。
CREATE TEMP TABLE pbl_author_eligible ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_author_eligible；提交时自动清理。
SELECT DISTINCT ON (e.subject_id) e.*, -- 按患者去重；下方按ICU入住时间排序后保留首次合格入住。
       LEAST(e.outtime,e.deathtime,e.t0+INTERVAL '120h') AS followup_end -- 取转出、院内死亡和入组后120小时中最早者，定义随访终点。
FROM pbl_preeligible e LEFT JOIN pbl_goc g USING(stay_id) -- 指定本层数据来源；别名只在当前查询中有效。
WHERE NOT COALESCE(g.author_limits_intubation,FALSE) -- 排除已记录的插管限制；缺少记录保留，但在缺失汇总中单列。
ORDER BY e.subject_id,e.intime,e.stay_id; -- 明确排序；DISTINCT ON将按此顺序保留每组第一行。
CREATE UNIQUE INDEX ON pbl_author_eligible(stay_id); -- 为上一张临时表建立唯一索引，同时检查同一键是否重复。
ANALYZE pbl_author_eligible; -- 更新临时表统计信息，帮助数据库选择高效执行方法。

CREATE TEMP TABLE pbl_eligible ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_eligible；提交时自动清理。
SELECT DISTINCT ON (e.subject_id) e.*, -- 按患者去重；下方按ICU入住时间排序后保留首次合格入住。
       COALESCE(g.code_status_records,0) AS code_status_records, -- 按从左到右取首个非空值；这里只按写明的研究规则补默认值。
       LEAST(e.outtime,e.deathtime,e.t0+INTERVAL '120h') AS followup_end -- 取转出、院内死亡和入组后120小时中最早者，定义随访终点。
FROM pbl_preeligible e LEFT JOIN pbl_goc g USING (stay_id) -- 指定本层数据来源；别名只在当前查询中有效。
WHERE NOT COALESCE(g.limits_intubation,FALSE) -- 排除已记录的插管限制；缺少记录保留，但在缺失汇总中单列。
ORDER BY e.subject_id,e.intime,e.stay_id; -- 明确排序；DISTINCT ON将按此顺序保留每组第一行。
CREATE UNIQUE INDEX ON pbl_eligible(stay_id); -- 为上一张临时表建立唯一索引，同时检查同一键是否重复。
ANALYZE pbl_eligible; -- 更新临时表统计信息，帮助数据库选择高效执行方法。

-- Q4：只取明确ART.动脉血；必须在入组后、随访结束前且插管前。
CREATE TEMP TABLE pbl_pf80 ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_pf80；提交时自动清理。
SELECT DISTINCT ON (e.stay_id) e.*, -- 每次合格入住只保留首次达标血气，不把多次血气重复计作多人。
       b.charttime AS t_pf80,b.pao2fio2ratio AS pf_ratio,b.specimen, -- 选取或计算测量时刻、首次PF<80时刻。
       COALESCE(b.fio2,b.fio2_chartevents) AS threshold_fio2_pct, -- 按从左到右取首个非空值；这里只按写明的研究规则补默认值。
       current_device.device_code AS threshold_device_code -- 选取或计算氧疗装置分类。
FROM pbl_eligible e -- 指定本层数据来源；别名只在当前查询中有效。
JOIN mimiciv_derived.bg b ON b.hadm_id=e.hadm_id AND b.subject_id=e.subject_id -- 按所写编号连接；只保留能匹配的记录，避免跨患者混接。
JOIN LATERAL ( -- 对每次血气单独查询最近的氧疗装置记录。
    SELECT o.device_code FROM pbl_devices o -- 选取或计算氧疗装置分类。
    WHERE o.stay_id=e.stay_id AND o.charttime<=b.charttime -- 逐行保留满足条件的记录；NULL比较不会自动视为真。
      AND o.charttime>=b.charttime-INTERVAL '8h' AND o.device_code IS NOT NULL -- 只向前查8h内最后非空装置，空值不能覆盖上一条有效装置。
    ORDER BY o.charttime DESC,o.device_code DESC LIMIT 1 -- 按记录时刻倒序，只取最近非空装置；同刻时取高优先级。
) current_device ON current_device.device_code IN (3,4,5) -- 最近有效装置仍须是NRB/HFNC/NIV，才能判定阈值。
WHERE b.specimen='ART.' AND b.po2>0 AND b.pao2fio2ratio>0 AND b.pao2fio2ratio<80 -- 只纳入明确动脉血且PaO2和PF为正、PF严格小于80的血气。
  AND COALESCE(b.fio2,b.fio2_chartevents) BETWEEN 20 AND 100 -- 优先用同次血气FiO2，其次用bg配对的监护FiO2，限定20%至100%。
  AND b.charttime>=e.t0 AND b.charttime<e.followup_end -- 血气不能早于入组，且必须严格早于随访终点。
  AND (e.t_imv IS NULL OR b.charttime<e.t_imv) -- 排除插管同时或插管之后的血气，避免把结局后的低PF当暴露。
ORDER BY e.stay_id,b.charttime,b.pao2fio2ratio; -- 明确排序；DISTINCT ON将按此顺序保留每组第一行。
CREATE UNIQUE INDEX ON pbl_pf80(stay_id); -- 为上一张临时表建立唯一索引，同时检查同一键是否重复。

CREATE TEMP TABLE pbl_outcomes ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_outcomes；提交时自动清理。
SELECT h.*, -- 选择显示或计算的列；每层结果粒度由本层GROUP BY或去重规则决定。
       COALESCE(t_imv>=t_pf80 AND t_imv<=t_pf80+INTERVAL '3h' -- 按从左到右取首个非空值；这里只按写明的研究规则补默认值。
                AND t_imv<=followup_end,FALSE) AS imv_3h, -- 插管不得晚于随访截止；无插管或条件不满足记FALSE，保留分母。
       (followup_end<t_pf80+INTERVAL '3h' -- 选取或计算首次PF<80时刻、随访终点。
        AND (t_imv IS NULL OR t_imv>followup_end)) AS early_non_imv_end -- 还须同时满足这一项条件，不能仅满足前一项。
FROM pbl_pf80 h; -- 指定本层数据来源；别名只在当前查询中有效。

-- 课程延伸：按入组时装置分层。分母是本层达阈值人数，不是该层全部队列。
CREATE TEMP TABLE pbl_strata ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_strata；提交时自动清理。
SELECT CASE e.device_code WHEN 3 THEN 'NRB' WHEN 4 THEN 'HFNC' WHEN 5 THEN 'NIV' END AS baseline_device, -- 选取或计算氧疗装置分类。
       COUNT(*) AS cohort_n, -- 本装置层全部合格队列人数，不是插管率分母。
       COUNT(o.stay_id) AS threshold_n, -- 本装置层达阈值的人数，是本层比例的分母。
       COUNT(*) FILTER(WHERE o.imv_3h) AS imv_3h_n, -- 条件计数：只计算满足括号内条件的行，NULL不会自动算阳性。
       ROUND(100.0*COUNT(*) FILTER(WHERE o.imv_3h)/NULLIF(COUNT(o.stay_id),0),2) AS pct_3h -- 用达阈值人数作分母、三小时插管人数作分子，乘100得到百分比。
FROM pbl_eligible e LEFT JOIN pbl_outcomes o USING(stay_id) -- 指定本层数据来源；别名只在当前查询中有效。
GROUP BY e.device_code; -- 按指定编号或分类合并记录；组内用COUNT、MIN或BOOL_OR等计算。

-- 缺失质控：在尚未插管的随访内，看动脉血气和可计算PF覆盖，不能把未测当正常。
CREATE TEMP TABLE pbl_coverage ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_coverage；提交时自动清理。
SELECT e.stay_id, -- 选取或计算ICU入住编号。
       COUNT(b.charttime) AS arterial_bg_rows, -- 统计当前患者随访内明确动脉血气的记录条数。
       COUNT(b.pao2fio2ratio) FILTER(WHERE COALESCE(b.fio2,b.fio2_chartevents) BETWEEN 20 AND 100) AS valid_pf_rows, -- 统计FiO2在20%至100%且PF非空的动脉记录；不等于通过全部阈值条件。
       COUNT(*) FILTER(WHERE b.charttime IS NOT NULL AND COALESCE(b.fio2,b.fio2_chartevents) IS NULL) AS missing_fio2_rows, -- 条件计数：只计算满足括号内条件的行，NULL不会自动算阳性。
       COUNT(*) FILTER(WHERE b.charttime IS NOT NULL AND b.pao2fio2ratio IS NULL) AS missing_pf_rows -- 条件计数：只计算满足括号内条件的行，NULL不会自动算阳性。
FROM pbl_eligible e -- 指定本层数据来源；别名只在当前查询中有效。
LEFT JOIN mimiciv_derived.bg b ON b.subject_id=e.subject_id AND b.hadm_id=e.hadm_id -- 左连接，保留左表全部对象；无匹配时右表记为NULL。
 AND b.specimen='ART.' AND b.charttime>=e.t0 AND b.charttime<e.followup_end -- 覆盖检查只限明确动脉标本和随访窗；此处不筛PF<80或PaO2/PF正值。
 AND (e.t_imv IS NULL OR b.charttime<e.t_imv) -- 排除插管同时或插管之后的血气，避免把结局后的低PF当暴露。
GROUP BY e.stay_id; -- 按指定编号或分类合并记录；组内用COUNT、MIN或BOOL_OR等计算。

-- 基线分类汇总仅输出分组数量，不输出任何患者标识符或时间。
CREATE TEMP TABLE pbl_baseline_categories ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_baseline_categories；提交时自动清理。
SELECT 'sex' AS variable,COALESCE(gender::text,'MISSING') AS category,COUNT(*) AS n FROM pbl_eligible GROUP BY gender -- 按从左到右取首个非空值；这里只按写明的研究规则补默认值。
UNION ALL SELECT 'race',COALESCE(race,'MISSING'),COUNT(*) FROM pbl_eligible GROUP BY race -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 'first_careunit',COALESCE(first_careunit,'MISSING'),COUNT(*) FROM pbl_eligible GROUP BY first_careunit -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 'anchor_year_group',COALESCE(anchor_year_group,'MISSING'),COUNT(*) FROM pbl_eligible GROUP BY anchor_year_group; -- 把另一项计数追加到汇总；这里不连接患者明细。


CREATE TEMP TABLE pbl_author_pf80 ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_author_pf80；提交时自动清理。
SELECT DISTINCT ON (e.stay_id) e.*, -- 每次合格入住只保留首次达标血气，不把多次血气重复计作多人。
       b.charttime AS t_pf80,b.pao2fio2ratio AS pf_ratio,b.specimen, -- 选取或计算测量时刻、首次PF<80时刻。
       COALESCE(b.fio2,b.fio2_chartevents) AS threshold_fio2_pct, -- 按从左到右取首个非空值；这里只按写明的研究规则补默认值。
       current_device.device_code AS threshold_device_code -- 选取或计算氧疗装置分类。
FROM pbl_author_eligible e -- 指定本层数据来源；别名只在当前查询中有效。
JOIN mimiciv_derived.bg b ON b.hadm_id=e.hadm_id AND b.subject_id=e.subject_id -- 按所写编号连接；只保留能匹配的记录，避免跨患者混接。
JOIN LATERAL ( -- 对每次血气单独查询最近的氧疗装置记录。
    SELECT o.device_code FROM pbl_devices o -- 选取或计算氧疗装置分类。
    WHERE o.stay_id=e.stay_id AND o.charttime<=b.charttime -- 逐行保留满足条件的记录；NULL比较不会自动视为真。
      AND o.charttime>=b.charttime-INTERVAL '8h' AND o.device_code IS NOT NULL -- 只向前查8h内最后非空装置，空值不能覆盖上一条有效装置。
    ORDER BY o.charttime DESC,o.device_code DESC LIMIT 1 -- 按记录时刻倒序，只取最近非空装置；同刻时取高优先级。
) current_device ON current_device.device_code IN (3,4,5) -- 最近有效装置仍须是NRB/HFNC/NIV，才能判定阈值。
WHERE b.specimen='ART.' AND b.po2>0 AND b.pao2fio2ratio>0 AND b.pao2fio2ratio<80 -- 只纳入明确动脉血且PaO2和PF为正、PF严格小于80的血气。
  AND COALESCE(b.fio2,b.fio2_chartevents) BETWEEN 20 AND 100 -- 优先用同次血气FiO2，其次用bg配对的监护FiO2，限定20%至100%。
  AND b.charttime>=e.t0 AND b.charttime<e.followup_end -- 血气不能早于入组，且必须严格早于随访终点。
  AND (e.t_imv IS NULL OR b.charttime<e.t_imv) -- 排除插管同时或插管之后的血气，避免把结局后的低PF当暴露。
ORDER BY e.stay_id,b.charttime,b.pao2fio2ratio; -- 明确排序；DISTINCT ON将按此顺序保留每组第一行。
CREATE UNIQUE INDEX ON pbl_author_pf80(stay_id); -- 为上一张临时表建立唯一索引，同时检查同一键是否重复。


CREATE TEMP TABLE pbl_sensitivity ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_sensitivity；提交时自动清理。
SELECT 'expanded_code_status' AS definition, -- 选择显示或计算的列；每层结果粒度由本层GROUP BY或去重规则决定。
       (SELECT COUNT(*) FROM pbl_eligible) AS cohort_n,COUNT(*) AS threshold_n, -- 继续当前表达式；与上下行共同完成本段计算。
       COUNT(*) FILTER(WHERE imv_3h) AS imv_3h_n, -- 条件计数：只计算满足括号内条件的行，NULL不会自动算阳性。
       ROUND(100.0*COUNT(*) FILTER(WHERE imv_3h)/NULLIF(COUNT(*),0),2) AS pct_3h -- 用达阈值人数作分母、三小时插管人数作分子，乘100得到百分比。
FROM pbl_outcomes -- 指定本层数据来源；别名只在当前查询中有效。
UNION ALL -- 继续当前表达式；与上下行共同完成本段计算。
SELECT 'author_item228687_only', (SELECT COUNT(*) FROM pbl_author_eligible),COUNT(*), -- 选择显示或计算的列；每层结果粒度由本层GROUP BY或去重规则决定。
       COUNT(*) FILTER(WHERE COALESCE(t_imv>=t_pf80 AND t_imv<=t_pf80+INTERVAL '3h' AND t_imv<=followup_end,FALSE)), -- 条件计数：只计算满足括号内条件的行，NULL不会自动算阳性。
       ROUND(100.0*COUNT(*) FILTER(WHERE COALESCE(t_imv>=t_pf80 AND t_imv<=t_pf80+INTERVAL '3h' AND t_imv<=followup_end,FALSE))/NULLIF(COUNT(*),0),2) -- 用达阈值人数作分母、三小时插管人数作分子，乘100得到百分比。
FROM pbl_author_pf80; -- 指定本层数据来源；别名只在当前查询中有效。

-- 基线合并症使用作者Baseline_4的代码集合，并显式区分ICD9/10；不等同所有肺病。
CREATE TEMP TABLE pbl_dx ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_dx；提交时自动清理。
SELECT d.hadm_id, -- 选取或计算住院编号。
       BOOL_OR((d.icd_version=9 AND btrim(d.icd_code) IN -- 组内任一记录满足条件就标真，避免诊断多行导致人数膨胀。
                 ('496','49121')) OR -- 继续当前表达式；与上下行共同完成本段计算。
               (d.icd_version=10 AND btrim(d.icd_code) IN -- 继续当前表达式；与上下行共同完成本段计算。
                 ('J449','J441','J440','J439'))) AS copd, -- 继续当前表达式；与上下行共同完成本段计算。
       BOOL_OR((d.icd_version=9 AND btrim(d.icd_code) IN -- 组内任一记录满足条件就标真，避免诊断多行导致人数膨胀。
                 ('4280','42833','42832','4254','42843')) OR -- 继续当前表达式；与上下行共同完成本段计算。
               (d.icd_version=10 AND btrim(d.icd_code) IN -- 继续当前表达式；与上下行共同完成本段计算。
                 ('I110','I5033','I130','I5023','I255','I5032','I509','I429','I5022','I420'))) AS chf -- 继续当前表达式；与上下行共同完成本段计算。
FROM mimiciv_hosp.diagnoses_icd d -- 指定本层数据来源；别名只在当前查询中有效。
JOIN (SELECT DISTINCT hadm_id FROM pbl_eligible) e USING (hadm_id) -- 按所写编号连接；只保留能匹配的记录，避免跨患者混接。
GROUP BY d.hadm_id; -- 按指定编号或分类合并记录；组内用COUNT、MIN或BOOL_OR等计算。

CREATE TEMP TABLE pbl_flow ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_flow；提交时自动清理。
SELECT 1 AS seq,'source_icu_stays' AS step,COUNT(*) AS n FROM pbl_stays -- 选择显示或计算的列；每层结果粒度由本层GROUP BY或去重规则决定。
UNION ALL SELECT 2,'adult_non_elective_with_outcome',COUNT(*) FROM pbl_stays -- 把另一项计数追加到汇总；这里不连接患者明细。
 WHERE admission_age>=18 AND admission_type NOT IN ('ELECTIVE','SURGICAL SAME DAY ADMISSION') -- 排除择期和当日手术住院，不把所有手术患者一概删除。
   AND discharge_location IS NOT NULL AND outtime>intime -- 要求出院去向有记录，且ICU转出晚于入住。
UNION ALL SELECT 3,'eligible_device_observed',COUNT(DISTINCT stay_id) FROM pbl_oxygen_candidates -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 4,'device_and_fio2_ge40',COUNT(DISTINCT stay_id) FROM pbl_oxygen_candidates -- 把另一项计数追加到汇总；这里不连接患者明细。
 WHERE fio2_pct BETWEEN 40 AND 100 -- 逐行保留满足条件的记录；NULL比较不会自动视为真。
UNION ALL SELECT 5,'no_prior_imv_or_trach',COUNT(*) FROM pbl_preeligible -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 6,'no_documented_intubation_limit_expanded',COUNT(*) FROM pbl_preeligible e -- 把另一项计数追加到汇总；这里不连接患者明细。
 LEFT JOIN pbl_goc g USING(stay_id) WHERE NOT COALESCE(g.limits_intubation,FALSE) -- 左连接，保留左表全部对象；无匹配时右表记为NULL。
UNION ALL SELECT 7,'first_eligible_stay_per_patient',COUNT(*) FROM pbl_eligible -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 8,'first_arterial_pf_lt80',COUNT(*) FROM pbl_outcomes -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 9,'imv_within_3h',COUNT(*) FROM pbl_outcomes WHERE imv_3h; -- 把另一项计数追加到汇总；这里不连接患者明细。

CREATE TEMP TABLE pbl_qc ON COMMIT DROP AS -- 建立只在本会话存在的临时表：pbl_qc；提交时自动清理。
SELECT 'duplicate_patients' AS check_name, -- 选择显示或计算的列；每层结果粒度由本层GROUP BY或去重规则决定。
       COUNT(*)-COUNT(DISTINCT subject_id) AS failures FROM pbl_eligible -- 选取或计算患者编号。
UNION ALL SELECT 'duplicate_threshold_stays',COUNT(*)-COUNT(DISTINCT stay_id) FROM pbl_outcomes -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 'threshold_before_eligibility',COUNT(*) FROM pbl_outcomes WHERE t_pf80<t0 -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 'threshold_after_imv',COUNT(*) FROM pbl_outcomes WHERE t_pf80>=t_imv -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 'threshold_after_followup',COUNT(*) FROM pbl_outcomes WHERE t_pf80>=followup_end -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 'nonarterial_threshold',COUNT(*) FROM pbl_outcomes WHERE specimen<>'ART.' -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 'invalid_threshold_fio2',COUNT(*) FROM pbl_outcomes WHERE threshold_fio2_pct NOT BETWEEN 20 AND 100 OR threshold_fio2_pct IS NULL -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 'null_outcomes',COUNT(*) FROM pbl_outcomes WHERE imv_3h IS NULL -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 'invalid_enrollment_fio2',COUNT(*) FROM pbl_eligible WHERE fio2_pct<40 OR fio2_pct>100 -- 把另一项计数追加到汇总；这里不连接患者明细。
UNION ALL SELECT 'positive_outcome_outside_window',COUNT(*) FROM pbl_outcomes -- 把另一项计数追加到汇总；这里不连接患者明细。
 WHERE imv_3h AND (t_imv<t_pf80 OR t_imv>t_pf80+INTERVAL '3h' OR t_imv>followup_end); -- 逐行保留满足条件的记录；NULL比较不会自动视为真。

-- Q5/Q6：打印流程、质控和JSON汇总；任何患者ID或时间都不输出。
SELECT * FROM pbl_flow ORDER BY seq; -- 输出逐级流程人数，用于检查是否出现异常增加。
SELECT * FROM pbl_qc ORDER BY check_name; -- 输出质控失败数；正常情况下各项均为0。
SELECT 'RESULT_JSON:'||json_build_object( -- 把本项汇总装入JSON结构，便于复跑比对；不装患者级明细。
 'analysis','MIMIC-IV 2.2 classroom adaptation; strict-contemporaneous enrollment; first observed arterial PF<80; device LOCF<=8h', -- 记录这次本地教学分析名称；不是完整原论文复现。
 'data_version','2.2','study_complete_scope','single-threshold teaching analysis only', -- 记录MIMIC数据版本；版本号不是由结果人数推定。
 'flow',(SELECT json_agg(f ORDER BY seq) FROM pbl_flow f), -- 保存各层人数，并保留流程顺序。
 'qc',(SELECT json_agg(q ORDER BY check_name) FROM pbl_qc q), -- 保存各项质控的失败数，必须全部为0。
 'sensitivity',(SELECT json_agg(s ORDER BY definition) FROM pbl_sensitivity s), -- 保存仅改变治疗限制字段的两种分析结果。
 'code_status',json_build_object( -- 治疗状态来源覆盖及排除数的汇总。
   'candidate_stays_with_records',(SELECT COUNT(*) FROM pbl_goc), -- 尚未按治疗限制排除前，有治疗状态记录的合格候选入住数。
   'expanded_limited_stays',(SELECT COUNT(*) FROM pbl_goc WHERE limits_intubation), -- 主分析识别到明确CMO/DNI的候选入住数。
   'author_limited_stays',(SELECT COUNT(*) FROM pbl_goc WHERE author_limits_intubation), -- 仅作者字段与其两个排除值能识别的候选入住数。
   'values',(SELECT json_agg(v ORDER BY itemid,code_value) FROM (SELECT itemid,code_value,COUNT(*) AS n FROM pbl_code_records GROUP BY itemid,code_value) v)), -- 按itemid与真实状态文字汇总记录量；不输出患者ID。
 'strata',(SELECT json_agg(s ORDER BY baseline_device) FROM pbl_strata s), -- 保存基线装置分层，与下方阈值时装置分层分开。
 'threshold_device_strata',(SELECT json_agg(t ORDER BY threshold_device) FROM ( -- 原文Table4按阈值时装置，另输出，勿与基线分组混用。
     SELECT CASE threshold_device_code WHEN 3 THEN 'NRB' WHEN 4 THEN 'HFNC' WHEN 5 THEN 'NIV' END AS threshold_device, -- 把阈值时装置编码翻译为名称。
       COUNT(*) AS threshold_n,COUNT(*) FILTER(WHERE imv_3h) AS imv_3h_n, -- 本层达阈值者作分母，3h插管者作分子。
       ROUND(100.0*COUNT(*) FILTER(WHERE imv_3h)/NULLIF(COUNT(*),0),2) AS pct_3h -- 百分比；无分母时保持NULL。
     FROM pbl_outcomes GROUP BY threshold_device_code) t), -- 只聚合已生成结果，无新的临床筛选。
 -- 保存按入组氧疗装置分层的结果。
 'baseline_categories',(SELECT json_agg(c ORDER BY variable,category) FROM pbl_baseline_categories c), -- 保存性别、种族、ICU类型和参照年代的计数。
 'coverage',(SELECT json_build_object('cohort_n',COUNT(*), -- 保存血气和可计算PF的覆盖/缺失情况。
     'no_arterial_bg',COUNT(*) FILTER(WHERE arterial_bg_rows=0), -- 随访内没有明确动脉血气记录的人数；不能视为血气正常。
     'no_valid_pf',COUNT(*) FILTER(WHERE valid_pf_rows=0), -- 随访内没有可计算有效PF的人数。
     'arterial_bg_rows',SUM(arterial_bg_rows), -- 符合时间窗的动脉血气记录条数；这是记录数，不是人数。
     'missing_fio2_rows',SUM(missing_fio2_rows), -- 动脉血气中FiO2来源均缺失的记录数。
     'missing_pf_rows',SUM(missing_pf_rows)) FROM pbl_coverage), -- 动脉血气中派生PF为空的记录数。
 'input_qc',json_build_object( -- 检查输入派生表键是否重复，防止连接后行数膨胀。
     'duplicate_device_time_rows',(SELECT COUNT(*) FROM (SELECT stay_id,charttime FROM pbl_devices GROUP BY stay_id,charttime HAVING COUNT(*)>1) t), -- 同一stay_id、charttime是否多行；失败数应为0。
     'duplicate_icustay_detail_rows',(SELECT COUNT(*) FROM (SELECT stay_id FROM mimiciv_derived.icustay_detail GROUP BY stay_id HAVING COUNT(*)>1) t)), -- ICU详情中同一stay_id是否重复；应为0。
 'primary',(SELECT json_build_object('met_threshold',COUNT(*), -- 保存主分析的达阈值人数、插管人数和比例。
      'imv_within_3h',COUNT(*) FILTER(WHERE imv_3h), -- 分子：阈值后≤3h且随访截止前首次插管的人数。
      'pct_3h',ROUND(100.0*COUNT(*) FILTER(WHERE imv_3h)/NULLIF(COUNT(*),0),2), -- 100乘分子除分母；NULLIF防止零分母除法。
      'early_non_imv_followup_end',COUNT(*) FILTER(WHERE early_non_imv_end), -- 达阈值后未插管但不足3h便结束随访的人数，仍保留分母。
      'early_non_imv_death',COUNT(*) FILTER(WHERE early_non_imv_end AND deathtime=followup_end), -- 上述短随访中以已知院内死亡结束者。
      'early_non_imv_icu_discharge',COUNT(*) FILTER(WHERE early_non_imv_end AND outtime=followup_end AND (deathtime IS NULL OR deathtime>outtime)), -- 上述短随访中以ICU转出结束者，排除已先死亡者。
      'early_non_imv_120h',COUNT(*) FILTER(WHERE early_non_imv_end AND t0+INTERVAL '120h'=followup_end AND outtime>followup_end AND (deathtime IS NULL OR deathtime>followup_end)), -- 上述短随访中到达入组120h截止者。
      'imv_strictly_lt3h',COUNT(*) FILTER(WHERE imv_3h AND t_imv<t_pf80+INTERVAL '3h'), -- 按作者严格<3h边界计算插管人数。
      'imv_exactly_3h',COUNT(*) FILTER(WHERE imv_3h AND t_imv=t_pf80+INTERVAL '3h')) -- 专门统计恰好3h的插管者，解释≤与<边界差别。
      FROM pbl_outcomes), -- 指定本层数据来源；别名只在当前查询中有效。
 'baseline',(SELECT json_build_object('n',COUNT(*), -- 保存完整合格队列基线，不仅是达阈值者。
      'age_mean',ROUND(AVG(e.admission_age),2), -- 计算本次住院年龄均值，保留两位小数。
      'age_median',percentile_cont(0.5) WITHIN GROUP(ORDER BY e.admission_age), -- 本次住院年龄中位数。
      'female',COUNT(*) FILTER(WHERE e.gender='F'), -- 记录性别为F的人数。
      'copd',COUNT(*) FILTER(WHERE COALESCE(dx.copd,FALSE)), -- 出院诊断符合作者COPD编码集合的人数。
      'chf',COUNT(*) FILTER(WHERE COALESCE(dx.chf,FALSE)), -- 出院诊断符合作者CHF编码集合的人数。
      'age_missing',COUNT(*) FILTER(WHERE e.admission_age IS NULL), -- 本次住院年龄缺失人数。
      'age_q1',percentile_cont(0.25) WITHIN GROUP(ORDER BY e.admission_age), -- 年龄第25百分位数。
      'age_q3',percentile_cont(0.75) WITHIN GROUP(ORDER BY e.admission_age), -- 年龄第75百分位数。
      'race_unknown',COUNT(*) FILTER(WHERE e.race IS NULL OR e.race IN ('UNKNOWN','UNABLE TO OBTAIN','PATIENT DECLINED TO ANSWER')), -- 种族未记、未知、无法获取或拒答的人数。
      'no_diagnosis_row',COUNT(*) FILTER(WHERE dx.hadm_id IS NULL), -- 未匹配到住院诊断记录的人数，区别于未见某病编码。
      'nrb',COUNT(*) FILTER(WHERE e.device_code=3), -- 基线NRB非重复呼吸面罩人数。
      'hfnc',COUNT(*) FILTER(WHERE e.device_code=4), -- 基线HFNC高流量鼻导管人数。
      'niv',COUNT(*) FILTER(WHERE e.device_code=5), -- 基线NIV无创通气人数。
      'enrollment_flow_estimate',COUNT(*) FILTER(WHERE e.used_flow_estimate), -- 入组FiO2靠NRB流量规则估计的人数。
      'no_code_status_documented',COUNT(*) FILTER(WHERE e.code_status_records=0)) -- 合格队列中未见所查治疗状态记录的人数；不等同证实Full code。
      FROM pbl_eligible e LEFT JOIN pbl_dx dx USING(hadm_id)), -- 指定本层数据来源；别名只在当前查询中有效。
 'reference',json_build_object('cohort',3365,'met_threshold',232,'imv_within_3h',44,'pct_3h',19), -- 仅保存原论文参照值3365/232/44/19%，不是本地结果。
 'interpretation','Descriptive method adaptation; does not establish an optimal intubation threshold or treatment effect.' -- 结果解释边界：描述性分析不证明最佳插管阈值或治疗效果。
) AS aggregate_result; -- 结束当前子查询、函数或临时表定义。
DO $$ -- 执行数据库内部质控断言；有失败则抛出错误。
BEGIN -- 质控条件块的起始或结束标记。
 IF EXISTS(SELECT 1 FROM pbl_qc WHERE failures<>0) THEN -- 检查是否有任一质控项目的失败数非零。
  RAISE EXCEPTION '质控失败：请检查上方失败项目，停止解释结果'; -- 发现质控失败时中止，禁止把失败运行当成有效结果。
 END IF; -- 质控条件块的起始或结束标记。
END $$; -- 质控条件块的起始或结束标记。
ROLLBACK; -- 回滚并清理本次全部临时表，保留永久临床表原样。

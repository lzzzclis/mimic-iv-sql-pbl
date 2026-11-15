# 核心SQL通俗导读

状态：以下取自最终已运行SQL并重写解释。仅作阅读用节选，不能从本页中途单独执行，因为临时表要在完整脚本的同一会话内建立。没有生成模拟患者或替代真实分析。

## 先记住三个时刻

| 名称 | 通俗解释 | 当前用途 |
|---|---|---|
| intime | 这一次进ICU的时刻 | 确定前6h至后24h的入组寻找窗口 |
| t0 | 第一次满足本次入组条件的记录时刻 | 从这里开始研究随访，最长120h |
| t_pf80 | 入组后、插管前第一条合格PF<80的时刻 | 从这里向后数3小时找IMV |

一次入住像一个文件夹，里面有很多装置、血气和治疗记录。本次先选合格文件夹，再找里面第一个合格的低PF记录，最后检查之后是否插管；没有把一条血气当成一个人。

## 第一段：每人只选首次合格入住

```sql
SELECT DISTINCT ON (e.subject_id) e.*, -- 同一患者最终只保留一行；e.*带上这次合格入住的所有列。
       COALESCE(g.code_status_records,0) AS code_status_records, -- 没匹配到所查状态记录时把“记录条数”记0，不表示已确认Full code。
       LEAST(e.outtime,e.deathtime,e.t0+INTERVAL '120h') AS followup_end -- 取出ICU、已知死亡、入组120h中最早的随访截止时刻。
FROM pbl_preeligible e LEFT JOIN pbl_goc g USING (stay_id) -- e是候选入住，g是治疗限制汇总；按同一次ICU编号匹配。
WHERE NOT COALESCE(g.limits_intubation,FALSE) -- 排除已记录的明确限制；缺少所查记录者保留并单独报告。
ORDER BY e.subject_id,e.intime,e.stay_id; -- 先按患者排，再按ICU入住时间排，DISTINCT ON留下最前一行。
```

AS像给结果起名字。e和g是表的简短代号。这里先有pbl_preeligible候选表，才能“先判断合格，再每人取首次”，不能一开始就删掉所有后续入住。PostgreSQL的LEAST会忽略NULL参数；所以没有已知院内死亡时，仍可用其余截止时刻，不是把未知死亡当作已经发生。

注意：g使用ICU入住后144h内的治疗状态记录，可能包含入组后的信息，不能说这里仅排除了基线DNI。

## 第二段：找到第一条合格低PF，而非判断从高值降下来

```sql
SELECT DISTINCT ON (e.stay_id) e.*, -- 对每次合格ICU只保留排序后的第一条阈值血气。
       b.charttime AS t_pf80,b.pao2fio2ratio AS pf_ratio,b.specimen, -- 记下本次血气时间、PF值和标本类型。
       COALESCE(b.fio2,b.fio2_chartevents) AS threshold_fio2_pct, -- 优先取血气FiO2，否则取bg已配对的监护FiO2。
       current_device.device_code AS threshold_device_code -- 保存这条血气时判定的装置分类。
FROM pbl_eligible e -- 从最终合格患者入住出发。
JOIN mimiciv_derived.bg b ON b.hadm_id=e.hadm_id AND b.subject_id=e.subject_id -- 匹配同一患者、同次住院的血气；下面还要限制时间。
JOIN LATERAL ( -- 对当前这一条血气，另外寻找它之前最近的装置记录。
    SELECT o.device_code FROM pbl_devices o -- 只需要装置分类这一列。
    WHERE o.stay_id=e.stay_id AND o.charttime<=b.charttime -- 必须属于同次ICU且装置记录不晚于这次血气。
      AND o.charttime>=b.charttime-INTERVAL '8h' AND o.device_code IS NOT NULL -- 最多往前找8小时，跳过空装置。
    ORDER BY o.charttime DESC,o.device_code DESC LIMIT 1 -- 最近的排最前，同刻按分类优先级，只取一条。
) current_device ON current_device.device_code IN (3,4,5) -- 最近装置还必须是NRB、HFNC或NIV之一。
WHERE b.specimen='ART.' AND b.po2>0 AND b.pao2fio2ratio>0 AND b.pao2fio2ratio<80 -- 只要明确动脉血、正的PaO2和正的PF，且PF低于80。
  AND COALESCE(b.fio2,b.fio2_chartevents) BETWEEN 20 AND 100 -- PF所用FiO2须在20%到100%，含两端。
  AND b.charttime>=e.t0 AND b.charttime<e.followup_end -- 血气不早于入组，严格早于随访截止。
  AND (e.t_imv IS NULL OR b.charttime<e.t_imv) -- 从未记录插管，或这条血气明确早于首次插管。
ORDER BY e.stay_id,b.charttime,b.pao2fio2ratio; -- 同次ICU按血气时间从早到晚，同刻再按PF从小到大，保留第一条。
```

这段前面在完整脚本中有CREATE TEMP TABLE pbl_pf80，把选择结果保存成临时表。LATERAL可理解成“每读到一条血气，就为它查一次最近的装置”；JOIN负责把相互关联的信息放在同一行。光匹配患者/住院不够，还要检查这次ICU的装置、入组和随访时间，防止跨入住混入。

这里没有LAG。筛出符合规则的PF<80后取第一条，已经回答“首次记录到低值”。如果加上“上一条≥80”，就变成另一个问题，176人的结果不能沿用。我们此前讲过LAG，但还未确认你已能独立使用它。

## 第三段：有无窗口内IMV，不丢掉未插管者

```sql
SELECT h.*, -- 保留176名达阈值者，每人仍是一行。
       COALESCE(t_imv>=t_pf80 AND t_imv<=t_pf80+INTERVAL '3h' -- 判断首次插管是否落在阈值后3小时内。
                AND t_imv<=followup_end,FALSE) AS imv_3h, -- 还必须不晚于随访截止；无符合事件则记FALSE。
       (followup_end<t_pf80+INTERVAL '3h' -- 看随访是否没满3小时就结束。
        AND (t_imv IS NULL OR t_imv>followup_end)) AS early_non_imv_end -- 同时没有截止前IMV，才标记短随访未观察到IMV。
FROM pbl_pf80 h; -- 从阈值患者临时表读取，不在WHERE中删除未插管的人。
```

AND表示条件都满足，OR表示至少一个满足。NULL表示不知道或没有匹配记录，不能直接当0。COALESCE把这个结局判断中由缺少t_imv产生的NULL转为FALSE，用于“未观察到窗口内事件”的计数；它没有补造患者的治疗史。后来汇总176行，其中41行为TRUE，得到41/176。若先在WHERE只留下插管者，就会破坏分母。

## 第四段：覆盖检查与阈值检查是两件事

```sql
COUNT(b.pao2fio2ratio) FILTER(WHERE COALESCE(b.fio2,b.fio2_chartevents) BETWEEN 20 AND 100) AS valid_pf_rows, -- 只数PF非空且FiO2范围合格的动脉记录，不等于通过全部阈值条件。
```

这行位于完整脚本的pbl_coverage查询中，前后还有限定患者和时间的连接。变量名虽叫valid_pf_rows，实际没有在此处额外检查PF正值或装置，也没有要求PF<80。按这个覆盖定义，1,830人计数为0；他们不能被说成“PF都正常”。已修正该段原有的不准确注释，计算语句未变。

## 你目前需要能用自己的话说明的四件事

1. 2,569、176、41分别是哪一步的人数，为什么23.30%除以176。
2. intime、t0、t_pf80分别从哪里开始计时。
3. 为什么阈值血气必须在插管前；为什么未插管者仍留在分母。
4. 为什么缺少PF与PF正常不能画等号。

这些是接下来的学习目标，不是已经通过的测试。整份349行脚本保留逐行中文注释，继续学习时可据此定位；本页节选不另起数据库计算。

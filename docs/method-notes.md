# 原文与课堂示例：实施前须核对的事项

## 上游执行顺序

作者README给出的MIMIC取数顺序为：

1. O2DeliveryFiO2Table_1.sql
2. PAHRC_OC_Eligibility_2.sql
3. PAHRC_OC_Timevarying_3.sql
4. PAHRC_OC_Baseline_4.sql

随后进入CreateCohortR、MultipleImputation、Outcomes和Plots。原代码使用BigQuery和作者私有中间表，本仓库不能把它们直接交给PostgreSQL执行。原论文完整分析也不能等同于一条课堂SQL。

## 当前已核对的差异

- 数据版本：本地MIMIC-IV 2.2有73,181次ICU入住；原论文起始76,540次入住。两者不能预期得到相同队列人数。
- 治疗限制：本地没有code_status派生表，但上游Eligibility_2直接读取chartevents的itemid 228687；缺少派生表不意味着必须省略该排除。原代码将CMO及DNR/DNI组合判为限制插管，不应将DNR单独直接等同于DNI。
- 同时成立：原代码对FiO₂/装置采用有限窗口前向填充；严格相同charttime的JOIN是不同定义，必须报告差异。
- 每人去重：应先判合格再选首次合格入住，不能先限定首次ICU入住而错过之后的合格入住。
- 年龄：anchor_age不是每次住院的年龄；应核对icustay_detail.admission_age或按anchor_year与住院年份计算。
- P:F：须确认动脉标本及FiO₂来源，不将静脉PO₂等同PaO₂。
- 结局：阈值必须发生于插管/死亡/出ICU/随访截止之前；仅JOIN血气再判断三小时通气不足以保证正确风险集。
- 缺失：本阶段不把未测生理变量填成正常，不声称完成原文的100套多重插补。
- BigQuery和PostgreSQL的迁移须逐项核对，尤其IGNORE NULLS、时间运算、数组取首项和私有中间表。

## 尚未取得

期刊在线补充材料、教师配套mimic_iv_pbl_lab.sql尚未取得。论文原文及归档作者代码已在本地核验保存；本仓库只引用来源，不再分发PDF、PPT或上游整包。

## 当前阶段

已实现：数据库对象/列检查、患者/住院/ICU计数。未实现：最终队列、P:F事件时间轴、3小时插管结局、基线与缺失质控、多重插补和回归。后续实施必须保留上述差异，不将文献参照值报告为本地结果。

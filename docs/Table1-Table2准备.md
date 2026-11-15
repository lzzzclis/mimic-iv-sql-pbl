# Table 1 / Table 2：已运行的本地教学适配

2026-11-15，真实MIMIC-IV 2.2 / PostgreSQL16；不是完整论文复现。

## 直接看结果

- [Table1：17个阈值中文定义](../results/table12/table1-threshold-definitions.csv)。仅PF<80已做主分析，其余16项是定义整理。
- [Table2：总体与基线装置分层表](../results/table12/table2-local-adaptation.csv)，并列原文MIMIC参照及定义差异。
- [Q5人数及比例CSV](../results/table12/q5_result.csv)：176人达阈值、41人≤3h IMV、23.30%。UTF-8 BOM含表头，由程序保存；不冒称用户完成了pgAdmin点击导出。
- [完整中文注释SQL04](../sql/04_table2_classroom.sql)：复用03队列并补Table2，必须在新会话整份运行。仅TEMP，末尾ROLLBACK，不改永久临床表。
- [可读HTML](table12/index.html)：下载或克隆整个仓库后本地打开。GitHub网页可直接阅读本页和CSV。
- [11项结构质控与已知异常](../results/table12/table12-validation.json)；[独立盲法核对](盲法独立复跑核对.md)。

## 为什么有两种表号

论文Table1是阈值定义，Table2是队列特征，Q5的PF80插管比例对应Table3的一行。作者R把分层基线输出命名pdx_T1.csv，实际对应论文Table2。这里保留这一差别，不代老师补写未见的口头要求。

## 计算口径与差异

主队列2569人；基线NRB/HFNC/NIV为1977/512/80。SpO₂与RR分别取入组前12h至入组时刻的最后有效值；FiO₂取同刻入组值，含NRB流量估计。这一基线窗为本地教学选择，不是额外教师要求或完整作者处理。

SpO₂为96[93–99]%，缺378；RR为23[19–27]次/分，缺363；FiO₂为66[60–100]%，1365人依赖流量估计。连续项只对有效非空值求中位数/IQR；缺失不从主队列静默删除。机器可读文件含观测数、缺失数与分母。

曾用NRB/HFNC/NIV为2027/700/272，可重叠；统计入组后至首次IMV/死亡/转出/120h最早者之前。基线装置与曾用装置不能混为一谈。120h首结局互斥：IMV693、插管前死亡130、无在先插管/死亡的ICU转出1503、行政截止243。

年龄主表用本次住院admission_age，作者用anchor_age；[作者分组对照](../results/table12/table2-author-mapping-sensitivity.csv)另列。Race主表对MIMIC2.2细分文字扩展映射，另保留作者精确字符串映射；ICU用first_careunit而作者用入住时transfer连接。anchor_year_group只是脱敏参照年代，不能当作本次ICU精确真实年份。

28天指标只记录本次住院deathtime，从ICU入住起算且严格<28天，共497。发现1人死亡早于ICU入住，标志置空并保留主分母；[仅剔除该人的敏感性](../results/table12/table2-chronology-sensitivity.csv)为2568人，PF80/IMV仍176/41。不能将其他人自动称为确认存活，也不能将本指标称为全因28天死亡。11项结构质控为0不消除这项临床时序异常。

治疗限制与气切排除含未来信息，存在选择偏倚；同刻FiO₂可用性也会影响入组构成。老师配套mimic_iv_pbl_lab.sql与期刊在线补充仍缺，作者BigQuery2/3/4原样患者级导出链没有执行。本仓库只公开聚合。未执行Amsterdam队列、其他16阈值完整分析、多重插补或回归。

## 如何运行

已有MIMIC-IV2.2与派生表无需重建/重导。在pgAdmin连接自己的mimic4数据库，新建Query Tool打开SQL04并全部执行。查看RESULT_JSON/TABLE12_JSON与质控；ROLLBACK后TEMP表即清理，不能另开会话直接SELECT这些临时表。若自行使用psql，请用已配置的安全连接并启用ON_ERROR_STOP。

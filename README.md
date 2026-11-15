# MIMIC-IV SQL PBL：论文方法复现作业

基于 Yarnell 等 AJRCCM 2023 论文，以 PostgreSQL 学习队列构建、变量映射、时间窗和结局质控。使用真实观察性数据重新分析，不生成虚拟患者。

**状态：准备阶段，尚未产出论文队列与3小时插管率。** 本仓库当前提供作业任务链、固定版本代码来源、只读数据库检查及其真实汇总结果，不代表已完成论文复现。

## 研究问题

在符合入组条件的低氧性呼吸衰竭患者中，首次达到 P:F < 80 mmHg 后，有多少人在3小时内接受有创机械通气？P:F = PaO₂ / FiO₂（FiO₂用小数）。

论文 MIMIC 队列报告：3,365名患者，232名达到该阈值，44名在3小时内接受有创通气（19%）。**这些是文献参照值，不是本仓库运行结果。** 两个数据库的原文完整分析包含更多阈值及多重插补；本作业首先实现MIMIC单队列、单阈值的教学版。

## 快速开始

1. 在获授权的本地环境中准备MIMIC-IV 2.2和PostgreSQL；现有数据库不需要重新导入。
2. 设置标准PostgreSQL连接参数（PGHOST、PGPORT、PGUSER、PGDATABASE），或直接在pgAdmin中选中已有数据库。不要将连接凭证写进仓库。
3. 检查表是否就绪：

```bash
psql -X -v ON_ERROR_STOP=1 -f sql/00_preflight.sql
psql -X -v ON_ERROR_STOP=1 -f sql/01_id_counts.sql
```

两份SQL仅输出汇总，使用只读事务，不创建或修改原始表。也可在pgAdmin Query Tool逐份执行。

4. 获取并核验论文归档代码（只下载，不执行）：

```bash
python3 scripts/fetch_upstream.py
python3 -m zipfile -e vendor/ObservedThresholdsForIMV-v1.0.1.zip vendor/upstream-v1.0.1
```

下载内容保存在被Git忽略的vendor目录。获取GitHub开发版可使用：

```bash
git clone https://github.com/cjyarnell/ObservedThresholdsForIMV.git vendor/ObservedThresholdsForIMV
git -C vendor/ObservedThresholdsForIMV checkout c58137b62c4e300f396657d44ddce8800e3d581d
```

## 任务与交付

- [小组作业步骤](docs/assignment.md)：Q1–Q6、分工、检查点和提交物。
- [方法核对](docs/method-notes.md)：原论文、课堂示例、本地实现之间需要确认的差异。
- [代码来源](sources.json)：论文DOI、归档版本、GitHub commit与校验值。
- `results/environment-check.json`：本地数据库可用性汇总；不是研究结果。

计划交付为可复跑SQL、1页结果与差异说明、3分钟小组汇报；截止时间及教师最终要求待确认。完整论文多重插补及回归尚未实现。

## 公开范围

仓库公开自行编写的代码、方法说明和经检查的汇总结果。MIMIC患者明细、ID、事件时间、原始数据、凭证及数据库文件留在授权环境。论文PDF、教师PPT、上游下载包不随仓库再分发；上游资料通过DOI和仓库地址引用，其权利归原权利人。

## 来源

Yarnell CJ et al. *Do Thresholds for Invasive Ventilation in Hypoxemic Respiratory Failure Exist? A Cohort Study.* AJRCCM. 2023;207(3):271–282. [论文](https://doi.org/10.1164/rccm.202206-1092OC) · [代码归档](https://doi.org/10.5281/zenodo.6505220) · [开发仓库](https://github.com/cjyarnell/ObservedThresholdsForIMV)。

本作业文档与初始脚本在AI辅助下整理；组员须理解、复核并按课程规定说明各自贡献，不将工具生成内容冒充独立完成的工作。

# 第三周截图清单

截图只展示命令、版本、状态和结果；不得展示 `.env` 内容、API Key 或 Docker inspect 的环境变量值。

|编号|验收点|终端命令或文件|应出现的结果|
|---|---|---|---|
|S1|基础真实 soak|Get-Content 1-basic-soak/evidence/real-pass-30/result.json`|`"status": "PASS"`、30/30、P50/P95|
|S2|三个参数|同一份 S1 的 `config`|`rounds`、`interval_seconds`、`duration_seconds`|
|S3|错误 Key 容错|Get-Content 1-basic-soak/evidence/invalid-api-key-5rounds/result.json`|`"status": "FAIL"`、5 轮已完成|
|S4|L0/L1|`Get-ChildItem 2-memory-l0l3/evidence/memory-data-new/conversations,2-memory-l0l3/evidence/memory-data-new/records`|两个目录均有 JSONL 文件|
|S5|L2/L3|`Get-ChildItem 2-memory-l0l3/evidence/memory-data-new/scene_blocks; Get-Content 2-memory-l0l3/evidence/memory-data-new/persona.md -TotalCount 20`|scene 文件与 persona 内容|
|S6|recall 与四层总检|`Get-Content 2-memory-l0l3/evidence/memory-report-final.json`|四层 `present: true`，关键词无缺失|
|S7（选交）|完整流水线结果|`Get-Content 3-full-pipeline/evidence/pass-30rounds-retry/soak-results/result.json; Get-Content 3-full-pipeline/evidence/pass-30rounds-retry/memory-report.json`|soak 30/30 PASS，且流水线导出的 L0–L3 均为 `present: true`|

## 文件位置截图（补充）

命令截图证明“内容和状态”；下列资源管理器/编辑器截图证明“文件实际存在、目录归属正确”。截图中只显示本仓库路径，不打开 `.env`、`auth.json` 或 Docker inspect。

|编号|截图位置（在资源管理器打开）|画面应包含|建议保存名|
|---|---|---|---|
|F1|`1-basic-soak/evidence/real-pass-30/`|`rounds.jsonl`、`result.json`、`report.txt` 三个文件|`assets/f1-basic-pass-files.png`|
|F2|`1-basic-soak/evidence/invalid-api-key-5rounds/`|错误 Key 的 `rounds.jsonl`、`result.json`、`report.txt`|`assets/f2-invalid-key-files.png`|
|F3|`2-memory-l0l3/evidence/memory-data-new/`|`conversations/`、`records/`、`scene_blocks/` 三个目录与 `persona.md`|`assets/f3-memory-l0l3-files.png`|
|F4|`2-memory-l0l3/facts.json`（用 VS Code 打开）|30 条事实剧本；不要截取或修改 `.env`|`assets/f4-facts-30.png`|
|F5|`3-full-pipeline/evidence/pass-30rounds-retry/`|`soak-results/`、`memory-data/`、`gateway.log`、`memory-report.json`|`assets/f5-pipeline-output-files.png`|
|F6|`3-full-pipeline/evidence/pass-30rounds-retry/gateway.log`（用 VS Code 搜索）|`Gateway listening`、`L1 complete`、`L2 Extraction complete`、`Task completed: L3` 任意连续日志|`assets/f6-gateway-log.png`|

## 与同学提交的对照

- 董博文的 PR #22 使用 22 张图，覆盖容器/Gateway、30 轮结果、L0–L3、recall、容错和 Git 状态；本清单新增 F1–F6 以补齐其“目录实物 + Gateway 日志”证据强度。
- 谢增业的 PR #21 有 18 张图，但部分是重复备份；本作业不需要凑数量，S1–S7 与 F1–F6 各自只保留一张清晰、信息不重复的截图即可。
- 任德霖的 PR #23 展示了脚本和单测；本作业以真实 Hermes 30/30、真实错误 Key 5/5 和真实 L0–L3 产物为主，证据更贴合课程验收。

完成截图后，保存为 `assets/s1-basic-pass.png` 至 `assets/s6-memory-report.png`（选交另加 `s7-pipeline.png`），再加上 F1–F6；随后在 `README.md` 使用相对路径引用。

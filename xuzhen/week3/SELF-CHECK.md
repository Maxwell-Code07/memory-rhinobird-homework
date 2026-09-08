# 第三周自检

## 基础：自动 soak

- [x] `soak.py` 自动执行多轮 `hermes --oneshot` 对话。
- [x] `--rounds`、`--interval`、`--duration` 和 `--timeout` 均可配置。
- [x] 每轮写入 `rounds.jsonl`，结束写入 `result.json` 和 `report.txt`。
- [x] 真实模型结果：30/30 PASS；见 `1-basic-soak/evidence/real-pass-30/result.json`。
- [x] 结构化结果含 PASS/FAIL、轮次、总耗时、逐轮延迟与 P50/P95。
- [x] 真实错误 Key 结果：5/5 FAIL，但结果文件完整生成；见 `1-basic-soak/evidence/invalid-api-key-5rounds/result.json`。

## 进阶 1：L0-L3 记忆

- [x] 基于第二周 `hermes:0.20.6` 镜像，运行时安装 `memory_tencentdb` Provider 与 Gateway。
- [x] 使用事实型剧本驱动真实 Hermes 对话。
- [x] L0 `conversations/`、L1 `records/`、L2 `scene_blocks/`、L3 `persona.md` 均非空。
- [x] `POST /recall` 返回 `code: 0`、`strategy: keyword` 并命中“小陈 / Python / 上海”。
- [x] 机器可读总验证：`2-memory-l0l3/evidence/memory-report-final.json`，状态为 PASS。

## 选交：完整流水线

- [x] `3-full-pipeline/run_pipeline.py` 一键复用第二周 Dockerfile，完成 build → run → 插件 → Gateway → 事实型 soak。
- [x] 已在全新容器独立实测：30/30 soak PASS；见 `3-full-pipeline/evidence/pass-30rounds-retry/soak-results/result.json`。
- [x] 已导出并检查 L0 `conversations/`、L1 `records/`、L2 `scene_blocks/`、L3 `persona.md`；见 `3-full-pipeline/evidence/pass-30rounds-retry/memory-report.json`。

## 提交前

- [ ] 依据 `SCREENSHOT-CHECKLIST.md` 截取终端证据并放入 `assets/`，再在 README 中引用。
- [x] `.env` 被 Git 忽略；提交前再次执行 `git check-ignore xuzhen/week3/.env`。

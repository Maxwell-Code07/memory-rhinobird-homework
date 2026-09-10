# Week3 截图执行清单

**目的**：替 9-04 历史 401 失败截图做替换 / 补全，把"全链路跑通 + 容器化 30/30 + L0-L3 + /recall 5/5 命中"四件事实变成可证伪的图。  
**工具**：`Win + Shift + S`（截图工具） → 在 Snip & Sketch 里 `Ctrl + S` 保存到 `pictures/` 目录。  
**目录约定**：
- 必交·基础层 → `week3/1-basic-soak/pictures/`
- 必交·进阶1 → `week3/2-memory-l0l3/pictures/`
- 选交·进阶2 → `week3/3-full-pipeline/pictures/`

> **建议顺序**：A → B → C → D → E → F → G（H·Git 可同时）

---

## A · 容器化基础设施已就绪

| # | 去哪里 | 执行什么 | 截图要包含什么 | 文件名 |
|---|---|---|---|---|
| A1 | 系统托盘 | 双击 Docker Desktop 图标后等鲸鱼停止转动 | 鲸鱼图标常亮 + 底部状态栏 `RAM / CPU / Disk` 三行（任选一行清晰即可） | `3-full-pipeline/pictures/a01-docker-running.png` |
| A2 | PowerShell | `docker images \| Select-String hermes` | 至少 2 行：`hermes 0.20.5`（1.27GB）+ `hermes-week3 0.20.5` | `3-full-pipeline/pictures/a02-images.png` |
| A3 | PowerShell | `docker ps --filter name=hermes-week3-runner` | `hermes-week3-runner` 行，状态 `Up`，端口 `0.0.0.0:8642->8642/tcp, 0.0.0.0:8420->8420/tcp` | `3-full-pipeline/pictures/a03-container-up.png` |

---

## B · Gateway 健康（两个端点）

| # | 去哪里 | 执行什么 | 截图要包含什么 | 文件名 |
|---|---|---|---|---|
| B1 | PowerShell（**去掉 `--noproxy`**） | `Invoke-WebRequest http://127.0.0.1:8642/health \| Select-Object StatusCode,Content` | `StatusCode : 200` + `Content : {"status":"ok",...}` | `3-full-pipeline/pictures/b01-health-8642.png` |
| B2 | PowerShell | `Invoke-WebRequest http://127.0.0.1:8420/health \| Select-Object StatusCode,Content` | `StatusCode : 200` + `Content : {"status":"ok",...}` | `3-full-pipeline/pictures/b02-health-8420.png` |

---

## C · Soak 30 轮 · 必交·基础层 + 选交·进阶2 共用产物

主产物：`D:\memory-rhinobird-homework\dongbowen\week3\pipeline-out\container-20260905-124437\soak-out\`

| # | 去哪里 | 执行什么 | 截图要包含什么 | 文件名 |
|---|---|---|---|---|
| C1 | 文件管理器 → 上述目录 | 右键 `meta.json` → Edit (VS Code) | `"pass_count": 30, "fail_count": 0, "pass_rate": 1` 清晰可见 | `3-full-pipeline/pictures/c01-meta-json.png` |
| C2 | 同目录 → `report.txt` | 右键 Edit | `PASSED (100%)` / `30 / 30` / `p50=49ms p95=71ms max=91ms` | `3-full-pipeline/pictures/c02-report-txt.png` |
| C3 | 同目录 → `turns.jsonl` | 右键 Edit，头 30 行 | 30 条对话原文（每行 `{"role":"user","content":"...","reply":"..."}`） | `3-full-pipeline/pictures/c03-turns-jsonl.png` |
| C4 | 同目录 → `soak-direct.log` | 右键 Edit，末 20 行 | `30 rounds completed` / `pass_rate=1` | `3-full-pipeline/pictures/c04-soak-log-tail.png` |

---

## D · 记忆沉淀 L0-L3（4 张图，分别截 4 个真实数据目录）

> 路径：`C:\Users\35348\.memory-tencentdb\memory-tdai\`

| # | 去哪里 | 执行什么 | 截图要包含什么 | 文件名 |
|---|---|---|---|---|
| D1 | 文件管理器 → `conversations/` | 切到"详细信息"视图 | 3 行：`2026-08-26.jsonl 11K`, `2026-09-04.jsonl 39K`, `2026-09-05.jsonl 80K` | `3-full-pipeline/pictures/d01-l0-conversations.png` |
| D2 | 同上 → `records/` | "详细信息" | 1 行：`2026-09-05.jsonl 5.8K` | `3-full-pipeline/pictures/d02-l1-records.png` |
| D3 | 同上 → `scene_blocks/` | "详细信息" | 4 行（4 个 .md，总和 ≈ 6950 B）：学业背景-计算机科学.md / 学术研究...AI智能体与强化学习.md / 用户基础信息与学术职业背景.md / 职业发展-犀牛鸟项目.md | `3-full-pipeline/pictures/d03-l2-scene-blocks.png` |
| D4 | 同上 → `persona.md` | 右键 → 打开方式 → 记事本 | 第 1 屏（用户画像、关键事实、口吻样例） | `3-full-pipeline/pictures/d04-l3-persona.png` |

---

## E · 记忆验证整体结果（容器化 · overall=pass）

> 文件：`pipeline-out\container-20260905-124437\soak-out\verify-memory.json`

| # | 去哪里 | 执行什么 | 截图要包含什么 | 文件名 |
|---|---|---|---|---|
| E1 | 记事本 / VS Code 打开 verify-memory.json | 头部 | `"overall": "pass", "all_layers_nonempty": true, "any_recall_ok": true` | `3-full-pipeline/pictures/e01-verify-head.png` |
| E2 | 同文件 | 滚到 `layers` 段 | `L0/L1/L2/L3` 4 行 + 字节数 `131630/5929/6950/1669` | `3-full-pipeline/pictures/e02-verify-layers.png` |
| E3 | 同文件 | 滚到 `recall` 段 | 5 行全 hit：`董博文 hit`、`海南大学 hit`、`Hermes hit`、`Python hit`、`周杰伦 hit` | `3-full-pipeline/pictures/e03-verify-recall-5of5.png` |

---

## F · 必交·进阶1 同套数据（宿主机直接跑，非容器化）

> 文件：`D:\memory-rhinobird-homework\dongbowen\week3\2-memory-l0l3\soak-out\verify-memory.json`（若产物在别处，先 `cd 2-memory-l0l3 && cat verify-memory.json`）

| # | 去哪里 | 执行什么 | 截图要包含什么 | 文件名 |
|---|---|---|---|---|
| F1 | 文件管理器 / VS Code | 打开 `2-memory-l0l3/soak-out/report.txt` | 30/30 / pass_rate=1 / p50/p95 数值 | `2-memory-l0l3/pictures/f01-soak-report.png` |
| F2 | 同上 → `verify-memory.json` | 头部 | `"overall": "pass"` + `all_layers_nonempty=true` + `any_recall_ok=true` | `2-memory-l0l3/pictures/f02-verify-head.png` |

---

## G · 必交·基础层（宿主机 · 容错版）

> 文件：`D:\memory-rhinobird-homework\dongbowen\week3\1-basic-soak\soak-out\report.txt`（用 `--bad-key` 跑过的那次）

| # | 去哪里 | 执行什么 | 截图要包含什么 | 文件名 |
|---|---|---|---|---|
| G1 | PowerShell | `cd 1-basic-soak && node soak.js --bad-key --rounds 5`（拿新鲜一次） | `5/5 failed`、`errors: {"401":5}`、`exit_code: 2` | `1-basic-soak/pictures/g01-bad-key-401.png` |
| G2 | PowerShell | `cd 1-basic-soak && node soak.js --rounds 30` | `30/30 pass`、`pass_rate=1` | `1-basic-soak/pictures/g02-good-30pass.png` |

---

## H · Git 状态（最后阶段）

| # | 去哪里 | 执行什么 | 截图要包含什么 | 文件名 |
|---|---|---|---|---|
| H1 | PowerShell | `cd D:\memory-rhinobird-homework\dongbowen && git log --oneline -10` | 5 个新 commit：`9f1b4d4`、`5d5e7a1`、`34c5713`、`8f1ab18`、`5bfd4f4` | `3-full-pipeline/pictures/h01-git-log.png` |
| H2 | PowerShell | `git status` | `Your branch is ahead of 'origin/main' by 5 commits` + `nothing to commit, working tree clean` | `3-full-pipeline/pictures/h02-git-status.png` |

---

## 总账

| 阶段 | 必截 | 备选 | 累计 |
|---|---|---|---|
| A 容器 | 3 张 | 0 | **3** |
| B 健康 | 2 张 | 0 | **5** |
| C Soak | 4 张 | (E1-3 共用 verify) | **9** |
| D L0-L3 | 4 张 | 0 | **13** |
| E 验证 | 3 张 | 0 | **16** |
| F 进阶1 | 2 张 | 0 | **18** |
| G 基础层 | 2 张 | 0 | **20** |
| H Git | 2 张 | 0 | **22** |

**最关键 8 张**（如果时间紧只截这些）：
- A3（容器在跑）
- B1 / B2（两个 health 200）
- C1（meta 30/30 pass）
- D1（80K 的 L0 文件）
- E1（overall: pass）
- E3（5/5 recall hit）
- H1（git log 显示 5 commits）

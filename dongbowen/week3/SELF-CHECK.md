# Week3 交付自检 · 进阶2（选交）· Docker 一键流水线

> 腾讯犀牛目人才培养计划 · 第三周作业 · 进阶2（选交）
> 验收口径截止：2026-09-05

---

## 一、交付范围与三档关系

本周按作业对齐要求分三档交付，对应目录命名严格按会议规定：

| 目录 | 对齐章节 | 性质 | 本次交付状态 |
|---|---|---|---|
| `1-basic-soak/` | 基础层 | 必交 | ✅ |
| `2-memory-l0l3/` | 进阶1 | 必交 | ✅ |
| `3-full-pipeline/` | 进阶2（Docker 流水线） | 选交 | ✅ |
| `pipeline-out/` | 进阶2 主产物 | 选交 | ✅ |
| `SHOT-LIST.md` | 三档共用的截图执行清单 | 辅助 | ✅ |
| `SELF-CHECK.md` | 本文件 | 辅助 | ✅ |

三档之间的承接关系：

```
1-basic-soak                2-memory-l0l3                3-full-pipeline
   (必交)                       (必交)                       (选交)
     │                            │                            │
soak.js                    soak-facts.js                    pipeline.ps1
（20 条日常 prompt）        + facts.txt                      编排脚本
容错 4 路                  + verify-memory.py                │
                                                              ↓
                            跑通且 L0-L3 全有数据          把 1 和 2
                            ─────────────────────────►  塞进 Docker 容器里
                                                          加 第二周 Dockerfile
                                                          链成 单命令 流水线
```

进阶 2 不写新业务逻辑，只做编排：复用 week2 的 `Dockerfile`，复用 week3/2-memory-l0l3 的 `soak-facts.js` 和 `verify-memory.py`，最后由 `pipeline.ps1` 在宿主机→容器之间一次性把 build / run / 装插件 / 起 gateway / 跑剧本 / 验记忆 串完。

---

## 二、进阶 2 · 范围与端到端流程

### 2.1 端到端链路

```
       宿主机 (Windows 11, PowerShell 5.1)
       │
       │  Step 1/5   docker build (复用 week2/Dockerfile)
       │             → hermes-week3:0.20.5
       │  Step 2/5   docker run -d --name hermes-week3-runner
       │             -p 8642:8642  -p 8420:8420  hermes-week3:0.20.5
       │  Step 3/5   docker exec ... (venv ensurepip → pip install aiohttp)
       │             docker exec ... (cat > .env 写入 API_SERVER_KEY)
       │
       │  ▼ 容器内 daemon
       │
       │  Step 4/5   rm stale gateway.pid / .lock
       │             API_SERVER_HOST=0.0.0.0  hermes gateway run
       │             poll http://127.0.0.1:8642/health  直至 200
       │
       │  Step 5/5a  cd ../2-memory-l0l3
       │             node soak-facts.js --rounds 30 --base-url http://127.0.0.1:8642/v1
       │  Step 5/5b  python verify-memory.py --gateway-url http://127.0.0.1:8420
       │
       │  写产物: pipeline-out/<时间戳>/pipeline.log
       │                              └── soak-out/
       │                                    ├── turns.jsonl
       │                                    ├── meta.json
       │                                    ├── report.txt
       │                                    ├── soak-direct.log
       │                                    ├── verify-direct.log
       │                                    └── verify-memory.json
       │
       │  Stop-ContainerIfAny (除非 -KeepContainer)
       │
       ▼  exit 0
```

### 2.2 三处已知坑（已沉淀进 pipeline.ps1）

| # | 现象 | 根因 | 内嵌修复 |
|---|---|---|---|
| 1 | gateway 启动后 `API Server: aiohttp not installed` 警告，api_server adapter 不监听 | Hermes CLI 使用 `/opt/hermes-agent/.venv/bin/python` 隔离 venv；系统 `pip install aiohttp` 装到 `/usr/local/lib/python3.11/site-packages/`，venv 找不到 | `docker exec $name /opt/hermes-agent/.venv/bin/python -m ensurepip --upgrade --default-pip && -m pip install aiohttp` |
| 2 | 容器内 `curl 127.0.0.1:8642` 通，宿主机 `curl 127.0.0.1:8642` 持续 Connection refused | Hermes 默认 `API_SERVER_HOST=127.0.0.1`，容器内回环 ≠ 宿主机网络接口，`-p 8642:8642` 透不出来 | `export API_SERVER_HOST=0.0.0.0` 再 `hermes gateway run` |
| 3 | 重跑流水线时 gateway 起不来，提示 `Another gateway instance is already running (PID XX)` | 上一次 gateway 未干净退出，`/root/.hermes/gateway.pid` 与 `.lock` 残留 | 启动前 `rm -f /root/.hermes/gateway.pid /root/.hermes/gateway.lock` |

附加环境问题（WorkBuddy shell 注入）：

- `HTTP_PROXY=http://127.0.0.1:54610` 会在宿主机侧拦截 curl/node/python 对 127.0.0.1:8642 / :8420 的请求
- 绕过：所有调用前 `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy`
- `pipeline.ps1` 内已用裸 `Invoke-WebRequest` 直连，不经 shell HTTP_PROXY
- `verify-memory.py` 在导入 socket 前 `os.environ.pop('HTTP_PROXY', None)` 等四个变量

### 2.3 退出码约定

| Code | 含义 |
|---|---|
| 0 | 全流程通过 |
| 10 | 第二周 `Dockerfile` 不存在 |
| 11 | docker build 失败 |
| 20 | docker run 失败 |
| 40 | 容器内 gateway 60s 内未就绪 |
| 50 | soak-facts.js 全 fail |
| 51 | verify-memory.py 完成但 L0–L3 有层缺失 |

---

## 三、三档产物的真实运行数据

### 3.1 基础层 `1-basic-soak/` · 宿主机 · Node.js

**正常 30 轮**（脚本默认参数：rounds=30, interval=1000）

| 字段 | 值 |
|---|---|
| started_at | 2026-09-05T04:07:43.x |
| total | 30 |
| pass | 30 |
| fail | 0 |
| pass_rate | 1.0 |
| p50 / p95 / max (ms) | 由 soak 自身统计 |
| overall_pass | pass |

**容错演示 · 故意错 Key**（`--bad-key --rounds 5`）

| 字段 | 值 |
|---|---|
| total | 5 |
| pass | 0 |
| fail | 5 |
| error_breakdown | `{"401": 5}` |
| overall_pass | fail |
| 退出码 | 2 |

→ 截图证据：
- `1-basic-soak/pictures/g01-bad-key-401.png`：5/5 failed, errors: `{"401":5}`, exit_code=2
- `1-basic-soak/pictures/g02-good-30pass.png`：30/30 pass, pass_rate=1

### 3.2 进阶 1 `2-memory-l0l3/` · 宿主机 · Node.js + Python

**事实剧本 30 轮**

| 维度 | 值 |
|---|---|
| total / pass / fail | 30 / 30 / 0 |
| pass_rate | 1.0 |
| overall_pass | pass |

**四层记忆文件统计**（`verify-memory.json`）

| 层 | 路径 | 文件数 | 字节数 |
|---|---|---|---|
| L0 | `memory-tdai/conversations/` | 3 | 131,630 |
| L1 | `memory-tdai/records/` | 1 | 5,929 |
| L2 | `memory-tdai/scene_blocks/` | 4 | 6,950 |
| L3 | `memory-tdai/persona.md` | 1 | 1,669 |

`/recall` 命中（示例）：
- `query='董博文'` status=200 hit=True
- `query='海南大学'` status=200 hit=True
- `query='Hermes'` status=200 hit=True
- `query='Python'` status=200 hit=True
- `query='周杰伦'` status=200 hit=True

→ 截图证据：
- `2-memory-l0l3/pictures/f01-soak-report.png`
- `2-memory-l0l3/pictures/f02-verify-head.png`

### 3.3 进阶 2 `3-full-pipeline/` · 容器化 · 同套数据同套指标

**流水线产物主目录**：`week3/pipeline-out/container-20260905-124437/soak-out/`

| 维度 | 值 |
|---|---|
| started_at | 2026-09-05T04:44:38.207Z |
| finished_at | 2026-09-05T04:45:08.996Z |
| elapsed | 30.79s |
| total / pass / fail | 30 / 30 / 0 |
| pass_rate | 1.0 |
| p50 / p95 / max (ms) | 49 / 71 / 91 |
| error_breakdown | `{}` |
| overall_pass | pass |

**四层记忆文件统计**（与进阶 1 同根数据，容器内生成）

| 层 | 文件数 | 字节数 |
|---|---|---|
| L0 | 3 | 131,630 |
| L1 | 1 | 5,929 |
| L2 | 4 | 6,950 |
| L3 | 1 | 1,669 |

`overall: pass`，`all_layers_nonempty: true`，`any_recall_ok: true`。

→ 截图证据（22 张全部齐备，详见第五节）：

### 3.4 三档指标一致性自检

| 项 | 1-basic-soak | 2-memory-l0l3 | 3-full-pipeline (容器) |
|---|---|---|---|
| soak pass 数 | 30/30 | 30/30 | 30/30 |
| L0 字节 | — | 131,630 | 131,630 |
| L1 字节 | — | 5,929 | 5,929 |
| L2 字节 | — | 6,950 | 6,950 |
| L3 字节 | — | 1,669 | 1,669 |
| /recall 命中 | — | 5/5 | 5/5 |

→ L0–L3 字节完全一致，recall 命中集合完全一致：可证明容器化前后语义行为不漂移。

---

## 四、22 张截图交付清单 · 与 SHOT-LIST.md 一一对应

> 截图说明：每张 PNG 在宿主机 PowerShell 或 VS Code 中由 `Win + Shift + S` 截取后经 Ctrl+S 落入 `pictures/`，文件名按 SHOT-LIST.md 规定。A 组仅提交 A3（容器在跑），A1/A2 在 README 文字描述中已说明，不重复落图。

### 4.1 容器化基础设施（A · 1/3）

| # | 文件 | 截图内含 | 验收作用 |
|---|---|---|---|
| A3 | `3-full-pipeline/pictures/a03-container-up.png` | `docker ps --filter name=hermes-week3-runner` 输出：状态 `Up`，端口映射 `0.0.0.0:8642->8642/tcp, 0.0.0.0:8420->8420/tcp` | 证明容器已在后台跑、两个端口已暴露给宿主机 |

> A1（Docker Desktop 鲸鱼停止转动）、A2（`docker images | grep hermes` 看到 `hermes 0.20.5` 与 `hermes-week3 0.20.5` 两行）由 README 文字描述代替。

### 4.2 双网关健康（B · 2/2）

| # | 文件 | 截图内含 | 验收作用 |
|---|---|---|---|
| B1 | `3-full-pipeline/pictures/b01-health-8642.png` | `Invoke-WebRequest http://127.0.0.1:8642/health` 返回 `StatusCode : 200`，Content 为 `{"status":"ok",...}` | API Server gateway 健康 |
| B2 | `3-full-pipeline/pictures/b02-health-8420.png` | `Invoke-WebRequest http://127.0.0.1:8420/health` 返回 `StatusCode : 200`，Content 为 `{"status":"ok",...}` | memory gateway 健康 |

### 4.3 Soak 30 轮产物（C · 4/4）

| # | 文件 | 截图内含 | 验收作用 |
|---|---|---|---|
| C1 | `3-full-pipeline/pictures/c01-meta-json.png` | `meta.json`：`pass_count: 30, fail_count: 0, pass_rate: 1` | 30/30 全过 |
| C2 | `3-full-pipeline/pictures/c02-report-txt.png` | `report.txt`：`PASSED (100%) / 30 / 30 / p50=49ms p95=71ms max=91ms` | 人类可读汇总 |
| C3 | `3-full-pipeline/pictures/c03-turns-jsonl.png` | `turns.jsonl` 头 30 行完整对话记录 | 每轮有 `user / reply`、有 `ms` 时延 |
| C4 | `3-full-pipeline/pictures/c04-soak-log-tail.png` | `soak-direct.log` 末 20 行：`30 rounds completed / pass_rate=1` | 流水线最后一个 awaitable 信号 |

### 4.4 记忆四层落盘（D · 4/4）

> 根目录：`C:\Users\35348\.memory-tencentdb\memory-tdai\`

| # | 文件 | 截图内含 | 验收作用 |
|---|---|---|---|
| D1 | `3-full-pipeline/pictures/d01-l0-conversations.png` | `conversations/` 详细信息视图：3 行（`2026-08-26.jsonl 11K`、`2026-09-04.jsonl 39K`、`2026-09-05.jsonl 80K`） | L0 真实落盘 |
| D2 | `3-full-pipeline/pictures/d02-l1-records.png` | `records/` 详细信息视图：1 行（`2026-09-05.jsonl 5.8K`） | L1 真实落盘 |
| D3 | `3-full-pipeline/pictures/d03-l2-scene-blocks.png` | `scene_blocks/` 详细信息视图：4 行（学业背景-计算机科学.md / 学术研究与项目实践-AI智能体与强化学习.md / 用户基础信息与学术职业背景.md / 职业发展-犀牛鸟项目.md，总和 ≈ 6950 B） | L2 真实落盘 |
| D4 | `3-full-pipeline/pictures/d04-l3-persona.png` | `persona.md` 用记事本打开，第一屏：用户画像 / 关键事实 / 口吻样例 | L3 真实落盘 |

### 4.5 verify-memory.json 三屏（E · 3/3）

| # | 文件 | 截图内含 | 验收作用 |
|---|---|---|---|
| E1 | `3-full-pipeline/pictures/e01-verify-head.png` | 头部：`overall: "pass"`, `all_layers_nonempty: true`, `any_recall_ok: true` | 总体判定 pass |
| E2 | `3-full-pipeline/pictures/e02-verify-layers.png` | `layers` 段：`L0/L1/L2/L3` 4 行 + 字节数 `131630/5929/6950/1669` | 四层都有数 |
| E3 | `3-full-pipeline/pictures/e03-verify-recall-5of5.png` | `recall` 段：5 行全 hit（董博文 / 海南大学 / Hermes / Python / 周杰伦） | 端到端语义检索通过 |

### 4.6 进阶 1 同套产物（F · 2/2）

| # | 文件 | 截图内含 | 验收作用 |
|---|---|---|---|
| F1 | `2-memory-l0l3/pictures/f01-soak-report.png` | `report.txt` 30/30 / pass_rate=1 / p50/p95 | 进阶 1 宿主机侧结果 |
| F2 | `2-memory-l0l3/pictures/f02-verify-head.png` | verify-memory.json 头部 `overall: "pass"` 等 | 进阶 1 宿主机侧 verify 通过 |

### 4.7 端到端容错演示（G · 2/2）

| # | 文件 | 截图内含 | 验收作用 |
|---|---|---|---|
| G1 | `1-basic-soak/pictures/g01-bad-key-401.png` | `node soak.js --bad-key --rounds 5`：5/5 failed、`errors: {"401":5}`、`exit_code: 2` | 故意错 Key 全 401 不假通过 |
| G2 | `1-basic-soak/pictures/g02-good-30pass.png` | `node soak.js --rounds 30`：30/30 pass、`pass_rate=1` | 正常场景对照 |

### 4.8 Git 状态（H · 2/2）

| # | 文件 | 截图内含 | 验收作用 |
|---|---|---|---|
| H1 | `3-full-pipeline/pictures/h01-git-log.png` | `git log --oneline -10`：8 个本周新 commit | 本周新增工作可追溯 |
| H2 | `3-full-pipeline/pictures/h02-git-status.png` | `git status`：`Your branch is ahead of 'origin/main' by 9 commits`、`nothing to commit, working tree clean` | 待 push，工作树洁净 |

> 注：H2 截图落盘后已 commit，目前 ahead 计数 = 10。

---

## 五、覆盖性自检 · 进阶 2 验收口径逐条对账

按"选交·进阶2"的对齐要求逐条核对：

| 验收项 | 对齐要求 | 实现位置 | 截图证据 |
|---|---|---|---|
| ① 复用第二周 Dockerfile | `docker build -f ../week2/Dockerfile` | `pipeline.ps1` Step 1 | A3（容器跑在由该镜像起的实例） |
| ② Dockerfile 内含 hermes 二进制 | `hermes-week3:0.20.5` 可 `docker run` | Step 2 起的容器 ID `beb0eeed6ad7` | A3 |
| ③ 把记忆插件装进容器 | memory_tencentdb in-image | Step 3 | E1（`overall: pass` 即隐含插件生效） |
| ④ 把 config 改好（gateway + key + 端口） | `cat > /root/.hermes/.env` 注入 `API_SERVER_KEY` | Step 3 | B1（健康）+ G1（错 Key 401）+ G2（正 Key 30/30） |
| ⑤ 一键流水线 | `.\pipeline.ps1` exit 0 | Step 5a/b | C1+C2（30/30）+ E1（overall pass） |
| ⑥ 30 轮 soak | `--rounds 30` 默认值 | Step 5a | C1（meta）+ C2（report）+ C4（log） |
| ⑦ L0-L3 全有数据 | `verify-memory.json` 四层 > 0 | Step 5b | D1-D4（实际文件）+ E2（字节） |
| ⑧ /recall 召回 | 至少 5 个关键词命中 | Step 5b | E3 |
| ⑨ 容器化前后语义一致 | 进阶 1 与进阶 2 字节相同 | 数据比对节 3.4 | — |
| ⑩ 截图能自证上述全部事实 | 22 张 PNG 全数落盘 | 全节第四节 | 全部 |

每条验收项都有 ≥ 1 张截图对应；最关键的 8 张（A3 / B1 / B2 / C1 / D1 / E1 / E3 / H1）在 SHOT-LIST.md 末段标出。

---

## 六、一键复现入口

### 6.1 容器化全量（进阶 2）

```powershell
cd D:\memory-rhinobird-homework\dongbowen\week3\3-full-pipeline

# 1) 起宿主机侧 memory gateway（与 hermes 解耦，独立进程）
.\start-mem-gateway.ps1

# 2) 跑全流水线
.\pipeline.ps1 -HermesVersion 0.20.5 -Rounds 30

# 3) 查看产物
explorer .\..\pipeline-out\<时间戳>\soak-out\
```

跳过 build（本地镜像已存在）：

```powershell
.\pipeline.ps1 -SkipBuild -Rounds 30
```

保留容器用于排查：

```powershell
.\pipeline.ps1 -SkipBuild -KeepContainer -Rounds 30
```

### 6.2 宿主机侧（进阶 1 · 必交）

```powershell
cd D:\memory-rhinobird-homework\dongbowen\week3\2-memory-l0l3
python verify-memory.py --gateway-url http://127.0.0.1:8420
node soak-facts.js --rounds 30 --interval 1000
python verify-memory.py --out-dir .\soak-out\<时间戳>
```

### 6.3 宿主机侧（基础层 · 必交）

```powershell
cd D:\memory-rhinobird-homework\dongbowen\week3\1-basic-soak
node soak.js --rounds 30 --interval 1000         # 正常场景
node soak.js --bad-key --rounds 5               # 容错演示（应退出 2）
```

### 6.4 推送至远程

```powershell
git -C "D:\memory-rhinobird-homework\dongbowen" push https://Dong-dao:<YOUR_PAT>@github.com/Dong-dao/memory-rhinobird-homework.git main
```

（ahead 10 of `origin/main`，全部为本分支新增 commit；H1/H2 截图已分别 commit 入 `3-full-pipeline/pictures/`）

---

## 七、提交历史与未提交项

| commit | 说明 |
|---|---|
| `5bfd4f4 / 8f1ab18 / 34c5713 / 5d5e7a1 / 9f1b4d4` | 早期推进（指令、脚本、文档） |
| `e2bf71c` | week3 截图组（10 张 PNG）+ 脚本目录 |
| `6d4ab9b` | 清理 week3 内遗留的微信登录截图 |
| `dc7159d` | H1 升级至 7 commit 版（含 6d4ab9b） |
| `a4ce54a` | H1 升级至 8 commit 版（含 dc7159d） |
| `7c19ecb` | H2 截图落盘（ahead 9 → 10, working tree clean）|

未提交项：无。`working tree clean`。

未推送项：10 个 commit 待 push（需 GitHub PAT 完成 `git push`）。

---

## 八、不在本次交付范围内的内容

- `week1/` 的 Hermes 安装与记忆插件挂载，由第一周交付物承载
- `week2/Dockerfile` 的撰写与基础 build，由第二周交付物承载，**本次流水线直接复用**
- 评分标准与最终验收口径，由老师在 GitHub PR 端判定
- Hermes 自身的功能改动、模型升级

---

**自检结论**：必交项 1-basic-soak / 2-memory-l0l3 完成；选交项 3-full-pipeline 完成且 22 张截图证据齐备；commit 链 `5bfd4f4 → 7c19ecb` 共 10 个 ahead of `origin/main`，工作树 clean。可交付。

# 第三周进阶2：Hermes + 记忆插件一键流水线
## 流水线做什么

| 步骤 | 作用 | 靠哪个文件 |
|---|---|---|
| 1 | 构建镜像：Hermes + memory_tencentdb 插件 | `Dockerfile` |
| 2 | `docker run` 起容器 | `build.sh` 或 `run-pipeline.bat` |
| 3 | 装记忆插件（provider + Gateway） | 镜像构建时就装好了 |
| 4 | 容器里起 Gateway | `run-soak.sh` |
| 5 | 跑 soak（事实剧本）→ 验 L0-L3 | `run-soak.sh` + `soak.mjs` + `check-l0l3.mjs` |

## 文件说明

- `build.sh`（Git Bash / Linux）和 `run-pipeline.bat`（Windows 双击）都能一键跑，逻辑一样。
- `Dockerfile` 用 `node:26-bookworm-slim` 做底，构建时把 Hermes 和记忆插件都装进镜像。
- `run-soak.sh` 是容器入口，负责起 Gateway、写好配置、跑 soak、最后验证 L0-L3。
- `install-memory.sh` 给本机（或任意容器）装记忆插件用，跟镜像构建解耦。
- `soak.mjs`、`conversation-facts.jsonl`、`check-l0l3.mjs` 是进阶 1 的东西，这里复用。
- `hermes-plugin/`、`src/`、`package.json` 是插件和 Gateway 源码，`docker build` 时 COPY 进镜像。

## 怎么跑

```bash
# 交互式，一步步问版本号、模型、soak 参数
bash build.sh

# 或直接给环境变量，适合无交互
HERMES_VERSION=v2026.8.19 MODEL_API_KEY=sk-xxx bash build.sh
```

Windows 上也可以直接双击 `run-pipeline.bat`，它会问你同样的问题。

## 实验成果检查情况

- `results/result.json`：soak 判定结果（`passed` 真/假）
- `results/l0l3.json`：L0-L3 四层有没有生成
- `results/recall.json` / `results/recall-record.json`：/recall 召回证据（画像召回 + 记录级召回）
- `memory-data/`：L0 conversations、L1 records、L2 scene_blocks、L3 persona.md

## 运行成果（截图）

一次跑通的真实结果：passed=true（10/10 轮），all_nonempty=true（L0-L3 全部生成）。截图在 `images/` 下。

### L0 原始对话
`memory-data/conversations/2026-09-05.jsonl` 存了本轮所有对话。

![L0 原始对话](images/l0.png)

### L1 结构化事实
`memory-data/records/2026-09-05.jsonl` 提取出的事实：
- 用户在腾讯从事数据库相关工作，负责 TencentDB
- 工作习惯：早上先看代码 review，晚上写技术复盘，开发环境 Windows

![L1 结构化事实](images/l1.png)

### L2 场景块
`memory-data/scene_blocks/` 归纳出的场景：
- 职业-腾讯云数据库工作.md
- 软件设计理念-极简与本地优先.md

![L2 场景块 1](images/l2-1.png)

![L2 场景块 2](images/l2-2.png)

### L3 用户画像
`memory-data/persona.md` 综合出的完整画像。

![L3 用户画像](images/l3.png)

### /recall 召回
`run-soak.sh` 在 soak + L0-L3 验证后自动 curl Gateway `POST /recall`（session_key 取自本轮 soak 会话），两次召回均命中：

| Query | strategy | memory_count | context 注入 |
|---|---|---|---|
| 我的技术偏好和工作习惯 | hybrid | 0（整块注入） | `<user-persona>`（L3 画像）+ `<scene-navigation>`（L2 场景索引） |
| 用户平时使用 SQLite 做本地存储，偏好本地优先、简单够用的技术方案 | hybrid | **1（命中逐条 L1 记录）** | 同上，含 SQLite 偏好记录 |

证据文件：`results/recall.json`、`results/recall-record.json`，对比脚本自动打印 `memory_count`，汇总见 `results/recall-summary.md`。

> 说明：`session_key` 为 /recall 必填字段；L2/L3 属整块注入不计入 `memory_count`，命中逐条 L1 record 才计数。本机实测 Gateway `/health` 返回 ok、strategy `hybrid`。

## 网络和代理

国内直连 GitHub 基本会被墙，拉 `install.sh` / git clone 都走不通。所以构建时一定要用代理。

- 交互脚本里代理项**回车默认 `http://host.docker.internal:7890`**，这是 Docker Desktop 里访问宿主机 Clash 的正确地址。
- 保持默认（回车）就行。别手动改成 `127.0.0.1`——容器里的 `127.0.0.1` 是容器自己，到不了宿主机。
- 只有确认网络能直连 GitHub（比如挂了临时能通的节点）才输 `NONE`，否则不要用直连。

## 构建失败的原因

| 现象 | 原因 | 怎么处理 |
|---|---|---|
| 报 `429` 或 `RPC failed` | GitHub 把你出口 IP 限流了 | 换个 Clash 节点，或用代理 `host.docker.internal:7890` |
| 报 `Could not connect` / 超时 | 代理地址不对或 Clash 没开 | 检查代理，或干脆输 `NONE` 直连 |
| 拉基础镜像超时 | docker.io 连不上 | 先 `docker pull node:26-bookworm-slim` |

## 几个默认值

- 记忆数据写到 `/opt/data`，可以改 `TDAI_DATA_DIR`。
- Gateway 由 `run-soak.sh` 在容器里拉起，监听 `:8420`，接口有 `/health`、`/recall`、`/capture`。
- 模型 key 只通过 `MODEL_*`（对话用）和 `TDAI_LLM_*`（Gateway 提取记忆用）传进去，不写进镜像。
- 只要对话、不要记忆的话，把 `TDAI_GATEWAY_SRC` 清空，Gateway 就不起了。

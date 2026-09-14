# 第三周 · 进阶 1 —— 记忆插件下 L0-L3 真正生成

在**已装记忆插件**（memory_tencentdb）的 Hermes 上，用 soak 脚本驱动**富含事实**的多轮对话，让记忆系统的 L0-L3 四层真正落库，并用 `check-l0l3.mjs` 验证 + 截图。

## 文件

- `soak.mjs` — 从 `../1-basic-soak` 复用（带 `--wait-after`），对话 + 报 JSON
- `conversation.jsonl` — **事实剧本**（10 条，含身份/偏好/约束等）
- `check-l0l3.mjs` — 对话跑完后，检测 L0-L3 四层是否落库，输出结构化 JSON（可用于验收）
- `memory-evidence/` — L0/L1/L2/L3 四层截图

## 前置：装好记忆插件 + 起 Gateway

前提是 Hermes 已配置 `memory.provider: memory_tencentdb`，且 Gateway（:8420）在跑。装插件的可复用脚本见 `../3-full-pipeline/install-memory.sh`；也可以参考官方 `install_hermes_memory_tencentdb.sh`。

## 用法

```bash
# 1. 跑 soaked 对话（用事实剧本），跑完等 120s 让记忆管道沉降
node soak.mjs --hermes hermes \
  --conversation conversation.jsonl \
  --rounds 10 --interval 5 --max-total-seconds 600 \
  --wait-after 120 --result-file result.json

# 2. 检测 L0-L3 是否生成（--json 输出结构化结果，退出码 0=四层全在）
node check-l0l3.mjs --data-dir "$TDAI_DATA_DIR" --json
```

`TDAI_DATA_DIR` 默认是 `~/.memory-tencentdb/memory-tdai`（Linux）或 `C:\Users\<你>\.memory-tencentdb\memory-tdai`（Windows）。

## 验证 L0-L3 真正生成的截图

| 层 | 位置 | 截图 |
|---|---|---|
| **L0** 原始对话 | `conversations/*.jsonl` | 列出有该日期的 jsonl |
| **L1** 结构化事实 | `records/*.jsonl` | 抽出内容（type + content） |
| **L2** 场景块 | `scene_blocks/*.md` | 打开 scene 块文件 |
| **L3** 用户画像 | `persona.md` | 打开 persona.md |
| **/recall 召回** | Gateway `POST /recall` | curl 召回结果显示命中 |

`check-l0l3.mjs` 会把每层的非空/文件数打印出来，四张证据（L0-L3 + /recall）拼在一起，证明"记忆真的生成且可用"。截图放进 `memory-evidence/`。以下为本机实际跑出并截取的 L0-L3 四层 + /recall 召回：

### L0 原始对话
![L0 原始对话](L0-conversations.png)

### L1 结构化事实
![L1 结构化事实](L1-records.png)

### L2 场景块
![L2 场景块](L2-scene.png)

### L3 用户画像
![L3 用户画像](L3-persona.png)

### /recall 召回
![/recall 召回结果](memory-evidence/recall结果.png)

> 说明：`l2记忆.png` 其实拍的是 persona（L3），`l3记忆.png` 拍的是 scene 块（L2），已按真实内容改名为 `L3-persona.png` / `L2-scene.png`。

## /recall 召回验证

Gateway 起着时，用 curl 验证召回（响应保存为 JSON 证据，中文用编辑器 UTF-8 打开可正常显示）：

```bash
# 记录级召回：命中 L1 记录（memory_count ≥ 1）
curl -s -X POST http://localhost:8420/recall \
  -H "Content-Type: application/json" \
  -d '{"query":"用户平时使用 SQLite 做本地存储，偏好本地优先、简单够用的技术方案","session_key":"20260902_193309_a3034f","limit":5}' \
  -o memory-evidence/recall-result-2.json

# 画像/场景召回：返回 context 注入 <user-persona>（L3）与 <scene-navigation>（L2）
curl -s -X POST http://localhost:8420/recall \
  -H "Content-Type: application/json" \
  -d '{"query":"我的技术偏好和工作习惯","session_key":"20260902_193309_a3034f","limit":5}' \
  -o memory-evidence/recall-result.json
```

实际召回输出（Gateway `:8420`，strategy `hybrid`）：

| Query | memory_count | context 注入 | 结果文件 |
|---|---|---|---|
| 我的技术偏好和工作习惯 | 0 | `<user-persona>`（L3 画像）+ `<scene-navigation>`（L2 场景索引）| `memory-evidence/recall-result.json` |
| 用户平时使用 SQLite 做本地存储，偏好本地优先、简单够用的技术方案 | **1（命中逐条 L1 记录）** | 同上，含 SQLite 偏好记录 | `memory-evidence/recall-result-2.json` |
| 所有数据库变更必须先通过测试环境验证才能上生产 | 0 | persona + scene 边界注入 | `memory-evidence/recall-result-3.json` |

三条 query 的召回 context 均包含与 soak 剧本一致的事实（任德霖 / TencentDB / SQLite 本地优先 / 早上 review 晚复盘 / 变更须先过测试环境验证），personas 人可读汇总见 `memory-evidence/recall-summary.md`。说明：`session_key` 为必填字段（缺失会报 `Missing required fields: query, session_key`），取 soak 会话的 session_key 或任意字符串；L2/L3 属于整块注入不计入 `memory_count`，命中逐条 L1 record 才计数。

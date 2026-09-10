# Week3 基础要求：Hermes soak 自动对话脚本（1-basic-soak）

**目标**：把第二周「手动 docker build 出一台干净 Hermes」往前推一步——提供自动对话脚本，让 Hermes 自己跟自己对话很多轮，验证长时间稳定、能正常回复，最后输出结构化结果，明确 pass / fail。

## 文件

| 文件 | 说明 |
|---|---|
| `soak.mjs` | soak 驱动脚本（Node.js，**零依赖**，只需 Node ≥ 18） |
| `conversation-chat.txt` | 多轮闲聊剧本（一行一句，纯日常话题，不触发工具/不建文件） |
| `run-basic.sh` | 一键脚本：build（复用第二周 Dockerfile）→ 起容器 → 写模型配置 → 跑 soak |

## 用法

### 方式一：一键脚本（推荐，在装好 Docker 的 Linux 虚拟机上执行）

```bash
cd memory-rhinobird-homework/xiezengye/week3/1-basic-soak

MODEL_API_KEY=sk-xxxx \
MODEL_BASE_URL=https://api.lkeap.cloud.tencent.com/v1 \
MODEL_NAME=deepseek-v3.2 \
bash run-basic.sh
```

结果落在 `results-<时间戳>/`（每次运行独立目录，不覆盖历史）：`result.json`（结构化判定）、`report.txt`（人类可读报告）、`conversation.jsonl`（逐轮对话记录）。

### 方式二：手动分步（理解原理用）

```bash
# 1. 用第二周 Dockerfile 构建镜像
docker build -f ../../week2/Dockerfile --build-arg HERMES_VERSION=v2026.8.27 \
  -t hermes:v2026.8.27 ../../week2

# 2. 起容器
docker run -d --name hermes-basic hermes:v2026.8.27 sleep infinity

# 3. 写模型配置（config.yaml + .env）
docker exec hermes-basic mkdir -p /root/.hermes
docker exec hermes-basic bash -c 'cat > /root/.hermes/config.yaml <<EOF
model:
  default: "deepseek-v3.2"
  provider: "custom"
  base_url: "https://api.lkeap.cloud.tencent.com/v1"
  api_key: "sk-xxxx"
EOF
printf "OPENAI_API_KEY=sk-xxxx\n" > /root/.hermes/.env'

# 4. 拷脚本进容器并运行
docker cp soak.mjs hermes-basic:/opt/soak.mjs
docker cp conversation-chat.txt hermes-basic:/opt/conversation-chat.txt
docker exec hermes-basic node /opt/soak.mjs \
  --hermes hermes --conversation /opt/conversation-chat.txt \
  --rounds 10 --interval 5 --max-total-seconds 600 \
  --expected-version v2026.8.27 --out-dir /opt/soak-out

# 5. 收结果
docker cp hermes-basic:/opt/soak-out/. ./results/
```

## soak.mjs 可配置参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--rounds N` | 10 | 总对话轮次 |
| `--interval N` | 5 | 每轮之间的等待秒数 |
| `--max-total-seconds N` | 600 | 总对话时长上限，到点即止 |
| `--per-round-timeout-ms N` | 240000 | 单轮超时，超时 kill 并记失败 |
| `--max-consecutive-failures N` | 3 | 连续失败熔断，提前终止 |
| `--conversation PATH` | — | 多轮剧本（一行一句，循环取用） |
| `--prompt "文本"` | 内置问候 | 单条模式：每轮发同一句 |
| `--expected-version vX` | — | 校验 `hermes --version` 与期望一致 |
| `--out-dir PATH` | ./soak-out | 结果输出目录 |

## 输出示例（result.json）

```json
{
  "passed": true,
  "hermes_version": { "raw": "Hermes Agent v0.20.6 (2026.8.27)", "release_date": "2026.8.27", "verified": true },
  "rounds": { "total": 10, "executed": 10, "passed": 10, "failed": 0 },
  "stats": { "total_duration_seconds": 412.3, "avg_round_ms": 29450, "p50_round_ms": 28100, "p95_round_ms": 52000 },
  "failures": [],
  "termination_reason": "completed"
}
```

**判定 `passed: true` 的条件**：至少跑了 1 轮 && 所有已执行轮次全部成功 && 版本校验通过（若指定）&& 正常跑完（未被超时截断/熔断/中断）。人类可读的进度日志走 stderr，stdout 只有最终 JSON，方便 `docker logs` / CI 消费。

## 对话方式说明

Hermes 是 CLI Agent，没有 openclaw 那样的 HTTP `/v1/chat/completions` 接口。本脚本借 openclaw soak 的「循环 + 参数 + 出结果 + 容错」骨架，把对话接口换成 Hermes 的**单轮模式**：每轮 `spawn` 一个 `hermes -z "<prompt>"` 子进程，捕获 stdout 作为回复。

## 异常容错清单（对应硬要求 4）

| 异常 | 处理 |
|---|---|
| 单轮无响应 | 超过 `--per-round-timeout-ms` 强制 kill，记该轮失败 |
| 非零退出码 | 记失败，附 stderr 尾部 |
| 空响应（退出码 0 但无输出） | 记失败 |
| 报错回复（退出码 0 但输出是错误文本，如 `HTTP 401: not authorized`） | 正则识别，记失败——**避免假通过** |
| 连续失败 | 达到 `--max-consecutive-failures` 熔断终止 |
| 总时长到点 | 截断并标注 `termination_reason` |
| Ctrl+C / SIGTERM | 输出已跑部分的结果后按 130/143 退出 |
| 模型凭证错误（如 API Key 无效） | 每轮都判失败 → 熔断 → 整体 fail（可用此演示容错） |

## 演示异常容错（验收标准 4）

故意给一个错的 API Key：

```bash
MODEL_API_KEY=sk-invalid \
MODEL_BASE_URL=https://api.lkeap.cloud.tencent.com/v1 \
MODEL_NAME=deepseek-v3.2 \
bash run-basic.sh
```

预期：每轮回复 `HTTP 401: not authorized`（退出码 0 的假成功被识别）→ 连续失败 3 轮熔断 → `result.json` 为 `passed: false`，`termination_reason: "circuit_breaker"`，失败明细里能看到 401 文本。**脚本报失败而不是假通过**，截图这份 result.json 即可。

## 注意事项

1. **模型凭证三个环境变量必填**（`MODEL_API_KEY` / `MODEL_BASE_URL` / `MODEL_NAME`），用你 week1 对话时用的那家即可；
2. **版本号传日期式 git tag**（如 `v2026.8.27`），这是第二周就确认过的约定；
3. **耗时预期**：`hermes -z` 每轮一个独立进程（含启动开销），单轮几秒到几十秒都正常，10 轮约 5-10 分钟；首次跑请耐心等；
4. soak 判定不含「回复质量」——只验证能不能正常对话（能回、不报错、不超时），语义质量交给进阶 1 的记忆验证；
5. 镜像里**没有**记忆插件（第二周硬要求），本脚本在干净镜像上即可运行；带插件的跑法见 `../2-memory-l0l3/`。

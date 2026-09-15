# 1-basic-soak · 基础层：Hermes soak 自动对话脚本

> 腾讯犀牛目人才培养计划 · 第三周作业 · 基础要求

本目录是**必交**的"基础层"交付物：**一个零依赖的 Node.js 脚本，让 Hermes 自己跟自己聊 N 轮并出结构化结果**，验收会议要求的那 4 条全部满足。

---

## 文件清单

| 文件 | 用途 |
|---|---|
| `soak.js` | 主脚本：可配置轮次/间隔/总时长，结构化 JSON 输出，异常容错 |
| `README.md` | 本文件 |

---

## 快速开始

### 前提

1. `hermes` CLI 已装（v0.20.5 已验证）
3. `hermes gateway run` 正在运行，API Server 监听 `127.0.0.1:8642`
4. 配置文件 `config.yaml` 里 `platforms.api_server.enabled=true` 且 `key` 长度 ≥ 16

### 一行命令跑通

```bash
# 基础跑：10 轮对话，间隔 1 秒
node soak.js --rounds 10 --interval 1000

# 跑 30 轮 ~10 分钟（验收场景：时长上限 600 秒）
node soak.js --rounds 30 --interval 1000 --duration 600

# 故意给错 Key，演示容错（脚本报失败，不假通过）
node soak.js --rounds 5 --bad-key
```

### 输出

跑完会在 `soak-out/<时间戳>/` 下生成：

- `turns.jsonl`  每行 = 一轮对话结果 `{round, ok, status, ms, prompt, reply?, error?, ...}`
- `meta.json`   元信息 + 总体 `overall_pass`（pass / fail / partial）+ pass率 + P50/P95延迟
- `report.txt`  人类可读汇总

### 退出码

- `0` = 至少一轮成功（脚本能跑、整体正常）
- `2` = **所有轮次都失败**（用于验收容错：故意给错 Key 时应退出 2 而不是假通过）

---

## 配置项（命令行 / 环境变量 / 默认值）

| 参数 | CLI  | 环境变量 | 默认值 | 说明 |
|---|---|---|---|---|
| 轮次 | `--rounds N` | — | 30 | 目标对话轮数 |
| 间隔 | `--interval MS` | — | 1000 | 每轮间隔毫秒 |
| 总时长 | `--duration S` | — | 0 | 上限秒数，0=不限 |
| 模型 | `--model NAME` | — | hermes-agent | 调用的模型名 |
| API base | `--base-url URL` | `HERMES_BASE_URL` | http://127.0.0.1:8642/v1 | Hermes API Server |
| API key | `--api-key KEY` | `HERMES_API_KEY` | （从 `config.yaml` 读） | 长度 ≥ 16 |
| Prompt | `--prompt TEXT` | — | 见下方默认池 | 单一问题轮换发送 |
| Prompt 文件 | `--prompt-file PATH` | — | — | 每行一个 prompt |
| 超时 | `--timeout-ms MS` | — | 60000 | 单轮 HTTP 超时 |
| 故意错 Key | `--bad-key` | — | false | 演示容错 |
| 输出目录 | `--out-dir PATH` | — | `./soak-out/<ts>` | 结果落盘位置 |

---

## 默认 Prompt 池（20 条生活化对话）

脚本内置 20 条不同话题的 prompt，每轮顺序取一条。如果对话轮次超过 20 条，会循环复用。这样设计是为了：
1. **避免纯寒暄**（"你好"），让对话有意义；
2. **保证多轮上下文变化**，Hermes 不会陷入"是是是"循环。

如果你想做"基础 + 进阶1"复用同一个脚本，进阶1 会用 `--prompt-file` 指定富含事实的剧本（见 `2-memory-l0l3/facts.txt`）。

---

## 异常容错 4 条

| 场景 | 怎么处理 |
|---|---|
| 连接拒绝（gateway 未启） | `error: ECONNREFUSED`，记到 turns.jsonl，整体记 fail，**继续下一轮** |
| HTTP 401（Key 错） | `error: http-401`，记 fail，**不崩** |
| HTTP 500（后端错误） | `error: http-500`，记 fail，**不崩** |
| 超时（timeoutMs 到点） | `error: timeout`，记 fail，**不崩** |

`--bad-key` 选项专门用来跑容错演示：脚本应该**所有轮次都 fail**，但**仍正常输出 JSON**，并且**退出码 = 2**（让 CI 能识别"故意失败"而非"被忽略"）。

---

## 验收 4 条对照

会议列出的 4 条硬要求 → 本脚本如何满足：

| 验收点 | 实现位置 |
|---|---|
| ① 可配置（轮次 / 间隔 / 总时长） | `--rounds --interval --duration` + env 兜底 |
| ② 结构化 JSON（含轮次/耗时/Pass/Fail） | `meta.json` 字段：`summary.{total,pass,fail,pass_rate,latency_p50_ms,latency_p95_ms}` + `overall_pass` |
| ③ 自动持续对话（无需人干预） | 单 loop，跑完自动 `process.exit()` |
| ④ 异常容错 | 4 条全见上面 |

---

## 验收现场操作建议

```bash
# 1. 正常跑
node soak.js --rounds 20 --interval 500
# 退出码 0；turns.jsonl 中 20 行；meta.json 里 pass=20 fail=0

# 2. 演示容错（故意给错 Key）
node soak.js --rounds 5 --bad-key
# 退出码 2；meta.json 里 pass=0 fail=5；errByStatus.http-401=5

# 3. 演示中断（先关 gateway，再跑）
node soak.js --rounds 5 --interval 500
# 退出码 2；meta.json 里 pass=0 fail=5；errByStatus.ECONNREFUSED=5
```

---

## 不在本目录范围内的事

- 记忆验证（L0-L3）→ 见 `../2-memory-l0l3/`
- 一键流水线 → 见 `../3-full-pipeline/`
- Dockerfile（第二周交付） → 见 `../week2/Dockerfile`
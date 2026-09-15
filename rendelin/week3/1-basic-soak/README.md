# 第三周 · 基础要求 —— Hermes soak 自动对话脚本

自动跟 Hermes 持续对话（`hermes -z`），验证它能正常回复、长时间稳定，最后输出结构化 JSON（明确 pass/fail、含轮次与耗时统计）。

## 文件

- `soak.mjs` — soak 驱动脚本（Node.js，零依赖，只依赖 Node 内置）
- `conversation.jsonl` — 多轮对话剧本（纯闲聊：爱好/电影/天气，不触发工具不建文件），默认启用，验证长期稳定对话
- `test/` — 单元测试（用 mock Hermes，不需要 Docker / 真实模型）

> 进阶要求（L0-L3 记忆）见 `../2-memory-l0l3/`；一键流水线见 `../3-full-pipeline/`。

## 用法

```bash
# 基本：默认内置纯闲聊剧本，10 轮、间隔 5s、总时长上限 600s
node soak.mjs --hermes hermes

# 指定参数
node soak.mjs --hermes hermes --rounds 20 --interval 3 --max-total-seconds 300

# 换任意剧本路径（每轮发下一条，轮数多于条数则循环）
node soak.mjs --hermes hermes --conversation conversation.jsonl --rounds 14

# 跑完后等 90s，给记忆管道留出 L1/L2/L3 沉降时间（进阶需求用）
node soak.mjs --hermes hermes --rounds 10 --wait-after 90

# 输出到文件 + 断言版本
node soak.mjs --hermes hermes --expected-version v2026.8.19 --result-file result.json
```

## 可配置参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--rounds N` | 10 | 总共对话多少轮 |
| `--interval N` | 5 | 每轮之间的等待时间（秒） |
| `--max-total-seconds N` | 600 | 全程时长上限，到点即止 |
| `--per-round-timeout-ms N` | 180000 | 单轮超时 kill 并记失败 |
| `--max-consecutive-failures N` | 3 | 连续失败熔断，提前终止 |
| `--prompt "..."` / `--conversation <path>` | 内置闲聊 / — | 固定单条 / 多轮剧本 |
| `--expected-version vX` | — | 断言 `hermes --version` 版本匹配 |
| `--result-file PATH` | — | 额外把 JSON 落盘 |
| `--wait-after N` | 0 | 所以后额外等待 N 秒，让记忆管道（L1/L2/L3）沉降后再退出 |

## 输出

```json
{
  "passed": true,
  "hermes_version": { "releaseDate": "2026.8.19", "verified": true },
  "config": { "rounds": 14, "interval_seconds": 5, "max_total_seconds": 600, "conversation_turns": 16 },
  "rounds": { "total": 14, "executed": 14, "passed": 14, "failed": 0 },
  "stats": { "total_duration_seconds": 412.3, "avg_round_ms": 29450, "p95_round_ms": 52000 },
  "failures": [],
  "termination_reason": "completed"
}
```

判定 `passed: true`：所有已执行轮次成功 + 至少跑了 1 轮 + 版本校验通过 + 没被截断。

容错：单轮超时 kill、非零退出码捕获、空响应、报错回复识别（如 `HTTP 401` → 判失败）、连续失败熔断、总时长截断、SIGINT/SIGTERM 中断时输出部分结果。

退出码：`0` 通过；`1` 失败；`2` 参数错误；`130/143` 被中断。

## 运行示例（验收标准 1/2/3）

跑 5 轮、间隔 2s、总时长上限 90s，输出结构化 JSON（`verify.json`）：

```bash
node soak.mjs --hermes hermes --rounds 5 --interval 2 --max-total-seconds 90 --result-file verify.json
```

运行结果（终端逐轮记录 + 结构化 JSON，见 `verify.json`）：

![N轮对话终端](n轮对话示例2.png)

`verify.json` 内容（`passed: true`，含三参数和统计）：

![verify.json](n轮对话示例1.png)

`verify.json` 三处对应验收：
- `config.rounds / interval_seconds / max_total_seconds` —— **三参数生效**
- `rounds.passed / failed` —— **pass/fail 明确**
- `stats.total_duration_seconds / avg_round_ms / p95_round_ms` —— **耗时统计**

## 测试（不需要 Docker / 模型）

```bash
node test/test-soak.mjs     # 39 个用例
```

## 异常容错（验收标准 4）

soak 能把 `HTTP 401` 等报错回复识别成失败，而不是假通过。这有单元测试覆盖：

```bash
node test/test-soak.mjs
```

其中这条用例专门验证 401 报错回复会被判为失败：

```
T10 error-looking reply (HTTP 401) counted as failure, not OK
  ✓ all rounds failed (error reply)
  ✓ failure mentions error
39 passed, 0 failed
```

说明：`soak.mjs` 的 `looksLikeErrorReply()` 会匹配 `HTTP 401` / `not authorized` / `invalid api key` 等文本，即使 Hermes 的 exit code 是 0，也会判为报错回复、记为一轮失败。所以**不会把报错当成功**。

识别真实报错（exit 0 但输出错误文本）会判失败，不假通过。终端实际跑（3 轮全 FAILED，报 `HTTP 401`）：

![报错401终端](报错401示例.png)

结果 `passed: false`：

![报错401结果](报错示例2.png)

## 跟第 2 周 Dockerfile 的关系

第 2 周交付的 Dockerfile（交付物 A）会 `COPY` 本文件夹的 `soak.mjs`、`conversation.jsonl` 并在容器启动时运行（题目要求"镜像启动后自动执行自动对话"）。文件内容一致，此处独立可跑。

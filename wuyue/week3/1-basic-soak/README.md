# 1-basic-soak —— Hermes 自动对话 soak 工具（基础要求）

零依赖 Node.js 长稳测试工具：自动一轮接一轮地调用 Hermes 对话，验证长时间运行
稳定性与记忆管道状态，输出结构化 JSON（明确 pass / fail）与人工可读报告。

## 与参考脚本 openclaw-soak-tool 的关系

课程提供了参考实现 `openclaw-soak-tool`（standalone-soak.mjs，零依赖 Node.js），
本目录 `soak.js` **借它的骨架、换 Hermes 的接口**，结构映射如下：

| 参考 standalone-soak.mjs | Hermes 版 soak.js（本目录） |
|---|---|
| 经 OpenClaw HTTP `/v1/chat/completions` 对话 | 子进程调用 Hermes CLI headless：`hermes chat -q <消息> -Q`（答完即退，退出码+stdout 判定） |
| 同一 sessionKey 连续对话（session pinning） | `--session-mode same`：首轮解析 `session_id`，后续轮 `--resume` 续同一会话（默认 `new`：每轮新会话，跨会话召回更严格） |
| 六类话题池循环 | 内置 12 条中文 TOPICS 话题池（技术/习惯/偏好/事件/指令/成长） |
| 记忆探针：每 20 轮 植入→回忆→关键词核对 | `--probe-every N`：第 N/2 轮植入、第 N 轮验证（内置 3 组中文探针，`--probe-file` 可自定义），命中口径一致（≥⌈k/2⌉ 关键词） |
| Gateway 日志监控（error/warn/tdai 事件，2s 轮询） | `--log-files`：增量轮询 Hermes/tdai 日志，事件写 log-events.jsonl |
| 进程资源监控（RSS/CPU/FD，10s） | `--resource-interval-ms`：纯 `/proc` 实现（容器内无 ps/lsof 也能用），自动发现 memory gateway 进程 |
| 每 100 轮落盘 + meta-snapshot | 每轮流式写 conversations.jsonl + `--flush-every` 写快照（防中断丢数据） |
| 输出 conversations/resources/log-events/probes/meta/report | 同名输出（见下） |
| 连续失败提前退出（默认 50） | `--max-consecutive-failures N`（默认 0=关） |
| .env 配置 + shell 入口 | `run-hermes-soak.sh` + `.env`（SOAK_* 键） |

## 快速开始

```bash
# 运行环境：第二周镜像起的 Hermes 容器（内置 node + hermes + 记忆插件 + Gateway）
docker run -d --name hermes-soak \
  -e MODEL_API_KEY="your-key" -e MODEL_BASE_URL="https://api.deepseek.com/v1" \
  -e MODEL_NAME="deepseek-chat" -e MODEL_PROVIDER=custom \
  -v hermes_data:/opt/data hermes-memory:v2026.8.31

docker cp soak.js run-hermes-soak.sh hermes-soak:/root/

# 基础跑法：10 轮、间隔 6s（默认话题池）
docker exec -w /root hermes-soak node soak.js --rounds 10 --interval-ms 6000 --out /root/soak-out

# 参考入口（对齐 run-standalone-soak.sh：--smoke / --duration / --interval ...）
docker exec -w /root hermes-soak ./run-hermes-soak.sh --rounds 10 --interval 6000

# 带记忆探针 + 资源/日志监控的跑法
docker exec -w /root hermes-soak node soak.js --rounds 16 --interval-ms 6000 \
  --probe-every 8 --resource-interval-ms 5000 \
  --log-files /opt/data/logs/agent.log,/opt/data/logs/errors.log \
  --out /root/soak-out-probe

# 复制结果回宿主机
docker cp hermes-soak:/root/soak-out ./out
```

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--rounds N` | 10 | 目标对话轮次 |
| `--interval-ms N` | 5000 | 轮间间隔（毫秒） |
| `--duration-sec N` | 0（不限） | 总时长上限，到点即停（`stop_reason=duration`） |
| `--timeout-ms N` | 180000 | 单轮超时，超时杀进程记 failed=timeout 并继续 |
| `--message-file F` | — | 剧本文件（一行一轮，超出循环取；进阶任务用事实剧本） |
| `--auto-text T` | — | 固定文案模板（`{i}` `{n}` 占位）；缺省用内置话题池 |
| `--session-mode new\|same` | new | same=首轮后 `--resume` 同一 session（对齐参考的会话固定） |
| `--probe-every N` | 0（关） | 记忆探针：每 N 轮一组（第 N/2 轮植入、第 N 轮回忆核对关键词） |
| `--probe-file F` | 内置 3 组 | 自定义探针 JSON：`[{id,plantMessage,recallQuestion,expectedKeywords}]` |
| `--log-files a,b` | — | 增量监控日志（error/warn/memory-tdai 事件） |
| `--resource-interval-ms N` | 10000 | RSS/CPU/FD 采样间隔（0=关） |
| `--max-consecutive-failures N` | 0（关） | 连续失败提前退出（参考默认 50） |
| `--pass-rate R` | 0.9 | pass 判定成功率阈值 |
| `--hermes CMD` | hermes | hermes 可执行文件 |
| `--out DIR` | 自动 | 输出目录 |
| `--env NAME=VAL` | — | 附加子进程环境变量（坏 Key 容错演示用） |

环境变量与 `.env`：支持 `SOAK_ROUNDS / SOAK_INTERVAL_MS / SOAK_DURATION_SEC /
SOAK_TIMEOUT_MS / SOAK_HERMES / SOAK_SESSION_MODE / SOAK_PROBE_EVERY /
SOAK_LOG_FILES / SOAK_RESOURCE_INTERVAL_MS / SOAK_OUTPUT_DIR ...`（CLI 优先）。

## 输出结构（对齐参考命名）

```
out-<ts>/
├── conversations.jsonl   # 每轮一行：round/label/category/success/status/durationMs/responseLength/error
├── resources.jsonl       # 资源快照：RSS(kB)/CPU%/FD，每 --resource-interval-ms 一条
├── log-events.jsonl      # 日志事件：error/warn/memory-tdai
├── probes.json           # 记忆探针明细：recalled/foundKeywords/missingKeywords
├── meta.json             # verdict + 参考字段(successCount/latency p50-p99/topErrors/probes/resources/logs)
│                         #   + 作业字段 results{total,passed,failed,success_rate}
├── report.txt            # 人类可读报告（含 RECALL PROBES / RESOURCES 段落）
├── meta-snapshot.json    # 中间快照（每 --flush-every 轮；被 kill 也能找回最近状态）
└── rounds/round-NNN.{out,err}.txt   # 每轮完整原始输出
```

单轮判定：`exit=0 且 stdout 非空且无错误特征` → ok；
失败分类（不崩溃、继续跑）：`timeout` / `exit-<code>` / `spawn-error` / `empty-reply` / `error-reply`。
判定已剔除误报源：session_id 里的 "403"、正文里的 "500 元" 等需要 HTTP/status 语境才算错误码。

## 验收对照（基础要求 4 条）

1. **自动完成 N 轮并输出结构化 JSON**：`conversations.jsonl` + `meta.json`（见 `out-basic/`）。
2. **轮次 / 间隔 / 总时长三参数生效**：`meta.json.params` 回显；`out-duration/` 实测 90s 截停
   （`stop_reason=duration`，实际轮数 < 目标轮数）。
3. **明确 pass/fail + 轮次与耗时统计**：`meta.verdict` + `results` + `latency{p50,p95,...}`。
4. **异常容错演示**：`out-badkey/` 故意注入错误 API Key —— 每轮 FAIL、`verdict=fail`、
   进程正常退出码 1，不崩溃、不假通过。

## 实测样本（2026-09-06，deepseek-chat，镜像 local-v2026.8.31，Hermes v2026.8.31）

| 样本 | 命令要点 | 结果 |
|---|---|---|
| `out-basic/` | `--rounds 10 --interval-ms 6000`（话题池 + 资源监控） | verdict=pass, 10/10, p50≈15.1s / p95≈18.8s |
| `out-duration/` | `--rounds 100 --duration-sec 90 --interval-ms 20000` | 90s 截停 3 轮, stop_reason=duration, 3/3 pass |
| `out-badkey/` | `--rounds 3` + 改坏 api_key | verdict=fail, 0/3, `HTTP 401 ... api key is invalid` |
| `out-probe/` | `--rounds 16 --probe-every 8 --resource-interval-ms 5000 --log-files ...` | verdict=pass 16/16; 记忆探针 **2/2 RECALLED**（3/3、2/3 关键词）; 资源监控发现 gateway（RSS 峰值 595.8MB、CPU 峰值 11.2%、FD 34）; 日志事件 64 条 memory-tdai |

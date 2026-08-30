# 第 3 周作业 —— 交付物 B：Hermes 自动对话脚本

自动跟 Hermes 持续对话，验证它能正常回复、长时间稳定；最后输出结构化 JSON（明确 pass/fail、含轮次与耗时统计）。

## 文件

- `soak.mjs` —— soak 驱动脚本（Node.js，零依赖）
- `conversation.jsonl` —— 多轮对话剧本（纯闲聊：爱好、电影、食物、猫、心情这些，不涉及项目/文件/任务，所以不触发工具、不创建文件），默认启用，用来验证 Hermes 长时间稳定对话
- `entrypoint.sh` —— 容器入口（启动即生成模型配置并跑 soak）
- `build.bat` / `build.sh` —— 一键脚本：构建镜像（用第 2 周 Dockerfile）并运行自动对话
- `test/` —— 单元测试（用 mock Hermes，不需要 Docker / 真实模型）

## 用法

```bash
# 基本：默认用内置多轮剧本（纯闲聊），10 轮、间隔 5s、总时长上限 600s
node soak.mjs --hermes hermes

# 指定参数
node soak.mjs --hermes hermes --rounds 20 --interval 3 --max-total-seconds 300

# 换任意剧本路径（每轮发下一条，轮数多于条数则循环）
node soak.mjs --hermes hermes --conversation conversation.jsonl --rounds 14

# 退化为"固定单条"（不再走剧本）
node soak.mjs --hermes hermes --prompt "Hi there! Just saying hello."

# 输出到文件
node soak.mjs --hermes hermes --result-file result.json
```

默认的 `conversation.jsonl` 是纯日常闲聊，Hermes 只会自然回话，不会调用工具、也不会创建文件——这样能长时间稳定地测"能不能正常对话"。每轮按剧本发下一条，轮数比剧本条数多就循环。想换剧本用 `--conversation <path>`，想退化成单条用 `--prompt <文本>`。

## 可配置参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--rounds N` | 10 | 总共对话多少轮 |
| `--interval N` | 5 | 每轮之间的等待时间（秒） |
| `--max-total-seconds N` | 600 | 全程时长上限，到点即止 |
| `--per-round-timeout-ms N` | 180000 | 单轮超时 kill 并记失败 |
| `--max-consecutive-failures N` | 3 | 连续失败熔断，提前终止 |
| `--prompt "..."` / `--conversation <path>` | 内置闲聊剧本 / — | 固定单条 / 多轮剧本（默认用内置闲聊剧本） |
| `--expected-version vX` | — | 断言 `hermes --version` 版本匹配 |
| `--result-file PATH` | — | 额外把 JSON 落盘 |

这些参数在 build.bat / build.sh 里会逐个提示，回车用默认；也可以环境变量预置（`SOAK_ROUNDS` 等），或直接 `docker run -e SOAK_ROUNDS=14 ...`。

## 输出（JSON，走 stdout）

```json
{
  "passed": true,
  "hermes_version": { "releaseDate": "2026.8.19", "verified": true },
  "config": { "rounds": 14, "interval_seconds": 5, "max_total_seconds": 600, "conversation_turns": 14 },
  "rounds": { "total": 14, "executed": 14, "passed": 14, "failed": 0 },
  "stats": { "total_duration_seconds": 412.3, "avg_round_ms": 29450, "p95_round_ms": 52000 },
  "failures": [],
  "termination_reason": "completed"
}
```

判定 `passed: true` 的条件：所有已执行轮次成功 + 至少跑了 1 轮 + 版本校验通过 + 没被截断。

容错：单轮超时 kill、非零退出码捕获、空响应、报错回复识别（如 `HTTP 401` → 判失败）、连续失败熔断、总时长截断、SIGINT/SIGTERM 中断时输出部分结果。

退出码：`0` 通过；`1` 失败；`2` 参数错误；`130/143` 被中断。

## 测试（不需要 Docker / 模型）

```bash
node test/test-soak.mjs  
```

## 关于记忆验证

默认的 `conversation.jsonl` 是纯闲聊，不会沉淀记忆。如果要在**装了记忆插件的 Hermes** 上验证 L0-L3 记忆，就把剧本换成含丰富可提取事实的版本（比如身份、偏好、经历这些），或者直接用"装了插件的本地 Hermes"（不是这个镜像）对话后查数据目录 `~\.memory-tencentdb\memory-tdai\`。

## 跨周依赖

第 2 周交付的是 **Dockerfile**（构建镜像用，交付物 A），它 `COPY` 了本文件夹的 `soak.mjs`、`entrypoint.sh`、`conversation.jsonl` 并在启动时运行（因为题目要求"镜像启动后自动执行自动对话"）。

构建镜像时，把第 2 周的 `Dockerfile` 放到本文件夹（或把本文件夹的这三个文件复制到第 2 周目录），然后一键或手动构建：

```bash
# 一键（本目录自带 build.bat / build.sh，会提示版本/模型/soak 参数/代理）
build.bat          # 或 bash build.sh

# 手动（把第 2 周 Dockerfile 放进来后）
docker build --build-arg HERMES_VERSION=v2026.8.19 -t hermes-version-compat:v2026.8.19 .
docker run --rm -e MODEL_API_KEY=.. -e MODEL_BASE_URL=.. -e MODEL_NAME=.. -e MODEL_PROVIDER=custom \
  -e SOAK_ROUNDS=14 hermes-version-compat:v2026.8.19
```

网络：国内构建 GitHub 不通时，按脚本提示输入代理地址（本机 Clash 常用 `http://127.0.0.1:7890`；Docker Desktop 构建用 `http://host.docker.internal:7890`；Linux Docker 用宿主机 IP）。代理只作为 `--build-arg` 传给构建，避免 Docker Desktop 改写代理。

注：`soak.mjs` 同时也是第 2 周镜像构建时 COPY 进镜像的依赖脚本，两者内容一致。

感谢老师评阅，辛苦了！
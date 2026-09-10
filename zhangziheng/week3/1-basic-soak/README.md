# 第三周基础要求：Hermes 自动对话 Soak

这是一个零 npm 依赖的 Node.js 脚本。它调用的是 Hermes 自己的命令行接口：

```text
第一轮：hermes chat -q <prompt> --quiet
后续轮：hermes chat -q <prompt> --quiet --resume <session-id>
```

它没有照搬 OpenClaw 的 `/v1/chat/completions`。脚本从第一轮的标准错误流捕获 Hermes 输出的 `session_id`，后续轮次使用 `--resume` 续接同一个会话。

调用只使用 Hermes 0.19.0 和 0.20.6 均提供的公共参数，没有依赖 0.20.6 新增的 `--query-file`、`--create-if-missing` 或 `--run-budget`。prompt 通过 Node.js `spawn` 的参数数组直接传入，不经过 shell 拼接。

基础阶段只验证对话，因此脚本默认传入 Hermes 已定义的空工具集 `context_engine`，避免 TTS、浏览器等无关工具影响启动。需要其他工具时可用 `--toolsets` 覆盖。

## 四项要求对应关系

| 要求 | 实现 |
| --- | --- |
| 可配置参数 | `--rounds`、`--interval-ms`、`--duration-minutes`；三项同时约束执行，先达到轮次或总时长即停止 |
| 结构化结果 | 每轮写入 `conversations.jsonl`，结束写入 `meta.json`；总结果明确为 `pass` 或 `fail` |
| 自动持续对话 | 第一轮自动捕获 session ID，后续通过 `--resume` 复用同一个会话，无需人工输入 |
| 异常容错 | 捕获启动失败、非零退出、空响应和超时；失败会被记录，脚本仍生成最终报告 |

总体判定采用严格标准：至少完成一轮且所有轮次成功时为 `pass`；出现任意失败或被中断时为 `fail`。`pass` 退出码为 0，`fail` 退出码为 1。

## 前置条件

- Node.js 18 或更高版本；第二周镜像已经预装 Node.js 22。
- 已完成 Hermes 模型和 API Key 配置。
- 运行环境中能够执行 `hermes`，并已完成模型和 API Key 配置。

基础验收标准不限定运行环境：本机安装了 Hermes 就可以直接运行；Hermes 在容器里时，也可以把脚本放进容器运行，或者由本机脚本通过 `docker exec` 调用。为了与第二周成果和进阶一自然衔接，正式作业演示推荐使用第二周 Dockerfile 构建出的镜像。

## 在第二周镜像中运行

如果选择 Docker 环境，先使用第二周的原 Dockerfile 构建镜像，不要改写 Dockerfile。以下版本号仅为示例，脚本本身没有写死该版本：

```bash
docker build --progress=plain \
  --build-arg HERMES_VERSION=0.20.6 \
  -t hermes:0.20.6 \
  ../../第二周作业
```

下面示例将本目录挂载到容器的 `/workspace/soak`。请按照实际 provider 传入 API Key，并挂载已有的 Hermes 配置目录：

```bash
docker run --rm \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  -v hermes-home:/opt/hermes-home \
  -v "$PWD:/workspace/soak" \
  -w /workspace/soak \
  hermes:0.20.6 \
  node hermes-soak.mjs \
    --rounds 10 \
    --interval-ms 1000 \
    --duration-minutes 10
```

如使用其他 provider，请传入对应的环境变量，或在挂载的 Hermes home 中准备 `config.yaml`。API Key 不要写入 Dockerfile、脚本或提交文件。

## 在本机运行

如果本机已经安装并配置 Hermes，可以直接执行：

```bash
node hermes-soak.mjs \
  --rounds 10 \
  --interval-ms 1000 \
  --duration-minutes 10
```

也可以在本机运行脚本，但让它调用已启动容器中的 Hermes：

```bash
node hermes-soak.mjs \
  --command docker \
  --command-arg exec \
  --command-arg hermes-soak-container \
  --command-arg hermes \
  --rounds 10 \
  --interval-ms 1000 \
  --duration-minutes 10
```

此时 `hermes-soak-container` 容器必须已经启动，并已注入所需配置和 API Key。

也可以在已经启动且包含本脚本的容器内直接执行：

```bash
node hermes-soak.mjs \
  --rounds 10 \
  --interval-ms 1000 \
  --duration-minutes 10 \
  --output ./workspace/demo
```

三项核心参数含义：

- `--rounds`：最多执行多少轮。
- `--interval-ms`：一轮结束后，到下一轮开始前等待多少毫秒。
- `--duration-minutes`：整个循环最多运行多少分钟；支持小数，便于快速验证。

运行 `node hermes-soak.mjs --help` 可查看全部参数。也可以复制 `.env.example` 为 `.env` 使用环境变量配置；命令行参数优先。

## 输出

默认输出到 `workspace/run-<时间戳>/`：

```text
workspace/run-.../
├── conversations.jsonl  # 每轮 prompt、回复、耗时、状态和错误
└── meta.json            # 最终 pass/fail、配置、轮次和延迟统计
```

`meta.json` 中包含：

- 明确的 `status: pass | fail`
- 实际轮次、成功数、失败数和成功率
- 总耗时以及成功请求的 min/mean/P50/P95/max 延迟
- 按类型汇总的错误数量
- 最终停止原因：达到轮次、达到总时长或收到中断信号

## 自定义对话内容

使用 `--prompts prompts.example.json` 可替换内置对话。支持三种格式：

- `.json`：由 `{ "label", "message" }` 或字符串组成的数组
- `.jsonl`：每行一个 JSON 对象或字符串
- 其他文本文件：每个非空、非注释行作为一条 prompt

这个接口可以在进阶一中直接换成“富含事实”的剧本，无需重写循环和容错逻辑。

## Hermes 版本兼容性

脚本不判断或写死 Hermes 版本号，而是使用多个版本共有的 CLI 子集：`chat`、`-q`、`--quiet`、`--resume`、`--source`、`--toolsets`、`--model` 和 `--provider`。

当前已核对：

| 版本 | 公共 CLI 参数 | 兼容状态 |
| --- | --- | --- |
| Hermes 0.19.0 | 已核对并运行异常路径 | 兼容 |
| Hermes 0.20.6 | 已核对并运行异常路径 | 兼容 |

未来或更早版本只要保留上述公共参数并继续在标准错误流输出 `session_id: <id>`，即可使用同一脚本；如果 Hermes 将来改变 CLI 协议，脚本会明确记录 `session_id_missing` 或非零退出，而不会假装通过。

## 异常容错演示

例如传入错误 API Key。具体变量名按 provider 调整：

```bash
OPENAI_API_KEY=definitely-wrong \
node hermes-soak.mjs \
  --rounds 2 \
  --interval-ms 0 \
  --duration-minutes 1 \
  --output ./workspace/wrong-key
```

预期行为：Hermes 返回非零退出，脚本不会因未捕获异常崩溃；两轮失败均写入 `conversations.jsonl`，`meta.json` 的 `status` 为 `fail`，进程退出码为 1。

## 自动化测试

测试使用本地 mock Hermes，不消耗 API Key：

```bash
node --test tests/hermes-soak.test.mjs
```

覆盖正常多轮、非零退出和单轮超时三条路径。

# Hermes Soak 与记忆流水线设计

## 1. 目标与范围

第三周作业全部完成三个阶段：

1. `1-basic-soak`：Hermes 自动多轮对话、参数可配、异常容错和结构化结果。
2. `2-memory-l0l3`：用富含事实的剧本驱动已安装 `memory_tencentdb` 的 Hermes，验证 L0、L1、L2、L3 均非空，并验证 `/recall`。
3. `3-full-pipeline`：输入 Hermes 版本号，自动完成 build、启动容器、安装插件、启动 Gateway、运行 soak 和生成验收结果。

实现借鉴 `openclaw-soak-tool` 的结构，但不复制 OpenClaw 的 HTTP 接口、Gateway Token 或进程发现逻辑。

## 2. 技术选择

### 2.1 语言与职责

- Node.js 22 的 `.mjs` 脚本实现 soak 核心，仅使用内置模块，不增加 npm 依赖。
- Bash 脚本实现完整 Docker 流水线，负责组装已有工具，不承担对话统计逻辑。
- JSON 文件存放基础对话剧本与记忆剧本，使测试逻辑与测试数据分离。

### 2.2 Hermes 调用方式

`hermes -z` 虽然适合单次脚本调用，但 Hermes 0.19.0 的源码表明它是无状态通道，每次调用不恢复上一轮会话。为满足连续对话和记忆沉淀，soak 使用：

- 首轮：`hermes chat -Q -q <prompt> --source tool`
- 从首轮标准错误中提取 `session_id`。
- 后续轮：`hermes chat -Q --resume <session_id> -q <prompt> --source tool`

`-Q` 抑制横幅、spinner 和工具预览，便于程序捕获回答。`--resume` 保证每轮使用同一个 Hermes 会话。

soak 支持两种命令前缀：

- 本机：直接运行 `hermes`。
- 容器：运行 `docker exec <container> hermes`。

## 3. 目录与组件

```text
week3/
├── 1-basic-soak/
│   ├── Dockerfile
│   ├── hermes-soak.mjs
│   ├── run-soak.sh
│   ├── prompts.json
│   ├── hermes-config.yaml.example
│   ├── .env.example
│   ├── .gitignore
│   ├── README.md
│   └── results/
├── 2-memory-l0l3/
│   ├── Dockerfile
│   ├── hermes-soak.mjs
│   ├── run-soak.sh
│   ├── memory-prompts.json
│   ├── install-memory.sh
│   ├── tdai-gateway.json
│   ├── verify-memory.sh
│   ├── hermes-config.yaml.example
│   ├── .env.example
│   ├── .gitignore
│   ├── README.md
│   ├── results/
│   └── evidence/
└── 3-full-pipeline/
    ├── Dockerfile
    ├── hermes-soak.mjs
    ├── run-soak.sh
    ├── memory-prompts.json
    ├── install-memory.sh
    ├── verify-memory.sh
    ├── pipeline.sh
    ├── tdai-gateway.json
    ├── hermes-config.yaml.example
    ├── .env.example
    ├── .gitignore
    ├── README.md
    ├── results/
    └── evidence/
```

三个阶段都是可独立运行的项目：

- 不在运行时引用 `../week2`、`../1-basic-soak` 或其他阶段目录。
- 不用符号链接共享 Dockerfile、脚本或配置。
- 每个目录拥有自己的 Dockerfile、soak 核心、运行入口、剧本、配置模板和 README。
- 任一阶段目录单独复制到新位置后，只需按它自己的 README 准备凭证就能运行。

为满足这一交付要求，`hermes-soak.mjs`、Dockerfile 等通用文件会以真实文件复制到后续阶段。这是有意的交付物重复，不抽取跨目录共享模块。每次修改通用文件后，用 `cmp` 或校验和确认各份必要副本保持一致。

## 4. 基础 Soak 数据流

1. 解析命令行参数，校验数值和剧本文件。
2. 建立带时间戳的结果目录。
3. 首轮启动 Hermes 新会话并记录 `session_id`。
4. 后续轮流水执行，每轮捕获 stdout、stderr、退出码和耗时。
5. 每轮结果立即追加到 `conversations.jsonl`，避免中途中断时全部丢失。
6. 每轮后等待指定间隔。
7. 达到“最大轮数”或“总时间上限”任意一项时停止。
8. 计算成功数、失败数、成功率、总耗时、min/mean/P50/P95/max 延迟，写入 `summary.json` 和 `report.txt`。

### 4.1 必需参数

- `--rounds <N>`：最大对话轮数。
- `--interval <ms>`：轮次之间等待毫秒数。
- `--duration <seconds>`：总运行时间上限。

辅助参数包括 `--timeout`、`--prompts`、`--output`、`--hermes-command` 和 `--container`。优先级为“命令行 > 环境变量 > 默认值”。

### 4.2 pass/fail 规则

单轮 `pass` 必须同时满足：

- 在单轮超时之前结束。
- 进程退出码为 0。
- stdout 中存在非空回答。
- 首轮能提取会话 ID，后续轮能恢复该会话。

单轮 `fail` 可由超时、启动失败、非零退出、空回答或会话 ID 缺失引起。失败轮被记录后继续，但连续失败达到阈值时可提前停止。

整体 `pass` 必须同时满足：

- 完成轮数大于 0。
- 成功轮数大于 0。
- 失败率不高于可配阈值，默认 20%。
- 没有因连续失败达到阈值而提前终止。

整体结果明确写入 `summary.json` 的 `status: "pass" | "fail"`，进程退出码与之一致。

## 5. 异常容错

- 每轮子进程用 `AbortController` 和终止信号实现超时，超时后记录 `errorType: "timeout"`。
- 启动错误、API 错误和非零退出归类为失败，stderr 只保存截断后的诊断内容。
- `SIGINT`/`SIGTERM` 不立即丢弃数据，而是停止新轮次并尝试写出汇总。
- 失败不会被误判为空白成功，结果中保留 `errorType`、`errorMessage` 和 `exitCode`。
- 基础验收的容错演示使用极短 `--timeout`，避免更改或暴露真实 API Key。

## 6. L0–L3 记忆验证

`memory-prompts.json` 包含稳定、虚构且无敏感性的事实，覆盖身份、研究方向、工具偏好、作息、饮食约束、长期目标和回答风格。不使用学生真实隐私。

为了在作业时间内可重现 L0–L3，Gateway 使用测试专用配置：

- SQLite 本地存储，数据目录由 `TDAI_DATA_DIR` 显式指定。
- `pipeline.everyNConversations` 设为较小值。
- `pipeline.l1IdleTimeoutSeconds`、`l2DelayAfterL1Seconds` 和 `l2MinIntervalSeconds` 调低到测试合理值。
- `persona.triggerEveryN` 调低，使 L3 能在有限轮数后生成。
- 由于用户的 DeepSeek 兼容端点不提供通用 Embedding，`recall.strategy` 使用 `keyword`，不声称混合检索可用。

实际安装的 Gateway 源码读取 `TDAI_LLM_API_KEY`、`TDAI_LLM_BASE_URL` 和 `TDAI_LLM_MODEL`，因此流水线使用这组名称，而不依赖插件 README 中与当前源码不一致的旧名称。

验证脚本逐项输出：

- L0：原始对话 JSONL 存在且非空。
- L1：结构化记忆存储或文件非空。
- L2：scene Markdown 存在且含内容。
- L3：`persona.md` 存在且含内容。
- Recall：调用 `POST /recall` 时返回非空命中结果，并能找到预置探针关键词。

任一项不满足时输出该层 `fail` 和实际路径，不用“有 Gateway 日志”替代“文件真正落库”。

## 7. 完整 Docker 流水线

1. 接收 `HERMES_VERSION`，调用当前阶段目录自带的 Dockerfile 构建干净镜像。该 Dockerfile 的内容源自第二周交付物，但第三周运行时不依赖第二周目录。
2. 以 `sleep infinity` 覆盖默认入口，启动后台容器。
3. 通过 `docker exec -u root` 在运行中的容器内从 npm 安装指定版本的 `@tencentdb-agent-memory/memory-tencentdb`。
4. 把 provider 安装到 `/home/hermes/.hermes/plugins/memory_tencentdb`。PyPI 版 Hermes 0.19.0 从 `$HERMES_HOME/plugins/<name>` 发现用户插件，不使用本机源码 checkout 的插件路径。
5. 生成容器专用 `config.yaml` 和 Gateway 配置，用普通用户 `hermes` 持有配置与数据。
6. 以运行时环境变量注入 Hermes 推理凭证与 Gateway LLM 凭证。
7. 启动 Gateway，轮询 `GET /health` 直到就绪或超时。
8. 以容器模式运行富事实 soak，然后调用会话结束或等待管线完成。
9. 执行 L0–L3 与 recall 验证，收集 JSON 结果、Gateway 日志和证据文件。
10. 无论成功或失败都生成流水线汇总；默认保留容器便于截图与排错，另提供显式清理命令。

## 8. 凭证与安全

- `.env.example` 只保留空占位符，不带参考包中的 Token。
- 真实 `.env`、构建日志中的凭证和原始个人信息不提交。
- `.gitignore` 忽略 `.env`、临时结果、数据库与可能包含对话的中间文件；仅提交经检查的验收证据。
- 流水线日志对 API Key 只显示“已设置/未设置”，不打印值或末四位。
- 容器内存储为作业测试数据，清理前先导出验收证据。

## 9. 验证策略

### 独立性检查

- 扫描三个阶段的脚本、配置和 README，不允许出现运行时跨目录引用。
- 分别从三个阶段目录作为当前工作目录执行其 `--help` 与快速测试。
- 最终验收时可把某一阶段复制到临时目录，验证它不依赖 `week2` 或其他阶段文件。

### 基础阶段

- `--help` 展示全部参数。
- 非法的轮数、间隔或时长会在调用 Hermes 前失败。
- 2–3 轮快速测试生成 `conversations.jsonl`、`summary.json` 和 `report.txt`。
- 分别改变轮数、间隔与总时长，证明三个参数生效。
- 用极短单轮超时证明失败被记录且能输出汇总 JSON。

### 记忆阶段

- provider 发现结果包含 `memory_tencentdb` 且可用。
- Gateway `/health` 为 `ok` 或可解释的 `degraded`。
- Gateway 日志同时包含 capture 与 L1/L2/L3 完成证据。
- 磁盘数据逐层非空，`/recall` 返回预期关键词。

### 流水线阶段

- 新的容器名与数据目录每次唯一，避免旧数据造成假通过。
- 空数据目录开始的一键执行能走完所有步骤。
- 总结 JSON 明确列出 build、container、plugin、gateway、soak、L0、L1、L2、L3 和 recall 的 pass/fail。
- 最终退出码与总结状态一致。

## 10. 非目标

- 不修改第二周的干净 Dockerfile。各阶段在自己目录中保存其副本，但不把记忆插件固化进基础镜像。
- 不运行或依赖 OpenClaw Gateway。
- 不把 DeepSeek 文本生成端点宣称为 Embedding 服务。
- 不为作业引入外部 Node.js 依赖、数据库服务或编排平台。

# 第三周作业：Hermes Soak、分层记忆与端到端流水线

本周作业在前两周成果上继续向前扩展。第一周已经验证 Hermes 能够加载 TencentDB-Agent-Memory，第二周提供了按 `HERMES_VERSION` 动态构建的干净 Hermes Dockerfile；本周没有重新制作一份只适用于当前测试版本的 Dockerfile，而是直接复用第二周 Dockerfile，通过运行参数选择 Hermes 版本，并在容器运行期安装记忆插件。

整个实现分为三个递进阶段：

1. 基础阶段实现可配置、可持续运行、可记录结果、具备异常容错的 Hermes soak 脚本；
2. 进阶一在第二周构建的 Hermes 容器中安装记忆插件，用富含事实的真实对话验证 L0-L3 和记忆召回；
3. 进阶二将镜像构建、新容器创建、插件安装、Gateway 启动、真实 soak 和记忆验收串成一条自动流水线。

## 目录结构

```text
week3/
├── README.md
├── 1-basic-soak/
│   ├── hermes-soak.mjs
│   ├── prompts.example.json
│   ├── .env.example
│   ├── show-demo.ps1
│   ├── show-error-demo.ps1
│   ├── show-parameter-evidence.ps1
│   └── README.md
├── 2-memory-l0l3/
│   ├── fact-prompts.json
│   ├── tdai-gateway.yaml
│   ├── install-plugin-in-container.sh
│   ├── start-gateway-in-container.sh
│   ├── health-check.mjs
│   ├── verify-memory.mjs
│   ├── show-recall.mjs
│   ├── npx-offline-wrapper.sh
│   └── README.md
├── 3-full-pipeline/
│   ├── Dockerfile
│   ├── run-pipeline.ps1
│   ├── show-recall-evidence.ps1
│   └── README.md
├── evidence/advanced2/
│   ├── pipeline-summary.json
│   ├── meta.json
│   └── recall-query.json
└── pictures/
    ├── 基础/
    ├── 进阶一/
    └── 进阶二/
```

提交中保留了实现脚本、配置、脱敏后的结构化验收摘要和截图。`.env`、API Key、运行期数据库、Gateway 日志、完整 persona/recall 内容以及临时插件归档均未提交。

## 一、基础阶段：可配置的 Hermes Soak

### 目标

基础阶段不是简单循环执行几条命令，而是实现一个可用于真实 Hermes 的 soak 工具。脚本需要满足四项要求：

1. 每轮对话和最终汇总均输出结构化 JSON；
2. 轮数、轮次间隔和最长持续时间三个核心参数能够生效；
3. 运行结束后给出成功率、耗时分布、错误分类和最终 session；
4. 单轮失败不会导致整个脚本立即崩溃，非法参数和 API 异常都能留下明确结果。

### 实现方式

核心脚本是 `1-basic-soak/hermes-soak.mjs`。它通过 Node.js `spawn` 的参数数组调用 Hermes CLI，不通过 shell 拼接 prompt，因此可以安全处理中文、引号和空格。

脚本使用同一个 Hermes session 连续对话：第一轮自动创建 session，后续轮次从 Hermes 的标准错误输出中提取 `session_id` 并继续使用。每轮结果追加到 `conversations.jsonl`，最终汇总写入 `meta.json`。

核心参数：

| 参数 | 含义 | 示例 |
| --- | --- | --- |
| `--rounds` | 最大对话轮数 | `8` |
| `--interval-ms` | 两轮之间的等待时间 | `1000` |
| `--duration-minutes` | 最长持续时间 | `20` |
| `--request-timeout-ms` | 单轮请求超时 | `180000` |
| `--prompts` | 自定义 prompt JSON | `prompts.example.json` |
| `--output` | 结构化结果目录 | `evidence/soak` |
| `--toolsets` | Hermes toolsets | `context_engine,memory` |

示例：

```powershell
node .\1-basic-soak\hermes-soak.mjs `
  --rounds 8 `
  --interval-ms 1000 `
  --duration-minutes 20 `
  --request-timeout-ms 180000 `
  --prompts .\1-basic-soak\prompts.example.json `
  --output .\evidence\soak
```

### 三个核心参数验证

截图中分别改变轮数、间隔和持续时间，确认脚本读取并执行传入值。

![基础阶段参数设置](<pictures/基础/参数设置.png>)

### 真实多轮对话

每一轮均调用真实 Hermes 和已配置的模型，不使用 mock 对话。

![基础阶段真实多轮对话](<pictures/基础/多轮对话.png>)

运行结束后，`meta.json` 会汇总实际轮数、成功率、完成原因、耗时统计和最终 session ID。

![基础阶段多轮对话摘要](<pictures/基础/多轮对话summary.png>)

### 异常容错

非法 API 配置会被记录为请求失败，脚本仍然生成结构化错误结果，而不是只输出一段无法审计的堆栈。

![非法 API 容错](<pictures/基础/异常容错_不合法API.png>)

参数在执行前进行校验，例如 `--rounds 0` 会直接返回清晰的参数错误。

![非法参数容错](<pictures/基础/异常容错_不合法参数.png>)

## 二、进阶一：在第二周 Hermes 镜像上安装记忆插件

### 与第二周结果的关系

进阶一严格基于第二周 Dockerfile 构建的 Hermes 镜像。第二周镜像保持干净，只包含指定版本的 Hermes 和运行所需环境；TencentDB-Agent-Memory 在容器启动后安装，避免把基础镜像和插件层混在一起。

这意味着升级 Hermes 时仍然只需要改变第二周的构建参数：

```powershell
docker build --progress=plain `
  --build-arg HERMES_VERSION=0.20.6 `
  -t hermes:0.20.6 `
  <第二周作业目录>
```

这里的 `0.20.6` 是本次真实验收使用的实例版本，不是脚本内部写死的唯一版本。

下图展示了在docker中构建hermes的部分过程。

![基于第二周 Dockerfile 构建 Hermes](<pictures/进阶一/基于dockerfile构建Hermes.png>)

### 容器运行期安装插件

`install-plugin-in-container.sh` 完成以下工作：

1. 将插件源码安装到 Hermes home 目录；
2. 安装生产依赖或使用预先准备的 Linux x64 离线依赖；
3. 创建 `memory_tencentdb` provider 软链接；
4. 更新 Hermes 的 memory provider 配置；
5. 写入 Gateway host、port、数据目录和模型环境变量；
6. 调用 Hermes provider discovery 验证插件可以被发现。

![安装 memory_tencentdb provider](<pictures/进阶一/装上记忆插件（provider=memory_tencentdb).png>)

上图中的“provider=memory_tencentdb”, 表明tencentdb这个记忆插件已经被正确安装。

### 富含事实的真实对话

`fact-prompts.json` 中的 prompt 均采用第一人称、正常交流表达，不使用“请记住以下测试字段”一类生硬指令。8 轮内容覆盖：

- 姓名、城市、职业和技术栈；
- 工作习惯和文档偏好；
- 当前项目、职责和量化目标；
- 饮食偏好与严重过敏项；
- 作息、运动安排和旅行偏好；
- 学习方式和未来三个月计划。

![进阶一真实事实对话](<pictures/进阶一/soak多轮对话.png>)

8 轮真实 MiniMax 对话全部成功，并保持在同一个 Hermes session 中。

![进阶一 PASS 摘要](<pictures/进阶一/多轮对话（PASS摘要）.png>)

### L0-L3 记忆验证

插件将对话逐步沉淀为四层数据：

| 层级 | 数据内容 | 验收位置 |
| --- | --- | --- |
| L0 | 用户与助手原始消息 | `runtime-data/conversations/*.jsonl` |
| L1 | 从对话抽取的结构化事实 | `runtime-data/records/*.jsonl` |
| L2 | 按主题组织的场景块 | `runtime-data/scene_blocks/*.md` |
| L3 | 汇总后的长期用户画像 | `runtime-data/persona.md` |

![L0-L3 数据目录](<pictures/进阶一/数据目录（L0-L3生成）.png>)

### Recall 验证

“青松灯塔-7429”是本次作业专门设计的合成项目事实和低碰撞检索标识，不代表腾讯或其他外部真实项目。对话中的完整事实是：用户负责该数据质量优化项目的规则引擎和可观测性，目标是把批处理任务告警误报率降到 5% 以下。

验收时以 `青松灯塔-7429` 作为 query 调用 Gateway `/recall`。返回结果不仅包含项目名称，还包含职责、量化目标、技术栈及关联 persona/scene context，证明并非只匹配一段硬编码文本。

![进阶一 recall 召回](<pictures/进阶一/recall召回.png>)

## 三、进阶二：参数化端到端流水线

### 设计目标

进阶二将前两个阶段串成一条可重复执行的流水线。入口为 `3-full-pipeline/run-pipeline.ps1`。按照“Dockerfile + soak 一键流水线”的交付要求，`3-full-pipeline` 中同时附带第二周 Dockerfile 的原样副本；两个文件的 SHA256 均为 `DF51ECE4674EFA62D33EA527290DDD3F065E311AD0BF1B3F4130EFEA48990CCB`。这只是为了让进阶二目录可以独立审阅，并没有重新编写或分叉第二周实现。

脚本不保存 Hermes 默认版本，也不维护版本号映射。`-HermesVersion` 是必填参数，并且只做标准 `x.y.z` 格式校验，然后原样传入第二周 Dockerfile：

```powershell
--build-arg HERMES_VERSION=$HermesVersion
```

因此，最终能否构建某个版本由第二周 Dockerfile 对官方 Hermes release 的动态解析结果决定；第三周脚本没有为 `0.20.6` 开特殊分支。

### 完整流程

```text
显式传入 HermesVersion
        ↓
调用第二周 Dockerfile 构建指定版本 Hermes
        ↓
创建全新容器和独立 home volume
        ↓
在容器运行期安装 memory_tencentdb
        ↓
启动 Gateway 并重试健康检查
        ↓
运行 8 轮真实事实 soak
        ↓
等待 L0、L1、L2、L3 生成
        ↓
使用唯一事实 query 验证 recall
        ↓
输出 pipeline-summary.json 和 evidence
```

### 运行命令

正常运行不要求预先准备插件源码、`.env`、`config.yaml` 或 Docker volume。流水线会自动拉取官方 TencentDB-Agent-Memory、生成配置并创建新 volume。模型 API Key 从当前进程的 `MINIMAX_CN_API_KEY` 读取；没有设置时，脚本会安全提示输入且不在终端回显。

因此其他人复现时只需要三个基础条件：Docker Desktop 已启动、Git 可用、拥有有效的 MiniMax API Key。在 `week3` 目录执行上述命令，脚本提示时粘贴 Key 即可；不需要把 Key 写进脚本或命令。Key 不进入日志和 evidence，流水线结束时还会从宿主机临时目录及 Docker home volume 中清除临时 `.env`。生产环境应进一步改用 Docker Secrets 或企业密钥管理系统。

![进阶二一键流水线总览](<pictures/进阶二/one command pipeline.png>)

```powershell
& .\3-full-pipeline\run-pipeline.ps1 `
  -HermesVersion "0.20.6" `
  -Rounds 8 `
  -KeepContainer
```

因此用户侧只需要 Docker、网络和模型凭证。插件源码、Hermes 配置以及运行 volume 都由脚本编排；模型密钥属于不可构建进镜像的运行凭证，不会写入 Git 或镜像层。

若需验证其他官方版本，只修改调用参数，例如：

```powershell
-HermesVersion "0.19.0"
```

不需要修改第三周脚本或第二周 Dockerfile。

默认情况下，流水线使用 `3-full-pipeline/Dockerfile`。如果希望直接从仓库的第二周目录构建，也可以额外传入：

```powershell
-Week2Dir "..\week2"
```

两处 Dockerfile 内容完全一致。

### 结构化 Soak 结果

本次零预置真实运行共完成 8 轮对话，`status=pass`、`successfulRounds=8`、`failedRounds=0`，最终 session 为 `20260909_073815_9245e5`。

![进阶二 soak meta](<pictures/进阶二/soak result.png>)

### 事实输入

截图展示了对话实际写入的身份、工作、健康和计划事实，便于将输入与后续记忆内容进行核对。

![进阶二事实内容](<pictures/进阶二/事实内容.png>)

### L0-L3 自动验收

`verify-memory.mjs` 不只检查目录是否存在，还统计各层非空内容，并等待异步记忆流水线完成。本次运行结果为：

```text
L0 = 16 条原始消息
L1 = 10 条结构化记录
L2 = 2 个非空场景文件
L3 = 6504 bytes persona
```

不同运行中 L1/L2 数量可能因模型对事实的归并方式发生变化，因此验收关注四层都生成非空数据、事实语义正确并且 recall 命中，而不是把某个固定条数写死。Recall 请求仍使用完整中文 query `青松灯塔-7429`，但自动断言检查稳定标识 `7429`；这是因为生成式记忆可能把项目名归纳为 `Qingsong Lighthouse-7429`，不应把正常翻译误判为记忆丢失。

![进阶二 L0-L3 verification](<pictures/进阶二/L0-L3 verification.png>)

### Query 与 Recall 内容

`show-recall-evidence.ps1` 同时展示 query、HTTP 状态、是否命中、命中记忆数以及完整 recall context，避免只看到 `matched=true` 却不知道召回了什么。

![进阶二 recall](<pictures/进阶二/recall (2).png>)

## 踩坑与解决过程

### 1. Soak 只输出终端文字，不利于验收

最初只关注多轮命令能否运行，但纯终端输出无法稳定判断成功率，也不便于自动化验收。最终将每轮记录写成 JSONL，并将配置、完成原因、延迟统计、错误分类和 session 写入 `meta.json`。

### 2. Hermes 不同版本的 CLI 参数可能变化

基础脚本最初容易依赖某个新版本才提供的 CLI 参数。最终只使用已核对的公共调用方式，并通过 Node.js 参数数组传入 prompt；版本选择留给第二周 Dockerfile 和进阶二的 `-HermesVersion` 参数，不在 soak 逻辑里为单一版本开小灶。

### 3. Provider discovery 与 Gateway 可用性不是同一个时刻

插件刚安装完成时，Hermes 已经可以发现 `memory_tencentdb`，但 Gateway 尚未启动，因此 provider 可能显示 `available=False`。这不代表安装失败。安装阶段只验证 provider 被发现；Gateway 启动后再通过 `/health` 和真实 recall 验证完整可用性。

### 4. Gateway 固定等待 2 秒会产生误判

插件第一次初始化 SQLite、BM25 和流水线时可能超过 2 秒。固定 sleep 会在 Gateway 即将就绪时判定失败。最终改为最多 60 秒的健康检查重试：只有持续无法返回 HTTP 200 才视为失败。

### 5. 容器内 `npm ci` 受网络影响

Docker 网络不稳定时，插件生产依赖安装会卡住；此外，官方仓库部分分支可能不包含 lockfile，固定执行 `npm ci` 会直接失败。最终实现会在 lockfile 存在时执行 `npm ci --omit=dev`，不存在时回退到 `npm install --omit=dev --legacy-peer-deps`，规避 npm 10 解析可选 peer dependency 时的 `edgesOut` 异常；仍保留 `-OfflineDependencies` 作为断网调试入口。离线依赖不提交到仓库，避免把大体积 `node_modules` 放入 PR。

### 6. PowerShell 中文参数发生代码页转换

曾直接从 PowerShell 把中文 query 传进容器，容器收到的内容出现乱码，导致 recall 明明返回相关上下文，字符串校验仍然失败。最终让 Node.js 验证脚本保存 UTF-8 默认 query；终端展示脚本使用 Unicode 码点生成中文，避免依赖 Windows 默认代码页。

### 7. 超时单位传错导致验证等待过久

`verify-memory.mjs` 接收的是 `--timeout-seconds`，早期流水线误写成 `--timeout-ms`，参数未被识别后使用了较长默认值。最终统一为秒，并设置明确的 180 秒等待窗口。

### 8. Docker Desktop 重启后命名管道暂时不可用

Docker Desktop 重启期间，CLI 曾返回 Linux Engine named pipe 权限或连接错误。重新确认 Desktop 状态、等待引擎完全恢复后再执行，而不是把这类基础设施异常误判成 Hermes 或插件问题。

## 验收要求对应关系

| 阶段 | 验收要求 | 实现与证据 |
| --- | --- | --- |
| 基础 | 结构化 JSON | `conversations.jsonl`、`meta.json`、多轮摘要截图 |
| 基础 | 三个参数生效 | `--rounds`、`--interval-ms`、`--duration-minutes` 与参数截图 |
| 基础 | 输出结果 | 成功率、耗时分布、错误分类、session ID |
| 基础 | 异常容错 | 非法 API、非法参数两类截图 |
| 进阶一 | 基于第二周结果 | 直接使用第二周 Dockerfile 构建的 Hermes 镜像 |
| 进阶一 | 安装记忆插件 | provider discovery 和 Gateway health |
| 进阶一 | 富含事实的真实 soak | 8 轮第一人称真实对话及 PASS 摘要 |
| 进阶一 | L0-L3 与 recall | 四层数据目录和 query 召回截图 |
| 进阶二 | 完整自动化 | `run-pipeline.ps1` 串联全部阶段 |
| 进阶二 | Dockerfile + soak | `3-full-pipeline/Dockerfile` 为第二周 Dockerfile 的原样副本，soak 剧本复用 `2-memory-l0l3/fact-prompts.json` |
| 进阶二 | 版本前向适配 | `HermesVersion` 必填并透传第二周 Dockerfile |
| 进阶二 | 无预置目录/volume | 自动拉取插件、生成配置并创建隔离 volume |
| 进阶二 | 新容器验收 | 每次创建独立容器和 volume，最终汇总记录 `fresh_container=true` |
| 进阶二 | 结果可审计 | pipeline summary、soak meta、verification 和截图 |

## 最近一次真实验收结果

本次实际使用 Hermes `0.20.6` 和 MiniMax 模型完成端到端验证：

```text
Docker build                 PASS
fresh container              PASS
memory_tencentdb discovery   PASS
Gateway /health              PASS
real soak                    8/8 PASS
L0                           16 records
L1                           10 records
L2                           2 scene files
L3                           6504 bytes
recall query                 青松灯塔-7429
recall matched               true
```

这里记录 `0.20.6` 只是说明本次证据来自哪个实际版本。最终脚本没有默认 Hermes 版本，调用者必须显式传入 `x.y.z`，并由第二周 Dockerfile 动态解析对应官方 release。

## 文件说明与复现边界

- `1-basic-soak` 可以在宿主机或 Docker 容器中运行，验收标准不依赖固定运行位置；
- `2-memory-l0l3` 负责插件安装、Gateway 和分层记忆验证；
- `3-full-pipeline` 负责把第二周构建结果与前两部分串联；
- `evidence/advanced2` 只保存脱敏后的关键 JSON 摘要；
- `pictures` 保存本次真实运行截图；
- API Key 只通过私有 `.env` 或 Docker volume 提供，不写入代码、镜像层或 Git。

首次完整复现需要访问 Docker Hub、Hermes 官方 Git 仓库、Python/npm 包索引以及所配置的模型 API；如果依赖已离线准备，可以使用流水线的离线依赖模式减少容器内网络请求。

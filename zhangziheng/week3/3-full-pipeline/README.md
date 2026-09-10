# 进阶二：Week 2 → Hermes → 插件 → Gateway → Soak → 记忆验收

`run-pipeline.ps1` 严格复用第二周的参数化 `Dockerfile`，构建全新 Hermes 镜像和容器；插件只在容器运行期安装，随后启动 Gateway，执行真实模型多轮事实对话，并验证 L0/L1/L2/L3 与 recall。为使进阶二目录成为完整交付物，本目录附带了第二周 Dockerfile 的原样副本；它与 `../week2/Dockerfile` 内容及 SHA256 完全一致，并不是重新实现的另一份 Dockerfile。

三种入口**彼此独立、互不调用**，各自完整实现同一套阶段图、参数/环境变量、校验、清理与 evidence 布局：
`run-pipeline.ps1`（Windows / PowerShell）、`run-pipeline.py`（Python 3.10+，跨平台）、`run-pipeline.sh`（纯 POSIX sh，Linux/macOS，自带参数解析、JSON 汇总与错误处理，不依赖 python 或 PowerShell）。三者都先读当前目录的 `.env`，再读脚本所在目录的 `.env`；退出码约定一致：`0`=通过、`1`=流水线失败、`2`=参数/用法错误（ps1 的用法错误由 PowerShell 以 `1` 退出）。`run-pipeline.sh` 需要 `docker`、`git`、`tar` 与 `sha256sum`（缺失时回退 `openssl dgst -sha256`）。

## 运行

```powershell
# Windows
& .\3-full-pipeline\run-pipeline.ps1 -HermesVersion '0.20.6' -Rounds 8 -KeepContainer
```

```bash
# Linux
cd 3-full-pipeline
./run-pipeline.sh --hermes-version 0.20.6 --rounds 8 --keep-container
```

```bash
# Python（Windows、Linux、macOS 均可）
cd 3-full-pipeline
python3 run-pipeline.py --hermes-version 0.20.6 --rounds 8 --keep-container
(或：python run-pipeline.py --hermes-version 0.20.6 --rounds 8 --keep-container)
```

Python 入口是独立实现，不会调用 PowerShell 或 Shell；在 Linux/WSL 上如果不想依赖 Shell，可直接使用 `python3` 命令。三种入口都会优先读取当前工作目录的 `.env`，再读取 `3-full-pipeline/.env`。建议先复制模板并填写 `HERMES_API_KEY`、`HERMES_BASE_URL`、`HERMES_MODEL`，版本号可以写入 `HERMES_VERSION`，也可以显式传入命令行参数。

参数对应：`-HermesVersion`↔`--hermes-version`、`-Rounds`↔`--rounds`、`-KeepContainer`↔`--keep-container`、`-DisableThinking`↔`--disable-thinking`、`-ModelProvider`↔`--model-provider/--api-style`、`-ModelBaseUrl`↔`--model-base-url/--base-url`、`-LlmBaseUrl`↔`--llm-base-url`。

`-HermesVersion` 是必填参数，不存在针对某个版本的默认分支。脚本只把它透传为第二周 Dockerfile 的 `--build-arg HERMES_VERSION`；因此可替换为任意被第二周 Dockerfile 成功解析的官方 Hermes `x.y.z` 版本。默认使用本目录附带的 Dockerfile；也可以通过 `-Week2Dir` 显式指向原始 `week2` 目录并得到相同构建结果。

流水线默认从 `https://github.com/Tencent/TencentDB-Agent-Memory.git` 拉取插件，自动生成 Hermes `.env` 和 `config.yaml`，并创建全新的 home volume。它不绑定具体厂商，只要求一个 **OpenAI 兼容端点**：`HERMES_API_STYLE` 只接受 `openai`（留空即默认），Hermes provider 固定为 `openai-api`，`TDAI_LLM_BASE_URL` 默认等于 `HERMES_BASE_URL`——一条 URL 同时服务对话与记忆抽取两条腿。API key 依次读取 `HERMES_API_KEY`、`OPENAI_API_KEY`（兼容旧环境中的 `ANTHROPIC_API_KEY`/`MINIMAX_CN_API_KEY`），缺失且终端可交互时安全提示输入、不回显（CI 请用环境变量注入）。

`TDAI_LLM_DISABLE_THINKING` 控制记忆抽取那次 LLM 调用的思考开关：留空时按 `HERMES_BASE_URL` 域名自动推断（`minimax*`→`anthropic`、`deepseek*`→`deepseek`、`dashscope|aliyun`→`dashscope`、`openai.com|openrouter`→`openai`、`anthropic*`→`anthropic`、`google*`→`gemini`，其他/自建→`false` 即不注入任何字段），也可用 `-DisableThinking` / `--disable-thinking` 显式覆盖。该值必须与端点匹配：插件只认 `false | vllm | deepseek | dashscope | openai | anthropic | kimi | gemini` 七种策略，写错会静默失效（例如 `true` 会被映射成 vLLM 专用的 `chat_template_kwargs`，MiniMax 不认）。推理未被关闭时，抽取器会把非 JSON 内容当作记忆候选而解析失败，导致 L1/L2/L3 为空、recall 失败——这是"soak 全过但 verify 挂掉"最常见的原因。

Key 不写入脚本、命令行、日志或 evidence；运行中生成的临时 `.env` 会在 `finally` 中从宿主机临时目录和 Docker home volume 一并清除。CI 可通过 `HERMES_API_KEY`、`HERMES_MODEL`、`HERMES_BASE_URL`、`HERMES_VERSION`（可选 `HERMES_API_STYLE`、`TDAI_LLM_DISABLE_THINKING`、`HERMES_PROVIDER_API_KEY_ENV`）注入配置；脚本不再请求 `/models` 枚举，模型名必须显式给出。

## 进阶二验收截图

以下三张图对应同一次真实 8 轮流水线验收，按“构建 → Soak → 记忆验证”排列：

![一键式构建与 Docker build](<../pictures/进阶二/pipeline-build.png>)

![8 轮真实 Soak 结构化结果](<../pictures/进阶二/soak-8-rounds-pass.png>)

![L0-L3 与 recall 验证结果](<../pictures/进阶二/memory-l0-l3-recall-pass.png>)

以 MiniMax 为例，对话与记忆抽取共用同一个 OpenAI 兼容端点，不需要再配两个 URL：

```ini
# pipeline-test/.env
HERMES_API_STYLE=openai
HERMES_BASE_URL=https://api.minimax.cn/v1
HERMES_MODEL=MiniMax-M3
TDAI_LLM_DISABLE_THINKING=      # 留空 => 按 minimax 域名自动选择 anthropic 策略
```

抽取腿对模型输出格式比对话腿敏感：实测 MiniMax-M3 在思考被正确关闭后能稳定返回可解析的 JSON 数组，而 M2/M2.5 在该端点上无法关闭思考，解析失败率明显更高。换用其他厂商端点时，请保留 `TDAI_LLM_DISABLE_THINKING` 自动推断（或按该厂商显式指定），否则可能出现 soak 全过、verify 失败。

`-PluginDir` 和 `-ConfigVolume` 仅作为调试/离线兼容入口，不是正常运行的前置条件。`-OfflineDependencies` 仅在本机已准备 Linux x64 生产依赖时使用；默认路径在新容器中执行 `npm ci --omit=dev`。

## 最近一次真实验收

运行目录：`runs/20260910_121637/`（`run-pipeline.ps1 -HermesVersion 0.20.6 -Rounds 8`，耗时 285 秒）。正常入口只传 Hermes 版本与轮次，没有传入本地插件目录或预置配置 volume。脚本自动拉取官方插件、生成配置、创建隔离 volume；bootstrap / build / prepare / install_plugin / gateway / soak / verify_memory 七个阶段全部 PASS。soak 为 8/8 真实 MiniMax 对话（p50 13.6s），`verification.json` 为 L0=16、**L1=18**、L2=1、L3=5791B、`recall.matched=true`。

同一命令在修正 `TDAI_LLM_DISABLE_THINKING` 之前（`runs/20260910_114005/`）是 L0=16、L1=0、L2=0、L3=0B、recall=false，`verify_memory` 以 exit 1 失败——可作为"抽取腿被打断"的对照。

诚实说明：抽取并非 100% 稳定。上述 PASS 运行中 12 次抽取调用仍有 2 次 JSON 解析失败（`extracted=0`），靠其余轮次累积到 L1=18 才通过验收；根治需要修上游插件的解析器（贪婪正则）或改用结构化输出。

## 关于验收事实“青松灯塔-7429”

“青松灯塔-7429”是本次验收使用的合成项目事实和唯一检索标识，不代表腾讯或其他外部真实项目。它被故意设计为低碰撞关键词，并在多轮第一人称对话中反复出现：用户负责规则引擎与可观测性，目标是把批处理任务告警误报率降到 5% 以下。验收时用它作为 recall query，确认事实已经从 L0 原始对话逐步沉淀到 L1/L2/L3，并能由 Gateway 返回包含项目背景的完整记忆上下文。

# 进阶二：Week 2 → Hermes → 插件 → Gateway → Soak → 记忆验收

`run-pipeline.ps1` 严格复用第二周的参数化 `Dockerfile`，构建全新 Hermes 镜像和容器；插件只在容器运行期安装，随后启动 Gateway，执行真实模型多轮事实对话，并验证 L0/L1/L2/L3 与 recall。为使进阶二目录成为完整交付物，本目录附带了第二周 Dockerfile 的原样副本；它与 `../week2/Dockerfile` 内容及 SHA256 完全一致，并不是重新实现的另一份 Dockerfile。

## 运行

```powershell
& .\3-full-pipeline\run-pipeline.ps1 `
  -HermesVersion '0.20.6' `
  -KeepContainer
```

`-HermesVersion` 可直接传入，也可写在当前目录 `.env` 的 `HERMES_VERSION` 中。脚本只把它透传为第二周 Dockerfile 的 `--build-arg HERMES_VERSION`；因此可替换为任意被第二周 Dockerfile 成功解析的官方 Hermes `x.y.z` 版本。默认使用本目录附带的 Dockerfile；也可以通过 `-Week2Dir` 显式指向原始 `week2` 目录并得到相同构建结果。

流水线默认从 `https://github.com/Tencent/TencentDB-Agent-Memory.git` 拉取插件，自动生成 Hermes `.env` 和 `config.yaml`，并创建全新的 home volume。请先复制 `.env.example` 为当前目录 `.env`，填写 API Key、Hermes provider、Hermes 模型及 Base URL；脚本不再交互式输入模型信息。Hermes 模型和记忆插件 LLM 默认使用同一模型，接口不同时可分别配置 `HERMES_MODEL_BASE_URL` 与 `HERMES_LLM_BASE_URL`。常见 provider 的密钥环境变量名会自动推断，也可用 `HERMES_PROVIDER_API_KEY_ENV` 指定。

别人复现时只需安装并启动 Docker Desktop、安装 Git，并准备一个兼容接口的模型服务；不需要预先下载插件或创建 Docker volume。复制 `.env.example` 为 `.env` 并填写配置后，在仓库 `week3` 目录执行命令即可。Key 不写入脚本、命令行、日志或 evidence；运行中生成的临时 `.env` 会在 `finally` 中从宿主机临时目录和 Docker home volume 一并清除。若用于长期运行，应改接 Docker Secrets 或组织的密钥管理系统。

例如 MiniMax 的 Hermes 接口与记忆插件接口 URL 不同时，模型列表应从 OpenAI-compatible `/v1` 地址获取；Hermes 本身再单独使用 Anthropic-compatible 地址：

```powershell
.\3-full-pipeline\run-pipeline.ps1 -HermesVersion '0.20.6' `
  -Model 'MiniMax-M2' -ModelProvider 'minimax-cn' `
  -ProviderApiKeyEnv 'MINIMAX_CN_API_KEY' `
  -ModelBaseUrl 'https://api.minimaxi.com/anthropic' `
  -LlmBaseUrl 'https://api.minimaxi.com/v1'
```


`-PluginDir` 和 `-ConfigVolume` 仅作为调试/离线兼容入口，不是正常运行的前置条件。`-OfflineDependencies` 仅在本机已准备 Linux x64 生产依赖时使用；默认路径在新容器中执行 `npm ci --omit=dev`。

## 最近一次真实验收

运行目录：`runs/20260909_153626/`。正常入口只传入 `-HermesVersion`（另加 `-Rounds 8 -KeepContainer` 作为本次验收参数），没有传入本地插件目录或预置配置 volume。脚本自动拉取官方插件、生成配置、创建隔离 volume；构建、全新容器、插件发现、Gateway、soak、记忆验收均为 PASS。soak 为 8/8 真实 MiniMax 对话，最终会话 `20260909_073815_9245e5`，L0=16、L1=10、L2=2、L3=6504B，recall=true。

## 关于验收事实“青松灯塔-7429”

“青松灯塔-7429”是本次验收使用的合成项目事实和唯一检索标识，不代表腾讯或其他外部真实项目。它被故意设计为低碰撞关键词，并在多轮第一人称对话中反复出现：用户负责规则引擎与可观测性，目标是把批处理任务告警误报率降到 5% 以下。验收时用它作为 recall query，确认事实已经从 L0 原始对话逐步沉淀到 L1/L2/L3，并能由 Gateway 返回包含项目背景的完整记忆上下文。

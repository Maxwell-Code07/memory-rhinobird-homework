# 进阶二：Week 2 → Hermes → 插件 → Gateway → Soak → 记忆验收

`run-pipeline.ps1` 严格复用第二周的参数化 `Dockerfile`，构建全新 Hermes 镜像和容器；插件只在容器运行期安装，随后启动 Gateway，执行真实模型多轮事实对话，并验证 L0/L1/L2/L3 与 recall。为使进阶二目录成为完整交付物，本目录附带了第二周 Dockerfile 的原样副本；它与 `../week2/Dockerfile` 内容及 SHA256 完全一致，并不是重新实现的另一份 Dockerfile。

## 运行

```powershell
& .\3-full-pipeline\run-pipeline.ps1 `
  -HermesVersion '0.20.6' `
  -KeepContainer
```

`-HermesVersion` 是必填参数，不存在针对某个版本的默认分支。脚本只把它透传为第二周 Dockerfile 的 `--build-arg HERMES_VERSION`；因此可替换为任意被第二周 Dockerfile 成功解析的官方 Hermes `x.y.z` 版本。默认使用本目录附带的 Dockerfile；也可以通过 `-Week2Dir` 显式指向原始 `week2` 目录并得到相同构建结果。

流水线默认从 `https://github.com/Tencent/TencentDB-Agent-Memory.git` 拉取插件，自动生成 Hermes `.env` 和 `config.yaml`，并创建全新的 home volume。它不绑定 MiniMax：API Key 依次读取 `HERMES_API_KEY`、`OPENAI_API_KEY`（兼容旧环境中的 `MINIMAX_CN_API_KEY`），缺失时安全提示输入且不回显。得到 Key 和 OpenAI-compatible Base URL 后，脚本请求标准 `GET {BaseUrl}/models`，展示服务端实际返回的模型并让用户编号选择；只有模型枚举不可用时才回退为手动输入。`ModelProvider` 默认 `openai`，`ModelBaseUrl` 默认与插件使用的 `LlmBaseUrl` 相同；两者接口不同时可分别传入。脚本会为常见 provider 推断 Hermes 所需的 Key 环境变量名，也可用 `-ProviderApiKeyEnv` 显式指定。

别人复现时只需安装并启动 Docker Desktop、安装 Git，并准备一个兼容接口的模型服务；不需要预先下载插件、编写配置文件或创建 Docker volume。在仓库 `week3` 目录执行上面的命令，然后按提示输入 API Key 和 Base URL，再从自动获取的模型列表中选择即可。Key 不写入脚本、命令行、日志或 evidence；运行中生成的临时 `.env` 会在 `finally` 中从宿主机临时目录和 Docker home volume 一并清除。CI 可通过 `HERMES_API_KEY`、`HERMES_MODEL`、`HERMES_LLM_BASE_URL` 和可选的 `HERMES_MODEL_PROVIDER`、`HERMES_MODEL_BASE_URL` 注入配置。非标准模型列表地址可用 `-ModelsEndpoint` 或 `HERMES_MODELS_ENDPOINT` 指定；CI 已给定模型名时不会请求模型列表。若用于长期运行，应改接 Docker Secrets 或组织的密钥管理系统。

例如 MiniMax 的 Hermes 接口与记忆插件接口 URL 不同时，可以只在参数中说明差异，Key 仍由安全提示输入：

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

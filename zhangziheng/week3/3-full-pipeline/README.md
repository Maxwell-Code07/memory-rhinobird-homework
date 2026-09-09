# 进阶二：Week 2 → Hermes → 插件 → Gateway → Soak → 记忆验收

`run-pipeline.ps1` 严格复用第二周的参数化 `Dockerfile`，构建全新 Hermes 镜像和容器；插件只在容器运行期安装，随后启动 Gateway，执行真实 MiniMax 多轮事实对话，并验证 L0/L1/L2/L3 与 recall。为使进阶二目录成为完整交付物，本目录附带了第二周 Dockerfile 的原样副本；它与 `../week2/Dockerfile` 内容及 SHA256 完全一致，并不是重新实现的另一份 Dockerfile。

## 运行

```powershell
& .\3-full-pipeline\run-pipeline.ps1 `
  -HermesVersion '0.20.6' `
  -KeepContainer
```

`-HermesVersion` 是必填参数，不存在针对某个版本的默认分支。脚本只把它透传为第二周 Dockerfile 的 `--build-arg HERMES_VERSION`；因此可替换为任意被第二周 Dockerfile 成功解析的官方 Hermes `x.y.z` 版本。默认使用本目录附带的 Dockerfile；也可以通过 `-Week2Dir` 显式指向原始 `week2` 目录并得到相同构建结果。

流水线默认从 `https://github.com/Tencent/TencentDB-Agent-Memory.git` 拉取插件，自动生成 Hermes `.env` 和 `config.yaml`，并创建全新的 home volume。模型凭证从当前进程的 `MINIMAX_CN_API_KEY` 读取；未设置时会安全提示输入且不回显。每次运行都会创建新的镜像标签、容器、home volume 和 evidence 目录。

别人复现时只需安装并启动 Docker Desktop、安装 Git，并准备一个有效的 MiniMax API Key；不需要预先下载插件、编写配置文件或创建 Docker volume。在仓库 `week3` 目录执行上面的命令，未设置环境变量时按提示粘贴 Key 即可。Key 不写入脚本、命令行、日志或 evidence；运行中生成的临时 `.env` 会在 `finally` 中从宿主机临时目录和 Docker home volume 一并清除。若用于长期运行而非作业验收，应改接 Docker Secrets 或组织的密钥管理系统。

`-PluginDir` 和 `-ConfigVolume` 仅作为调试/离线兼容入口，不是正常运行的前置条件。`-OfflineDependencies` 仅在本机已准备 Linux x64 生产依赖时使用；默认路径在新容器中执行 `npm ci --omit=dev`。

## 最近一次真实验收

运行目录：`runs/20260909_153626/`。正常入口只传入 `-HermesVersion`（另加 `-Rounds 8 -KeepContainer` 作为本次验收参数），没有传入本地插件目录或预置配置 volume。脚本自动拉取官方插件、生成配置、创建隔离 volume；构建、全新容器、插件发现、Gateway、soak、记忆验收均为 PASS。soak 为 8/8 真实 MiniMax 对话，最终会话 `20260909_073815_9245e5`，L0=16、L1=10、L2=2、L3=6504B，recall=true。

## 关于验收事实“青松灯塔-7429”

“青松灯塔-7429”是本次验收使用的合成项目事实和唯一检索标识，不代表腾讯或其他外部真实项目。它被故意设计为低碰撞关键词，并在多轮第一人称对话中反复出现：用户负责规则引擎与可观测性，目标是把批处理任务告警误报率降到 5% 以下。验收时用它作为 recall query，确认事实已经从 L0 原始对话逐步沉淀到 L1/L2/L3，并能由 Gateway 返回包含项目背景的完整记忆上下文。

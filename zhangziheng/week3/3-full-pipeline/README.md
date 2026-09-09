# 进阶二：Week 2 → Hermes → 插件 → Gateway → Soak → 记忆验收

`run-pipeline.ps1` 严格复用第二周的参数化 `Dockerfile`，构建全新 Hermes 镜像和容器；插件只在容器运行期安装，随后启动 Gateway，执行真实 MiniMax 多轮事实对话，并验证 L0/L1/L2/L3 与 recall。为使进阶二目录成为完整交付物，本目录附带了第二周 Dockerfile 的原样副本；它与 `../week2/Dockerfile` 内容及 SHA256 完全一致，并不是重新实现的另一份 Dockerfile。

## 运行

```powershell
& .\3-full-pipeline\run-pipeline.ps1 `
  -HermesVersion '0.20.6' `
  -PluginDir 'D:\Users\zzh\Desktop\腾讯开源计划\TencentDB-Agent-Memory-main' `
  -OfflineDependencies -KeepContainer
```

`-HermesVersion` 是必填参数，不存在针对某个版本的默认分支。脚本只把它透传为第二周 Dockerfile 的 `--build-arg HERMES_VERSION`；因此可替换为任意被第二周 Dockerfile 成功解析的官方 Hermes `x.y.z` 版本。默认使用本目录附带的 Dockerfile；也可以通过 `-Week2Dir` 显式指向原始 `week2` 目录并得到相同构建结果。

`-OfflineDependencies` 使用已准备好的 Linux x64 生产依赖，避免容器内重复联网安装；不指定时会执行插件目录的 `npm ci --omit=dev`。每次运行都会创建新的镜像标签、容器、home volume 和 evidence 目录。

## 最近一次真实验收

运行目录：`runs/20260909_093223/`。构建、全新容器、插件发现、Gateway、soak、记忆验收均为 PASS；soak 为 8/8 真实 MiniMax 对话，最终会话 `20260909_013326_00e1ed`，L0=16、L1=10、L2=2、L3=3725B，recall=true。

## 关于验收事实“青松灯塔-7429”

“青松灯塔-7429”是本次验收使用的合成项目事实和唯一检索标识，不代表腾讯或其他外部真实项目。它被故意设计为低碰撞关键词，并在多轮第一人称对话中反复出现：用户负责规则引擎与可观测性，目标是把批处理任务告警误报率降到 5% 以下。验收时用它作为 recall query，确认事实已经从 L0 原始对话逐步沉淀到 L1/L2/L3，并能由 Gateway 返回包含项目背景的完整记忆上下文。

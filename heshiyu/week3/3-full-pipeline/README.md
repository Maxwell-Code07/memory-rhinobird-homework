# Week3：完整记忆流水线

本目录用于验证 Hermes 与腾讯云数据库记忆插件的完整流程，包括持续对话、记忆写入、L0～L3 记忆生成以及独立召回。

## 实验内容

1. 使用 Docker 构建并运行隔离的 Hermes 环境。
2. 安装并启用 `memory_tencentdb` 记忆插件。
3. 执行多轮包含用户事实的对话测试。
4. 检查 L0 原始对话、L1 记忆记录、L2 场景记忆和 L3 用户画像。
5. 通过独立中文问题验证记忆召回结果。

## 主要文件

```text
3-full-pipeline/
├── Dockerfile                    # Hermes Docker 镜像配置
├── hermes-standalone-soak.mjs    # 多轮对话与记忆探针脚本
├── inspect-memory.mjs            # 检查记忆数据状态
├── verify-memory.mjs             # 验证 L0～L3 和召回结果
├── config/hermes-config.yaml     # Hermes 与记忆插件配置
├── scenarios/memory-soak.json    # 测试对话场景
├── evidence/final-20260909/      # 最终测试结果与记忆快照
├── Figure_week3.3/               # 实验截图
└── 实验过程.md                   # 完整实验步骤与结果说明
```

## 基本使用

需要提前准备 Docker、Node.js，并配置可用的 Hermes 模型服务。

查看测试脚本参数：

```powershell
node .\hermes-standalone-soak.mjs --help
```

运行六轮记忆对话测试示例：

```powershell
node .\hermes-standalone-soak.mjs `
  --rounds 6 `
  --interval 1s `
  --duration 15m `
  --scenario .\scenarios\memory-soak.json `
  --output .\results\soak
```

具体的 Docker 构建、插件安装、Gateway 启动和记忆验证过程，请参阅 [实验过程.md](./实验过程.md)。


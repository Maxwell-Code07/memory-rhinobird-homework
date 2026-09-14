# Hermes Soak & Memory Pipeline

用于对 Hermes 进行持续对话测试、记忆分层验证和 Docker 全流程自动化。项目通过 Hermes CLI 驱动多轮对话，生成结构化测试结果，并验证记忆插件产生的 L0–L3 数据及 `/recall` 召回能力。

项目采用 Bash 作为运行入口、Python 负责编排 Docker 流程、Node.js 实现 soak 和记忆校验，不依赖 PowerShell 脚本。

## 核心模块

| 模块 | 功能 |
| --- | --- |
| `1-basic-soak/` | 自动执行多轮 Hermes 对话，支持轮次、间隔和总时长配置，输出逐轮 JSONL、汇总 JSON 和文本报告，并对超时、认证失败等异常进行结构化记录。 |
| `2-memory-l0l3/` | 在已启用记忆插件的 Hermes 环境中运行富事实对话，检查 L0 原始对话、L1 事实记录、L2 scene block、L3 `persona.md` 和独立 `/recall`。 |
| `3-full-pipeline/` | 输入 Hermes 版本号，自动完成镜像构建、容器启动、记忆插件安装、Gateway 启动、soak、记忆校验和结果归档。 |

## 项目结构

```text
week3/
├── README.md
├── 1-basic-soak/
│   ├── run-basic-soak.sh          # 基础 soak 入口
│   ├── hermes-standalone-soak.mjs # 对话循环与结构化报告
│   ├── config/                     # Hermes 基础配置
│   ├── scenarios/                 # 基础对话剧本
│   ├── evidence/                  # 历史运行结果
│   └── Figure_week3.1/            # 运行截图
├── 2-memory-l0l3/
│   ├── Dockerfile                 # Hermes 镜像定义
│   ├── run-memory-soak.sh         # 记忆 soak 入口
│   ├── verify-memory.mjs          # L0–L3 与召回校验
│   ├── config/                     # Hermes 记忆配置
│   ├── scenarios/                 # 富事实对话剧本
│   ├── evidence/                  # 历史记忆数据与结果
│   └── Figure_week3.2/            # 运行截图
└── 3-full-pipeline/
    ├── Dockerfile                 # Hermes 镜像定义
    ├── run-full-pipeline.sh       # 完整流水线入口
    ├── pipeline.py                # Docker 流程编排
    ├── container/install-memory.sh # 容器内插件安装
    ├── config/                     # 容器内 Hermes 配置
    ├── scenarios/                 # 富事实对话剧本
    ├── evidence/                  # 历史流水线结果
    └── Figure_week3.3/            # 运行截图
```

## 快速开始

运行前进入对应模块目录，将 `.env.example` 复制为 `.env`，并填写模型服务地址、模型名称和 API Key。

### 基础对话测试

```bash
cd 1-basic-soak
cp .env.example .env
bash ./run-basic-soak.sh --rounds 6 --interval 1s --duration 10m
```

认证失败测试：

```bash
bash ./run-basic-soak.sh --invalid-api-key
```

### L0–L3 记忆测试

该入口要求 Hermes、记忆插件和 Memory Gateway 已经启动，并通过 `TDAI_DATA_DIR` 指定记忆数据目录。

```bash
cd 2-memory-l0l3
cp .env.example .env
bash ./run-memory-soak.sh --rounds 6 --interval 1s --duration 15m
```

### 完整 Docker 流水线

完整流水线要求宿主机已安装 Docker、Python 3.9 及以上版本和 Bash。

```bash
cd 3-full-pipeline
cp .env.example .env
bash ./run-full-pipeline.sh \
  --hermes-version 0.20.6 \
  --rounds 6 \
  --interval 1s \
  --duration 15m
```

流水线执行顺序：

```text
docker build → docker run → 安装记忆插件 → 启动 Gateway → 运行 soak → 校验 L0–L3
```
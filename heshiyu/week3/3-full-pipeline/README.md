# Hermes Memory Docker Pipeline

一个面向 Hermes 的可重复 Docker 流水线。输入 Hermes 版本号后，系统会构建对应镜像、启动隔离容器、安装记忆插件、启动 Memory Gateway、运行多轮事实型对话，并检查 L0–L3 数据和 `/recall` 召回结果。

流水线使用 Bash 提供命令入口，使用仅依赖 Python 标准库的 `pipeline.py` 编排 Docker，使用容器内的 Node.js 执行 soak 和记忆校验。完整 Docker 流水线不要求宿主机安装 Node.js；只有独立运行 soak 时才需要宿主机提供 Node.js 和 Hermes CLI。

## 流程

```text
Docker build
    ↓
启动隔离 Hermes 容器
    ↓
安装 memory-tencentdb 与 Hermes provider
    ↓
启动 Memory Gateway 并检查 /health
    ↓
运行富事实 soak
    ↓
校验 L0、L1、L2、L3 和 /recall
    ↓
保存结构化结果
```

## 项目结构

```text
3-full-pipeline/
├── Dockerfile                     # Hermes 镜像定义
├── run-full-pipeline.sh           # Bash 运行入口
├── pipeline.py                    # Docker 流程编排
├── run-standalone-soak.sh         # 独立 soak 调试入口
├── hermes-standalone-soak.mjs     # 多轮对话与结构化报告
├── verify-memory.mjs              # L0–L3 与 /recall 校验
├── show-memory-result.py          # 展示已保存的记忆结果
├── container/install-memory.sh    # 容器内插件安装
├── config/hermes-config.yaml      # Hermes 和记忆插件配置
├── scenarios/memory-soak.json     # 富事实对话剧本
├── evidence/                      # 历史运行结果
├── Figure_week3.3/                # 运行截图
└── 实验过程.md                     # 完整运行记录
```

## 环境要求

- Docker，并确保 Docker daemon 已启动；
- Python 3.9 或更高版本；
- Bash，例如 Git Bash、WSL、Linux 或 macOS Shell；
- 可访问 GitHub、npm 和配置的模型服务；
- 一个兼容 OpenAI Chat Completions 的模型接口。

如果没有 Bash，可以直接运行 `pipeline.py`。

## 配置

复制环境变量模板：

```bash
cp .env.example .env
```

填写 Hermes 对话使用的模型服务：

```dotenv
HERMES_SOAK_BASE_URL=https://your-model-service.example/v1
HERMES_SOAK_MODEL=your-model-name
HERMES_SOAK_API_KEY=your-api-key
```

记忆提取默认复用相同的模型服务。如需独立配置，可以设置：

```dotenv
TDAI_LLM_BASE_URL=https://your-memory-model-service.example/v1
TDAI_LLM_MODEL=your-memory-model-name
TDAI_LLM_API_KEY=your-memory-model-api-key
```

其他常用配置：

```dotenv
HERMES_VERSION=0.20.6
MEMORY_GATEWAY_PORT=8473
SOAK_ROUNDS=6
SOAK_INTERVAL=1s
SOAK_DURATION=15m
MEMORY_PACKAGE_SPEC=@tencentdb-agent-memory/memory-tencentdb@1.0.1
```

`.env` 已被 Git 忽略，不应提交真实 API Key。

## 运行流水线

```bash
bash ./run-full-pipeline.sh \
  --hermes-version 0.20.6 \
  --gateway-port 8473 \
  --rounds 6 \
  --interval 1s \
  --duration 15m
```

也可以直接使用 Python 入口：

```bash
python ./pipeline.py --env-file ./.env --hermes-version 0.20.6
```

只检查配置并显示执行计划，不启动 Docker：

```bash
python ./pipeline.py --env-file ./.env --hermes-version 0.20.6 --dry-run
```

执行两轮快速检查：

```bash
bash ./run-full-pipeline.sh --hermes-version 0.20.6 --smoke
```

常用参数：

| 参数 | 说明 |
| --- | --- |
| `--hermes-version` | 需要构建的 Hermes 版本，格式为 `0.x.x` |
| `--rounds` | 普通对话轮数，记忆场景至少需要 2 轮 |
| `--interval` | 每轮对话之间的等待时间 |
| `--duration` | 整次 soak 的总时长上限 |
| `--gateway-port` | Gateway 映射到宿主机的端口 |
| `--output-dir` | 指定一个新的或空的结果目录 |
| `--keep-container` | 运行结束后保留容器，便于调试 |
| `--dry-run` | 只验证配置并打印执行计划 |

## 结果与状态

默认结果目录：

```text
results/pipeline-<Hermes版本>-<时间>/
├── pipeline-meta.json            # 流水线最终状态
├── pipeline.log                  # 完整执行日志
├── gateway-health.json           # Gateway 健康检查响应
├── fresh-data-baseline.json      # soak 前的空数据基线
├── memory-verification.json      # L0–L3 与召回校验结果
├── docker-stats-before.json      # soak 前容器资源采样
├── docker-stats-after.json       # soak 后容器资源采样
├── soak/
│   ├── conversations.jsonl       # 逐轮对话记录
│   ├── resources.jsonl           # soak 驱动资源采样
│   ├── probes.json               # 记忆探针结果
│   ├── meta.json                 # soak 汇总状态和统计
│   └── report.txt                # 文本摘要
└── memory-snapshot/              # 校验通过后保存的 L0–L3 数据
```

`pipeline-meta.json` 只有在以下检查全部通过时才会记录 `"status": "pass"`：

- soak 完成全部目标轮次且记忆探针通过；
- L0 和 L1 包含有效、非空的 JSONL 记录；
- L2 scene block 和 L3 `persona.md` 包含有效正文；
- 独立会话调用 `/recall` 成功并命中预期关键词。

默认情况下，流水线结束后会删除本轮容器。数据、日志和结构化结果会保留在结果目录中。

## 独立运行 soak

如果 Hermes 和相关环境已经准备完成，可以跳过 Docker 编排，仅运行对话脚本：

```bash
bash ./run-standalone-soak.sh
```

该入口主要用于调试对话过程；完整环境安装、L0–L3 校验和结果归档仍由 `run-full-pipeline.sh` 负责。

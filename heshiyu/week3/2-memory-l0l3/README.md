# Hermes L0–L3 Memory Soak

用于验证 Hermes 多轮对话能否被记忆插件转换为可持久化、可召回的分层记忆。模块通过富含姓名、职业、偏好、习惯和约束的对话驱动记忆提取，并检查 L0、L1、L2、L3 和独立 `/recall`。

## 记忆层级

| 层级 | 检查内容 |
| --- | --- |
| L0 | `conversations/` 中的原始对话 JSONL |
| L1 | `records/` 中提取出的事实和偏好 JSONL |
| L2 | `scene_blocks/` 中生成的场景记忆正文 |
| L3 | `persona.md` 中形成的用户画像 |
| Recall | 使用独立 session 调用 Gateway `/recall` 并核对关键词 |

## 项目结构

```text
2-memory-l0l3/
├── Dockerfile                    # Hermes 基础镜像定义
├── run-memory-soak.sh            # 记忆 soak 与校验入口
├── hermes-standalone-soak.mjs    # 多轮事实对话与报告
├── verify-memory.mjs             # L0–L3 与 /recall 校验
├── config/hermes-config.yaml     # Hermes 和记忆插件配置
├── scenarios/memory-soak.json    # 富事实对话剧本
├── .env.example                  # 环境变量模板
├── evidence/                     # 历史记忆数据与结果
├── Figure_week3.2/               # 运行截图
└── 实验过程.md                    # 详细运行记录
```

## 环境要求

- Bash，例如 Git Bash、WSL、Linux 或 macOS Shell；
- Node.js 和 Hermes CLI；
- Hermes 已启用 `memory_tencentdb` provider；
- Memory Gateway 已启动且 `/health` 可访问；
- 可访问实际的 memory-tdai 数据目录；
- 一个兼容 OpenAI Chat Completions 的模型接口。

本目录保留了 Hermes Dockerfile。插件安装、Gateway 启动和容器编排的实现位于 `../3-full-pipeline/`。

## 配置

复制环境变量模板：

```bash
cp .env.example .env
```

填写 Hermes 对话所需的模型配置：

```dotenv
HERMES_SOAK_BASE_URL=https://your-model-service.example/v1
HERMES_SOAK_MODEL=your-model-name
HERMES_SOAK_API_KEY=your-api-key
```

指定记忆数据目录和 Gateway：

```dotenv
TDAI_DATA_DIR=/opt/data/.memory-tencentdb/memory-tdai
MEMORY_GATEWAY_URL=http://127.0.0.1:8420
```

常用默认参数：

```dotenv
HERMES_EXPECTED_VERSION=0.20.6
SOAK_ROUNDS=6
SOAK_INTERVAL=1s
SOAK_DURATION=15m
SOAK_ROUND_TIMEOUT=180s
SOAK_ROUND_RETRIES=2
SOAK_PROBE_WAIT=300s
MEMORY_VERIFY_WAIT=240s
```

如果 Gateway 需要独立的记忆提取模型，可以在启动 Gateway 的环境中配置 `TDAI_LLM_BASE_URL`、`TDAI_LLM_MODEL` 和 `TDAI_LLM_API_KEY`。

## 运行

```bash
bash ./run-memory-soak.sh \
  --rounds 6 \
  --interval 1s \
  --duration 15m
```

也可以显式指定数据目录和 Gateway：

```bash
bash ./run-memory-soak.sh \
  --data-dir /opt/data/.memory-tencentdb/memory-tdai \
  --gateway-url http://127.0.0.1:8420 \
  --rounds 6 \
  --interval 1s \
  --duration 15m
```

常用参数：

| 参数 | 说明 |
| --- | --- |
| `--rounds` | 富事实对话轮数 |
| `--interval` | 每轮之间的等待时间 |
| `--duration` | 整次 soak 的总时长上限 |
| `--data-dir` | memory-tdai 数据目录 |
| `--gateway-url` | Memory Gateway 地址 |
| `--output` | 指定结果目录 |
| `--env` | 指定环境变量文件 |
| `--smoke` | 执行两轮快速检查 |

## 执行过程

```text
检查 Gateway /health
    ↓
执行富事实多轮对话
    ↓
执行 Gateway 记忆探针
    ↓
检查 L0、L1、L2、L3 文件
    ↓
使用独立 session 调用 /recall
    ↓
生成组合 PASS/FAIL 结果
```


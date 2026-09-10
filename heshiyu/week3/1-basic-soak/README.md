# Hermes Basic Soak Runner

一个基于 Hermes CLI 的持续对话测试工具。它按照设定的轮数、间隔和总时长自动执行对话，逐轮记录输入、回复、延迟和错误，并在结束时生成结构化 PASS/FAIL 结果。

## 功能

- 自动连续执行 N 轮 Hermes 对话；
- 支持轮数、轮间隔和总时长限制；
- 支持单轮超时、失败重试和连续失败终止；
- 识别无响应、进程错误、服务错误和认证失败；
- 输出逐轮 JSONL、汇总 JSON、延迟统计和文本报告；
- 使用隔离的 Hermes 配置，默认关闭记忆插件，避免影响用户环境。

## 项目结构

```text
1-basic-soak/
├── run-basic-soak.sh              # Bash 运行入口
├── hermes-standalone-soak.mjs     # 对话循环与结果生成
├── config/hermes-basic-soak.yaml  # 隔离的 Hermes 基础配置
├── scenarios/basic-soak.json      # 基础对话剧本
├── .env.example                   # 环境变量模板
├── evidence/                      # 历史 PASS/FAIL 结果
├── Figure_week3.1/                # 运行截图
└── 实验过程.md                     # 详细运行记录
```

## 环境要求

- Bash，例如 Git Bash、WSL、Linux 或 macOS Shell；
- Node.js；
- Hermes CLI；
- 一个兼容 OpenAI Chat Completions 的模型接口。

## 配置

复制环境变量模板：

```bash
cp .env.example .env
```

填写模型服务配置：

```dotenv
HERMES_SOAK_BASE_URL=https://your-model-service.example/v1
HERMES_SOAK_MODEL=your-model-name
HERMES_SOAK_API_KEY=your-api-key
```

可选默认参数：

```dotenv
HERMES_EXPECTED_VERSION=0.20.6
SOAK_ROUNDS=6
SOAK_INTERVAL=1s
SOAK_DURATION=10m
SOAK_ROUND_TIMEOUT=180s
SOAK_ROUND_RETRIES=2
```

`.env` 不应提交到版本库。

## 运行

```bash
bash ./run-basic-soak.sh \
  --rounds 6 \
  --interval 1s \
  --duration 10m
```

常用参数：

| 参数 | 说明 |
| --- | --- |
| `--rounds` | 目标对话轮数 |
| `--interval` | 每轮之间的等待时间，例如 `1s` |
| `--duration` | 整次测试的总时长上限，例如 `10m` |
| `--output` | 指定结果目录 |
| `--env` | 指定环境变量文件 |
| `--smoke` | 执行两轮、五分钟上限的快速检查 |
| `--invalid-api-key` | 使用无效 Key 测试认证失败处理 |

## 认证失败测试

```bash
bash ./run-basic-soak.sh --invalid-api-key
```

该命令会使用故意构造的无效 API Key。预期结果为结构化 FAIL 和非零退出码，认证错误会写入结果文件，而不是导致脚本无记录退出。

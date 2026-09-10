# Hermes 基础 Soak 自动对话测试

## 一、项目目标

本目录实现第三周作业的基础要求：自动驱动 Hermes 完成多轮连续对话，在轮数上限或总时长上限到达时停止，并输出逐轮 JSONL、汇总 JSON 和文本报告。程序能识别超时、启动失败、非零退出、空回答和会话 ID 缺失，不会把异常误判为成功。

本阶段不安装或验证记忆插件。`Dockerfile` 构建的是指定版本的干净 Hermes 镜像，L0-L3 记忆测试在下一阶段单独完成。

## 二、设计思路

首轮通过以下形式创建 Hermes 会话：

```bash
hermes chat -Q -q "问题" --source tool
```

Hermes 在 stderr 输出 `session_id: ...`。脚本提取该 ID，后续轮次使用：

```bash
hermes chat -Q --resume "会话ID" -q "问题" --source tool
```

因此，多轮调用属于同一个连续会话，而不是彼此独立的单次问答。

## 三、文件说明

```text
1-basic-soak/
├── Dockerfile                 # 构建指定版本的干净 Hermes 镜像
├── hermes-soak.mjs            # 参数、循环、子进程、容错和统计核心
├── run-soak.sh                # 加载 .env 并启动 Node.js 核心
├── prompts.json               # 基础对话剧本
├── .env.example               # 可提交的配置模板
├── .gitignore                 # 排除凭证和运行数据
├── results/                   # 运行结果目录
└── test/                      # 零 API 消耗的自动测试与 Hermes 替身
```

核心脚本只使用 Node.js 内置模块，不需要执行 `npm install`。

## 四、环境要求

- Node.js 22
- 已安装并配置可用模型凭证的 Hermes
- 构建镜像时需要 Docker Desktop

检查命令：

```bash
node --version
hermes chat --help
docker version
```

## 五、配置

复制配置模板：

```bash
cp .env.example .env
```

`.env` 中可以设置轮数、间隔、总时长、单轮超时和连续失败阈值。真实模型 API Key 由 Hermes 自己的配置管理，不写入本项目的 `.env.example`。

配置优先级为：

```text
命令行参数 > .env > 程序默认值
```

## 六、运行

两轮快速测试：

```bash
./run-soak.sh \
  --rounds 2 \
  --interval 500 \
  --duration 300 \
  --timeout 120 \
  --output results/real-smoke
```

查看全部参数：

```bash
./run-soak.sh --help
```

主要参数：

| 参数 | 含义 | 默认值 |
| --- | --- | --- |
| `--rounds` | 最大对话轮数 | `10` |
| `--interval` | 轮次间隔，单位毫秒 | `1000` |
| `--duration` | 总时长上限，单位秒 | `300` |
| `--timeout` | 单轮超时，单位秒 | `120` |
| `--max-consecutive-failures` | 连续失败停止阈值 | `3` |
| `--prompts` | JSON 对话剧本路径 | `prompts.json` |
| `--output` | 本次结果目录 | 自动生成 |
| `--hermes-command` | Hermes 命令或路径 | `hermes` |
| `--container` | 通过 `docker exec` 调用的容器名 | 留空 |

`rounds` 与 `duration` 同时生效，先达到的条件决定停止原因。

若 Hermes 运行在容器中，可直接执行：

```bash
./run-soak.sh --container hermes-week3-basic --rounds 3
```

## 七、结果文件

每次运行生成：

```text
results/<运行目录>/
├── conversations.jsonl
├── summary.json
└── report.txt
```

- `conversations.jsonl`：每行对应一轮，包含 prompt、response、状态、错误类型、退出码、延迟和 session ID。
- `summary.json`：包含整体 pass/fail、停止原因、成功/失败轮数、失败率和延迟统计。
- `report.txt`：与汇总 JSON 对应的可读报告，适合验收截图。

整体通过条件为：至少完成一轮、至少成功一轮、失败率不超过 20%。

## 八、测试与异常容错

运行自动测试：

```bash
node --test test/hermes-soak.test.mjs
```

测试使用 `fake-hermes.mjs`，不会调用真实 API，覆盖：

- 参数帮助与非法参数；
- 两轮会话恢复；
- 单轮超时；
- 结构化结果文件；
- 连续失败后提前停止。

手动演示超时容错：

```bash
./run-soak.sh \
  --rounds 1 \
  --interval 0 \
  --duration 5 \
  --timeout 0.05 \
  --max-consecutive-failures 1 \
  --prompts ./test/timeout-prompts.json \
  --output results/timeout-proof \
  --hermes-command ./test/fake-hermes.mjs
```

预期汇总状态为 `fail`，错误类型为 `timeout`，但三份结果文件仍正常生成。

## 九、Dockerfile 验证

构建指定 Hermes 版本：

```bash
docker build \
  --build-arg HERMES_VERSION=0.19.0 \
  -t hermes-week3-basic:0.19.0 \
  .
```

验证版本：

```bash
docker run --rm hermes-week3-basic:0.19.0 --version
```

验证 Node.js：

```bash
docker run --rm \
  --entrypoint node \
  hermes-week3-basic:0.19.0 \
  --version
```

## 十、验收对应关系

1. 自动完成 N 轮：运行真实两轮测试，查看相同 session ID 和 `conversations.jsonl`。
2. 三个参数生效：分别调整 `--rounds`、`--interval`、`--duration`，查看 `summary.json`。
3. 结构化结果：检查 `status`、轮数、耗时和 P50/P95。
4. 异常容错：运行超时示例，确认结果为 fail 且程序仍输出汇总。

## 十一、安全说明

- `.env`、实际对话结果和本地数据库不会提交。
- `.env.example` 不包含真实 API Key。
- 截图前检查终端和配置文件，避免泄露凭证。

## 十二、已提交验收证据

`evidence/` 中保存了经过脱敏的真实对话汇总、超时容错汇总和终端截图。原始回答与凭证不进入 Git，证据文件与验收标准的对应关系见 `evidence/README.md`。

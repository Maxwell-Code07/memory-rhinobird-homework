# Hermes + memory-tencentdb 一键完整流水线

## 一、项目目标

本目录是第三周最终交付阶段。只需提供 Hermes 版本号和 OpenAI 兼容模型凭证，一条命令就会自动完成：

```text
构建镜像 → 启动容器 → 安装插件 → 启动 Gateway
→ Hermes 多轮对话 → 刷新记忆管线 → 验证 L0/L1/L2/L3/recall
→ 生成 pipeline-summary.json
```

本目录拥有自己的 Dockerfile、soak 程序、剧本、插件安装脚本、Gateway 配置和验证脚本。它可以单独复制到其他目录运行，不引用 week2、第一阶段或第二阶段。

## 二、核心思路

`pipeline.sh` 只负责编排，各组件职责分开：

- `Dockerfile`：根据 `HERMES_VERSION` 构建干净 Hermes 镜像；
- `install-memory.sh`：在运行中的容器安装插件，不把插件固化进基础镜像；
- `hermes-soak.mjs`：在同一 session 中自动完成多轮对话并统计；
- `tdai-gateway.json`：缩短作业测试周期，使用不依赖 embedding 的 keyword recall；
- `verify-memory.sh`：直接检查落库文件和 recall 响应；
- `pipeline.sh`：串联步骤，无论成功或失败都输出总汇。

这同时满足“干净镜像”和“完整记忆流水线”：镜像构建完成时只有 Hermes，插件是在容器运行阶段安装的。

## 三、文件结构

```text
3-full-pipeline/
├── Dockerfile
├── pipeline.sh
├── install-memory.sh
├── verify-memory.sh
├── hermes-soak.mjs
├── run-soak.sh
├── memory-prompts.json
├── tdai-gateway.json
├── hermes-config.yaml.example
├── .env.example
├── test/
├── results/
└── evidence/
```

## 四、环境要求

- Docker Desktop 正常运行；
- Node.js 22；
- 能访问 Docker Hub、PyPI、npm 和模型中转站；
- 中转站支持 OpenAI Chat Completions。

DeepSeek 文本接口不需要提供 Embedding。本项目采用 SQLite FTS5 keyword recall，文本生成模型负责 L1-L3。

## 五、配置

```bash
cp .env.example .env
```

编辑 `.env`：

```dotenv
HERMES_VERSION=0.19.0
HERMES_API_KEY=你的中转站Key
HERMES_BASE_URL=https://你的中转站地址/v1
HERMES_MODEL=你的模型名

TDAI_LLM_API_KEY=你的中转站Key
TDAI_LLM_BASE_URL=https://你的中转站地址/v1
TDAI_LLM_MODEL=你的模型名
```

如果省略 `TDAI_LLM_*`，`pipeline.sh` 会在本次进程内复用对应的 `HERMES_*` 值。日志只输出凭证“已设置/未设置”，不会显示 Key。

`.env` 已加入 `.gitignore`，不要提交。

## 六、一键运行

```bash
./pipeline.sh
```

也可以不写 `.env`，临时传入版本号：

```bash
HERMES_VERSION=0.19.0 ./pipeline.sh
```

常用选项：

| 参数 | 作用 | 默认值 |
| --- | --- | --- |
| `--version` | Hermes PyPI 版本 | `HERMES_VERSION` |
| `--plugin-version` | npm 记忆插件版本 | `latest` |
| `--rounds` | 记忆对话轮数 | `10` |
| `--wait` | 等待 L1-L3 的最长秒数 | `180` |
| `--image` | 自定义镜像标签 | 自动唯一标签 |
| `--container` | 自定义容器名 | 自动唯一名称 |
| `--output` | 本次结果目录 | `results/pipeline-时间戳` |
| `--cleanup` | 结束后删除容器 | 默认保留 |

查看帮助不会启动 Docker：

```bash
./pipeline.sh --help
```

## 七、输出与验收

每次运行生成独立目录：

```text
results/pipeline-<时间戳>/
├── pipeline-summary.json
├── build.log
├── plugin-install.log
├── gateway-health.json
├── provider-discovery.txt
├── gateway.log
├── session-end.json
├── verify.log
├── memory-verification.json
└── soak/
    ├── conversations.jsonl
    ├── summary.json
    └── report.txt
```

最终通过时，`pipeline-summary.json` 应包含：

```json
{
  "status": "pass",
  "stages": {
    "build": "pass",
    "container": "pass",
    "plugin": "pass",
    "gateway": "pass",
    "soak": "pass",
    "l0": "pass",
    "l1": "pass",
    "l2": "pass",
    "l3": "pass",
    "recall": "pass"
  }
}
```

验收截图建议包含：

1. Docker build 成功和容器内 `hermes --version`；
2. `provider-discovery.txt` 中 `memory_tencentdb` 为 `True`；
3. soak 汇总中的轮数、同一 session ID 和 pass；
4. `memory-verification.json` 中 L0-L3、recall 全部 pass；
5. `pipeline-summary.json` 中全部阶段 pass。

## 八、失败与排错

脚本遇到错误也会生成 `pipeline-summary.json`，未执行的阶段标记为 `not_run`。默认保留失败容器，方便检查：

```bash
docker logs <容器名>
docker exec <容器名> tail -n 100 \
  /home/hermes/.memory-tencentdb/gateway.log
```

排查完手动清理：

```bash
docker rm -f <容器名>
```

如果不需要保留容器：

```bash
./pipeline.sh --cleanup
```

常见问题：

- `Docker Engine 未运行`：先启动 Docker Desktop；
- 拉取镜像超时：检查 Docker Desktop 代理，而不只是终端代理；
- npm/PyPI 超时：确认容器能联网；
- Gateway 超时：查看 `gateway.log`，重点检查 `TDAI_LLM_*`；
- L0 pass、L1-L3 fail：文本生成模型调用失败或等待时间不够，可增加 `--wait 300`；
- recall fail：确认 `tdai-gateway.json` 的 strategy 是 `keyword` 且 L1 已非空。

## 九、自动测试与提交前检查

离线测试不会调用真实模型：

```bash
node --test test/hermes-soak.test.mjs
node --test test/memory-scripts.test.mjs
node --test test/pipeline.test.mjs
```

语法和安全检查：

```bash
bash -n run-soak.sh install-memory.sh verify-memory.sh pipeline.sh
node --check hermes-soak.mjs
find . -type l -print
rg -n 'sk-[A-Za-z0-9_-]+' .
```

前两项应无错误；符号链接和真实 API Key 扫描应没有输出。运行结果包含虚构对话，但仍默认不提交，只提交检查后的脱敏证据。

## 十、已提交验收证据

`evidence/` 中保存了本次一键执行生成的流水线总汇、soak 汇总、记忆验证汇总、provider 发现结果和终端截图。`pipeline-summary.json` 的所有阶段均为 `pass`，可直接用于验收。

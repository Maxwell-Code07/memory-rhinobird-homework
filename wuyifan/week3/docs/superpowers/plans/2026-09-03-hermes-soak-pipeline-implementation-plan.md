# Hermes Soak 与记忆流水线教学实施计划

> **For agentic workers:** 后续按本计划逐项教学。由于学生明确要求亲手完成作业，助手不得一次性生成三个阶段的交付物；每次只解释并让学生完成一个小步骤，确认成功后再继续。

**Goal:** 指导学生独立完成基础 Hermes soak、L0-L3 记忆验证和一键 Docker 流水线，并留下可复查的验收证据。

**Architecture:** 每个阶段都是独立项目，各自包含 Dockerfile、soak 核心、运行脚本、剧本、配置模板和 README，不跨目录引用。Node.js 22 零依赖脚本负责 Hermes 多轮会话和统计，Bash 负责 Docker 与插件编排，JSON 负责测试数据。

**Tech Stack:** Docker、Debian 12、Node.js 22、JavaScript ES modules、Bash、Hermes CLI、TencentDB Agent Memory Gateway、JSON/JSONL、SQLite。

---

## 教学约束

每个操作必须按以下顺序讲解：

1. 目标
2. 为什么 / 思路
3. 具体操作
4. 预期结果
5. 报错怎么看

一次只布置一个可在数分钟内完成的小操作。学生回复“成功”或贴出实际输出后，才能继续下一项。遇到报错先定位根因，不跳过验证。

## 最终文件结构

### `1-basic-soak`

- `Dockerfile`：独立构建指定 PyPI Hermes 版本的干净镜像。
- `hermes-soak.mjs`：参数解析、连续会话、超时、JSONL 和统计报告。
- `run-soak.sh`：加载 `.env` 并调用 Node.js 核心。
- `prompts.json`：基础测试问题。
- `hermes-config.yaml.example`：OpenAI 兼容模型配置示例。
- `.env.example`：空凭证与 soak 默认参数。
- `.gitignore`：排除真实凭证和运行结果。
- `README.md`：配置、运行、验收和排错说明。
- `results/`：运行时生成，不提交含隐私的原始结果。

### `2-memory-l0l3`

- 完整拥有基础阶段全部必要文件的真实副本，不使用符号链接。
- `memory-prompts.json`：虚构但事实密集的记忆剧本。
- `install-memory.sh`：在容器中安装 Gateway 和 provider。
- `tdai-gateway.json`：测试专用管线阈值与 keyword recall。
- `verify-memory.sh`：分别验证 L0、L1、L2、L3 和 recall。
- `evidence/`：保存脱敏后的验收截图或文本。

### `3-full-pipeline`

- 完整拥有第二阶段全部必要文件的真实副本，不使用符号链接。
- `pipeline.sh`：build、run、plugin、gateway、soak、verify、summary 的唯一入口。

## Task 1：建立三个独立阶段的目录骨架

**操作：** 在 `wuyifan/week3` 下创建规范要求的三个目录，再分别创建运行结果目录；第二、三阶段额外创建证据目录。

**验证：**

```bash
find . -maxdepth 2 -type d | sort
```

应看到三个规范目录名，且每个目录的子目录完整。此时还不创建任何代码文件。

## Task 2：在基础阶段创建并理解 Dockerfile

**文件：** `wuyifan/week3/1-basic-soak/Dockerfile`

从第二周已验证的 Dockerfile 手动录入一份独立副本，保留：

- `FROM node:22-bookworm-slim`
- `ARG HERMES_VERSION`
- 缺失版本号时主动失败
- Python venv 和 `hermes-agent==${HERMES_VERSION}`
- 普通用户 `hermes`
- `ENTRYPOINT ["hermes"]`

**验证：**

```bash
docker build --build-arg HERMES_VERSION=0.19.0 -t hermes-week3-basic:0.19.0 .
docker run --rm hermes-week3-basic:0.19.0 --version
```

版本输出必须为 `0.19.0`。

## Task 3：创建基础对话剧本

**文件：** `wuyifan/week3/1-basic-soak/prompts.json`

写入一个 JSON 数组，每项包含稳定的 `id` 和 `prompt`。问题覆盖问候、解释概念、简短推理和总结，避免要求工具调用，保证“回答非空”能作为成功判定。

**验证：**

```bash
node -e 'const p=require("./prompts.json"); if(!Array.isArray(p)||p.length<3||p.some(x=>!x.id||!x.prompt)) process.exit(1); console.log(`prompts=${p.length}`)'
```

## Task 4：搭建 soak 参数解析与输入校验

**文件：** `wuyifan/week3/1-basic-soak/hermes-soak.mjs`

先实现 `--help` 和以下参数：

- `--rounds <N>`：默认 10，必须为正整数。
- `--interval <ms>`：默认 1000，必须为非负整数。
- `--duration <seconds>`：默认 300，必须为正数。
- `--timeout <seconds>`：默认 120，必须为正数。
- `--prompts <path>`、`--output <path>`。
- `--hermes-command <command>` 或 `--container <name>`。
- `--max-consecutive-failures <N>`：默认 3。

环境变量作为默认值，命令行参数覆盖环境变量。参数非法时在调用 Hermes 前退出 2。

**验证：**

```bash
node --check hermes-soak.mjs
node hermes-soak.mjs --help
node hermes-soak.mjs --rounds 0
```

前两条成功，最后一条输出明确错误并返回非零退出码。

## Task 5：实现同一 Hermes 会话的逐轮调用

**文件：** `wuyifan/week3/1-basic-soak/hermes-soak.mjs`

首轮执行：

```text
hermes chat -Q -q <prompt> --source tool
```

从 stderr 提取 Hermes 输出的 `session_id`。后续轮执行：

```text
hermes chat -Q --resume <session_id> -q <prompt> --source tool
```

用 `spawn` 的参数数组传值，禁止把 prompt 拼成 shell 字符串。容器模式的命令前缀为 `docker exec <container> hermes`。每轮保存开始时间、耗时、stdout、截断后的 stderr、退出码和 session ID。

**验证：** 先用 2 轮运行，第二轮日志必须显示与首轮相同的 session ID。

## Task 6：实现超时、信号和连续失败容错

**文件：** `wuyifan/week3/1-basic-soak/hermes-soak.mjs`

每轮设置独立定时器；超时时终止子进程并记录 `errorType: "timeout"`。非零退出、启动失败、空 stdout、首轮缺少 session ID 都记为失败。单轮失败后继续下一轮，连续失败达到阈值才提前结束。收到 `SIGINT` 或 `SIGTERM` 时停止发起新轮次并写汇总。

**验证：** 用极短 `--timeout` 制造失败，确认脚本生成结果文件而不是抛出未捕获异常。

## Task 7：实现 JSONL、统计 JSON 和文本报告

**文件：** `wuyifan/week3/1-basic-soak/hermes-soak.mjs`

每轮结束立即追加 `conversations.jsonl`。最终写入：

- `summary.json`：`status`、计划/完成/成功/失败轮数、停止原因、总耗时、失败率、min/mean/P50/P95/max。
- `report.txt`：同一统计的可读版本。

整体通过条件：完成轮数和成功轮数均大于 0、失败率不超过 20%、没有因连续失败提前终止。最终进程退出码必须与 `status` 一致。

**验证：**

```bash
find results -type f -maxdepth 2 -print
node -e 'const s=require(process.argv[1]); console.log(s.status,s.completedRounds,s.latencyMs)' results/<本次目录>/summary.json
```

## Task 8：创建基础阶段运行入口与安全模板

**文件：**

- `wuyifan/week3/1-basic-soak/run-soak.sh`
- `wuyifan/week3/1-basic-soak/.env.example`
- `wuyifan/week3/1-basic-soak/hermes-config.yaml.example`
- `wuyifan/week3/1-basic-soak/.gitignore`

Shell 入口只负责定位自身目录、加载 `.env`、检查 Node.js 与剧本，再用 `exec node` 传递全部参数。`.env.example` 只放空占位符；`.gitignore` 至少忽略 `.env`、`results/*` 和系统临时文件。

**验证：**

```bash
bash -n run-soak.sh
./run-soak.sh --help
git check-ignore .env
```

## Task 9：完成基础阶段四项验收

依次保存证据：

1. 指定 `--rounds 3` 能自动完成三轮。
2. 分别改变 rounds、interval、duration，结果 JSON 反映真实停止条件。
3. `summary.json` 明确 pass/fail 且包含耗时统计。
4. 极短 timeout 或错误模型凭证时，结果为 fail 且仍生成汇总。

完成 `wuyifan/week3/1-basic-soak/README.md`，逐条对应作业验收标准。

## Task 10：建立完全独立的 L0-L3 阶段

把基础阶段所需文件复制为 `wuyifan/week3/2-memory-l0l3` 内的真实文件，再在该目录独立修改。不得出现 `../1-basic-soak`、`../week2` 或符号链接。

**验证：**

```bash
find . -type l -print
rg '\.\./(week2|1-basic-soak|3-full-pipeline)' .
```

两条命令均不应找到跨阶段依赖。

## Task 11：创建测试专用 Gateway 配置

**文件：** `wuyifan/week3/2-memory-l0l3/tdai-gateway.json`

配置本地数据目录、较小的 pipeline 触发阈值和 `recall.strategy: "keyword"`。DeepSeek 兼容文本端点不提供 embedding，因此不使用 `hybrid`。阈值要让数轮对话后触发 L1，再用短延迟触发 L2，并降低 persona 触发间隔以生成 L3。

**验证：**

```bash
node -e 'const c=require("./tdai-gateway.json"); if(c.recall?.strategy!=="keyword") process.exit(1); console.log("keyword recall configured")'
```

## Task 12：编写容器内记忆插件安装脚本

**文件：** `wuyifan/week3/2-memory-l0l3/install-memory.sh`

脚本接收容器名，在容器内以 root：

1. npm 安装 `@tencentdb-agent-memory/memory-tencentdb@latest`。
2. 安装 Gateway 运行需要的 `tsx`。
3. 把 provider 放到 `/home/hermes/.hermes/plugins/memory_tencentdb`。
4. 写入 Hermes `config.yaml` 的 `memory.provider: memory_tencentdb`。
5. 把目录所有权交给 `hermes` 用户。

安装后先检查 provider 目录和 Gateway 入口文件，再返回成功。

## Task 13：创建事实密集的记忆剧本

**文件：** `wuyifan/week3/2-memory-l0l3/memory-prompts.json`

使用统一的虚构人物，连续提供身份、研究方向、工具偏好、作息、饮食约束、长期目标、回答风格等互相一致的事实；加入唯一探针关键词供 recall 验证。避免学生真实隐私和相互矛盾的事实。

**验证：** 检查 JSON 格式、条目数量、ID 唯一，以及探针关键词存在。

## Task 14：实现逐层落库验证

**文件：** `wuyifan/week3/2-memory-l0l3/verify-memory.sh`

逐项检查并分别输出 pass/fail：

- L0：`conversations/*.jsonl` 存在且非空。
- L1：`records/*.jsonl` 存在且非空。
- L2：`scene_blocks/*.md` 存在且非空。
- L3：`persona.md` 存在且非空。
- Recall：POST `/recall` 返回非空结果并出现探针关键词。

脚本生成机器可读验证摘要；任一层为空时整体返回非零。Gateway 健康日志或 capture 日志只能作为辅助证据，不能替代文件检查。

## Task 15：完成 L0-L3 阶段验收

启动一个基于本目录 Dockerfile 的新容器，安装插件、注入 `TDAI_LLM_API_KEY`、`TDAI_LLM_BASE_URL`、`TDAI_LLM_MODEL` 和 `TDAI_DATA_DIR`，启动 Gateway，运行事实剧本并等待管线处理。保存 L0/L1、L2、L3、recall 四组脱敏证据和 soak JSON。

完成 `wuyifan/week3/2-memory-l0l3/README.md`，说明为什么 keyword recall 可用而 hybrid 不适用于当前端点。

## Task 16：建立完全独立的完整流水线阶段

把第二阶段所需文件复制为 `wuyifan/week3/3-full-pipeline` 内的真实文件，保持自己的 Dockerfile、soak 核心、剧本、安装脚本、验证脚本、配置模板和 README。不得运行时引用其他阶段。

## Task 17：实现一键流水线入口

**文件：** `wuyifan/week3/3-full-pipeline/pipeline.sh`

按固定阶段执行并记录状态：

1. 校验 `HERMES_VERSION` 和运行时凭证只报告“已设置/未设置”。
2. 使用本目录 Dockerfile build 唯一标签的干净镜像。
3. 用唯一容器名和空数据目录启动后台容器。
4. 调用本目录 `install-memory.sh`。
5. 启动 Gateway 并轮询 `/health`。
6. 调用本目录 `run-soak.sh` 运行事实剧本。
7. 等待记忆管线完成并调用本目录 `verify-memory.sh`。
8. 汇总 build、container、plugin、gateway、soak、L0、L1、L2、L3、recall 状态。

默认保留失败容器用于排查，提供明确的 `--cleanup` 或清理命令。即使中间失败，也应尽量写出 `pipeline-summary.json`，且最终退出码与总体状态一致。

## Task 18：完整流水线验收与独立性证明

从空数据目录执行一次：

```bash
HERMES_VERSION=0.19.0 ./pipeline.sh
```

验收结果必须包含：构建成功、容器运行、provider 被 Hermes 发现、Gateway 健康、soak JSON 为 pass、L0-L3 非空、recall 命中。

再把 `3-full-pipeline` 单独复制到临时目录，从临时目录执行静态检查和 `--help`，证明没有引用 week2 或另外两个阶段。

## Task 19：安全检查、文档和最终提交前检查

对三个阶段分别完成 README，内容包含环境要求、配置、运行、输出、验收和常见错误。随后执行：

```bash
find week3 -type l -print
rg -n 'sk-[A-Za-z0-9_-]+' week3
rg -n '\.\./(week2|1-basic-soak|2-memory-l0l3|3-full-pipeline)' week3
find week3 -name '*.sh' -exec bash -n {} \;
find week3 -name '*.mjs' -exec node --check {} \;
git status --short
```

预期：无符号链接、无真实 API Key、无跨阶段运行时引用、语法检查全部通过。人工检查截图没有暴露凭证或真实个人信息后，再按阶段提交。

## 需求覆盖检查

- 基础四项要求：Task 4–9 覆盖。
- L0-L3 与 recall：Task 10–15 覆盖。
- 一键完整流水线：Task 16–18 覆盖。
- 每阶段独立运行：Task 1、10、16、18、19 覆盖。
- 凭证不泄露：Task 8、15、17、19 覆盖。
- 三阶段 README 与验收证据：Task 9、15、18、19 覆盖。

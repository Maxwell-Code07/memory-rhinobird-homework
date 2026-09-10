# Hermes L0-L3 记忆落库验收

## 一、项目目标

本目录是一个可独立运行的第三周第二阶段项目。它构建干净的 Hermes 0.19.0 镜像，在运行中的容器里安装 `memory-tencentdb`，用十轮虚构信息对话触发记忆管线，并分别验证：

- L0：原始用户/助手消息；
- L1：LLM 提取的结构化长期记忆；
- L2：按场景整理的 Markdown 记忆；
- L3：综合形成的用户画像 `persona.md`；
- Recall：Hermes 在后续对话前能检索到验收标记。

所有必要文件都在本目录中，不引用 week2 或其他阶段。

## 二、为什么使用 keyword recall

当前使用的是 OpenAI 兼容的 DeepSeek/中转站文本生成接口，它能够完成 L1-L3 的总结生成，但不一定提供 `/embeddings` 接口。`hybrid` 检索依赖 EmbeddingService，缺少时会出现：

```text
Recall strategy "hybrid" requires EmbeddingService
```

因此 `tdai-gateway.json` 使用 `keyword`，并关闭 embedding。SQLite FTS5 仍能进行关键词检索，且不会影响 L0-L3 的生成。

## 三、文件说明

```text
2-memory-l0l3/
├── Dockerfile
├── hermes-soak.mjs
├── run-soak.sh
├── memory-prompts.json
├── install-memory.sh
├── verify-memory.sh
├── tdai-gateway.json
├── hermes-config.yaml.example
├── .env.example
├── test/
├── results/
└── evidence/
```

`memory-prompts.json` 使用统一的虚构人物“林澈”，不会写入提交者的真实隐私。

## 四、环境要求

- Docker Desktop 正常运行；
- Node.js 22；
- npm、PyPI 和模型中转站网络可访问；
- 一个支持 OpenAI Chat Completions 的 API Key。

检查：

```bash
docker version
node --version
```

## 五、配置凭证

```bash
cp .env.example .env
```

编辑 `.env`，至少填写：

```dotenv
HERMES_API_KEY=你的中转站Key
HERMES_BASE_URL=https://你的中转站地址/v1
HERMES_MODEL=你的模型名

TDAI_LLM_API_KEY=你的中转站Key
TDAI_LLM_BASE_URL=https://你的中转站地址/v1
TDAI_LLM_MODEL=你的模型名
```

Hermes 和 Gateway 可以共用同一个兼容接口。`.env` 已被 Git 忽略，禁止把真实 Key 写进 `.env.example`、README 或截图。

## 六、从空容器开始运行

### 1. 构建干净 Hermes 镜像

```bash
docker build \
  --build-arg HERMES_VERSION=0.19.0 \
  -t hermes-week3-memory:0.19.0 \
  .
```

### 2. 启动后台容器

```bash
docker rm -f hermes-week3-memory 2>/dev/null || true
docker run -d \
  --name hermes-week3-memory \
  --env-file .env \
  --entrypoint sleep \
  hermes-week3-memory:0.19.0 \
  infinity
```

### 3. 安装记忆插件

```bash
./install-memory.sh --container hermes-week3-memory
```

脚本会安装 Gateway、`tsx` 和 provider，并把目录命名为 Hermes 要求的 `memory_tencentdb`（下划线）。

### 4. 启动并检查 Gateway

```bash
docker exec -d -u hermes hermes-week3-memory sh -c \
  'cd /home/hermes/.memory-tencentdb/tdai-memory-openclaw-plugin && exec npx tsx src/gateway/server.ts >> /home/hermes/.memory-tencentdb/gateway.log 2>&1'

docker exec hermes-week3-memory node -e \
  'fetch("http://127.0.0.1:8420/health").then(r=>r.text()).then(console.log)'
```

健康状态允许为 `ok` 或 `degraded`。关闭 embedding 时出现 `degraded` 不等于 L0-L3 失败。

### 5. 运行十轮记忆对话

```bash
./run-soak.sh \
  --container hermes-week3-memory \
  --prompts ./memory-prompts.json \
  --rounds 10 \
  --interval 1000 \
  --duration 900 \
  --timeout 180 \
  --output results/memory-run
```

### 6. 主动刷新会话并等待管线

```bash
SESSION_ID=$(node -p \
  'require("./results/memory-run/summary.json").sessionId')

docker exec hermes-week3-memory node -e \
  'const s=process.argv[1];fetch("http://127.0.0.1:8420/session/end",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({session_key:s})}).then(r=>r.text()).then(console.log)' \
  "$SESSION_ID"

sleep 30
```

短周期配置会在少量对话后触发 L1，再触发 L2 和 L3。模型响应速度不固定，若验证时某层仍为空，可再等待 30-120 秒。

### 7. 验证真实落库

```bash
./verify-memory.sh \
  --container hermes-week3-memory \
  --session-key "$SESSION_ID" \
  --output evidence/memory-verification.json
```

预期终端逐项显示：

```text
L0       pass
L1       pass
L2       pass
L3       pass
recall   pass
```

## 七、证明插件确实被 Hermes 加载

Gateway 启动后执行：

```bash
docker exec -u hermes hermes-week3-memory \
  /opt/hermes-venv/bin/python -c \
  'from plugins.memory import discover_memory_providers; print([x for x in discover_memory_providers() if x[0]=="memory_tencentdb"])'
```

输出中的第三项为 `True`，才能证明 provider 已发现且 Gateway 可用。仅有 `/health` 只能证明 Gateway 在运行，不能单独证明 Hermes 已加载 provider。

## 八、自动测试

```bash
node --test test/hermes-soak.test.mjs
node --test test/memory-scripts.test.mjs
bash -n run-soak.sh install-memory.sh verify-memory.sh
```

测试不会调用真实模型。`memory-scripts.test.mjs` 会用临时假数据和本地假 Gateway 验证逐层判断逻辑。

## 九、结果与截图

建议提交或截图以下脱敏内容：

1. `results/memory-run/summary.json` 中十轮 soak 为 pass；
2. provider 发现输出中 `memory_tencentdb` 为 `True`；
3. Gateway 日志中的 `capture`、L1、L2、L3 完成信息；
4. `evidence/memory-verification.json` 五项全部为 pass；
5. `find` 或 `wc -c` 显示四层文件非空。

运行结果和原始记忆可能含对话内容，默认被 `.gitignore` 排除。提交证据前先确认没有 API Key 和真实隐私。

## 十、常见错误

- `hybrid requires EmbeddingService`：确认 `tdai-gateway.json` 已加载且 strategy 为 `keyword`。
- L0 有内容、L1-L3 为空：检查 `TDAI_LLM_*`，再查看 `/home/hermes/.memory-tencentdb/gateway.log`。
- provider 未发现：目录必须是 `/home/hermes/.hermes/plugins/memory_tencentdb`。
- recall 失败：先确认 L1 非空，再用完整验收标记查询。
- npm 超时：检查 Docker 容器出网和 Docker Desktop 代理配置。

## 十一、已提交验收证据

`evidence/` 中保存了本次真实 Docker 运行得到的 provider 发现结果、L0-L3 与 recall 汇总以及终端截图。证据只包含虚构人物信息和固定 marker，不包含模型凭证。

# Week3 进阶 2：完整流水线（3-full-pipeline）

**目标**：把前两周的东西串成一条一键流水线——输入一个版本号 + 模型凭证，自动完成 build → 拉起容器 → 装记忆插件 → 起 Gateway → 跑 soak（富含事实剧本）→ 输出 JSON 结果 + L0-L3 验证。

一句话：**输入一个版本号，输出「该版本 Hermes + 记忆插件」的对话测试结果和 L0-L3 证据。**

## 文件

| 文件 | 说明 |
|---|---|
| `run-pipeline.sh` | 一键流水线（在装好 Docker 的 Linux 宿主机/虚拟机执行，无需其它依赖） |

用到的其它交付物：

- 第二周 `../../week2/Dockerfile`（交付物 A：按版本号构建干净 Hermes 镜像）
- 基础 `../1-basic-soak/soak.mjs`（交付物 B：自动对话驱动）
- 进阶 1 `../2-memory-l0l3/conversation-facts.txt` + `verify-l0l3.sh`（事实剧本 + 四合一验证）

## 用法

```bash
cd memory-rhinobird-homework/xiezengye/week3/3-full-pipeline

MODEL_API_KEY=sk-xxxx \
MODEL_BASE_URL=https://api.lkeap.cloud.tencent.com/v1 \
MODEL_NAME=deepseek-v3.2 \
bash run-pipeline.sh
```

跑完输出：

- `results-<时间戳>/result.json` —— soak 结构化判定（pass/fail + 轮次统计）
- `results-<时间戳>/report.txt`、`results-<时间戳>/conversation.jsonl` —— 报告与逐轮记录
- 终端上的四合一 L0-L3 验证输出（**直接截图**）
- 容器保留存活，供随时 `docker exec` 进去补充截图

## 流水线 5 步（与会议对齐的步骤一一对应）

| 步骤 | 动作 | 复用 |
|---|---|---|
| 1 | `docker build`：用第二周 Dockerfile 构建干净 Hermes 镜像 | 第二周交付物 A |
| 2 | `docker run` 拉起容器（`sleep infinity` 后台常驻） | — |
| 3 | 容器内安装记忆插件：git clone 插件源码 → `npm install` → Provider 挂载到 `~/.hermes/plugins/memory_tencentdb` → 写 `config.yaml`（model + memory） | 记忆插件安装 |
| 4 | 启动 Gateway：`node --import tsx src/gateway/server.ts`（监听 `:8420`，轮询 `/health` 直到就绪） | — |
| 5 | 跑 soak（富含事实剧本）+ 收集 JSON 结果 + L0-L3 四合一验证 | 第三周交付物 B |

## 可配置参数（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `HERMES_VERSION` | `v2026.8.27` | 要构建的 Hermes 日期式 tag |
| `SOAK_ROUNDS` / `SOAK_INTERVAL` / `SOAK_MAX_TOTAL_SECONDS` | 12 / 5 / 1200 | soak 参数 |
| `TDAI_LLM_API_KEY` / `TDAI_LLM_BASE_URL` / `TDAI_LLM_MODEL` | 复用 `MODEL_*` | 记忆抽取（L1/L2/L3）用的 LLM |
| `PLUGIN_REPO` | TencentCloud/TencentDB-Agent-Memory | 插件源码仓库 |
| `PLUGIN_BRANCH` | `main` | 插件分支。**必须 clone main**：该仓库默认分支是 `feat/server_team`（重构中的新结构，根目录无 `package.json`），不指定分支会在 npm install 报 ENOENT |
| `GIT_PROXY_ARGS` | 空 | 容器内 git clone 走代理（见下面注意事项 3） |
| `NPM_REGISTRY` | 空 | npm 镜像源（如 `https://registry.npmmirror.com`） |
| `SKIP_BUILD` | 0 | 镜像已存在时置 1 跳过构建 |

## 换个版本再跑（验证参数化）

```bash
HERMES_VERSION=v2026.8.19 \
MODEL_API_KEY=sk-xxxx MODEL_BASE_URL=... MODEL_NAME=... \
bash run-pipeline.sh
```

## 注意事项

1. **耗时预期**：build 约 15-20 分钟（有缓存则几十秒）→ 装插件约 2-5 分钟 → soak 12 轮约 10-20 分钟 → 全程留 40 分钟左右；soak 阶段终端逐轮打印 `✓/✗`，不是卡住；
2. **凭证安全**：模型 Key 只经环境变量注入容器，不写入镜像层、不进 git；`config.yaml` 里会含 key，但只存在于容器内 `/root/.hermes/`；
3. **国内网络**：容器内 `git clone` GitHub 不通时，把宿主机代理传给 git：
   `GIT_PROXY_ARGS="-c http.proxy=http://<宿主机IP>:7890 -c https.proxy=http://<宿主机IP>:7890" bash run-pipeline.sh`（注意用宿主机在 docker 网络里的 IP，不是 127.0.0.1）；npm 慢就加 `NPM_REGISTRY=https://registry.npmmirror.com`；
4. **Gateway 起不来的排查**：`docker exec hermes-week3-pipeline tail -50 /tmp/gateway.log`，常见原因是 npm install 没装全或 TDAI_LLM_* 缺失；
5. **重复跑**：脚本开头会 `docker rm -f` 同名容器再重建，直接重跑即可；插件源码目录 `/opt/tdai` 已存在时跳过 clone，改用缓存的源码；
6. 跑完别急着删容器——四张 L0-L3 截图都在里面拍（`docker exec -it hermes-week3-pipeline bash` 进去随意翻）。

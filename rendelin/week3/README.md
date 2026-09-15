# 第三周作业 · 任德霖

week3 下三个目录，对应三次任务（基础、进阶 1 为必交，进阶 2 为选交）：

```
week3/
├── 1-basic-soak/        # 基础：soak 自动对话脚本
├── 2-memory-l0l3/       # 进阶1：记忆插件下 L0-L3 生成 + 验证截图
└── 3-full-pipeline/     # 进阶2：Dockerfile + soak 一键流水线
```

| 目录 | 内容 | 验证方式 |
|---|---|---|
| `1-basic-soak/` | soak 脚本 + 纯闲聊剧本 + 单元测试 | `node test/test-soak.mjs`（39 个用例，不依赖 Docker 与模型） |
| `2-memory-l0l3/` | 事实剧本 + `check-l0l3.mjs` 记忆检测 | 跑完 soak 后执行 `node check-l0l3.mjs --data-dir <记忆数据目录> --json`，以 `all_nonempty` 字段为准 |
| `3-full-pipeline/` | Dockerfile + `build.sh` / `run-pipeline.bat` 一键流水线 | `bash build.sh`（Git Bash / Linux）或直接运行 `run-pipeline.bat`（Windows） |

进阶 1、2 的设计要点：soak 剧本必须包含可提取事实（身份、偏好、习惯、约束），否则 Hermes 能正常应答但 L1/L2/L3 不会沉淀任何内容。`check-l0l3.mjs` 逐层检查 L0（conversations）、L1（records）、L2（scene_blocks）、L3（persona.md）是否非空；进阶 2 流水线在验证后还会调用 Gateway `POST /recall`，确认生成的记忆可被召回（证据见 `3-full-pipeline/results/recall*.json`）。

跑进阶 2 时进入 `3-full-pipeline/` 目录（week3 根目录无流水线脚本）：

```bash
cd 3-full-pipeline
bash build.sh                # Git Bash / Linux，交互式输入
# 或双击 run-pipeline.bat    # Windows
```

需要提供的参数：

- Hermes 版本号（如 `2026.8.19`，`v` 前缀可省略）
- `MODEL_API_KEY`（必填）；`MODEL_BASE_URL` 与 `MODEL_NAME` 默认使用 deepseek（`https://api.deepseek.com/v1` / `deepseek-v4-flash`）
- 构建代理，默认 `http://host.docker.internal:7890`（容器内访问宿主机 Clash 的地址；输入 `NONE` 表示直连）

完成后产出以下结果文件：

- `3-full-pipeline/results/result.json` —— soak 判定结果（`passed` 字段，true/false）
- `3-full-pipeline/results/l0l3.json` —— L0-L3 四层检查结果（`all_nonempty` 字段）
- `3-full-pipeline/results/recall.json` / `recall-record.json` —— /recall 召回验证证据
- `3-full-pipeline/memory-data/` —— 记忆数据：L0 conversations / L1 records / L2 scene_blocks / L3 persona.md

构建失败的常见原因：

| 现象 | 原因 | 处理 |
|---|---|---|
| `429` / `RPC failed` | GitHub 对出口 IP 限流 | 更换 Clash 节点，或使用 `host.docker.internal:7890` 代理 |
| `Could not connect` / 超时 | 代理地址错误或 Clash 未启动 | 核对代理配置，或输入 `NONE` 直连 |
| 基础镜像拉取超时 | docker.io 连接不通 | 预先执行 `docker pull node:26-bookworm-slim` |

各子目录的 README 附有实测结果与截图：进阶 1 见 `2-memory-l0l3/`（L0-L3 四层截图 + /recall 召回），进阶 2 见 `3-full-pipeline/`（soak 判定、四层检查、召回证据与运行截图）。

根目录原先平铺的第二周版 `Dockerfile`、`build.sh` 等旧文件已清理，对应内容归入子目录。

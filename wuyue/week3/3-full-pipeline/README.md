# 3-full-pipeline —— 一键流水线：build → 拉起 → soak → L0-L3 证据（进阶 2）

## 一句话

输入一个 Hermes 版本号 → 自动完成
**docker build（第二周 Dockerfile）→ docker run 拉起 → 记忆插件配置 → 跑事实剧本 soak → 验证 L0-L3 → 输出结果**。

```
输入: HERMES_VERSION + MODEL_API_KEY
  │
  ▼ pipeline.sh
[1/6] build    docker build --build-arg HERMES_VERSION=vX -t hermes-memory:hw-vX .（docker/Dockerfile = 第二周交付物）
[2/6] run      docker run 后台常驻（干净卷，Gateway :8420，等待 health）
[3/6] 插件调参  tdai-gateway.json 加速阈值（L1/L2/L3 尽快触发）→ restart
[4/6] 装载     soak.js + scenario-facts.txt + verify-l0l3.py
[5/6] soak     47 轮事实剧本自动对话 → soak/meta.json（pass/fail）
[6/6] 验证     等待管线沉降 → verify-l0l3.py → evidence.json/txt（L0-L3 + /recall）
  │
  ▼ 输出: results/<时间戳>/{soak/, evidence.json, evidence.txt, summary.txt}
```

## 文件

| 文件 | 来源 |
|---|---|
| `pipeline.sh` | 一键流水线（本目录） |
| `docker/Dockerfile` | **第二周交付物副本**（HERMES_VERSION 参数化 + 记忆插件 + Gateway） |
| `soak.js` | 第三周基础交付物（自动从 `../1-basic-soak/soak.js` 引用） |
| `scenario-facts.txt` / `verify-l0l3.py` | 进阶 1 交付物（从 `../2-memory-l0l3/` 引用） |
| `results/` | 实测输出 |

> soak 与剧本直接引用 1/2 目录（单一事实源）；若目录结构被拆散，
> 用 `--soak-dir` 指向任一包含 `soak.js` 的目录即可。

## 用法

```bash
# 真实 Key 只经环境变量进入，脚本不打印、不落盘
export MODEL_API_KEY="sk-..."
export MODEL_BASE_URL="https://api.deepseek.com/v1"   # 任意 OpenAI 兼容端点
export MODEL_NAME="deepseek-chat"

# 一键全流程（默认版本 v2026.8.31，47 轮 ≈ 20 分钟 + build 时间）
./pipeline.sh --version v2026.8.31

# 常用选项
./pipeline.sh --version v2026.8.27 --rounds 30 --interval-ms 6000 --duration-sec 900
./pipeline.sh --skip-build        # 镜像已存在时跳过 build
./pipeline.sh --name my-pipe      # 自定义容器名（默认 hermes-pipe）
./pipeline.sh --plugin-version 0.3.6               # 指定记忆插件版本（默认 latest）
./pipeline.sh --log-dir /opt/data/logs/tdai-custom # 自定义 Gateway 日志目录
```

参数：`--version / --rounds / --interval-ms / --duration-sec / --image / --name / --skip-build / --soak-dir / --plugin-version / --log-dir`。

## 记忆插件版本参数化（build 时可指定版本）

- build 参数 `--plugin-version`（默认 `latest`，等价于旧行为的 `@latest`）→ 透传给 Dockerfile 的 `ARG MEMORY_PLUGIN_VERSION`；
- 构建期版本校验：安装后读取网关包 `package.json` 的 `version`，**非 latest 请求必须精确匹配**，不一致直接构建失败；
- 版本不存在（如 `9.9.9`）：识别 npm 的 `ETARGET / No matching version found` 后**立即失败**，不会静默装成别的版本，也不做无谓重试；
- 运行时可查证：
  ```bash
  docker exec <容器> cat /opt/memory-tencentdb.version    # 实际安装版本
  docker inspect -f '{{ index .Config.Labels "memory_plugin.version" }}' <镜像>   # 请求的版本
  ```

## Gateway 日志落盘（日常 / 错误分文件）

Gateway（tdai-memory sidecar）的 stdout/stderr 重定向到两个文件，目录由
`MEMORY_TENCENTDB_LOG_DIR` 控制（默认 `/opt/data/logs/tdai`，在持久化卷内）：

| 文件 | 内容 |
|---|---|
| `gateway.stdout.log` | 日常日志（DEBUG/INFO，`[tdai-gateway] [memory-tdai]` 前缀） |
| `gateway.stderr.log` | 错误日志（异常/崩溃信息） |

```bash
# 查看（容器名按实际替换）
docker exec <容器> ls -la /opt/data/logs/tdai
docker exec <容器> tail -f /opt/data/logs/tdai/gateway.stdout.log
docker exec <容器> tail -f /opt/data/logs/tdai/gateway.stderr.log
```

> 注意：Gateway 输出改为落文件后，`docker logs` 不再包含 Gateway 运行日志（仅剩启动横幅几行）；
> 日志属于容器运行时产物，随卷持久化，不落 `results/` 目录。

## 输出与判定

```
results/<时间戳>/
├── summary.txt        # 一行结论：soak verdict + L0-L3 verdict → 整体 PASS/FAIL
├── soak/              # soak 全量输出（conversations.jsonl / probes.json / resources.jsonl / meta.json / report.txt）
├── evidence.json      # 四层 + recall 结构化验证
└── evidence.txt       # 可截图的人类可读证据
```

整体 PASS 判定：`soak meta.verdict == pass` 且 `evidence.verdict == pass`。
失败时容器保留（不自动删除）便于排查，`docker logs` / 目录内文件定位问题。

## 实测记录（本机 2026-09-06）

本机网络受限（GitHub git 协议被限），demo 用 `--skip-build` 复用第二周已验证镜像
（`hermes-memory:local-v2026.8.31`，即同版本参数构建产物），**其余步骤
（run → 插件配置 → soak → 验证）完整一键执行**。8 轮 soak 结果：

```
Hermes 一键流水线结果 (20260906-192514)  version=v2026.8.31
  soak    : verdict=pass  (8/8 pass)  详见 soak/meta.json
  L0-L3   : verdict=pass  详见 evidence.json / evidence.txt
  整体    : PASS
```

见 `results/20260906-192514/`（含 soak 的 conversations.jsonl/probes.json/meta.json、evidence.json/txt/png）。
soak 回复可看到记忆注入（"记住了，小巫。早上那杯黑咖啡是你的开工仪式…"）。
完整 47 轮跑法：`./pipeline.sh --version v2026.8.31`（默认 rounds=47），
任何正常网络下去掉 `--skip-build` 即为全自动 build→soak 闭环。

## 需求增强验证记录（2026-09-14 实测）

| 构建 | 参数 | 结果 |
|---|---|---|
| 默认 | 不传插件版本 | ✅ `installed: 1.0.2`;LABEL `memory_plugin.version=latest`;容器 health ok;`/opt/data/logs/tdai/` 两文件落盘（stdout 36 行 DEBUG/INFO,stderr 收录 WARN 类）;`-e MEMORY_TENCENTDB_LOG_DIR=/opt/data/logs/tdai-custom` 覆盖生效 |
| 指定版本 | `--plugin-version 0.3.6` | ✅ `installed: 0.3.6`;LABEL=0.3.6;0.3.6 网关也能正常启动（health ok）且日志正常落盘 |
| 不存在版本 | `--plugin-version 9.9.9` | ✅ **8 秒快速失败**：`ERROR: memory-tencentdb 版本 9.9.9 在 npm 上不存在`（exit 1,不重试） |
| 回归 | 3 轮 soak（默认镜像） | ✅ 3/3 pass;L0 捕获正常（conversations jsonl）;gateway.stdout.log 持续增长（434 行） |

复现命令：

```bash
docker build --build-arg HERMES_VERSION=v2026.8.31 --build-arg MEMORY_PLUGIN_VERSION=0.3.6 \
  -t hermes-memory:test-036 -f docker/Dockerfile docker
docker run -d --name t -e MODEL_API_KEY=dummy -e MEMORY_TENCENTDB_LOG_DIR=/opt/data/logs/tdai \
  -v t_data:/opt/data hermes-memory:test-036
docker exec t ls /opt/data/logs/tdai/           # gateway.stdout.log  gateway.stderr.log
docker exec t cat /opt/memory-tencentdb.version # 0.3.6
```

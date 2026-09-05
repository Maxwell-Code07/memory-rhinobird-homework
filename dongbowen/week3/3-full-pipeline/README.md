# 3-full-pipeline · 进阶2：一键流水线（Dockerfile + soak）

> 腾讯犀牛目人才培养计划 · 第三周作业 · 进阶2（选交）

把第二周的 Dockerfile 和本周的事实剧本串成一条流水线：

```
docker build (week2/Dockerfile)
        ↓
docker run（后台常驻）
        ↓
容器内：装记忆插件 + 改 config
        ↓
容器内：hermes gateway run（后台）
        ↓
宿主机：node soak-facts.js（通过 -p 把容器 8642/8420 映到宿主机）
        ↓
宿主机：python verify-memory.py 验证 L0/L1/L2/L3
```

---

## 文件清单

| 文件 | 用途 |
|---|---|
| `pipeline.ps1` | PowerShell 编排脚本：build → run → 装插件 → 起 gateway → 跑 soak → 验证 |
| `README.md` | 本文件 |

---

## 一键运行

```powershell
# 默认参数：HERMES_VERSION=0.20.5，ROUNDS=30
cd D:\memory-rhinobird-homework\dongbowen\week3\3-full-pipeline
.\pipeline.ps1
```

指定版本和轮次：

```powershell
.\pipeline.ps1 -HermesVersion 0.20.5 -Rounds 30
```

跳过 build（本地镜像已存在）：

```powershell
.\pipeline.ps1 -SkipBuild
```

跑完保留容器（用于调试）：

```powershell
.\pipeline.ps1 -KeepContainer
```

---

## 输出

流水线产物写到 `week3/pipeline-out/<时间戳>/`：

```
pipeline-out/
  20260904-181500/
    pipeline.log        # 整条流水的运行日志
    soak-out/
      turns.jsonl       # 每轮对话
      meta.json         # pass/fail + P50/P95
      report.txt        # 人类可读汇总
      verify-memory.json  # L0-L3 文件数 + /recall 召回结果
```

---

## 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 全流程 pass（soak 全过 + verify L0-L3 全有） |
| 10/11 | Dockerfile 不存在 / docker build 失败 |
| 20 | docker run 失败 |
| 40 | 容器内 gateway 60 秒内没起来 |
| 50 | soak-facts.js 跑完但 fail |
| 51 | verify-memory.py 跑完但 L0-L3 有层缺失 |

---

## 关键设计点

### 5 步串行 + 失败立即退出

每一步都做健康检查，发现问题立刻 exit 对应错误码。CI/老师复现时按退出码能知道是哪一步挂了。

### 端口映射

宿主机和容器都用 8642（API Server）和 8420（memory gateway），避免端口漂移。脚本参数 `-GatewayPort` / `-MemoryPort` 让你换成别的端口也行。

### 复用第二周 Dockerfile

不重写 Dockerfile，直接 `docker build -f ../week2/Dockerfile` 复用。

### 记忆插件安装容错

容器里优先用本地 .whl；找不到就 fallback 到 git+pip 拉源码。两步都失败也不立即退出，让 step 4 启动 gateway 的健康检查来兜底（gateway 没装好会显式退出 40）。

---

## 验收现场操作清单（进阶2）

1. **确认第二周交付物**：`../week2/Dockerfile` 存在且可 build
3. **运行流水线**：`.\pipeline.ps1 -HermesVersion 0.20.5 -Rounds 30`
4. **截图 5 张**：
   - pipeline 启动日志（`pipeline.log` 前 30 行）
   - docker images 看到 `hermes-week3:0.20.5`
   - docker ps 看到 hermes-week3-runner 在跑
   - soak-out/meta.json（pass=30 fail=0）
   - soak-out/verify-memory.json（overall=pass）
5. **关掉流水线**（不写 -KeepContainer 的话会自动清理）

---

## 调试技巧

- **docker build 阶段超时** → 你的宿主机 git/uv/Docker 网络问题（参考第二周 README 的镜像配置段）
- **gateway 起不来** → 跑 `docker exec hermes-week3-runner tail /tmp/gateway.log`，通常是 API_SERVER_KEY 太短
- **soak 全 fail 但 curl /health 通** → 大概率是 API Key 不一致：脚本里 `soak-test-key-2026-dongbowen-dbrh` 必须和 .env 里 `API_SERVER_KEY` 完全相同

---

## 已知坑（已写入 pipeline.ps1）

踩过三个 root cause，整合进去了，下次跑直接通：

### 坑1 · 容器内 venv 没 aiohttp

hermes CLI 用 `/opt/hermes-agent/.venv/bin/python`（独立 venv）。系统 `pip install aiohttp` 装到 `/usr/local/lib/python3.11/site-packages/`，venv 里 `import aiohttp` 找不到 → gateway WARNING `API Server: aiohttp not installed` → api_server adapter 起不来。

**修复**（已自动写入 pipeline.ps1 Step 3）：
```bash
docker exec $NAME /opt/hermes-agent/.venv/bin/python -m ensurepip --upgrade --default-pip
docker exec $NAME /opt/hermes-agent/.venv/bin/python -m pip install aiohttp
```

### 坑2 · gateway 默认 bind 127.0.0.1，docker 端口映射转不出来

容器内 hermes 默认 `API_SERVER_HOST=127.0.0.1`，这个 127.0.0.1 是容器 namespace 的回环，宿主机的 `-p 8642:8642` 转不到。`curl 127.0.0.1:8642` 在宿主机一直 Connection refused，但容器内 `ss -tlnp` 看着在 listen。

**修复**（已自动写入 Step 4）：
```bash
docker exec -d $NAME bash -c 'export API_SERVER_HOST=0.0.0.0; nohup hermes gateway run &'
```

副作用警告（忽略即可）：
```
API server is network-accessible (0.0.0.0) AND the terminal backend is 'local' (unsandboxed).
```

### 坑3 · stale gateway.pid 锁

前一次 gateway 没干净退出时，`/root/.hermes/gateway.pid` / `.lock` 会留下，新的 gateway 启动会拒绝：`Another gateway instance is already running (PID XX)`。

**修复**（已自动写入 Step 4）：启动前 `rm -f /root/.hermes/gateway.pid /root/.hermes/gateway.lock`。

---

## 验收一次性记忆 gateway

pipeline 默认假设 **8420 (memory gateway)** 在宿主机上独立跑着（与 hermes 解耦）。如果没起来，`python verify-memory.py` 报 `/recall 不可达 → overall: fail`。

启动 memory gateway（PowerShell 里手动跑一次，会话结束后进程仍在）：
```powershell
cd D:\memory-rhinobird-homework\dongbowen\week3\3-full-pipeline
.\start-mem-gateway.ps1
```

然后重跑：
```powershell
cd D:\memory-rhinobird-homework\dongbowen\week3\2-memory-l0l3
python verify-memory.py --gateway-url http://127.0.0.1:8420 --out-dir <任意 soak-out 目录>
```

预期输出：
```
--- Layer file counts ---
  L0: 3 个文件, 131630 字节
  L1: 1 个文件, 5929 字节
  L2: 4 个文件, 6950 字节
  L3: 1 个文件, 1669 字节

--- /recall 召回测试 ---
  query='董博文': status=200 hit=True
  query='海南大学': status=200 hit=True
  ...
=== overall: pass ===
```

---

## HTTP_PROXY 干扰（WorkBuddy 环境）

当前 shell `HTTP_PROXY=http://127.0.0.1:54610`（WorkBuddy 内部 MCP 转 proxy），会拦截 8642/8420 端口请求。

- Windows `curl 8.13.0` 上 `--noproxy '*'` 不生效
- Python `urllib` 自动读 `HTTP_PROXY` env

**绕过**：所有命令前加 `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy`

或者脚本里显式传：
```python
import os
for k in ['HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy']: os.environ.pop(k, None)
```

---

## 与 week2 的关系

- 复用：`week2/Dockerfile`（第二周交付物）
- 复用：`week2/hermes-agent-0.20.5.tar.gz`（如未删）
- 新增：本周的 `soak-facts.js` + `verify-memory.py` + 编排脚本 `pipeline.ps1`

---

## 与基础、进阶1 的关系

| 阶段 | 复用 1-basic-soak | 复用 2-memory-l0l3 |
|---|---|---|
| 进阶2 | soak.js（被 soak-facts 替代） | **全部**（soak-facts.js + verify-memory.py） |

进阶2 就是把进阶1的两个脚本塞进 Docker 容器里，让整条流程自动跑——所以本质上**不写新逻辑**，只写编排。
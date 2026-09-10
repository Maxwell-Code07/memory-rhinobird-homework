# week3 · Hermes Agent 第三周交付物

> 腾讯犀牛目人才培养计划 · 第三周作业（截止下周四 17:00）

---

## 总览

本周交付分三档，目录严格按对齐内容里规定的命名：

| 目录 | 对应要求 | 是否必交 |
|---|---|---|
| `1-basic-soak/` | 基础：soak 自动对话脚本 | ✅ 必交 |
| `2-memory-l0l3/` | 进阶1：记忆 L0-L3 落库 + 截图 | ✅ 必交 |
| `3-full-pipeline/` | 进阶2：Dockerfile + soak 一键流水线 | 选交 |

第二周交付物 `../week2/`（Dockerfile 等）也保留在本仓库下，进阶2 流水线会复用。

---

## 三档之间的关系

```
1-basic-soak          2-memory-l0l3           3-full-pipeline
   (必交)               (必交)                  (选交)
     │                     │                        │
   可配置对话             │                        │
   JSON + 容错             │                        │
   跑通 → 和 →          把 soak-facts + facts.txt + verify-memory.py
                     ────────────────────────────►  塞进 Docker 容器
                                                  pipeline.ps1 一键串起
```

---

## 快速开始（基础层）

前置：Hermes v0.20.5、`hermes gateway run` 起着（8642 端口）、`API_SERVER_KEY` 长度 ≥ 16。

```bash
cd 1-basic-soak
node soak.js --rounds 30 --interval 1000
```

产物：`soak-out/<ts>/` 下的 turns.jsonl / meta.json / report.txt。

验收：脚本能跑通 + 三个参数都生效 + pass/fail 区分明确 + 至少一种容错可演示。

---

## 快速开始（进阶1）

复用基础层的前置，外加：`memory.provider=memory_tencentdb`、`MEMORY_TENCENTDB_GATEWAY_*` 已配。

```bash
cd 2-memory-l0l3
node soak-facts.js --rounds 30 --interval 1000
python verify-memory.py
```

验收：L0/L1/L2/L3 四层文件都非空 + 至少一个关键词 /recall 命中。

---

## 快速开始（进阶2）

复用第二周 Dockerfile + 进阶1 的两个脚本。

```powershell
cd 3-full-pipeline
.\pipeline.ps1 -HermesVersion 0.20.5 -Rounds 30
```

验收：整条流水线 exit=0；产物 `pipeline-out/<ts>/pipeline.log` + `soak-out/*` + `verify-memory.json`。

---

## 目录结构

```
week3/
├── README.md                  ← 本文件
├── 1-basic-soak/
│   ├── soak.js                ← 自动对话脚本（零依赖 Node.js）
│   └── README.md
├── 2-memory-l0l3/
│   ├── soak-facts.js          ← 含事实剧本的 soak
│   ├── facts.txt              ← 30 条事实剧本（可编辑）
│   ├── verify-memory.py       ← L0-L3 验证 + /recall 召回
│   └── README.md
└── 3-full-pipeline/
    ├── pipeline.ps1           ← 一键流水线
    └── README.md
```

---

## 与前两周的关系

- **week1**（第一周）：Hermes 装好 + 记忆插件挂载 + 5 张截图。本周所有脚本都跑在 week1 装好的环境上。
- **week2**（第二周）：Dockerfile 一键构建干净 Hermes 镜像。本周进阶2 流水线 `docker build` 时复用 `../week2/Dockerfile`。
- **week3**（本周）：自动对话 + 记忆验证 + 流水线。

---

## 不在本周范围内的事

- Hermes 本身的安装、配置：`../week1/`
- Dockerfile 编写：`../week2/`
- 评分/验收：老师在 GitHub PR 上看

---

## 已知限制 / 调试入口

- `API_SERVER_KEY` 长度必须 ≥ 16（Hermes 强制要求，否则启动拒绝）
- 默认 base URL 是 `http://127.0.0.1:8642/v1`；如果本地端口漂移，用 `--base-url` 覆盖
- `verify-memory.py` 在 4 个候选路径上尝试 `/recall`，全部不通时不报错而是返回 status=0，便于排查端点路径
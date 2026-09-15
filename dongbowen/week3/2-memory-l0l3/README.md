# 2-memory-l0l3 · 进阶1：让 Hermes 记忆系统的 L0/L1/L2/L3 真正生成

> 腾讯犀牛目人才培养计划 · 第三周作业 · 进阶1（必交）

基础层只测"能不能对话"，这一层测的是"对话能不能变成记忆"。

`1-basic-soak/soak.js` 跑纯寒暄时，对话能正常进行但 L1/L2/L3 是空的，因为记忆抽取器没东西可抽。本目录把 prompt 池换成"富含可提取事实"的内容（姓名/职业/学校/爱好/偏好/习惯/强约束），让记忆系统的四层都有数据可写。

---

## 文件清单

| 文件 | 用途 |
|---|---|
| `soak-facts.js` | 同 1-basic-soak/soak.js 的结构，但内置 30 条事实剧本 |
| `facts.txt` | 同样 30 条事实剧本（每行一条），可用 `--prompt-file` 加载 |
| `verify-memory.py` | 扫记忆目录的 L0/L1/L2/L3 四层文件 + 调 /recall 召回 |
| `README.md` | 本文件 |

---

## 一、跑事实剧本（让 Hermes 产生可被抽取的输入）

```bash
# 内置 30 条事实剧本
node soak-facts.js --rounds 30 --interval 1000

# 从 facts.txt 加载（同样 30 条，便于编辑扩展）
node soak-facts.js --rounds 30 --interval 1000 --prompt-file facts.txt

# 演示容错
node soak-facts.js --rounds 5 --bad-key
```

跑完会输出到 `soak-out/<时间戳>/`：`turns.jsonl`、`meta.json`、`report.txt`。如果 gateway 没启或 Key 错，fail 全部进 JSON 但脚本不崩。

---

## 二、验证 L0-L3 是否真生成

事实剧本跑完后立刻跑：

```bash
# 用默认 gateway URL
python verify-memory.py

# 指定 soak-out 目录（验证结果会写到 verify-memory.json）
python verify-memory.py --out-dir ../soak-out/<时间戳>
```

输出示例：

```
=== Hermes Memory Verification (L0/L1/L2/L3) ===
gateway : http://127.0.0.1:8420
memory-root: C:\Users\35348\.hermes\memories

--- Layer file counts ---
  L0: 12 个文件, 4218 字节
  L1: 8 个文件, 3120 字节
  L2: 4 个文件, 1820 字节
  L3: 1 个文件, 510 字节

--- /recall 召回测试 ---
  query='董博文': status=200 hit=True
  query='海南大学': status=200 hit=True
  ...

=== overall: pass ===
```

判定条件（任一不满足即 fail）：
- L0 / L1 / L2 / L3 文件数都 > 0
- 至少一个关键词的 /recall 状态=200 + body 包含该关键词

---

## 三、验收需要截图的内容（5 张必拍）

| 截图 | 内容 |
|---|---|
| L0 层 | 终端里 `ls <memory-root>/<user>/<session>/l0/` 看到 .json 文件 |
| L1 层 | 同上，l1/ 目录 |
| L2 层 | 同上，l2/ 目录（含 scene 块） |
| L3 层 | `cat <memory-root>/<user>/<session>/l3/persona.md` 输出 |
| 召回 | `curl -d '{"query":"董博文是哪里人"}' http://127.0.0.1:8420/recall` 返回命中 |

**五张拼一起**就能证明"记忆真的生成且可用"。

---

## 验收现场操作清单（进阶1）

1. **关掉旧 gateway**，重新 `hermes gateway run`（确认 platforms.api_server.enabled=true）
2. **跑事实剧本**：`node soak-facts.js --rounds 30 --interval 1000`（约 30 秒跑完）
3. **跑验证脚本**：`python verify-memory.py`，确认四层非空 + 召回成功
4. **截图 5 张**：L0/L1/L2/L3 四个目录 + /recall 输出
5. **整理**：把这些放进 `2-memory-l0l3/pictures/`，README 里贴出 verify-memory.json 摘要

---

## 与基础层的差异（为什么是"进阶1"）

| 维度 | 1-basic-soak | 2-memory-l0l3 |
|---|---|---|
| prompt 来源 | 20 条日常话题（"你好/天气"等） | 30 条含事实（姓名/职业/爱好/习惯） |
| 测的是 | 对话能力 + 稳定性 | 记忆抽取 + 多层落库 |
| 验收点 | pass率 + P50/P95 + 容错 | L0-L3 文件非空 + /recall 命中 |
| 跑的轮数 | 通常 30 轮 | 建议 ≥ 30 轮，让记忆系统有时间抽取 |

---

## 调试技巧

如果四层中有任意一层为空，最常见的原因：
1. **`memory_tencentdb` 插件没被启用** → `cat config.yaml` 看 `memory.provider` 是否为 `memory_tencentdb`
2. **`MEMORY_TENCENTDB_GATEWAY_HOST/PORT` 配错** → `cat .env` 确认 host/port
3. **memory gateway 没启**（这是另一回事）→ 应该已经在 `hermes gateway run` 里随主 gateway 一起跑了

遇到 `no /recall endpoint reachable` 时：先 curl `127.0.0.1:8420/health`，确认 8420 上有响应，再核对 verify-memory.py 里的候选路径。
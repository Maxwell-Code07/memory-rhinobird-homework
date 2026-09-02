# Week3 进阶 1：装好记忆插件的 Hermes 上，让 L0-L3 真正生成（2-memory-l0l3）

**目标**：在一个**已经装好记忆插件的 Hermes** 上，用 soak 脚本驱动多轮对话，让记忆系统的 **L0-L3 四层**都真正落库，截图证明。

> 基础要求测「能不能对话」，进阶要求测「对话能不能变成记忆」。

## 文件

| 文件 | 说明 |
|---|---|
| `conversation-facts.txt` | 富含可提取事实的对话剧本（身份/偏好/经历/约束 + 召回验证轮） |
| `verify-l0l3.sh` | 四合一验证脚本：Gateway /health、数据目录、L3 persona、/recall 召回 |

## 剧本设计：每句话沉淀什么

纯闲聊（"你好""今天天气不错"）什么记忆都不会沉淀，L1/L2/L3 是空的。所以进阶 1 的剧本换成**富含可提取事实**的内容：

| 剧本内容 | 预期沉淀层 |
|---|---|
| 我叫谢曾烨、计算机专业、做 AI Agent 项目 | L1 事实 → L3 画像 |
| 研究方向：智能体记忆系统、毕业设计方向 | L1 事实 |
| 最喜欢的语言 Python；只喝拿铁 | L1 偏好 |
| 对花生严重过敏 | L1 偏好/约束 |
| 养了猫叫布丁、三岁橘猫 | L1 经历 |
| 家乡福建厦门、爱吃沙茶面 | L1 经历 → L3 画像 |
| 作息 23 点睡 7 点起 | L1 习惯 |
| 参加腾讯开源项目、每周四交作业、周末爬山 | L2 场景块 |
| 最后三轮：问名字/问家乡过敏/总结画像 | 触发 `/recall` 召回，验证记忆可用 |

## 怎么跑（推荐：直接用进阶 2 的一键流水线）

进阶 1 的环境准备（build + 装插件 + 起 Gateway）和进阶 2 的流水线是同一套动作，直接：

```bash
cd ../3-full-pipeline

MODEL_API_KEY=sk-xxxx \
MODEL_BASE_URL=https://api.lkeap.cloud.tencent.com/v1 \
MODEL_NAME=deepseek-v3.2 \
bash run-pipeline.sh
```

流水线跑完会自动执行本目录的 `verify-l0l3.sh` 做四合一验证。

## 手动步骤（理解原理用）

```bash
# 前置：跑过一次 run-pipeline.sh（容器 hermes-week3-pipeline 已装好插件并起好 Gateway），
# 或按 week1 的方式在虚拟机本地装好插件。

# 1. 跑富含事实的 soak
docker exec hermes-week3-pipeline node /opt/soak/soak.mjs \
  --hermes hermes --conversation /opt/soak/conversation-facts.txt \
  --rounds 15 --interval 5 --out-dir /opt/soak/out-facts

# 2. 等 1-2 分钟（L1/L2/L3 是异步抽取沉淀的）

# 3. 四合一验证（本目录脚本已在容器 /opt/soak/ 下）
docker exec hermes-week3-pipeline bash /opt/soak/verify-l0l3.sh
```

`verify-l0l3.sh` 也可以在任何装好插件的本地环境直接 `bash verify-l0l3.sh` 运行（默认数据目录 `~/.memory-tencentdb/memory-tdai`，可用 `TDAI_DATA_DIR` 覆盖）。

## 四张截图（验收要求）

`verify-l0l3.sh` 一次跑完四个检查点，逐个截图：

| 截图 | 内容 | 证明 |
|---|---|---|
| ① | `curl http://127.0.0.1:8420/health` 返回 ok | Gateway（大脑）活着 |
| ② | 数据目录文件清单非空（L0 对话存储、L1 抽取、L2 scene 块） | L0/L1/L2 有记录 |
| ③ | L3 persona.md 文件有内容（画像预览） | L3 已合成 |
| ④ | `/recall` 用「我叫什么名字？我养了什么宠物？」召回出剧本里的事实 | 记忆可召回可用 |

四张图合在一起，才能证明「记忆真的生成且可用」。

## 注意事项

1. **L1/L2/L3 是异步沉淀的**：soak 跑完立刻查可能 L2/L3 还是空的，等 1-2 分钟再跑 `verify-l0l3.sh`（脚本里也会提示）；
2. **记忆抽取需要第二个 LLM**：Gateway 用 `TDAI_LLM_*` 环境变量做 L1/L2/L3 抽取，`run-pipeline.sh` 默认复用对话模型（`MODEL_*`），也可以单独指定更便宜的模型；
3. **数据目录**：默认 `~/.memory-tencentdb/memory-tdai`，流水线里用 `TDAI_DATA_DIR=/root/memory-tdai` 显式固定，方便截图和 docker cp；
4. **Provider 目录名必须是 `memory_tencentdb`**（下划线），且 `config.yaml` 里 `memory.provider: memory_tencentdb`——名字错了 Hermes 扫不到插件，对话正常但什么记忆都不会沉淀；
5. 如果 soak 全部通过但数据目录是空的：先看 Gateway 日志（`docker exec hermes-week3-pipeline tail -50 /tmp/gateway.log`）里有没有 capture 记录，再确认 `config.yaml` 的 memory 段没写漏。

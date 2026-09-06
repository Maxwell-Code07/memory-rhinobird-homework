# 2-memory-l0l3 —— 记忆插件下跑出 L0-L3（进阶 1）

## 目标

在**第二周 Dockerfile 构建的 Hermes 镜像**（已装 memory_tencentdb 插件）上，
用 soak 脚本驱动**富含事实的多轮对话**，让记忆系统 L0→L1→L2→L3 四层真正生成，
并给出可截图证据。

> 关键认知（第三次会议纪要也强调）：纯闲聊不会沉淀记忆。
> 本目录的剧本 `scenario-facts.txt` 让"用户"（虚构人设"小巫"，后端工程师）逐轮
> 说出姓名、职业、团队、技术栈、偏好、习惯、经历等可提取事实——L1 提取、L2 场景、
> L3 画像才有原料。

## 文件

| 文件 | 作用 |
|---|---|
| `scenario-facts.txt` | 事实剧本，47 条富含事实的消息（姓名/职业/技术栈/喜好/经历/规划…） |
| `verify-l0l3.py` | 四层验证脚本：L0/L1/L2/L3 目录非空 + `/recall` 召回（输出 evidence.json/txt） |
| `soak.js` | 与 1-basic-soak 同源（复用基础交付物，`--message-file` 喂剧本） |
| `evidence/` | **实测证据**（soak 输出 + evidence.json/txt，2026-09-06 实测） |

## 怎么跑（复现命令）

```bash
# 1) 用第二周 Dockerfile 起干净容器（版本自选）
docker run -d --name hermes-mem \
  -e MODEL_API_KEY="your-key" -e MODEL_BASE_URL="https://api.deepseek.com/v1" \
  -e MODEL_NAME="deepseek-chat" -e MODEL_PROVIDER=custom \
  -v hermes_mem_data:/opt/data hermes-memory:v2026.8.31

# 2) 记忆管线调参（可选但强烈建议）：soak 时间有限，把 L1/L2/L3 触发阈值调小
#    ⚠️ Gateway 的配置文件从自身 CWD 读取（镜像 WORKDIR=/opt/tdai-gateway），
#    不是数据目录！写入 /opt/tdai-gateway/tdai-gateway.json 后 docker restart：
docker exec -i hermes-mem sh -c 'cat > /opt/tdai-gateway/tdai-gateway.json' <<'EOF'
{
  "memory": {
    "pipeline": { "everyNConversations": 1, "l1IdleTimeoutSeconds": 15,
                  "l2DelayAfterL1Seconds": 10, "l2MinIntervalSeconds": 60,
                  "l2MaxIntervalSeconds": 240 },
    "persona": { "triggerEveryN": 6 },
    "extraction": { "maxMemoriesPerSession": 50 },
    "recall": { "strategy": "keyword" }
  }
}
EOF
docker restart hermes-mem

# 3) 跑事实剧本 soak（47 轮 ≈ 12-15 分钟）
docker cp soak.js scenario-facts.txt hermes-mem:/root/
docker exec -w /root hermes-mem node soak.js \
  --rounds 47 --interval-ms 5000 \
  --message-file /root/scenario-facts.txt --out /root/soak-out

# 4) 等管线沉降 2 分钟，然后验证四层
docker cp verify-l0l3.py hermes-mem:/root/
docker exec hermes-mem python3 /root/verify-l0l3.py --out /root/evidence
#   输出 evidence.txt / evidence.json；终端打印即可截图
```

## 截图证明的四个要点（会议纪要要求）

1. **L0 有记录** → `conversations/*.jsonl` 非空（原始对话落库）；
2. **L1 有提取** → `records/` 有事实记忆文件；
3. **L2 有 scene 块** → `scene_blocks/*.md` 非空；
4. **L3 persona.md 有内容** → `persona.md` 含用户画像（姓名/职业/偏好锚点）；
5. **/recall 能召回** → 用关键词 POST 召回命中。

`verify-l0l3.py` 一次性输出这五项的 pass/fail + 内容样例——见本目录 `evidence/`（实测）。

## 实测结果（本机 2026-09-06，deepseek-chat，镜像 local-v2026.8.31，新版 soak 47 轮）

`verify-l0l3.py` 判定 **PASS**（`evidence/evidence.json`），五项全过：

| 层 | 判定 | 实测数据 |
|---|---|---|
| L0 | PASS | `conversations/2026-09-06.jsonl`，对话记录 **87 行**（47 轮） |
| L1 | PASS | `records/2026-09-06.jsonl` 事实记忆，样例："用户（小巫）是一名后端开发工程师，主要使用 Go 语言编写服务端程序，在深圳工作。" |
| L2 | PASS | `scene_blocks/` **2 个场景块**（heat 最高 19，跨会话叙事持续累积） |
| L3 | PASS | `persona.md` **65 行**，5 个锚点全命中（小巫/后端/Go/咖啡/羽毛球），Archetype："双子座、湖南长沙出身、深圳自立门户的高并发支付 Go 团队负责人兼导师…" |
| recall | PASS | `/recall` keyword 策略命中 **5 条**记忆，context 注入 3868 字（persona + 记忆片段） |

soak 本身：**47/47 pass（100%）**，p50 ≈ 12.3s，`evidence/soak/meta.json`。
配套证据：`evidence/evidence.txt`（可截图）、`evidence/evidence.png`（渲染图）。

> 对话中可观察到记忆真的在起作用：Hermes 会引用前几轮的事实（"你之前说打球是
> 周四晚上和周日早上…现在周六早上还有固定羽毛球课"），并记住口头禅"问题不大"。

# Hermes + TencentDB-Agent-Memory 第一周验收证据

## 任务 2：证明记忆插件已加载并调用 Gateway

```text
2026-08-25T08:37:17.588+00:00 DEBUG [tdai-gateway] [memory-tdai] [pipeline] Initialized: everyNConversations=1, warmup=disabled, l1IdleTimeout=5s, l2DelayAfterL1=1s
2026-08-25T08:37:18.900+00:00 DEBUG [tdai-gateway] [memory-tdai] [pipeline-v2] Initialized: defaultInstance=default, everyN=1, warmup=false, l1Idle=5s
[observability][console][middleware] REQUEST_START POST /capture
2026-08-25T09:19:53.229+00:00 DEBUG [tdai-gateway] [memory-tdai][l0] Extracted 2 user/assistant messages from 2 total
2026-08-25T09:19:53.231+00:00 DEBUG [tdai-gateway] [memory-tdai] [capture] L0 recorded: 2 messages for session 20260825_091951_726af6
2026-08-25T09:19:53.241+00:00 DEBUG [tdai-gateway] [memory-tdai] [pipeline-v2] [20260825_091951_726af6] Threshold reached (1), L1 task enqueued
2026-08-25T09:19:53.242+00:00 INFO  [tdai-gateway] [memory-tdai] [capture] Capture timing: total=16ms, msgs=2
2026-08-25T09:19:53.242+00:00 INFO  [tdai-gateway] Capture completed in 16ms: l0=2
[observability][console][middleware] REQUEST_END POST /capture status=200 duration=17ms
```

说明：日志中的 `memory-tdai`、`capture`、`L0 recorded` 以及 `/capture status=200` 表明 `memory_tencentdb` 插件已加载，并成功调用记忆 Gateway。

## 任务 3：证明 L0–L3 记忆已生成并落库

```text
2026-08-25T09:19:53.244+00:00 INFO  [tdai-gateway] [memory-tdai] [pipeline-factory] [l1] Processing 2 L0 messages
2026-08-25T09:19:53.244+00:00 DEBUG [tdai-gateway] [memory-tdai] [standalone-runner] run() start: taskId=l1-extraction, model=deepseek-chat
2026-08-25T09:19:55.123+00:00 DEBUG [tdai-gateway] [memory-tdai][l1-writer] Stored memory m_1787649595112_bb86552f: 用户是大连理工大学的学生。
2026-08-25T09:19:55.126+00:00 INFO  [tdai-gateway] [memory-tdai][l1-extractor] Extraction complete: extracted=1, stored=1
2026-08-25T09:19:55.128+00:00 INFO  [tdai-gateway] [memory-tdai] [pipeline-factory] [l1] L1 complete: extracted=1, stored=1

2026-08-25T09:19:56.141+00:00 DEBUG [tdai-gateway] [memory-tdai] [standalone-runner] run() start: taskId=scene-extract-1787649596141, model=deepseek-chat
2026-08-25T09:20:01.255+00:00 DEBUG [tdai-gateway] [memory-tdai] [pipeline-factory] [L2] Extraction complete: processed=1
2026-08-25T09:20:01.257+00:00 DEBUG [tdai-gateway] [memory-tdai] [trigger] Evaluating: total_processed=4, memories_since=1, scenes=1
2026-08-25T09:20:01.259+00:00 INFO  [tdai-gateway] [memory-tdai] [pipeline-factory] [L3] Starting persona generation
2026-08-25T09:20:04.591+00:00 DEBUG [tdai-gateway] [storage][local] putObject: persona.md
2026-08-25T09:20:06.394+00:00 INFO  [tdai-gateway] [memory-tdai] [persona] Persona written
2026-08-25T09:20:06.397+00:00 INFO  [tdai-gateway] [memory-tdai] [pipeline-factory] [L3] Persona generation succeeded
```

说明：

- `L0 recorded`：原始对话已捕获；
- `L1 complete`：结构化记忆已提取并落库；
- `L2 Extraction complete`：场景记忆已生成；
- `Persona written` 和 `L3 Persona generation succeeded`：用户画像已生成并写入 `persona.md`。

因此，日志证明 L0、L1、L2、L3 四层记忆流水线均已运行成功。

## 截图证据

### Hermes 启动与模型配置

![Hermes 启动与模型配置](https://cdn.jsdelivr.net/gh/wwuhuasheng/memory-rhinobird-homework@main/wuyue/week1/screenshots/hermes-startup.png)

### Hermes 对话记录

![Hermes 对话记录](https://cdn.jsdelivr.net/gh/wwuhuasheng/memory-rhinobird-homework@main/wuyue/week1/screenshots/hermes-memory-conversation.png)

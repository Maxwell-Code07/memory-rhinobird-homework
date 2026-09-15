# /recall 召回验证（进阶 2 一键流水线）

- Gateway: 容器 :8420 映射宿主机 localhost:8420
- 时间: 2026-09-05T15:01:29.750Z
- session_key: 20260905_034450_cf7463（取自本轮 soak 会话 L0 首条记录）

| Query | strategy | memory_count | context 注入 | 证据文件 |
|---|---|---|---|---|
| 我的技术偏好和工作习惯 | hybrid | 0（整块注入） | <user-persona>（L3 画像）+ <scene-navigation>（L2 场景索引），含 SQLite/TencentDB 事实 | `results/recall.json` |
| 用户平时使用 SQLite 做本地存储，偏好本地优先、简单够用的技术方案 | hybrid | **1（命中逐条 L1 记录）** | 同上，含 SQLite 偏好记录 | `results/recall-record.json` |

> 说明：session_key 为 /recall 必填字段；L2/L3 整块注入不计入 memory_count，命中逐条 L1 record 才计数。两次召回的 context 内容与 soak 事实剧本一致（任德霖 / TencentDB / SQLite 本地优先）。

# 第一周作业：Hermes + TencentDB-Agent-Memory

## 目标

在 Windows 原生 Hermes Agent 上接入 TencentDB-Agent-Memory（main 分支源码），完成至少一轮对话，并验证插件加载、Gateway 服务和记忆落库。

## 环境

- Windows
- Node.js `v22.16.0`
- Hermes Agent
- Gateway：`127.0.0.1:8420`
- 代理：`127.0.0.1:7890`（仅用于依赖下载）

## 验收对话

本次对话围绕“家庭植物管家”展开：记录绿萝、薄荷和多肉“小石头”，补充摆放位置、浇水规则、项目技术栈和项目路径；随后离开并回来，要求 Hermes 召回项目和当天需要关注的植物。

关键召回结果：Hermes 正确回忆出项目名“家庭植物管家”、TypeScript 技术栈、项目路径 `C:\Users\33176\Documents\plant-manager`、三盆植物及薄荷优先提醒规则。

## 插件加载证据

Hermes 日志 `C:\Users\33176\AppData\Local\hermes\logs\agent.log` 中出现：

```text
Memory provider 'memory_tencentdb' registered (3 tools)
memory-tencentdb Gateway already running (127.0.0.1:8420)
Memory provider 'memory_tencentdb' activated
```

配置文件 `C:\Users\33176\AppData\Local\hermes\config.yaml`：

```yaml
memory:
  provider: memory_tencentdb
  memory_enabled: true
```

插件入口存在于：

```text
C:\Users\33176\AppData\Local\hermes\hermes-agent\plugins\memory\memory_tencentdb\plugin.yaml
```

## Gateway 验证

请求 `http://127.0.0.1:8420/health` 返回：

```json
{"status":"ok","version":"0.1.0","stores":{"vectorStore":true,"embeddingService":false}}
```

## 记忆落库证据

对话后生成或更新以下文件：

```text
C:\Users\33176\.memory-tencentdb\memory-tdai\vectors.db
C:\Users\33176\.memory-tencentdb\memory-tdai\vectors.db-wal
C:\Users\33176\.memory-tencentdb\memory-tdai\metadata\tdai_metadata_default\metadata.db
C:\Users\33176\.memory-tencentdb\memory-tdai\conversations\2026-08-24.jsonl
C:\Users\33176\.memory-tencentdb\memory-tdai\.metadata\checkpoint.json
```

`conversations/2026-08-24.jsonl` 中包含本次“家庭植物管家”对话原文，SQLite 数据库和 WAL 文件的更新时间与对话时间一致，说明对话已写入记忆系统。

## 说明

当前版本以 JSONL 保存 L0 原始对话，以 SQLite/metadata 保存索引和结构化数据；磁盘上不一定直接出现名为 `L0`、`L1`、`L2`、`L3` 的目录。`embeddingService=false` 表示本次使用本地 BM25/SQLite 检索，不影响基础记忆保存和召回。

# 第一周作业 · 跑通 Hermes + 记忆插件

## 我交的截图就这五张

01-shenfen.png
  └─ 跟 Hermes 自我介绍，问它记不记得我。看记忆真的存进去了没。

02-first-chat.png
  └─ Hermes Agent v0.20.9 启动界面，问"你好介绍一下你自己"，能看到它是用 deepseek-chat 在跑。

03-xuexi-asks.png
  └─ 接着问常识问题，证明对话是连续的、不是卡死。

04-plugin-loaded.png
  └─ 跑 `discover_memory_providers()` 出来的列表，`memory_tencentdb True` 说明插件确实挂上了。

05-memory-folder.png
  └─ 文件管理器打开 `~/.memory-tencentdb/memory-tdai/conversations/`，能看到 `2026-08-26.jsonl` 这个对话存档文件已经生成了。

## 跑通的证据总结

- Hermes 能正常对话 ✅（图1、2、3）
- 腾讯记忆插件 memory_tencentdb 被成功加载 ✅（图4）
- 对话真的落到了本地数据目录 ✅（图5 + 图1里的 JSON 内容）

环境：Windows 11 + Node.js v24.16 + Python 3.10，模型用的 deepseek-chat。
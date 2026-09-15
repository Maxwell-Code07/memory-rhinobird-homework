# L0-L3 验收证据

- `provider-discovery.txt`：Hermes 发现 `memory_tencentdb`，第三项为 `True`。
- `memory-soak-summary.json`：富含事实的真实记忆剧本完成 10/10 轮，失败率为 0。
- `memory-soak-10-rounds.png`：真实十轮记忆对话汇总截图。
- `memory-verification.json`：L0、L1、L2、L3 和 recall 五项全部为 `pass`。
- `l0-l1.png`：L0/L1 非空文件数量与字节数。
- `l2.png`：L2 scene block 非空文件数量与字节数。
- `l3.png`：L3 `persona.md` 非空及字节数。
- `recall-and-provider.png`：recall 命中固定 marker，且 provider 被 Hermes 加载。
- `layer-file-sizes.txt`：容器内四层文件数量与字节数的原始检查输出。
- `test-results.txt`：本阶段 20 项自动测试的本轮输出。

对话剧本使用虚构人物“林澈”，文件不含 API Key。

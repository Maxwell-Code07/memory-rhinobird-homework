# 基础 Soak 验收证据

- `real-soak-summary.json`：真实模型完成 2 轮连续对话，状态为 `pass`，两轮使用同一 session ID。
- `timeout-summary.json`：故意制造单轮超时，程序返回 `fail` 并正常写出结构化结果，证明异常没有导致脚本崩溃。
- `basic-and-timeout.txt`：两项结果的脱敏可读摘要。
- `basic-and-timeout.png`：以上两项结果的本地文件截图。
- `test-results.txt`：基础脚本 11 项自动测试的本轮输出。

原始对话内容与 API Key 不提交。

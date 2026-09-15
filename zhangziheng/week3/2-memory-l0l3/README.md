# 进阶一：Hermes + memory-tencentdb L0-L3

本目录只保存运行期安装材料，不改写第二周 Dockerfile。基础镜像已使用第二周原始 Dockerfile（Hermes 0.20.6）构建；插件源码在容器运行期复制，生产依赖在宿主机按 Linux x64 离线准备后注入容器。

## 已验证

- `memory_tencentdb` 已被 Hermes provider discovery 找到并激活。
- Gateway `GET /health` 返回 200，`vectorStore=true`。
- Hermes 已建立真实 MiniMax session，Gateway 收到真实 recall/flush 请求。
- `fact-prompts.json` 的 8 轮提示词均为第一人称、正常交流表达。

## 验收截图

进阶一的 Docker 构建、插件安装、真实事实对话、L0-L3 生成和 recall 截图统一收录在上级 `pictures/进阶一/` 目录：

![基于第二周 Dockerfile 构建 Hermes](<../pictures/进阶一/基于dockerfile构建Hermes.png>)

![安装 memory_tencentdb provider](<../pictures/进阶一/装上记忆插件（provider=memory_tencentdb).png>)

![L0-L3 数据生成](<../pictures/进阶一/数据目录（L0-L3生成）.png>)

![recall 召回](<../pictures/进阶一/recall召回.png>)

## 验收结果

2026-09-09 已完成 8 轮真实 MiniMax soak：8/8 PASS，session `20260909_002212_652bc3`。严格验证结果为 L0=16、L1=8、L2=3、L3 persona=3392B，关键词 `青松灯塔-7429` recall=true，详见 `evidence/verification.json`。

如需重跑，容器 `hermes-real-demo`、Gateway 和离线依赖仍保留，可直接执行：

```sh
docker exec hermes-real-demo node /workspace/soak/hermes-soak.mjs \
  --rounds 8 --interval-ms 1000 --duration-minutes 20 \
  --request-timeout-ms 180000 --toolsets context_engine,memory \
  --prompts /workspace/advanced/fact-prompts.json \
  --output /workspace/advanced/evidence/soak
```

完成后，从 `meta.json` 取 `finalSessionId`，执行：

```sh
docker exec hermes-real-demo node /workspace/advanced/verify-memory.mjs \
  --session <finalSessionId> --keyword 青松灯塔-7429
```

验证脚本只在 L0、L1、L2、L3 和精确关键词 recall 全部满足时退出 0。

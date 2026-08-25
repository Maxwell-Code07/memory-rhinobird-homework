# 第 2 周作业 —— 交付物 A：Hermes 版本兼容检测 Dockerfile

本文件夹只提交一个文件：**`Dockerfile`**（交付物 A）。

## 这个 Dockerfile 做什么

按传入的 Hermes 版本号，构建一个**安装了该版本 Hermes 的干净基线镜像**：

- 预装 **Node.js 26 LTS**（Hermes 要求 ≥26；记忆插件 Gateway 依赖 ≥22.16）
- 用官方 `install.sh --branch <tag>` 无头安装指定版本 Hermes（非交互）
- **不安装记忆插件、不 COPY 本仓库源码**（只 COPY 交付物 B 脚本与入口脚本）
- **构建期版本断言**：`hermes --version` 的 release 日期必须等于 `HERMES_VERSION`，否则构建失败
- **镜像启动自动执行自动对话**（交付物 B 的 soak）：`CMD` 运行 `entrypoint.sh` → 生成模型配置 → 跑 `soak.mjs`

```bash
# 构建（版本号带 v 前缀的 git tag）
docker build --build-arg HERMES_VERSION=v2026.8.19 -t hermes-version-compat:v2026.8.19 .
```

## ⚠️ 跨周依赖（重要）

题目规定交付物 A "**镜像启动后自动执行自动对话（交付物 B）**"，因此 Dockerfile 里 `COPY` 了三个文件、并在启动时运行它们：

```
COPY soak.mjs /opt/hermes-version-compat/soak.mjs
COPY entrypoint.sh /opt/hermes-version-compat/entrypoint.sh
COPY conversation.jsonl /opt/hermes-version-compat/conversation.jsonl
CMD ["bash", "/opt/hermes-version-compat/entrypoint.sh"]
```

这三个文件属于**第 3 周交付物 B（soak 脚本）**，现在放在第 3 周作业文件夹里。所以：

- **仅第 2 周这个 Dockerfile 单独放，`docker build` 会因缺少 COPY 的文件而失败**（这是题目"第 2 周只交 Dockerfile、但 Dockerfile 又要自动跑第 3 周 soak"的必然矛盾）。
- **实际构建**：把第 3 周的 `soak.mjs`、`entrypoint.sh`、`conversation.jsonl` 放到与本 Dockerfile 同目录（或直接在第 3 周文件夹里 `docker build`），然后：
  ```bash
  docker build --build-arg HERMES_VERSION=v2026.8.19 -t hermes-version-compat:v2026.8.19 .
  docker run --rm -e MODEL_API_KEY=.. -e MODEL_BASE_URL=.. -e MODEL_NAME=.. -e MODEL_PROVIDER=custom \
    -e SOAK_ROUNDS=14 hermes-version-compat:v2026.8.19
  ```
- **网络/代理**：国内构造如 GitHub 不通，需代理（见第 3 周 README 的代理说明；构建时用 `--build-arg HTTP_PROXY/HTTPS_PROXY=<可达地址>`）。

> 一句话：**第 2 周交这份"镜像图纸"（Dockerfile），第 3 周交"自动对话引擎"（soak 等），两者合起来才能构建并运行。** 这也正是题目把两件事分到两周的目的。

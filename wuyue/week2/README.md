# 第二周：参数化 Hermes Dockerfile

## 文件

- `Dockerfile`：通过 `ARG HERMES_VERSION` 构建指定版本的干净 Hermes 镜像。
- 基础镜像为 `node:22-bookworm-slim`，自带 Node.js 22（满足 Node ≥ 22.16.0）。
- 构建时只从 Hermes 上游仓库克隆指定版本，不 `COPY` 本作业仓库源码，也不安装 TencentDB-Agent-Memory 插件。

## 构建

在本目录执行（把 `0.20.5` 换成要验收的版本号）：

```bash
cd wuyue/week2
docker build --build-arg HERMES_VERSION=0.20.5 -t hermes:0.20.5 .
```

## 验收命令

```bash
# 1. 镜像内 Hermes 版本应与输入版本一致
docker run --rm hermes:0.20.5 hermes --version

# 2. Node.js 版本应为 22.16.0 或更高
docker run --rm hermes:0.20.5 node --version

# 3. 启动 Hermes 进程（需要终端和模型 API 配置）
docker run --rm -it \
  -e MODEL_API_KEY="$MODEL_API_KEY" \
  -e MODEL_BASE_URL="https://api.deepseek.com" \
  -e MODEL_NAME="deepseek-chat" \
  hermes:0.20.5
```

构建日志和上述三个命令的终端输出可截图作为第二周验收证据。

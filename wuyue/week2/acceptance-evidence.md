# 第二周验收证据

## 1. 根据指定版本构建镜像

执行：

```bash
docker build --progress=plain \
  --build-arg HERMES_VERSION=2026.8.27 \
  -t hermes:2026.8.27 .
```

结果：构建成功，镜像标记为 `hermes:2026.8.27`。

## 2. 镜像内版本验证

```text
$ docker run --rm hermes:2026.8.27 hermes --version
Hermes Agent v0.20.6 (2026.8.27)
Install directory: /opt/hermes-src
Install method: unknown
Python: 3.11.2
OpenAI SDK: 2.24.0

$ docker run --rm hermes:2026.8.27 node --version
v22.23.2
```

输入的 `HERMES_VERSION=2026.8.27` 已体现在 Hermes 版本输出中；Node.js 为 22.23.2，满足不低于 22.16.0 的要求。

## 3. Hermes 进程启动验证

```text
$ docker run --rm hermes:2026.8.27 hermes --help
usage: hermes [-h] [--version] [-z PROMPT] [--usage-file PATH] [-m MODEL]
              [--provider PROVIDER] [--reasoning LEVEL] [-t TOOLSETS]
              ...
exit_code=0
```

帮助命令由镜像中的 Hermes 可执行程序正常完成（退出码 0），证明进程能够启动。交互对话时再按需传入 `MODEL_API_KEY`、`MODEL_BASE_URL` 和 `MODEL_NAME` 环境变量。

## 作业约束核对

- Dockerfile 使用 `ARG HERMES_VERSION`，版本号由构建参数传入。
- 基础镜像为官方 Node.js 22 Bookworm slim（AWS Public ECR 镜像副本）。
- 未安装 TencentDB-Agent-Memory 记忆插件。
- 未 `COPY` 作业仓库源码，Hermes 源码在构建时从上游仓库按版本下载。

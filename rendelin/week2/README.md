# 第 2 周作业：按版本号构建 Hermes 镜像

本目录提交 `Dockerfile` 和本 `README.md`。

`Dockerfile` 根据传入的 Hermes 版本号，构建一个装好了对应版本 Hermes 的干净镜像。只装 Hermes 本体。

## 基础镜像与依赖

- 基础镜像 `node:26-bookworm-slim`（Debian 12，自带 Node 26）
- 这个版本同时满足记忆插件 Gateway 对 Node ≥ 22.16 的依赖

Hermes 用官方 `install.sh --branch <tag>` 安装，非交互。

## 版本号怎么传

构建时用 `--build-arg` 传入：

```bash
docker build --build-arg HERMES_VERSION=v2026.8.19 -t my-hermes:v2026.8.19 .
```

Hermes 的版本号有两套写法，`hermes --version` 会同时输出：

```
Hermes Agent v0.20.5 (2026.8.19)
```

前面 `v0.20.5` 是语义化版本，括号里的 `2026.8.19` 是日期发布版，两者是同一个版本。

构建时**必须用日期 tag**。Hermes 的 git tag 全部是日期格式

Dockerfile 会做两层校验：

- 格式校验：版本号必须形如 `vYYYY.M.D` 或 `YYYY.M.D`，不合法直接构建失败
- 版本断言：构建完成后跑 `hermes --version`，把语义化版本和日期都抠出来打印，日期必须等于传入的 `HERMES_VERSION`，不一致则构建失败

## 构建

构建时要把代理显式传给 `docker build`。Docker 的 `buildx` 不会继承 shell 里的 `HTTP_PROXY`，拉 `node:26-bookworm-slim` 基础镜像时如果直连 Docker Hub，国内环境会超时。

Windows / PowerShell（实际终端效果）：

![Windows 构建命令](屏幕截图%202026-08-28%20115554.png)

Linux / macOS / Git Bash：

```bash
docker build --build-arg HERMES_VERSION=v2026.8.19 \
  --build-arg HTTP_PROXY=http://127.0.0.1:7890 \
  --build-arg HTTPS_PROXY=http://127.0.0.1:7890 \
  -t my-hermes:v2026.8.19 .
```

参数说明：

- `--build-arg HERMES_VERSION=...`：版本号（日期 tag）
- `--build-arg HTTP_PROXY / HTTPS_PROXY`：给镜像构建用的代理
- `-t`：镜像名和标签

如果本机不需要代理就能连通 Docker Hub，去掉两个 `PROXY` 参数即可。

## 验证

镜像默认启动会先打印 Hermes 版本，然后启动 headless 后端服务并**持续运行**（不退出），不需要模型密钥：

```bash
docker run --rm -e HERMES_HOME=/opt/data my-hermes:v2026.8.19
```

启动输出（验收标准 2：版本一致）：

![运行验证输出](屏幕截图%202026-08-28%20115541.png)

`v0.20.5` 和 `2026.8.19` 与传入的版本一致，即验收 2 通过。

Hermes 后端服务随后常驻运行（验收标准 3：进程跑起来）：

![Hermes 后端常驻运行](屏幕截图%202026-08-28%20124959.png)

看到 `HERMES_BACKEND_READY port=9119` 且终端不退回命令行，说明 Hermes 进程已启动并持续运行。用 `Ctrl + C` 停止。

直接验证后端服务常驻（跳过版本打印）：

```bash
docker run --rm -e HERMES_HOME=/opt/data --entrypoint hermes my-hermes:v2026.8.19 serve --skip-build
```

进容器交互排查：

```bash
docker run --rm -it --entrypoint bash my-hermes:v2026.8.19
```
## 代理地址

本机 Clash 常用 `http://127.0.0.1:7890`。如果用的是 Docker Desktop（WSL2 后端）、宿主机 Clash 只监听回环地址，容器里访问不了 `127.0.0.1`，就改用 `http://host.docker.internal:7890`。


# Hermes 指定版本 Docker 镜像

## 一、作业目标

本项目使用 Dockerfile 将 Hermes 的手工安装过程固化为 Docker 镜像。

构建镜像时，使用者可以通过 `HERMES_VERSION` 参数指定需要安装的 Hermes 版本。构建完成后，可以得到一个已经安装指定版本 Hermes 的干净运行环境，从而避免不同计算机之间出现环境不一致的问题。

## 二、文件说明

本目录包含以下文件：

- `Dockerfile`：定义 Hermes 镜像的构建步骤。
- `README.md`：说明镜像的构建、验证和运行方法。

该镜像具有以下特点：

- Hermes 版本通过构建参数传入，没有写死在 Dockerfile 中。
- 基础镜像为 `node:22-bookworm-slim`，其中包含 Node.js 22。
- 使用 Python 虚拟环境安装 Hermes。
- 不安装 TencentDB 记忆插件。
- 不使用 `COPY` 或 `ADD` 将本作业仓库源码复制到镜像中。
- 使用普通用户 `hermes` 运行程序，而不是使用 `root` 用户。

## 三、环境要求

构建前需要准备：

- Docker Desktop
- 能够访问 Docker Hub 和 PyPI 的网络
- PyPI 中已经发布的 Hermes 版本号

可以使用以下命令检查 Docker 是否正常运行：

```bash
docker version
```

正常情况下，输出中应同时包含 `Client` 和 `Server`。

## 四、构建镜像

进入 Dockerfile 所在目录后，执行：

```bash
docker build \
  --build-arg HERMES_VERSION=0.19.0 \
  -t hermes:0.19.0 \
  .
```

参数说明：

- `docker build`：根据 Dockerfile 构建镜像。
- `--build-arg HERMES_VERSION=0.19.0`：把 Hermes 版本号 `0.19.0` 传给 Dockerfile。
- `-t hermes:0.19.0`：将镜像命名为 `hermes`，标签设为 `0.19.0`。
- 最后的 `.`：表示使用当前目录作为 Docker 构建上下文。

如果需要构建其他 PyPI 已发布版本，可以同时修改构建参数和镜像标签。例如：

```bash
docker build \
  --build-arg HERMES_VERSION=0.18.0 \
  -t hermes:0.18.0 \
  .
```

构建完成后，可以检查镜像是否存在：

```bash
docker image ls hermes:0.19.0
```

## 五、验证镜像

### 1. 验证 Hermes 版本

```bash
docker run --rm hermes:0.19.0 --version
```

输出应包含：

```text
0.19.0
```

这证明镜像内实际安装的 Hermes 版本与构建时输入的版本一致。

### 2. 验证 Node.js 版本

```bash
docker run --rm \
  --entrypoint node \
  hermes:0.19.0 \
  --version
```

输出应为 `v22.x.x`，并且版本不低于 `22.16.0`。

### 3. 验证 Hermes 可以启动

```bash
docker run --rm hermes:0.19.0 --help
```

如果能够正常显示 Hermes 帮助信息，说明 Hermes 进程可以启动。

### 4. 验证运行用户和镜像入口

```bash
docker image inspect hermes:0.19.0 \
  --format 'Entrypoint={{json .Config.Entrypoint}} User={{.Config.User}} Workdir={{.Config.WorkingDir}}'
```

预期输出类似：

```text
Entrypoint=["hermes"] User=hermes Workdir=/home/hermes
```

### 5. 验证未安装 TencentDB 记忆插件

```bash
docker run --rm \
  --entrypoint sh \
  hermes:0.19.0 \
  -c 'if find /opt/hermes-venv -iname "*memory_tencentdb*" | grep -q .; then echo "ERROR: memory plugin found"; exit 1; else echo "OK: memory plugin not installed"; fi'
```

预期输出：

```text
OK: memory plugin not installed
```

## 六、运行 Hermes

交互式启动 Hermes：

```bash
docker run --rm -it hermes:0.19.0
```

参数说明：

- `-it`：为容器提供交互式终端，允许使用者与 Hermes 交互。
- `--rm`：容器停止后自动删除该容器。
- `hermes:0.19.0`：指定要运行的镜像及标签。

Dockerfile 使用：

```dockerfile
ENTRYPOINT ["hermes"]
```

因此，镜像启动时会默认运行 Hermes。写在镜像名称后面的参数会直接传给 Hermes，例如：

```bash
docker run --rm hermes:0.19.0 --version
```

等价于在容器中执行：

```bash
hermes --version
```

## 七、版本范围

本方案通过以下形式从 PyPI 安装 Hermes：

```text
hermes-agent==指定版本号
```

因此，传入的版本必须已经发布到 PyPI。

本作业使用 `0.19.0` 作为构建和验收示例。本机源码版本 `0.20.4` 没有对应的 PyPI 发布版本，所以不能直接通过本 Dockerfile 的 PyPI 安装方案构建。

如果传入的版本不存在，pip 会提示找不到匹配的版本，镜像构建会失败。

## 八、常见问题

### 1. 无法连接 Docker

如果 `docker version` 只有 `Client`，没有 `Server`，通常表示 Docker Desktop 尚未启动。启动 Docker Desktop 后重新执行命令。

### 2. 无法下载基础镜像

如果出现访问 `registry-1.docker.io` 超时，说明当前网络无法访问 Docker Hub。需要检查网络、VPN或 Docker Desktop 的代理设置。

### 3. Hermes 版本不存在

如果出现：

```text
No matching distribution found for hermes-agent
```

说明输入的版本没有发布到 PyPI，或者该版本与当前 Python 环境不兼容。应检查版本号并重新构建。

### 4. 忘记传入版本号

如果构建时没有提供 `HERMES_VERSION`，Dockerfile 会主动停止并显示：

```text
ERROR: HERMES_VERSION must be provided
```

正确构建时必须添加：

```bash
--build-arg HERMES_VERSION=0.19.0
```

### 5. 网络代理端口错误

如果出现：

```text
connect: connection refused
```

需要检查代理软件是否运行，以及 Docker Desktop 配置的代理端口是否与系统实际代理端口一致。

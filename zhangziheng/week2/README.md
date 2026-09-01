# 第二周作业：参数化 Hermes Dockerfile

本次作业，提供了一个能够按 Hermes 语义化版本号动态构建的干净镜像。构建时只需传入类似 `0.20.6` 的版本号，Dockerfile 会自动在官方 Git tags 中定位对应的日期式 tag、安装该版本，并在构建阶段完成版本和环境校验。

镜像基于 `node:22-bookworm-slim`，只安装 Hermes 本体，不安装记忆插件，也不会将本仓库源码复制到镜像中。

## 本版 Dockerfile 实现的功能

1. **动态构建指定版本**：通过 `ARG HERMES_VERSION` 接收标准 `x.y.z` 版本号，不维护静态版本映射表。
2. **自动解析官方 tag**：从 Hermes 官方 Git 仓库读取 tags，优先通过 release 提交信息匹配版本，必要时读取对应 tag 的 `pyproject.toml` 复核。
3. **构建期版本断言**：安装完成后读取 Python 包元数据，确保镜像内 Hermes 版本与构建参数完全一致。
4. **Node.js 环境校验**：使用 `node:22-bookworm-slim`，并在构建阶段检查 Node.js 不低于 `22.16.0`。
5. **保持基础镜像干净**：只安装 Hermes 核心，并检查常见外部记忆包没有被安装。
6. **不复制本仓库**：Dockerfile 不使用 `COPY` 或 `ADD`，镜像中的 Hermes 源码来自官方仓库。
7. **为插件扩展留出基础层**：后续可以从指定版本的 `hermes:x.y.z` 派生镜像，再安装 TencentDB-Agent-Memory。

## 构建镜像

在项目目录下执行：

```bash
docker build --progress=plain \
  --build-arg HERMES_VERSION=0.20.6 \
  -t hermes:0.20.6 .
```

`HERMES_VERSION` 必须通过 `--build-arg` 传入。Dockerfile 会在构建过程中：

- 检查版本参数是否为空；
- 校验版本号是否符合标准 `x.y.z` 格式；
- 使用 Git 原生协议获取 Hermes 官方仓库和 tags；
- 自动解析对应的官方 release tag 并 checkout；
- 在独立 Python 虚拟环境中安装 Hermes 核心；
- 检查 Hermes 版本、Node.js 版本以及外部记忆包。

例如，当前已验证的版本对应关系如下：

| Hermes 版本 | 官方 Git tag |
| --- | --- |
| `0.20.6` | `v2026.8.27` |
| `0.19.0` | `v2026.7.20` |

其他已发布版本也可以使用同样的构建命令，不需要修改 Dockerfile；如果官方仓库没有对应 release，构建会明确失败。

## 实现流程

```text
传入 HERMES_VERSION
        ↓
校验 x.y.z 格式和 Node.js 版本
        ↓
通过 Git 获取 Hermes 官方仓库及 tags
        ↓
从 release 提交信息匹配版本
        ↓（未匹配时）
读取各 tag 的 pyproject.toml 复核版本
        ↓
checkout 对应 tag 并安装 Hermes
        ↓
断言实际版本一致、外部记忆包未安装
        ↓
生成 hermes:x.y.z 镜像
```

## 版本验证

```bash
docker run --rm hermes:0.20.6 hermes --version
docker run --rm hermes:0.20.6 node --version
```

注意：验证 Hermes 时必须显式写出 `hermes --version`。如果只执行 `docker run --rm hermes:0.20.6 --version`，Node 官方基础镜像的入口脚本会把 `--version` 交给 Node.js，因此输出会是类似 `v22.23.2` 的 Node.js 版本。

预期结果应包含 Hermes `0.20.6`，并且 Node.js 版本不低于 `22.16.0`，例如：

```text
Hermes Agent v0.20.6
v22.x.x
```

也可以用其他已发布版本复验参数化能力：

```bash
docker build --progress=plain \
  --build-arg HERMES_VERSION=0.19.0 \
  -t hermes:0.19.0 .
docker run --rm hermes:0.19.0 hermes --version
```

## 启动 Hermes

Hermes 默认以交互式 CLI 运行，需要使用 TTY：

```bash
docker run --rm -it hermes:0.20.6
```

API Key 和模型配置应在容器运行时提供，不应写入 Dockerfile 或镜像层。

例如使用环境变量传入 API Key：

```bash
docker run --rm -it \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  hermes:0.20.6
```

进入 Hermes 后，可以通过 `hermes model` 配置 DeepSeek 模型。

## 容器启动检查

如果只需要确认容器和 Hermes 进程能够启动，可以执行：

```bash
docker run --name hermes-smoke -dit \
  -e OPENAI_API_KEY=dummy \
  hermes:0.20.6

docker ps
docker logs --tail 50 hermes-smoke
docker top hermes-smoke
docker rm -f hermes-smoke
```

## 踩坑与解决过程

这份 Dockerfile 不是一次写成的。实现过程中主要经历了以下几个问题，也逐步明确了“参数化构建”真正需要解决的边界。

### 1. 只把参数写成 `ARG`，但版本映射仍然写死

第一版虽然声明了 `ARG HERMES_VERSION`，却只支持：

```text
0.20.6 → v2026.8.27
```

传入其他版本会得到 `Unsupported Hermes version`。这只能算“半参数化”：输入形式可以变化，内部实现仍然依赖人工维护映射，无法服务后续新版本。

Hermes 的包版本使用 `0.20.6` 这样的语义化版本，而官方 Git tag 使用 `v2026.8.27` 这样的日期格式，两者不能通过简单字符串拼接转换。

最终方案是不再保存静态映射表。Dockerfile 获取官方 tags 后，先读取 release 提交信息中的版本号；如果旧版本的提交信息格式不同，再读取 tag 中的 `pyproject.toml`，用其中的 `project.version` 完成匹配。这样新版本发布后不需要修改 Dockerfile。

### 2. Dockerfile 变量被错误转义

中间版本曾将变量写成：

```dockerfile
\${HERMES_VERSION}
```

反斜杠阻止了 shell 展开变量，校验逻辑拿到的是字面量 `${HERMES_VERSION}`，因此即使传入 `0.20.6`，构建仍提示版本格式错误。

修复后使用正常的 `${HERMES_VERSION}`，并在构建日志中确认参数实际展开为目标版本。

### 3. GitHub REST API 触发 rate limit

为了自动查询 release，曾直接访问 GitHub Releases API。未认证请求很快返回：

```text
HTTP Error 403: rate limit exceeded
```

这会让 Docker 构建依赖外部 API 配额，不适合作为稳定的构建方案。

最终移除 GitHub REST API，改用 `git clone --filter=blob:none --no-checkout` 获取官方仓库和 tags。版本解析在本地完成，不再消耗 GitHub REST API 配额；blobless clone 也避免在定位版本前下载全部源码内容。

### 4. `--version` 查询到了 Node.js

曾使用下面的命令验证 Hermes：

```bash
docker run --rm hermes:0.20.6 --version
```

由于镜像基于 Node 官方镜像，继承的入口脚本会把单独的 `--version` 交给 Node.js，因此输出为 `v22.23.2`，而不是 Hermes 版本。

正确做法是明确指定容器内命令：

```bash
docker run --rm hermes:0.20.6 hermes --version
docker run --rm hermes:0.20.6 node --version
```

这两条命令分别验证 Hermes 和 Node.js，避免把两个版本混淆。

## 验收截图

### 1. Docker 镜像构建成功

![Docker 构建过程 1](<pictures/docker build 1.png>)

![Docker 构建过程 2](<pictures/docker build 2.png>)

![Docker 构建过程 3](<pictures/docker build 3.png>)

### 2. Hermes  版本验证

![版本验证](<pictures/验证版本.png>)

### 3. Hermes 容器正常启动

![启动 Hermes 进程](<pictures/启动进程.png>)

### 4. Hermes 会话运行

![Hermes 会话](<pictures/会话.png>)

## 五条硬要求对应关系

1. **版本号参数化**：使用 `ARG HERMES_VERSION`，构建时通过 `--build-arg` 传入，并动态解析官方 release tag。
2. **干净镜像**：只安装 Hermes，不安装记忆插件。
3. **不复制本仓库源码**：Dockerfile 不使用 `COPY` 或 `ADD`。
4. **预装 Node.js**：基础镜像为 `node:22-bookworm-slim`，满足 Node.js ≥ `22.16.0` 的要求。
5. **配套说明文档**：本 README 说明了构建、版本验证、启动和截图验收方式。

## 面向后续版本和插件扩展

Dockerfile 不维护静态的“版本号 → Git tag”列表。静态列表会在 Hermes 发布新版本后立即过期，并要求人工修改 Dockerfile。当前实现会在每次构建时读取 Hermes 官方 Git tags，优先从 release 提交信息解析语义版本，必要时再读取 tag 中的 `pyproject.toml` 进行匹配。

因此，Hermes 发布新版本后，只要官方仍保留 Git tag、release 提交或 `pyproject.toml` 中声明标准 `x.y.z` 版本，就可以直接传入新版本号构建，不需要修改本仓库。

本镜像保持为不含外部记忆插件的 Hermes 基础镜像。后续安装 TencentDB-Agent-Memory 时，可以基于指定版本继续派生镜像，例如：

```dockerfile
FROM hermes:0.20.6

# 在派生镜像中安装和配置 TencentDB-Agent-Memory
```

这样可以分别验证 Hermes 基础镜像和 TencentDB 插件层，升级 Hermes 时只需重新构建对应版本的基础镜像。

## 文件说明

```text
.
├── Dockerfile
├── README.md
├── 第二次会议对齐内容.md
└── pictures/
    ├── docker build 1.png
    ├── docker build 2.png
    ├── docker build 3.png
    ├── 验证版本.png
    ├── 启动进程.png
    └── 会话.png
```

首次构建需要访问 Docker Hub、Hermes 官方 Git 仓库和 Python 包索引。

# Hermes Docker 镜像实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **本次执行方式：**由学生逐步手工完成；Codex 只解释原理、检查输出和协助排错，不代替学生创建 `Dockerfile` 或 `README.md`。

**目标：**通过 `HERMES_VERSION` 接收 PyPI 版本号，构建干净的 Hermes Docker 镜像，并完成中文使用说明。

**架构：**以 `node:22-bookworm-slim` 为基础镜像，安装 Python 和虚拟环境，再通过 pip 精确安装 `hermes-agent==${HERMES_VERSION}`。构建阶段验证版本，运行阶段以 `hermes` 作为入口。

**技术栈：**Docker、Debian 12、Node.js 22、Python 3.11、venv、pip、Hermes Agent 0.19.0、Git。

---

## 文件职责

- `Dockerfile`：定义镜像构建过程，不使用 `COPY` 或 `ADD`。
- `README.md`：说明构建参数、运行方式、验收命令、版本范围和常见问题。

### 任务 1：确认环境

- [ ] 进入作业目录：

```bash
cd '/Users/may/Documents/Academic/腾讯犀牛鸟/agent memory作业/memory-rhinobird-homework/wuyifan/week2'
pwd
```

预期：路径以 `/wuyifan/week2` 结尾。

- [ ] 检查 Docker：

```bash
docker version
```

预期：同时出现 `Client` 和 `Server`。若只有 Client，先启动 Docker Desktop。

- [ ] 检查 Git：

```bash
git status --short --branch
```

预期：位于 `main` 分支。不要提交上级目录中的 `.DS_Store`。

### 任务 2：手工创建 Dockerfile

**文件：**新建 `Dockerfile`

- [ ] 先确认文件不存在：

```bash
test -f Dockerfile
```

预期：无输出并返回非 0。

- [ ] 使用编辑器创建文件：

```bash
nano Dockerfile
```

手工输入以下内容：

```dockerfile
FROM node:22-bookworm-slim

ARG HERMES_VERSION

RUN test -n "$HERMES_VERSION" || \
    (echo "ERROR: HERMES_VERSION must be provided" >&2; exit 1)

ENV VIRTUAL_ENV=/opt/hermes-venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"
ENV HERMES_HOME=/home/hermes/.hermes
ENV PIP_NO_CACHE_DIR=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    python3 -m venv "$VIRTUAL_ENV" && \
    pip install --upgrade pip && \
    pip install "hermes-agent==${HERMES_VERSION}" && \
    python -c "import importlib.metadata as m; actual=m.version('hermes-agent'); expected='${HERMES_VERSION}'; assert actual == expected, f'expected {expected}, got {actual}'"

RUN useradd --create-home --shell /bin/bash hermes && \
    mkdir -p "$HERMES_HOME" && \
    chown -R hermes:hermes /home/hermes

USER hermes
WORKDIR /home/hermes

ENTRYPOINT ["hermes"]
```

保存：`Ctrl+O`、回车、`Ctrl+X`。

- [ ] 检查内容：

```bash
sed -n '1,200p' Dockerfile
awk 'toupper($1) == "COPY" || toupper($1) == "ADD" { found=1 } END { exit found }' Dockerfile
```

预期：第二条命令无输出并成功返回，说明没有 `COPY`/`ADD`。

- [ ] 验证缺少版本参数时会主动失败：

```bash
docker build -t hermes:missing-version .
```

预期：在 `HERMES_VERSION must be provided` 处失败。这个失败是参数保护，不是 bug。

### 任务 3：构建指定版本镜像

- [ ] 构建 `0.19.0`：

```bash
docker build \
  --build-arg HERMES_VERSION=0.19.0 \
  -t hermes:0.19.0 \
  .
```

预期：构建成功并生成 `hermes:0.19.0`。

- [ ] 确认镜像存在：

```bash
docker image ls hermes:0.19.0
```

预期：出现仓库名 `hermes`、标签 `0.19.0`。

### 任务 4：完成验收

- [ ] Hermes 版本与输入一致：

```bash
docker run --rm hermes:0.19.0 --version
```

预期：输出包含 `0.19.0`。

- [ ] Node.js 满足要求：

```bash
docker run --rm --entrypoint node hermes:0.19.0 --version
```

预期：输出 `v22.x.x`，且不低于 `22.16.0`。

- [ ] Hermes 进程能启动：

```bash
docker run --rm hermes:0.19.0 --help
```

预期：打印 Hermes 帮助信息并正常退出。

- [ ] TencentDB 记忆插件未安装：

```bash
docker run --rm --entrypoint sh hermes:0.19.0 -c \
  'if find /opt/hermes-venv -iname "*memory_tencentdb*" | grep -q .; then echo "ERROR: memory plugin found"; exit 1; else echo "OK: memory plugin not installed"; fi'
```

预期：`OK: memory plugin not installed`。

- [ ] 镜像入口和运行用户正确：

```bash
docker image inspect hermes:0.19.0 \
  --format 'Entrypoint={{json .Config.Entrypoint}} User={{.Config.User}}'
```

预期：包含 `Entrypoint=["hermes"]` 和 `User=hermes`。

### 任务 5：手工编写中文 README

**文件：**新建 `README.md`

- [ ] 创建文件：

```bash
nano README.md
```

- [ ] 用自己的语言写完以下章节：

```markdown
# Hermes 指定版本 Docker 镜像

## 作业目标
说明为什么要把手工安装过程固化成镜像。

## 文件说明
说明 Dockerfile 的职责，并声明不包含记忆插件和本仓库源码。

## 环境要求
列出 Docker Desktop、可用网络和 PyPI 版本限制。

## 构建镜像
写出带 --build-arg HERMES_VERSION=0.19.0 的完整命令，并解释参数。

## 验证镜像
给出 Hermes 版本、Node.js 版本、启动测试、无记忆插件四类命令。

## 运行 Hermes
解释 docker run --rm -it hermes:0.19.0，以及 -it、--rm 的含义。

## 版本范围
说明仅支持 PyPI 已发布版本，以及 0.20.4 为什么不支持。

## 常见问题
说明 Docker 引擎未启动、版本不存在、网络下载失败三种情况。
```

不要原样保留“说明……”等提示语，要改成自己的解释。

- [ ] 检查 README 是否覆盖关键要求：

```bash
rg -n 'HERMES_VERSION|0\.19\.0|docker build|docker run|Node|memory|COPY|ADD' README.md
```

### 任务 6：最终检查与提交

- [ ] 检查改动：

```bash
git status --short
git diff --check
git diff -- Dockerfile README.md
```

预期：只包含有意创建的 week2 文件；`git diff --check` 无输出。

- [ ] 重跑并截图三项核心验收：

```bash
docker run --rm hermes:0.19.0 --version
docker run --rm --entrypoint node hermes:0.19.0 --version
docker run --rm hermes:0.19.0 --help
```

截图应同时包含命令和关键输出，不得包含 API Key。

- [ ] 提交作业文件：

```bash
git add Dockerfile README.md
git commit -m "feat: add versioned Hermes Docker image"
```

预期：新提交只包含 `Dockerfile` 和 `README.md`，不包含 `.DS_Store`。


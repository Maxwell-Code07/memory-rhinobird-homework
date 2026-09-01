# Hermes Agent Docker 镜像构建说明

第二周作业：输入一个 Hermes 版本号，构建出装好该版本的干净镜像（不含记忆插件）。相当于把第一周手工安装 Hermes 的流程，写成了一个可复现的 Dockerfile。

## 硬性要求对照

| # | 要求 | 实现方式 |
|---|---|---|
| 1 | 版本号参数化，不写死 | `ARG HERMES_VERSION`，构建时 `--build-arg` 传入 |
| 2 | 只装 Hermes，不装记忆插件 | 源码包用官方仓库 `git archive` 导出（只含 git 跟踪文件），`uv sync` 只装本体 |
| 3 | 不 COPY 本作业仓库源码 | 镜像内源码是官方仓库的 tarball（`hermes-agent-<版本>.tar.gz`），和作业仓库完全隔离 |
| 4 | 预装 Node.js >= 22.16.0 | 基础镜像 `node:22-bookworm-slim`（Debian 12），自带 Node 22 |
| 5 | 附带 README.md | 本文件 |

## 构建方法

### 0. 准备源码包

构建目录下需要有 `hermes-agent-<版本号>.tar.gz`，两种方式：

方式一（推荐，版本精确）：在 Hermes 官方仓库的 clone 目录里执行

```bash
git clone https://github.com/NousResearch/hermes-agent.git
cd hermes-agent
grep '^version' pyproject.toml        # 确认是你要的版本
git archive --format=tar.gz -o hermes-agent-0.20.5.tar.gz HEAD
mv hermes-agent-0.20.5.tar.gz <作业目录>/
```

`git archive` 只导出 git 跟踪的文件，工作区里没提交的内容（比如记忆插件）不会被带进包。

方式二：直接下载官方 tarball

```bash
curl -L -o hermes-agent-0.20.5.tar.gz \
  https://codeload.github.com/NousResearch/hermes-agent/tar.gz/refs/heads/main
```

这种方式拿到的是 main 分支最新版，版本号以 pyproject.toml 为准。

### 1. 构建镜像

```bash
docker build --build-arg HERMES_VERSION=0.20.5 -t hermes:0.20.5 .
```

构建时会比对源码包 `pyproject.toml` 里的版本和 `HERMES_VERSION`，不一致直接报错退出，保证镜像内版本和传入版本一致。

### 2. 验证

```bash
docker images hermes:0.20.5
docker run --rm hermes:0.20.5 hermes --version
```

## 验收自查

- [x] `docker build` 全流程跑通（截图在 pictures/02）
- [x] 容器内 `hermes --version` 输出 0.20.5，与传入参数一致（截图在 pictures/01）
- [x] 容器能正常启动，hermes 命令可运行
- [x] 版本号通过 ARG 传入，没有写死
- [x] 镜像内没有记忆插件源码 / 作业仓库源码

## 构建中遇到的问题

1. 容器里直连 GitHub 拉源码会被 TLS 断连（报 `GnuTLS recv error` / `early EOF`），git clone 走不通。GitHub 镜像源（ghfast.top 等）对这个仓库也返回 403。最后改成在本地先把源码导出成 tarball，再 COPY 进镜像，绕开容器内访问 GitHub。
2. Debian 官方 apt 源下载很慢（实测只有几十 KB/s），换成了清华镜像，35MB 的包 6 秒下完。
3. uv 的官方安装脚本（astral.sh）在国内也下不动，改用 pip 从清华 PyPI 装 uv，顺便把 Hermes 的依赖也指到清华源。
4. `uv sync` 时不能加 `--no-install-project`，否则 .venv 里没有 hermes 命令，容器起不来。

## 环境信息

- 基础镜像：`node:22-bookworm-slim`（Debian 12）
- Node.js：22.x（>= 22.16.0）
- Python：3.11（Hermes 要求 >= 3.11, < 3.14）
- 包管理：uv
- Hermes 源码：`github.com/NousResearch/hermes-agent`（tarball 方式导入）

# 第二周作业：Hermes Docker 镜像

用 Dockerfile 根据版本号构建 Hermes 镜像，镜像里只装 Hermes，不装记忆插件。

## 文件说明

- `Dockerfile`：构建脚本，版本号用 ARG 传入，没有写死
- `README.md`：说明文档（本文件）
- `pictures/`：构建过程和验证结果的截图
- `verify.ps1`：我自己验证用的脚本，可跑可不跑

## 构建方法

先准备源码包 `hermes-agent-0.20.5.tar.gz`，放在本目录下。这个包是从 Hermes 官方仓库用 git archive 导出的，好处是版本号和 pyproject.toml 里的一致，而且导出的时候只带 git 跟踪的文件，记忆插件之类没提交的内容不会被带进去。

然后执行：

```bash
docker build --build-arg HERMES_VERSION=0.20.5 -t hermes:0.20.5 .
```

构建过程中会检查源码包里的版本号，跟 HERMES_VERSION 不一致会直接报错退出，防止镜像装错版本。

## 验证

```bash
docker run --rm hermes:0.20.5 hermes --version
```

输出 `Hermes Agent v0.20.5` 就说明版本对了。也可以进容器里查：

```bash
docker run -it --rm hermes:0.20.5 bash
hermes --version
```

## 构建时踩的几个坑

1. 直连 GitHub 拉源码会超时（容器里 TLS 直接被掐断），git clone 走不通。所以改成先在本地把源码导出成 tarball，再 COPY 进镜像，绕开这个问题。
2. debian 官方源下载太慢，只有几十 KB/s，apt 换成了清华的源，快了很多。
3. uv 的官方安装脚本在国内也基本下不动，改用 pip 从清华 PyPI 装 uv，顺便把 Hermes 的依赖也走了清华源。
4. 基础镜像用 `node:22-bookworm-slim`（Debian 12），自带 Node 22，满足作业要求的 Node >= 22.16.0，不用单独装。

## 其他

- 镜像里没有记忆插件。git archive 导出源码时只导出 git 跟踪的文件，第一周装的 TencentDB 插件在工作区里没有提交，所以不会进镜像。
- 镜像里也没有本作业仓库的任何文件，源码全部来自官方仓库。

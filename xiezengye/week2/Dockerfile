# ============================================================
# Week2 交付物 A：按版本号构建 Hermes 干净镜像
# 构建命令：
#   docker build --build-arg HERMES_VERSION=v2026.8.27 -t hermes:v2026.8.27 .
# ============================================================

# 1 基础镜像：Node 22 + Debian 12(bookworm) 精简版
#    同时满足"预装 Node >= 22.16.0"（记忆插件 Gateway 的运行依赖）
FROM node:22-bookworm-slim

# 2 版本号参数化：不写死版本，构建时用 --build-arg 传入
#    Hermes 的 git tag 是日期式（如 v2026.8.27），语义化版本（v0.20.6）只出现在
#    Release 标题里，git 仓库中不存在 v0.20.6 这个 tag，因此本参数传日期式 tag
ARG HERMES_VERSION

# 3 忘了传参就直接报错终止，而不是装出个错误镜像
RUN test -n "$HERMES_VERSION" || \
      (echo "ERROR: 请用 --build-arg HERMES_VERSION=<tag> 传入版本号" && exit 1)

# 4 把版本号转成运行期环境变量，容器跑起来后 echo $HERMES_VERSION 也能看到
ENV HERMES_VERSION=${HERMES_VERSION}

# 5 装系统工具 + 换国内源：
#    slim 镜像没有 curl/git，而官方 install.sh 需要 git clone 和下载 uv，必须补上
RUN sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git \
 && rm -rf /var/lib/apt/lists/*

# 6 给 uv 装 Python 依赖时走 TUNA 的 PyPI 镜像（国内加速）
ENV UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple

# 7 核心：安装指定版本的 Hermes
#    官方 install.sh 内部就是 git clone --branch <tag> + uv 安装；
#    --skip-setup --non-interactive 跳过交互式配置向导（构建环境无法交互）；
#    容器内以 root 安装，装完后：命令在 /usr/local/bin/hermes，代码在 /usr/local/lib/hermes-agent
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
      | bash -s -- --branch "${HERMES_VERSION}" --skip-setup --non-interactive

# 8 启动命令：默认进入 hermes 交互界面（配 docker run -it 使用）
CMD ["hermes"]

# ============================================================
# Week2 交付物 A：按版本号构建 Hermes 干净镜像
# 构建命令（默认使用官方 apt/PyPI 源，任何网络环境可直接构建）：
#   docker build --build-arg HERMES_VERSION=v2026.8.27 -t hermes:v2026.8.27 .
# 国内加速（可选，apt 与 PyPI 源同时切换）：
#   docker build --build-arg HERMES_VERSION=v2026.8.27 \
#     --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn \
#     --build-arg UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple \
#     -t hermes:v2026.8.27 .
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

# 5 装系统工具：
#    slim 镜像没有 curl/git，而官方 install.sh 需要 git clone 和下载 uv，必须补上
#    apt 源默认官方；国内网络可传 --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn 加速
ARG APT_MIRROR=deb.debian.org
RUN sed -i "s|deb.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git \
 && rm -rf /var/lib/apt/lists/*

# 6 uv 安装 Python 依赖的索引，默认官方 PyPI；国内可传 TUNA 镜像地址覆盖
ARG UV_DEFAULT_INDEX=https://pypi.org/simple
ENV UV_DEFAULT_INDEX=${UV_DEFAULT_INDEX}

# 7 核心：安装指定版本的 Hermes
#    官方 install.sh 内部就是 git clone --branch <tag> + uv 安装；
#    --skip-setup --non-interactive 跳过交互式配置向导（构建环境无法交互）；
#    下载与执行分离（不用 curl | bash 管道）：curl 失败时 && 链直接中断，
#    不会出现"管道吞掉退出码、构建成功但实际没装"的假成功；
#    --retry/--retry-connrefused 让网络抖动时自动重试，提升构建稳定性；
#    容器内以 root 安装，装完后：命令在 /usr/local/bin/hermes，代码在 /usr/local/lib/hermes-agent
RUN curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused \
      https://hermes-agent.nousresearch.com/install.sh -o /tmp/install.sh \
 && bash /tmp/install.sh --branch "${HERMES_VERSION}" --skip-setup --non-interactive \
 && rm /tmp/install.sh

# 8 启动命令：默认进入 hermes 交互界面（配 docker run -it 使用）
CMD ["hermes"]

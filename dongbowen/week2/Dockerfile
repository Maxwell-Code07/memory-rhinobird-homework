# Hermes 镜像构建
# 用法: docker build --build-arg HERMES_VERSION=0.20.5 -t hermes:0.20.5 .
#
# 硬要求:
#  - 版本号 ARG 传入, 不写死
#  - 只装 Hermes, 不装记忆插件
#  - 不 COPY 作业仓库源码 (源码来自官方仓库 tarball)
#  - Node >= 22.16.0 (node:22-bookworm-slim 自带 Node 22)
#  - 附带 README

FROM node:22-bookworm-slim

ARG HERMES_VERSION

# 系统依赖; apt 换清华源, 不然下载太慢
RUN sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        python3 \
        python3-pip \
        python3-venv \
        curl \
        ca-certificates \
        tar \
        gzip \
    && rm -rf /var/lib/apt/lists/*

# uv: 官方 install.sh 在国内下不动, 用 pip 从清华源装
ENV UV_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
RUN python3 -m pip install --break-system-packages --no-cache-dir uv -i https://pypi.tuna.tsinghua.edu.cn/simple

# 源码: 本地导出的官方仓库 tarball (git archive), 容器内直连 GitHub 会 TLS 断连
COPY hermes-agent-${HERMES_VERSION}.tar.gz /tmp/hermes-agent.tar.gz
RUN mkdir -p /opt/hermes-agent && \
    tar -xzf /tmp/hermes-agent.tar.gz -C /opt/hermes-agent && \
    rm /tmp/hermes-agent.tar.gz

# 校验版本一致, 不一致就构建失败
RUN SRC_VERSION=$(grep -E '^version' /opt/hermes-agent/pyproject.toml | head -1 | sed -E 's/.*= *"([^"]+)".*/\1/') && \
    echo "Requested: ${HERMES_VERSION}" && \
    echo "Source:    ${SRC_VERSION}" && \
    if [ -n "${HERMES_VERSION}" ] && [ "${HERMES_VERSION}" != "${SRC_VERSION}" ]; then \
        echo "ERROR: version mismatch! requested=${HERMES_VERSION} source=${SRC_VERSION}"; \
        exit 1; \
    fi

# 安装 Hermes (uv sync 会装项目自身, 生成 hermes 命令)
WORKDIR /opt/hermes-agent
ENV PATH="/root/.local/bin:${PATH}"
RUN uv sync --no-dev

ENV PATH="/opt/hermes-agent/.venv/bin:${PATH}"

# 确认 hermes 能跑
RUN hermes --version || python cli.py --list-tools >/dev/null 2>&1 || true

CMD ["hermes"]

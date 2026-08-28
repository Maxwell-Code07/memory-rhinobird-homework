# 第二周作业：按传入的版本号构建干净 Hermes 镜像
#
# 使用说明（在本目录执行）：
#   docker build --build-arg HERMES_VERSION=0.20.5 -t hermes:0.20.5 .
#   docker run --rm hermes:0.20.5 hermes --version
#   docker run --rm hermes:0.20.5 node --version
#
# HERMES_VERSION 必须通过 --build-arg 传入，不能写死在镜像中。
# 本文件不 COPY 作业仓库；构建时只下载指定版本的上游 Hermes 源码。
# 镜像不安装 TencentDB-Agent-Memory 或其他记忆插件。
FROM node:22-bookworm-slim

ARG HERMES_VERSION

# Keep the selected version visible to image inspection tools.
ENV HERMES_VERSION=${HERMES_VERSION}
LABEL org.opencontainers.image.title="Hermes Agent" \
      org.opencontainers.image.version="${HERMES_VERSION}"

WORKDIR /opt

# Hermes is distributed from source.  Install only the runtime/build tools
# needed for a clean source installation; no TencentDB memory plugin is added.
RUN test -n "${HERMES_VERSION}" || (echo "HERMES_VERSION is required" >&2; exit 1) && \
    node -e 'const [major,minor,patch]=process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && (minor < 16 || (minor === 16 && patch < 0)))) process.exit(1)' && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates git python3 python3-venv python3-pip build-essential && \
    rm -rf /var/lib/apt/lists/* && \
    git clone --depth 1 --branch "v${HERMES_VERSION}" \
      https://github.com/NousResearch/hermes-agent.git /opt/hermes-src && \
    python3 -m venv /opt/hermes-venv && \
    /opt/hermes-venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/hermes-venv/bin/pip install --no-cache-dir --editable /opt/hermes-src && \
    rm -rf /opt/hermes-src/.git && \
    apt-get purge -y --auto-remove git python3-pip build-essential && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/hermes-venv/bin:${PATH}"
WORKDIR /opt/data

# The default command starts Hermes.  For a non-interactive version check,
# override it with: docker run --rm hermes:<version> hermes --version
CMD ["hermes"]

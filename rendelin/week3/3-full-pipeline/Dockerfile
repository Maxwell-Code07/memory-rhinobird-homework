# ============================================================================
# 进阶 2 基础镜像：Hermes + memory_tencentdb 记忆插件（基于第 2 周交付物）
# ============================================================================
# 在第 2 周"按版本号构建干净 Hermes 镜像"的基础上，预装 memory_tencentdb
# 记忆插件，作为流水线（build -> 拉起 -> 装插件 -> 起 Gateway -> soak）的底图。
#
# 构建：
#   docker build --build-arg HERMES_VERSION=v2026.8.19 -t hermes-memory:v2026.8.19 .
#
#   【重要】GitHub raw.githubusercontent.com 直连常被限流(HTTP 429)。拉 install.sh
#   和 git clone 必须走代理。推荐：
#     docker build --build-arg HERMES_VERSION=v2026.8.19 \
#       --build-arg INSTALL_PROXY=http://host.docker.internal:7890 \
#       -t hermes-memory:v2026.8.19 .
#   INSTALL_PROXY 在"拉 install.sh + install.sh 运行期(git clone)"生效；
#   apt/npm/拉基础镜像不受它影响（那些能直连）。
#   若不传 INSTALL_PROXY（=直连），当 GitHub 不外网限流时也能构建成功。
#
# 运行（模型凭证运行时注入）：
#   docker run --rm -e MODEL_API_KEY=.. -e MODEL_BASE_URL=.. -e MODEL_NAME=.. \
#     -e MODEL_PROVIDER=custom -p 8420:8420 hermes-memory:v2026.8.19
# ============================================================================

# 目标 Hermes 版本（git tag，带 v 前缀）
ARG HERMES_VERSION=v2026.8.19

FROM node:26-bookworm-slim

ARG HERMES_VERSION

ENV HERMES_VERSION=${HERMES_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# ---- 1. 系统依赖 + Node 26（Hermes 与记忆插件 Gateway 的运行时依赖）---------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg python3 python3-venv python3-dev build-essential && \
    rm -rf /var/lib/apt/lists/* && \
    node --version && npm --version

# ---- 2. 安装指定版本 Hermes（复用第 2 周无头安装逻辑）------------------------
ARG INSTALLER_REF=${HERMES_VERSION}
# INSTALL_PROXY：拉 install.sh 与 install.sh 运行期(git clone)走代理。允许空值=直连。
ARG INSTALL_PROXY=
RUN if [ -n "$INSTALL_PROXY" ]; then \
      (curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors -x "$INSTALL_PROXY" \
        "https://raw.githubusercontent.com/NousResearch/hermes-agent/${INSTALLER_REF}/scripts/install.sh" \
        -o /tmp/install-hermes.sh) || \
      (curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors -x "$INSTALL_PROXY" \
        "https://codeload.github.com/NousResearch/hermes-agent/tar.gz/refs/tags/${INSTALLER_REF}" \
        -o /tmp/hermes-src.tar.gz && \
       mkdir -p /tmp/hermes-src && \
       tar -xzf /tmp/hermes-src.tar.gz -C /tmp/hermes-src && \
       cp /tmp/hermes-src/*/scripts/install.sh /tmp/install-hermes.sh && \
       rm -rf /tmp/hermes-src /tmp/hermes-src.tar.gz); \
    else \
      (curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
        "https://raw.githubusercontent.com/NousResearch/hermes-agent/${INSTALLER_REF}/scripts/install.sh" \
        -o /tmp/install-hermes.sh) || \
      (curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
        "https://codeload.github.com/NousResearch/hermes-agent/tar.gz/refs/tags/${INSTALLER_REF}" \
        -o /tmp/hermes-src.tar.gz && \
       mkdir -p /tmp/hermes-src && \
       tar -xzf /tmp/hermes-src.tar.gz -C /tmp/hermes-src && \
       cp /tmp/hermes-src/*/scripts/install.sh /tmp/install-hermes.sh && \
       rm -rf /tmp/hermes-src /tmp/hermes-src.tar.gz); \
    fi && \
    export HTTP_PROXY="$INSTALL_PROXY" HTTPS_PROXY="$INSTALL_PROXY" && \
    git config --global http.proxy "$INSTALL_PROXY" && \
    git config --global https.proxy "$INSTALL_PROXY" && \
    HOME=/root bash /tmp/install-hermes.sh \
        --skip-setup --skip-browser --skip-computer-use --no-skills \
        --non-interactive --branch "${HERMES_VERSION}" && \
    git config --global --unset http.proxy || true; \
    git config --global --unset https.proxy || true; \
    rm -f /tmp/install-hermes.sh /root/.hermes/config.yaml /root/.hermes/.env

# ---- 3. 装 memory_tencentdb 记忆插件 ----------------------------------------
# 把 provider 源码复制进 Hermes 实际扫描的插件目录（/usr/local/lib/hermes-agent/
# plugins/memory/，不是 ~/.hermes/hermes-agent/——那处 Hermes 读不到），并在
# config.yaml 声明 provider。这是"容器内装插件"（进阶 2 流水线的第 3 步）。
COPY hermes-plugin /tmp/tdai-src/hermes-plugin
RUN mkdir -p /usr/local/lib/hermes-agent/plugins/memory && \
    cp -r /tmp/tdai-src/hermes-plugin/memory/memory_tencentdb /usr/local/lib/hermes-agent/plugins/memory/memory_tencentdb && \
    (grep -q "memory_tencentdb" /root/.hermes/config.yaml 2>/dev/null || \
      printf 'memory:\n  provider: memory_tencentdb\n  memory_enabled: true\n' >> /root/.hermes/config.yaml) && \
    rm -rf /tmp/tdai-src

# ---- 3b. 拷贝记忆 Gateway 源码 + 流水线脚本到 /opt/tdai 和 /opt/pipeline -----
# Gateway 源码(src/gateway/server.ts)是记忆捕获的真正引擎，provider 只是客户端。
COPY src /opt/tdai/src
COPY package.json /opt/tdai/package.json
COPY soak.mjs /opt/pipeline/soak.mjs
COPY conversation-facts.jsonl /opt/pipeline/conversation-facts.jsonl
COPY check-l0l3.mjs /opt/pipeline/check-l0l3.mjs
COPY run-soak.sh /opt/pipeline/run-soak.sh
RUN chmod +x /opt/pipeline/run-soak.sh && \
    cd /opt/tdai && (npm install --omit=dev >/tmp/npm.log 2>&1 || echo "WARN: npm install failed")

# ---- 4. 禁止运行时写 __pycache__（避免并发假失败）---------------------------
ENV PYTHONDONTWRITEBYTECODE=1

# ---- 5. 数据目录 / 记忆数据目录 ----------------------------------------------
ENV HERMES_HOME=/opt/data
ENV TDAI_DATA_DIR=/opt/data
VOLUME ["/opt/data"]

# ---- 6. 启动：跑 soak（对话 + 记忆验证）-----------------------------------
CMD ["bash", "/opt/pipeline/run-soak.sh"]

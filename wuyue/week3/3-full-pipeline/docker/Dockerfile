# ============================================================================
# Hermes Agent + TDAI Memory — 按 Hermes 版本号构建的一体化镜像
#
# 第二周作业：把第一周"手工安装 Hermes"的动作固化成 Dockerfile——
#   输入一个 Hermes 版本号，docker build 一下，
#   得到一台装好了该版本 Hermes（含 memory_tencentdb 记忆插件）的干净机器。
#
# 用法：
#   docker build --build-arg HERMES_VERSION=v2026.8.31 -t hermes-memory:v2026.8.31 .
#
# 设计说明：
#   * Hermes 版本号 = NousResearch/hermes-agent 仓库的日期制 git tag
#     （vYYYY.M.D[.n]，如 v2026.8.31）。可用下面命令列出全部可用版本：
#       git ls-remote --tags https://github.com/NousResearch/hermes-agent.git
#   * 安装使用 hermes-agent 官方 install.sh 并以 `--branch ${HERMES_VERSION}`
#     浅克隆出指定 tag（detached HEAD），与"装最新 main"一刀两断。
#   * 构建收尾用 `git describe --tags --exact-match` 校验实际落盘版本，
#     不一致（或 tag 不存在）时构建失败，杜绝"以为装了 vX 其实装了别的"。
#
# 上游参考：TencentCloud/TencentDB-Agent-Memory 仓库
#   docker/opensource/Dockerfile.hermes（main 分支快照），改动点见 README.md
# ============================================================================

ARG HERMES_VERSION=v2026.8.31

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# ============================================================
# 系统依赖（与上游 install 脚本保持一致；apt 增加重试/限 IPv4，
# 应对公共构建网络常见的 DNS 抖动 —— 语义不变，只是更抗抖动）
# ============================================================
RUN set -eux; \
    for i in 1 2 3 4 5; do \
        if apt-get update -o Acquire::ForceIPv4=true -o Acquire::Retries=5 -o Acquire::http::Timeout=60 \
           && apt-get install -y --no-install-recommends \
                -o Acquire::ForceIPv4=true -o Acquire::Retries=5 -o Acquire::http::Timeout=60 \
                git curl ripgrep ffmpeg python3-pip python3-venv build-essential python3-dev make g++; then \
            break; \
        fi; \
        echo "[apt] attempt $i failed, retry in 8s"; sleep 8; \
    done; \
    dpkg -s git ffmpeg python3-venv >/dev/null 2>&1 || { echo "[apt] install failed after retries" >&2; exit 1; }; \
    # Node.js 22（TDAI Memory Gateway 需要）
    for i in 1 2 3; do \
        if curl -fsSL --retry 5 https://deb.nodesource.com/setup_22.x | bash -; then break; fi; \
        echo "[nodesource] attempt $i failed, retry in 8s"; sleep 8; \
    done; \
    apt-get install -y --no-install-recommends -o Acquire::ForceIPv4=true -o Acquire::Retries=5 nodejs; \
    rm -rf /var/lib/apt/lists/*

# ============================================================
# 安装 TDAI Memory Gateway（npm 包 @tencentdb-agent-memory/memory-tencentdb）
# ============================================================
WORKDIR /opt/tdai-gateway

RUN echo '{"name":"tdai-memory-standalone","version":"1.0.0","type":"module","private":true}' > package.json && \
    set -eux; \
    for i in 1 2 3 4 5 6; do \
        if npm install --no-audit --no-fund --maxsockets=10 \
               --fetch-retries=5 --fetch-retry-mintimeout=10000 --fetch-retry-maxtimeout=120000 \
               @tencentdb-agent-memory/memory-tencentdb@latest tsx; then \
            break; \
        fi; \
        echo "[npm] attempt $i failed, retry in 10s"; sleep 10; \
    done; \
    npm cache clean --force

# ============================================================
# 安装指定版本号的 Hermes Agent（官方 install.sh + 版本参数化）
# ============================================================
ARG HERMES_VERSION

# 跳过浏览器（Playwright/Chromium）相关依赖 —— 镜像只承担对话 + 记忆职责
ENV HERMES_SKIP_BROWSER_SETUP=1

RUN curl -fsSL --retry 10 --retry-all-errors --retry-delay 3 https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh -o /tmp/install-hermes.sh && \
    # 补丁 1：install_node_deps() 里跳过浏览器依赖（上游同款，官方 --skip-browser
    #         只跳过 Playwright 本身，这里连 npm 工作区依赖一起跳过，保持镜像轻量）
    sed -i '/^install_node_deps() {/a\    if [ "${HERMES_SKIP_BROWSER_SETUP:-0}" = "1" ]; then echo "Skipping browser deps"; return 0; fi' /tmp/install-hermes.sh && \
    # 补丁 2：确保浅克隆（当前 install.sh 已自带 --depth 1，此行为兼容旧版的兜底）
    sed -i 's/git clone --branch/git clone --depth 1 --branch/' /tmp/install-hermes.sh && \
    HOME=/root bash /tmp/install-hermes.sh --skip-setup --skip-browser --skip-computer-use --branch "${HERMES_VERSION}" && \
    rm -f /tmp/install-hermes.sh && \
    # ---- 校验：实际安装的代码 == 请求的版本号 ----
    INSTALLED_TAG="$(git -C /usr/local/lib/hermes-agent describe --tags --exact-match 2>/dev/null || true)" && \
    echo "==> HERMES_VERSION requested: ${HERMES_VERSION}" && \
    echo "==> hermes-agent installed at tag: ${INSTALLED_TAG:-<none, 非 tag 检出>}" && \
    if [ -n "${INSTALLED_TAG}" ] && [ "${INSTALLED_TAG}" != "${HERMES_VERSION}" ]; then \
        echo "ERROR: installed ${INSTALLED_TAG} != requested ${HERMES_VERSION}" >&2; exit 1; \
    fi; \
    if [ -z "${INSTALLED_TAG}" ] && [ "${HERMES_VERSION#v}" != "${HERMES_VERSION}" ]; then \
        echo "ERROR: 无法在 /usr/local/lib/hermes-agent 校验到 tag ${HERMES_VERSION}（版本号写错？）" >&2; exit 1; \
    fi; \
    # 把请求的版本号写进镜像，运行时随时可查
    printf '%s\n' "${HERMES_VERSION}" > /opt/hermes-agent.version

LABEL org.opencontainers.image.title="hermes-agent (pinned) + memory_tencentdb gateway" \
      hermes.version="${HERMES_VERSION}"

# Hermes 数据目录（用户无关，volume 持久化）
ENV HERMES_HOME=/opt/data

# 去掉安装器生成的配置，让 $HERMES_HOME 成为唯一配置来源（CMD 启动时生成）
RUN rm -f /root/.hermes/config.yaml /root/.hermes/.env

# 把 memory_tencentdb 插件软链进 Hermes 内置插件发现路径
# （plugins/memory/__init__.py 扫描 <hermes-repo>/plugins/memory/<name>/）
RUN ln -sf /opt/tdai-gateway/node_modules/@tencentdb-agent-memory/memory-tencentdb/hermes-plugin/memory/memory_tencentdb \
    /usr/local/lib/hermes-agent/plugins/memory/memory_tencentdb

# ============================================================
# 配置 —— 统一模型配置（Hermes + TDAI 共用一套 MODEL_* 变量）
# ============================================================
RUN mkdir -p /opt/data/tdai-memory

# MODEL_API_KEY 必须在运行时通过 -e 传入（不烤进镜像）
ENV MODEL_NAME=deepseek-v3.2
ENV MODEL_BASE_URL=https://api.lkeap.cloud.tencent.com/v1
ENV MODEL_PROVIDER=custom

# Gateway 端口/数据目录
ENV TDAI_GATEWAY_PORT=8420
ENV TDAI_GATEWAY_HOST=0.0.0.0
ENV TDAI_DATA_DIR=/opt/data/tdai-memory

# 插件 → Gateway 的连接参数
ENV MEMORY_TENCENTDB_GATEWAY_HOST=127.0.0.1
ENV MEMORY_TENCENTDB_GATEWAY_PORT=8420

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -sf http://localhost:8420/health || exit 1

EXPOSE 8420
VOLUME ["/opt/data"]

# ============================================================
# CMD：同步 MODEL_* → 生成配置文件 → 前台启动 Gateway（容器常驻）
#      对话方式：docker exec -it <container> hermes
# ============================================================
CMD ["bash", "-c", "\
  mkdir -p /opt/data/tdai-memory && \
  CFG=/opt/data/config.yaml && \
  ENVFILE=/opt/data/.env && \
  export TDAI_LLM_MODEL=\"${MODEL_NAME}\" && \
  export TDAI_LLM_BASE_URL=\"${MODEL_BASE_URL}\" && \
  export TDAI_LLM_API_KEY=\"${MODEL_API_KEY}\" && \
  printf \"model:\\n  default: \\\"${MODEL_NAME}\\\"\\n  provider: \\\"${MODEL_PROVIDER}\\\"\\n  base_url: \\\"${MODEL_BASE_URL}\\\"\\n  api_key: \\\"${MODEL_API_KEY}\\\"\\n\\nmemory:\\n  provider: memory_tencentdb\\n\" > \"$CFG\" && \
  printf \"OPENAI_API_KEY=${MODEL_API_KEY}\\n\" > \"$ENVFILE\" && \
  echo \"=== hermes-agent version: $(cat /opt/hermes-agent.version) ===\" && \
  echo \"=== Config: model=${MODEL_NAME}, provider=${MODEL_PROVIDER}, url=${MODEL_BASE_URL} ===\" && \
  echo \"=== Gateway starting... ===\" && \
  echo \"=== Use: docker exec -it <container> hermes  to start a conversation ===\" && \
  exec node --import tsx/esm \
    /opt/tdai-gateway/node_modules/@tencentdb-agent-memory/memory-tencentdb/src/gateway/server.ts \
"]

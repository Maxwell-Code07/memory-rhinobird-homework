# ============================================================================
# Hermes 版本兼容检测 —— 交付物 A：按版本号构建干净 Hermes 基线镜像
# ============================================================================
# 用途：根据传入的 HERMES_VERSION 构建一个安装了指定版本 Hermes 的干净镜像
#       （不安装记忆插件、不 COPY 本仓库源码），预装 Node.js（记忆插件
#       Gateway 的运行依赖），容器启动后自动执行自动对话 soak 测试（交付物 B）。
#
# 构建：
#   docker build --build-arg HERMES_VERSION=v2026.8.18 \
#                -t hermes-version-compat:v2026.8.18 .
#
# 运行（模型凭证运行时注入，不写入镜像）：
#   docker run --rm \
#     -e MODEL_API_KEY="<your-key>" \
#     -e MODEL_BASE_URL="https://api.lkeap.cloud.tencent.com/v1" \
#     -e MODEL_NAME="deepseek-v3.2" \
#     -e MODEL_PROVIDER="custom" \
#     -v "$PWD/results:/results" \
#     hermes-version-compat:v2026.8.18
#
# 额外参数：
#   --build-arg INSTALLER_REF=main   install.sh 来源 git ref（默认与目标 tag 相同；
#                                    个别旧版本安装脚本缺少新 flag 时可回退 main）
#   -e SOAK_ROUNDS / SOAK_INTERVAL / SOAK_MAX_TOTAL_SECONDS  调整 soak 参数
# ============================================================================

# 目标 Hermes 版本（git tag，带 v 前缀，如 v2026.8.18）
ARG HERMES_VERSION=v2026.8.18

FROM ubuntu:24.04

ARG HERMES_VERSION
# install.sh 拉取来源：默认取与目标版本相同的 tag（版本锁定）；可回退 main
ARG INSTALLER_REF=${HERMES_VERSION}

ENV HERMES_VERSION=${HERMES_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# ============================================================================
# 1. 系统依赖 + Node.js 26 LTS（Hermes 要求 Node >= 26；记忆插件要求 >= 22.16，
#    预装 Node 26 同时满足两者，供后续插件层 / 记忆插件 Gateway 使用）
# ============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg \
        python3 python3-venv python3-dev build-essential && \
    curl -fsSL https://deb.nodesource.com/setup_26.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/* && \
    node --version && npm --version

# ============================================================================
# 2. 通过官方安装脚本安装指定版本 Hermes（无头模式）
#    install.sh 内部为 `git clone --depth 1 --branch <tag>`，tag 可直接使用。
#    拉取 install.sh 时带重试；raw.githubusercontent 偶发 429 限流时回退
#    到 codeload 源码包提取（构建重跑时 RUN 层缓存使该步骤可快速重试）。
#    安装完成后清除安装器生成的默认配置，让 HERMES_HOME 完全接管。
# ============================================================================
RUN (curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
        "https://raw.githubusercontent.com/NousResearch/hermes-agent/${INSTALLER_REF}/scripts/install.sh" \
        -o /tmp/install-hermes.sh) || \
    (curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
        "https://codeload.github.com/NousResearch/hermes-agent/tar.gz/refs/tags/${INSTALLER_REF}" \
        -o /tmp/hermes-src.tar.gz && \
     mkdir -p /tmp/hermes-src && \
     tar -xzf /tmp/hermes-src.tar.gz -C /tmp/hermes-src && \
     cp /tmp/hermes-src/*/scripts/install.sh /tmp/install-hermes.sh && \
     rm -rf /tmp/hermes-src /tmp/hermes-src.tar.gz) && \
    HOME=/root bash /tmp/install-hermes.sh \
        --skip-setup \
        --skip-browser \
        --skip-computer-use \
        --no-skills \
        --non-interactive \
        --branch "${HERMES_VERSION}" && \
    rm -f /tmp/install-hermes.sh /root/.hermes/config.yaml /root/.hermes/.env

# 禁止运行时写入 __pycache__：多次启动 hermes 时并发的 .pyc 写入会偶发
# "SystemError: non-string found in code slot"（长时间 soak 下的假失败源）
ENV PYTHONDONTWRITEBYTECODE=1

# ============================================================================
# 3. 构建期版本断言（验收标准 2：镜像内 Hermes 版本与输入的版本号一致）
#    hermes --version 输出形如 "Hermes Agent v0.20.4 (2026.8.18)"
# ============================================================================
RUN VOUT="$(hermes --version)" && \
    REL="$(printf '%s' "$VOUT" | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p')" && \
    EXP="$(printf '%s' "$HERMES_VERSION" | sed 's/^v//')" && \
    printf 'Installed Hermes: %s (expected release %s)\n' "$VOUT" "$EXP" && \
    { [ "$REL" = "$EXP" ] || { printf 'VERSION MISMATCH: installed release "%s" != expected "%s"\n' "$REL" "$EXP"; exit 1; }; }

# ============================================================================
# 4. Hermes 数据目录（配置 / 会话 / .env；容器启动时自动 mkdir）
# ============================================================================
ENV HERMES_HOME=/opt/data

# ============================================================================
# 5. 交付物 B + 容器入口 + 多轮对话剧本（本镜像 COPY 的三个文件，均为交付物而非仓库源码）
# ============================================================================
COPY soak.mjs /opt/hermes-version-compat/soak.mjs
COPY entrypoint.sh /opt/hermes-version-compat/entrypoint.sh
COPY conversation.jsonl /opt/hermes-version-compat/conversation.jsonl

# ============================================================================
# 6. 运行时模型配置（沿用仓库 docker/opensource/Dockerfile.hermes 惯例：
#    MODEL_* 环境变量统一配置；MODEL_API_KEY 必须在运行时通过 -e 传入）
# ============================================================================
# 运行时模型配置：不绑定任何 provider 默认值。MODEL_API_KEY / MODEL_BASE_URL /
# MODEL_NAME 由一键脚本（build.bat/sh）交互收集或 docker run -e 传入（任意模型/供应商）；
# entrypoint 启动时会校验必须齐全，缺失即报错，避免静默用错地址导致 401。
# MODEL_PROVIDER 只保留通用的 custom（OpenAI 兼容接口），其余随时可覆盖。
ENV MODEL_PROVIDER=custom

# soak 默认参数（可通过 -e 覆盖）
ENV SOAK_ROUNDS=10
ENV SOAK_INTERVAL=5
ENV SOAK_MAX_TOTAL_SECONDS=600
ENV SOAK_RESULT_FILE=/results/result.json

# ============================================================================
# 7. 启动：生成模型配置 -> 运行 soak（自动对话 + 版本断言 + JSON 结果）
#    逻辑在 entrypoint.sh（避免 CMD 内嵌长脚本的转义问题）；退出码即 soak
#    退出码（0 = 通过），供 CI 判定
# ============================================================================
CMD ["bash", "/opt/hermes-version-compat/entrypoint.sh"]

VOLUME ["/opt/data", "/results"]

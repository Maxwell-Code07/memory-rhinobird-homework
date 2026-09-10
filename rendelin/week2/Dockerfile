# ============================================================================
# Hermes 版本兼容检测 —— 按版本号构建干净 Hermes 基线镜像（第 2 周交付物 A）
# ============================================================================
# 用途：根据传入的 HERMES_VERSION 构建一个装了指定版本 Hermes 的干净镜像。
#       只装 Hermes 本体——不装记忆插件、不 COPY 本仓库源码；预装 Node.js
#       供记忆插件 Gateway 使用；容器启动后打印 Hermes 版本（验收标准 2）。
#
# 构建（版本号形如 vYYYY.M.D 或 YYYY.M.D，Hermes 用日期当版本号）：
#   docker build --build-arg HERMES_VERSION=v2026.8.19 -t my-hermes:v2026.8.19 .
#
# 运行（验证镜像内 Hermes 版本，无需模型密钥）：
#   docker run --rm my-hermes:v2026.8.19
#
# 进容器交互（可选）：
#   docker run --rm -it --entrypoint bash my-hermes:v2026.8.19
# ============================================================================

# 目标 Hermes 版本（git tag，带 v 前缀，如 v2026.8.19）
ARG HERMES_VERSION=v2026.8.19

# 预装 Node 26 的 Debian 12（bookworm）基础镜像：
#   - Node >= 26 是 Hermes 官方硬要求（其 install.sh 中写死 NODE_VERSION="26"）
#   - 同时满足记忆插件 Gateway 的 Node >= 22.16 依赖
#   - Debian 12（bookworm）符合题目要求；Node 26 由镜像自带，无需手动安装
FROM node:26-bookworm-slim

ARG HERMES_VERSION
# install.sh 拉取来源：默认取与目标版本相同的 tag（版本锁定）；个别旧版本可回退 main
ARG INSTALLER_REF=${HERMES_VERSION}

ENV HERMES_VERSION=${HERMES_VERSION}
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# 版本号格式校验：必须形如 vYYYY.M.D 或 YYYY.M.D；非法立即失败（build 提前报错，
# 而不是拉完一堆依赖后才失败）。Hermes 用日期命名版本，所以日期即版本号。
RUN printf '%s' "$HERMES_VERSION" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+$' || \
    { printf 'ERROR: 非法版本号 "%s"，需形如 v2026.8.19 或 2026.8.19\n' "$HERMES_VERSION"; exit 1; }

# 系统依赖（Node 26 已由基础镜像自带，无需手动安装）：
#   ca-certificates/curl/git/gnupg   安装 Hermes 用
#   python3-venv                     Hermes 创建 Python 虚拟环境用
#   python3-dev/build-essential      编译 node-pty 等原生 Node 模块用（node-gyp 依赖）
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg \
        python3 python3-venv python3-dev build-essential && \
    rm -rf /var/lib/apt/lists/* && \
    node --version && npm --version

# 通过官方 install.sh 安装指定版本 Hermes（无头、非交互）
#   install.sh 内部为 `git clone --depth 1 --branch <tag>`，tag 可直接使用。
#   拉取 install.sh 时带重试；raw.githubusercontent 偶发 429 限流时回退
#   到 codeload 源码包提取（构建重跑时 RUN 层缓存使该步骤可快速重试）。
#   安装完成后清除安装器生成的默认配置，让 HERMES_HOME 完全接管。
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
# "SystemError: non-string found in code slot"
ENV PYTHONDONTWRITEBYTECODE=1

# 构建期版本断言（验收标准 2：镜像内 Hermes 版本与输入的版本号一致）
#   hermes --version 输出形如 "Hermes Agent v0.20.5 (2026.8.19)"
#   同时校验两部分（兼容语义化版本 + 日期两种写法；0.20.5 与 2026.8.19 是同一版本）：
#     - 语义化版本 SEMVER（v 后面的 0.20.5）—— 证明装的是这一版
#     - 日期 DATE（括号里 2026.8.19）—— 必须等于传入的 HERMES_VERSION
RUN VOUT="$(hermes --version)" && \
    SEMVER="$(printf '%s' "$VOUT" | sed -n 's/^Hermes Agent v\([0-9][0-9.]*\).*/\1/p')" && \
    DATE="$(printf '%s' "$VOUT" | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p')" && \
    EXP="$(printf '%s' "$HERMES_VERSION" | sed 's/^v//')" && \
    printf 'Installed Hermes: %s\n  semver=%s  release_date=%s  (expected=%s)\n' "$VOUT" "$SEMVER" "$DATE" "$EXP" && \
    [ -n "$DATE" ] || { printf 'ERROR: 未能从输出解析 release date\n'; exit 1; } && \
    { [ "$DATE" = "$EXP" ] || { printf 'VERSION MISMATCH: release date "%s" != expected "%s"\n' "$DATE" "$EXP"; exit 1; }; }

# Hermes 数据目录（配置 / 会话 / .env；容器启动时自动 mkdir）
ENV HERMES_HOME=/opt/data

VOLUME ["/opt/data"]

# 默认启动：先打印 Hermes 版本（验收 2：版本一致），再接 exec 启动 headless 后端服务
#   （验收 3：Hermes 进程跑起来并持续运行）。用 sh -c 串联，exec 让 Hermes 作为 PID 1
#   前台进程保持存活（信号可直传，符合容器最佳实践），无需模型密钥即可跑通。
#   --skip-build：跳过 web UI 构建（npm run build），直接 serve 现有 dist——这是非交互
#   场景（CI/容器）下让 Hermes 常驻不退出的关键，否则会进入构建分支导致退出。
#   交互式对话：docker run --rm -it -e OPENROUTER_API_KEY=.. --entrypoint hermes my-hermes:v2026.8.19
CMD ["sh", "-c", "hermes --version && exec hermes serve --skip-build"]

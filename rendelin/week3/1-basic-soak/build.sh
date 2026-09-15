#!/usr/bin/env bash
# ============================================================================
#  Hermes 版本兼容检测 —— 一键构建 + 自动对话（Linux/macOS 用）
#
#  流程：输入 Hermes 版本号 -> docker build（按版本构建基线镜像）
#        -> docker run（自动对话 soak，--rm 容器跑完即删）
#        -> 清理模型密钥等敏感信息（不写盘、环境变量用完即 unset）
#
#  所有可交互项都支持"环境变量预置"跳过提问（便于 CI / 非交互使用）：
#    HERMES_VERSION   e.g. 2026.8.18 / v2026.8.18
#    MODEL_API_KEY / MODEL_BASE_URL / MODEL_NAME / MODEL_PROVIDER
#    SOAK_ROUNDS / SOAK_INTERVAL / SOAK_MAX_TOTAL_SECONDS
#    PROXY_ADDR       如 http://host.docker.internal:7890（仅作为 --build-arg 传给构建）
#
#  国内网络构建如失败（GitHub 限流/不通），可用 PROXY_ADDR 或交互输入代理地址；仅作
#  build-arg 传递，不设客户端 env（避免 Docker Desktop 改写代理导致拉基础镜像失败）。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

echo
echo "  ============================================================"
echo "    Hermes 版本兼容检测 — 一键构建 + 自动对话"
echo "  ============================================================"
echo

# 版本号必须为日期格式（Hermes 以 YYYY.M.D 命名 tag），可带 v 前缀
valid_version() { [[ "${1#v}" =~ ^[0-9]+\.[0-9]+\.[0-9.]+$ ]]; }

# 交互提问：环境变量已预置则跳过；否则读入，空输入或 EOF 用默认值
ask() { # ask <var> <prompt> <default>
    local var=$1 prompt=$2 default=$3
    [ -n "${!var:-}" ] && return 0
    printf "%s（回车默认 %s）：" "$prompt" "$default"
    read -r "$var" || true
    [ -n "${!var}" ] || printf -v "$var" "%s" "$default"
}

# 交互提问（整数）：环境变量已预置则跳过；否则读入，空/EOF 用默认值，非负整数校验
ask_int() { # ask_int <var> <prompt> <default>
    local var=$1 prompt=$2 default=$3
    [ -n "${!var:-}" ] && return 0
    while true; do
        printf "%s（回车默认 %s）：" "$prompt" "$default"
        if ! read -r "$var" || [ -z "${!var}" ]; then printf -v "$var" "%s" "$default"; return 0; fi
        [[ "${!var}" =~ ^[0-9]+$ ]] && return 0
        echo "[错误] 请输入非负整数。"
    done
}

# ---- 0. 检查 docker --------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "[错误] 未找到 docker 命令，请先安装并启动 Docker。"
    exit 1
fi

# ---- 1. 输入 Hermes 版本号（格式不对则提示并重新输入，Ctrl+C 退出）-------------
if [ -n "${HERMES_VERSION:-}" ]; then
    VERSION_IN="$HERMES_VERSION"
else
    printf "您选择的 Hermes 版本为（注意：Hermes 版本号是日期格式 YYYY.M.D，例如 2026.8.18；v 前缀可省略）："
    if ! read -r VERSION_IN; then echo; exit 1; fi
fi
while ! valid_version "$VERSION_IN"; do
    echo "[错误] 版本号格式不正确：\"$VERSION_IN\""
    echo "       正确格式：日期 YYYY.M.D，例如 2026.8.18（v 前缀可省略，如 v2026.8.18 也行）"
    echo "       可用版本查看：https://github.com/NousResearch/hermes-agent/tags"
    echo
    if [ -n "${HERMES_VERSION:-}" ]; then
        echo "[错误] 环境变量 HERMES_VERSION 预置的版本号无效，已退出。"
        exit 1
    fi
    printf "您选择的 Hermes 版本为（注意：Hermes 版本号是日期格式 YYYY.M.D，例如 2026.8.18；v 前缀可省略）："
    if ! read -r VERSION_IN; then echo; exit 1; fi
done
VERSION="v${VERSION_IN#v}"
echo "[信息] 将构建 Hermes 版本：$VERSION"
echo

# ---- 2. 模型配置（API Key 必填且掩码输入）------------------------------------
if [ -n "${MODEL_API_KEY:-}" ]; then
    APIKEY="$MODEL_API_KEY"
else
    printf "请输入 MODEL_API_KEY（模型密钥，输入不回显）："
    read -r -s APIKEY
    echo
    if [ -z "$APIKEY" ]; then
        echo "[错误] 未输入 API Key，无法进行自动对话。"
        exit 1
    fi
fi
ask MODEL_BASE_URL "请输入 MODEL_BASE_URL" "https://api.deepseek.com"
ask MODEL_NAME "请输入 MODEL_NAME" "deepseek-v4-flash"
ask MODEL_PROVIDER "请输入 MODEL_PROVIDER" "custom"
echo "[信息] 模型配置：$MODEL_NAME @ $MODEL_BASE_URL (provider: $MODEL_PROVIDER)"
echo
echo "  ---- 自动对话（soak）参数，回车用默认值 ----"
ask_int SOAK_ROUNDS "对话轮次" "10"
ask_int SOAK_INTERVAL "每轮间隔（秒）" "5"
ask_int SOAK_MAX_TOTAL_SECONDS "总对话时长上限（秒）" "600"
echo "[信息] soak 参数：轮次=$SOAK_ROUNDS  间隔=${SOAK_INTERVAL}s  总时长上限=${SOAK_MAX_TOTAL_SECONDS}s"
echo

# ---- 2c. 网络代理（构建需访问 GitHub/PyPI；环境变量已预置则跳过提问）------------
# “任意电脑可运行”的关键：不同机器的代理地址不一样（Docker Desktop 专用
# host.docker.internal；Linux Docker 用宿主机 IP；无代理则直接回车）。本段由用户
# 显式操作，并把代理转发给 docker build（下方 EXTRA_ARGS 自动带上）。
if [ -z "${PROXY_ADDR:-}" ]; then
  echo "  ---- 网络代理（构建需访问 GitHub/PyPI）----"
  echo "  本机 Clash 常用 http://127.0.0.1:7890 （就是常见的 **** 端口，按你的实际填）。"
  echo "  Docker Desktop 构建用 http://host.docker.internal:7890；Linux Docker 用宿主机 IP（如 192.168.x.x:7890）。"
  echo "  你的网络能直连 GitHub 请直接回车；需 Clash/代理则填地址。"
  printf "代理地址（回车=不使用代理）："
  if ! read -r PROXY_ANS; then PROXY_ANS=""; fi
  PROXY_ADDR="${PROXY_ANS}"
else
  echo "[信息] 检测到预置代理：$PROXY_ADDR"
fi
if [ -n "$PROXY_ADDR" ]; then
  # 只作为 --build-arg 传给 docker build（不设置客户端 env，避免 Docker Desktop
  # 把代理改写成 WSL 网关 IP 导致拉基础镜像失败）
  echo "[信息] 使用代理构建：$PROXY_ADDR"
else
  echo "[信息] 不使用代理构建（直连；若构建卡在 GitHub 说明需要代理，重跑选代理）"
fi
echo

# ---- 3. 构建镜像 --------------------------------------------------------------
IMAGE="hermes-version-compat:${VERSION}"
EXTRA_ARGS=()
[ -n "${PROXY_ADDR:-}"   ] && EXTRA_ARGS+=(--build-arg "HTTP_PROXY=$PROXY_ADDR" --build-arg "HTTPS_PROXY=$PROXY_ADDR")
[ -n "${NO_PROXY:-}"     ] && EXTRA_ARGS+=(--build-arg "NO_PROXY=$NO_PROXY")
echo "[信息] 开始构建镜像 $IMAGE ..."
if ! docker build --build-arg HERMES_VERSION="$VERSION" "${EXTRA_ARGS[@]}" -t "$IMAGE" .; then
    echo "[错误] 镜像构建失败。"
    exit 1
fi
echo "[信息] 镜像构建成功：$IMAGE （构建期已断言镜像内 Hermes 版本 = $VERSION）"
echo

# ---- 4. 运行自动对话（soak）---------------------------------------------------
RESULT_DIR="$(pwd)/results"
mkdir -p "$RESULT_DIR"
echo "[信息] 开始自动对话（soak），结果将写入 $RESULT_DIR/result.json"
echo "[信息] 轮次：${SOAK_ROUNDS:-10}  间隔：${SOAK_INTERVAL:-5}s  总时长上限：${SOAK_MAX_TOTAL_SECONDS:-600}s"
echo

# 密钥只通过环境变量传给容器（-e MODEL_API_KEY 不带值 = 继承本进程环境），
# 不落入命令行；结束后 unset。容器 --rm 使其内部含密钥的配置随之销毁。
export MODEL_API_KEY="$APIKEY"
SOAK_FLAGS=()
[ -n "${SOAK_ROUNDS:-}" ]            && SOAK_FLAGS+=(-e "SOAK_ROUNDS=$SOAK_ROUNDS")
[ -n "${SOAK_INTERVAL:-}" ]          && SOAK_FLAGS+=(-e "SOAK_INTERVAL=$SOAK_INTERVAL")
[ -n "${SOAK_MAX_TOTAL_SECONDS:-}" ] && SOAK_FLAGS+=(-e "SOAK_MAX_TOTAL_SECONDS=$SOAK_MAX_TOTAL_SECONDS")
if docker run --rm \
    -e MODEL_API_KEY \
    -e MODEL_BASE_URL="$MODEL_BASE_URL" \
    -e MODEL_NAME="$MODEL_NAME" \
    -e MODEL_PROVIDER="$MODEL_PROVIDER" \
    "${SOAK_FLAGS[@]}" \
    -v "$RESULT_DIR:/results" \
    "$IMAGE"; then
    RC=0
else
    RC=$?
fi
unset MODEL_API_KEY APIKEY

echo
if [ "$RC" -eq 0 ]; then
    echo "[结果] 检测通过：PASSED"
else
    echo "[结果] 检测失败：FAILED （退出码 $RC）"
fi
echo "[信息] 结果文件：$RESULT_DIR/result.json"
echo "[信息] 敏感信息已清理：容器 --rm 已删除（内部含密钥的配置随容器销毁），密钥未写入任何文件，环境变量已 unset。"
exit "$RC"

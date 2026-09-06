#!/usr/bin/env bash
# ============================================================================
#  进阶 2 · 一键流水线：build -> 拉起 -> 装插件 -> 起 Gateway -> soak
#
#  一句话：输入一个版本号，输出"该版本 Hermes + 记忆插件"的对话测试结果和
#          L0-L3 记忆生成证据。
#
#  用法：
#    bash build.sh                              # 交互输入
#    HERMES_VERSION=v2026.8.19 bash build.sh     # 环境变量预置
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

echo
echo "  ============================================================"
echo "    Hermes + 记忆插件 · 一键流水线 (build->拉起->装插件->soak)"
echo "  ============================================================"
echo

# ---- 版本号（日期格式 YYYY.M.D，可带 v）------------------------------------
valid_version() { [[ "${1#v}" =~ ^[0-9]+\.[0-9]+\.[0-9.]+$ ]]; }
VERSION_IN="${HERMES_VERSION:-}"
[ -n "$VERSION_IN" ] || { printf "Hermes 版本（如 2026.8.19，v 可省）："; read -r VERSION_IN; }
while ! valid_version "$VERSION_IN"; do
  echo "[错误] 版本号格式应为 YYYY.M.D，如 2026.8.19"
  printf "Hermes 版本（如 2026.8.19，v 可省）："; read -r VERSION_IN
done
VERSION="v${VERSION_IN#v}"

# ---- 模型配置 --------------------------------------------------------------
ask() { local v=$1 prompt=$2 def=$3; if [ -n "${!v:-}" ]; then return; fi
  printf "%s（回车默认 %s）：" "$prompt" "$def"; read -r "$v" || true; [ -n "${!v}" ] || printf -v "$v" "%s" "$def"; }
ask MODEL_API_KEY "MODEL_API_KEY" ""
[ -n "$MODEL_API_KEY" ] || { echo "[错误] MODEL_API_KEY 必填"; exit 1; }
ask MODEL_BASE_URL "MODEL_BASE_URL" "https://api.deepseek.com/v1"
ask MODEL_NAME "MODEL_NAME" "deepseek-v4-flash"
ask MODEL_PROVIDER "MODEL_PROVIDER(deepseek 用 deepseek; 其它兼容模型用 custom)" "deepseek"
ask SOAK_ROUNDS "soak 轮次" "10"
ask SOAK_INTERVAL "soak 间隔(秒)" "5"
ask SOAK_MAX_TOTAL_SECONDS "soak 总时长上限(秒)" "600"
ask SOAK_WAIT_AFTER "soak 跑完等待记忆沉降(秒)" "120"
ask INSTALL_PROXY "拉 install.sh 的代理(GitHub raw 直连常429; 回车默认 http://host.docker.internal:7890, 输 NONE=直连)" "http://host.docker.internal:7890"
# 用户输 NONE/0 = 不用代理(直连)，把它清空以免被当成代理地址传给 build-arg
[ "$INSTALL_PROXY" = "NONE" ] && INSTALL_PROXY=""
[ "$INSTALL_PROXY" = "0" ] && INSTALL_PROXY=""

# ---- 第 1 步：build 镜像 ----------------------------------------------------
IMAGE="hermes-memory:${VERSION}"
echo "[1/5] 构建镜像 $IMAGE ..."
EXTRA=()
[ -n "$INSTALL_PROXY" ] && EXTRA+=(--build-arg "INSTALL_PROXY=$INSTALL_PROXY" --build-arg "HTTP_PROXY=$INSTALL_PROXY" --build-arg "HTTPS_PROXY=$INSTALL_PROXY")
docker build --build-arg HERMES_VERSION="$VERSION" "${EXTRA[@]}" -t "$IMAGE" .
echo "[1/5] 镜像构建成功"

# ---- 第 2 步：拉起容器（前台；容器启动即自动跑 run-soak.sh 完成第3~5步）------
RESULT_DIR="$(pwd)/results"
MEMDATA_DIR="$(pwd)/memory-data"
mkdir -p "$RESULT_DIR" "$MEMDATA_DIR"
echo "[2/5] 拉起容器（容器启动即自动起 Gateway 并跑 soak）..."
docker rm -f hermes-memory-run 2>/dev/null || true
docker run --rm --name hermes-memory-run \
  -e MODEL_API_KEY="$MODEL_API_KEY" \
  -e MODEL_BASE_URL="$MODEL_BASE_URL" \
  -e MODEL_NAME="$MODEL_NAME" \
  -e MODEL_PROVIDER="$MODEL_PROVIDER" \
  -e TDAI_LLM_API_KEY="$MODEL_API_KEY" \
  -e TDAI_LLM_BASE_URL="$MODEL_BASE_URL" \
  -e TDAI_LLM_MODEL="$MODEL_NAME" \
  -e SOAK_ROUNDS="$SOAK_ROUNDS" \
  -e SOAK_INTERVAL="$SOAK_INTERVAL" \
  -e SOAK_MAX_TOTAL_SECONDS="$SOAK_MAX_TOTAL_SECONDS" \
  -e SOAK_WAIT_AFTER="$SOAK_WAIT_AFTER" \
  -e HERMES_HOME=/opt/data \
  -e TDAI_DATA_DIR=/opt/data \
  -e MEMORY_TENCENTDB_GATEWAY_HOST=127.0.0.1 \
  -e MEMORY_TENCENTDB_GATEWAY_PORT=8420 \
  -p 8420:8420 \
  -v "$RESULT_DIR:/results" \
  -v "$MEMDATA_DIR:/opt/data" \
  "$IMAGE" || RC=$?
RC="${RC:-0}"

# ---- 第 3 步：记忆插件已在镜像构建时预装（provider + Gateway 源码）----------
echo "[3/5] 记忆插件已随镜像构建安装 (provider=memory_tencentdb)"
# ---- 第 4 步：Gateway 由 run-soak.sh 在容器内自动拉起 (:8420) ----------------
# ---- 第 5 步：soak + L0-L3 验证由 run-soak.sh 完成后落到宿主机目录 ----------
echo "[4/5+5/5] 容器内已自动起 Gateway 并跑 soak，结果写入 $RESULT_DIR / $MEMDATA_DIR"

echo
if [ "$RC" -eq 0 ]; then echo "[结果] PASSED  ✅"; else echo "[结果] FAILED  ❌ (exit $RC)"; fi
echo "结果文件: $RESULT_DIR/result.json  $RESULT_DIR/l0l3.json"
echo "记忆数据: $MEMDATA_DIR/  (conversations / records / scene_blocks / persona.md)"
exit "$RC"

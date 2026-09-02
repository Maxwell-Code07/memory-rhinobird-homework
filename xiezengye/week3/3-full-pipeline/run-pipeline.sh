#!/usr/bin/env bash
# =============================================================================
# run-pipeline.sh — Week3 进阶2：一键流水线（在装好 Docker 的 Linux 宿主机/虚拟机执行）
#
# 输入一个 Hermes 版本号 + 模型凭证，自动完成：
#   [1/5] docker build —— 用第二周 Dockerfile 构建干净 Hermes 镜像
#   [2/5] docker run   —— 拉起容器（后台常驻）
#   [3/5] 容器内安装记忆插件 —— git clone 插件源码 + npm install +
#         Provider 挂载到 ~/.hermes/plugins/memory_tencentdb + 改 config.yaml
#   [4/5] 启动 Gateway —— node --import tsx src/gateway/server.ts（:8420）
#   [5/5] 跑 soak（富含事实剧本，驱动 L0-L3 生成）+ 收集 JSON 结果 + L0-L3 验证
#
# 用法（三个模型环境变量必填）：
#   MODEL_API_KEY=sk-xxxx \
#   MODEL_BASE_URL=https://api.lkeap.cloud.tencent.com/v1 \
#   MODEL_NAME=deepseek-v3.2 \
#   bash run-pipeline.sh
#
# 可选环境变量：
#   HERMES_VERSION          默认 v2026.8.27
#   SOAK_ROUNDS / SOAK_INTERVAL / SOAK_MAX_TOTAL_SECONDS   默认 12 / 5 / 1200
#   TDAI_LLM_*              记忆抽取用 LLM（L1/L2/L3 沉淀），默认复用 MODEL_*
#   PLUGIN_REPO             插件源码地址，默认 TencentCloud/TencentDB-Agent-Memory
#   PLUGIN_BRANCH           插件分支，默认 main（必须显式指定！该仓库默认分支是
#                           feat/server_team，目录结构完全不同、根目录没有 package.json，
#                           不指定分支直接 clone 会导致 npm install 报 ENOENT）
#   GIT_PROXY_ARGS          容器内 git clone 走代理，如：
#                           GIT_PROXY_ARGS="-c http.proxy=http://192.168.1.x:7890 -c https.proxy=http://192.168.1.x:7890"
#   NPM_REGISTRY            npm 镜像，如 https://registry.npmmirror.com
#   SKIP_BUILD=1            镜像已存在时跳过构建
#   CONTAINER_NAME          默认 hermes-week3-pipeline-<时间戳>（每次运行独立容器）
#   RESULTS_DIR             默认 results-<时间戳>（每次运行结果独立保存，不覆盖历史）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

HERMES_VERSION="${HERMES_VERSION:-v2026.8.27}"
IMAGE="hermes:${HERMES_VERSION}"
# 容器名与结果目录默认带时间戳后缀：并行/重复运行互不杀容器、互不覆盖结果。
# 需要固定名字时可用环境变量覆盖（CONTAINER_NAME=xxx RESULTS_DIR=yyy）
RUN_TS="$(date +%Y%m%d-%H%M%S)"
CONTAINER="${CONTAINER_NAME:-hermes-week3-pipeline-${RUN_TS}}"
RESULTS_DIR="${RESULTS_DIR:-results-${RUN_TS}}"
ROUNDS="${SOAK_ROUNDS:-12}"
INTERVAL="${SOAK_INTERVAL:-5}"
MAX_TOTAL="${SOAK_MAX_TOTAL_SECONDS:-1200}"
PLUGIN_REPO="${PLUGIN_REPO:-https://github.com/TencentCloud/TencentDB-Agent-Memory}"
PLUGIN_BRANCH="${PLUGIN_BRANCH:-main}"
GIT_PROXY_ARGS="${GIT_PROXY_ARGS:-}"
NPM_REGISTRY="${NPM_REGISTRY:-}"

: "${MODEL_API_KEY:?需要 MODEL_API_KEY 环境变量}"
: "${MODEL_BASE_URL:?需要 MODEL_BASE_URL 环境变量}"
: "${MODEL_NAME:?需要 MODEL_NAME 环境变量}"
MODEL_PROVIDER="${MODEL_PROVIDER:-custom}"
# 记忆抽取（L1/L2/L3 沉淀）用的 LLM，默认复用对话模型
TDAI_LLM_API_KEY="${TDAI_LLM_API_KEY:-$MODEL_API_KEY}"
TDAI_LLM_BASE_URL="${TDAI_LLM_BASE_URL:-$MODEL_BASE_URL}"
TDAI_LLM_MODEL="${TDAI_LLM_MODEL:-$MODEL_NAME}"

WEEK2_DIR="../../week2"        # 第二周交付物 A：Dockerfile（本脚本位于 xiezengye/week3/3-full-pipeline/）
SOAK_DIR="../1-basic-soak"     # 基础交付物：soak.mjs
L0L3_DIR="../2-memory-l0l3"    # 进阶1交付物：事实剧本 + 验证脚本

echo "===== [1/5] docker build（第二周 Dockerfile：${WEEK2_DIR}/Dockerfile）====="
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  echo "SKIP_BUILD=1，跳过构建，直接使用镜像 $IMAGE"
else
  docker build -f "$WEEK2_DIR/Dockerfile" --build-arg HERMES_VERSION="$HERMES_VERSION" -t "$IMAGE" "$WEEK2_DIR"
fi

echo "===== [2/5] docker run 拉起容器（后台常驻）====="
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
# TDAI_* 是记忆插件 Gateway 的运行环境变量（L1/L2/L3 抽取用 LLM 与数据目录）
docker run -d --name "$CONTAINER" \
  -e TDAI_LLM_API_KEY="$TDAI_LLM_API_KEY" \
  -e TDAI_LLM_BASE_URL="$TDAI_LLM_BASE_URL" \
  -e TDAI_LLM_MODEL="$TDAI_LLM_MODEL" \
  -e TDAI_DATA_DIR=/root/memory-tdai \
  "$IMAGE" sleep infinity

echo "===== [3/5] 容器内安装记忆插件（Gateway 源码 + Provider + config.yaml）====="
# 3.1 拉插件源码并安装依赖（国内网络不通 GitHub 时用 GIT_PROXY_ARGS / 换源）
NPM_ARGS=""
[ -n "$NPM_REGISTRY" ] && NPM_ARGS="--registry=$NPM_REGISTRY"
docker exec "$CONTAINER" bash -c "
  set -e
  if [ ! -d /opt/tdai ]; then
    # GitHub 直连偶发 TLS 握手失败（gnutls_handshake failed），自动重试 3 次
    for i in 1 2 3; do
      git clone $GIT_PROXY_ARGS --depth 1 -b "$PLUGIN_BRANCH" "$PLUGIN_REPO" /opt/tdai && break
      echo "[warn] git clone 第 $i 次失败（网络抖动），3 秒后重试..."
      rm -rf /opt/tdai
      sleep 3
    done
  fi
  [ -d /opt/tdai ] || { echo "[FAIL] git clone 重试 3 次仍失败：检查网络或用 GIT_PROXY_ARGS 走代理（见 README 注意事项 3）"; exit 1; }
  cd /opt/tdai
  # 插件的 peerDependencies（openclaw / node-llama-cpp，均 optional）会触发 npm 10.x
  # arborist 已知 bug：Cannot read properties of null (reading 'edgesOut')。
  # 这两个 peer 我们用不到（走 Hermes 而非 openclaw），失败时用 --legacy-peer-deps 跳过 peer 解析。
  if ! npm install $NPM_ARGS; then
    echo "[warn] npm install 失败，加 --legacy-peer-deps 重试（跳过 optional peerDependencies 解析）"
    npm install $NPM_ARGS --legacy-peer-deps
  fi
  # 挂载 Provider：目录名必须是 memory_tencentdb（下划线），Hermes 从 ~/.hermes/plugins/ 扫描
  mkdir -p /root/.hermes/plugins
  rm -rf /root/.hermes/plugins/memory_tencentdb
  cp -r /opt/tdai/hermes-plugin/memory/memory_tencentdb /root/.hermes/plugins/memory_tencentdb
"

# 3.2 写模型 + 记忆配置（config.yaml 同时声明 model 与 memory.provider）
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/config.yaml" <<EOF
model:
  default: "${MODEL_NAME}"
  provider: "${MODEL_PROVIDER}"
  base_url: "${MODEL_BASE_URL}"
  api_key: "${MODEL_API_KEY}"
memory:
  provider: memory_tencentdb
EOF
printf 'OPENAI_API_KEY=%s\n' "$MODEL_API_KEY" > "$TMP/.env"
docker exec "$CONTAINER" mkdir -p /root/.hermes
docker cp "$TMP/config.yaml" "$CONTAINER":/root/.hermes/config.yaml
docker cp "$TMP/.env" "$CONTAINER":/root/.hermes/.env
rm -rf "$TMP"; trap - EXIT

echo "===== [4/5] 启动 Gateway（node --import tsx src/gateway/server.ts，:8420）====="
docker exec -d "$CONTAINER" bash -c \
  'cd /opt/tdai && exec node --import tsx src/gateway/server.ts > /tmp/gateway.log 2>&1'
GATEWAY_OK=""
for i in $(seq 1 60); do
  if docker exec "$CONTAINER" curl -sf http://127.0.0.1:8420/health >/dev/null 2>&1; then
    GATEWAY_OK=1
    break
  fi
  sleep 1
done
if [ -z "$GATEWAY_OK" ]; then
  echo "[FAIL] Gateway 60 秒内未就绪，最近日志："
  docker exec "$CONTAINER" tail -40 /tmp/gateway.log || true
  exit 1
fi
docker exec "$CONTAINER" curl -s http://127.0.0.1:8420/health; echo "  ← Gateway 就绪"

echo "===== [5/5] 跑 soak（富含事实剧本，驱动 L0-L3 记忆生成）====="
docker exec "$CONTAINER" mkdir -p /opt/soak
docker cp "$SOAK_DIR/soak.mjs" "$CONTAINER":/opt/soak/soak.mjs
docker cp "$L0L3_DIR/conversation-facts.txt" "$CONTAINER":/opt/soak/conversation-facts.txt
docker cp "$L0L3_DIR/verify-l0l3.sh" "$CONTAINER":/opt/soak/verify-l0l3.sh

set +e
docker exec "$CONTAINER" node /opt/soak/soak.mjs \
  --hermes hermes \
  --conversation /opt/soak/conversation-facts.txt \
  --rounds "$ROUNDS" --interval "$INTERVAL" --max-total-seconds "$MAX_TOTAL" \
  --expected-version "$HERMES_VERSION" \
  --out-dir /opt/soak/out
SOAK_RC=$?
set -e

echo ""
echo "----- 收集结果 -----"
mkdir -p "$RESULTS_DIR"
docker cp "$CONTAINER":/opt/soak/out/. "$RESULTS_DIR/"
echo "soak 结果已复制到 $(pwd)/$RESULTS_DIR/（result.json / report.txt / conversation.jsonl）"

echo ""
echo "----- L0-L3 记忆验证（四张截图就位）-----"
# L1/L2/L3 是异步抽取沉淀的，等一会儿再查更稳
echo "（L1/L2/L3 为异步沉淀，先等 60 秒再验证……可 Ctrl+C 跳过等待直接查）"
sleep 60 || true
docker exec "$CONTAINER" bash /opt/soak/verify-l0l3.sh || true

echo ""
bar() { echo "============================================================"; }
bar
echo " 流水线完成：soak 退出码 $SOAK_RC（0=通过，1=失败）"
echo " 结果文件：$(pwd)/$RESULTS_DIR/"
echo " 容器 $CONTAINER 已保留，供手动截图 / 检查："
echo "   docker exec -it $CONTAINER bash"
echo "   docker exec $CONTAINER bash /opt/soak/verify-l0l3.sh    # 重跑四合一验证"
echo "   docker exec $CONTAINER tail -50 /tmp/gateway.log        # Gateway 日志"
echo " 清理：docker rm -f $CONTAINER"
bar
exit "$SOAK_RC"

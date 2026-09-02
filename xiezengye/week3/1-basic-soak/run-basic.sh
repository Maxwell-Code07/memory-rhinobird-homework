#!/usr/bin/env bash
# =============================================================================
# run-basic.sh — Week3 基础要求一键运行（在装好 Docker 的 Linux 宿主机/虚拟机执行）
#
# 流程：docker build（复用第二周 Dockerfile）→ docker run 拉起容器 →
#       写入模型配置 → 容器内跑 soak（纯闲聊剧本，验证长时间稳定对话）
#
# 用法（三个模型环境变量必填）：
#   MODEL_API_KEY=sk-xxxx \
#   MODEL_BASE_URL=https://api.lkeap.cloud.tencent.com/v1 \
#   MODEL_NAME=deepseek-v3.2 \
#   bash run-basic.sh
#
# 可选环境变量：
#   HERMES_VERSION           默认 v2026.8.27（日期式 git tag）
#   MODEL_PROVIDER           默认 custom（OpenAI 兼容接口）
#   SOAK_ROUNDS              默认 10
#   SOAK_INTERVAL            默认 5（秒）
#   SOAK_MAX_TOTAL_SECONDS   默认 600（秒）
#   SKIP_BUILD=1             镜像已存在时跳过构建
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

HERMES_VERSION="${HERMES_VERSION:-v2026.8.27}"
IMAGE="hermes:${HERMES_VERSION}"
CONTAINER="hermes-week3-basic"
ROUNDS="${SOAK_ROUNDS:-10}"
INTERVAL="${SOAK_INTERVAL:-5}"
MAX_TOTAL="${SOAK_MAX_TOTAL_SECONDS:-600}"

: "${MODEL_API_KEY:?请设置 MODEL_API_KEY 环境变量}"
: "${MODEL_BASE_URL:?请设置 MODEL_BASE_URL 环境变量}"
: "${MODEL_NAME:?请设置 MODEL_NAME 环境变量}"
MODEL_PROVIDER="${MODEL_PROVIDER:-custom}"

WEEK2_DIR="../week2"   # 第二周交付物 A：Dockerfile 所在目录

echo "===== [1/3] docker build（复用第二周 Dockerfile：${WEEK2_DIR}/Dockerfile）====="
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  echo "SKIP_BUILD=1，跳过构建，直接使用镜像 $IMAGE"
else
  docker build -f "$WEEK2_DIR/Dockerfile" --build-arg HERMES_VERSION="$HERMES_VERSION" -t "$IMAGE" "$WEEK2_DIR"
fi

echo "===== [2/3] docker run 拉起容器（后台常驻）并写入模型配置 ====="
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" "$IMAGE" sleep infinity

# 模型配置：config.yaml（Hermes 读取）+ .env（OPENAI_API_KEY，供 provider 认证）
# 凭证只经环境变量/临时文件注入容器，不写入镜像层，不进 git
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/config.yaml" <<EOF
model:
  default: "${MODEL_NAME}"
  provider: "${MODEL_PROVIDER}"
  base_url: "${MODEL_BASE_URL}"
  api_key: "${MODEL_API_KEY}"
EOF
printf 'OPENAI_API_KEY=%s\n' "$MODEL_API_KEY" > "$TMP/.env"

docker exec "$CONTAINER" mkdir -p /root/.hermes
docker cp "$TMP/config.yaml" "$CONTAINER":/root/.hermes/config.yaml
docker cp "$TMP/.env" "$CONTAINER":/root/.hermes/.env
rm -rf "$TMP"; trap - EXIT

echo "===== [3/3] 跑 soak（纯闲聊剧本，验证 Hermes 能长时间正常对话）====="
docker exec "$CONTAINER" mkdir -p /opt/soak
docker cp soak.mjs "$CONTAINER":/opt/soak/soak.mjs
docker cp conversation-chat.txt "$CONTAINER":/opt/soak/conversation-chat.txt

set +e
docker exec "$CONTAINER" node /opt/soak/soak.mjs \
  --hermes hermes \
  --conversation /opt/soak/conversation-chat.txt \
  --rounds "$ROUNDS" --interval "$INTERVAL" --max-total-seconds "$MAX_TOTAL" \
  --expected-version "$HERMES_VERSION" \
  --out-dir /opt/soak/out
SOAK_RC=$?
set -e

echo ""
echo "----- 收集结果 -----"
mkdir -p results
docker cp "$CONTAINER":/opt/soak/out/. results/
echo "结果已复制到 $(pwd)/results/：result.json（结构化判定）/ report.txt（报告）/ conversation.jsonl（逐轮记录）"
echo "soak 退出码：$SOAK_RC（0=通过，1=失败）"
echo ""
echo "容器 $CONTAINER 保留供检查：docker exec -it $CONTAINER bash"
echo "清理：docker rm -f $CONTAINER"
exit "$SOAK_RC"

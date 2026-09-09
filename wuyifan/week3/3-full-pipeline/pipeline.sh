#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${PIPELINE_ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

HERMES_VERSION="${HERMES_VERSION:-}"
MEMORY_PLUGIN_VERSION="${MEMORY_PLUGIN_VERSION:-latest}"
SOAK_ROUNDS_VALUE="${SOAK_ROUNDS:-10}"
MEMORY_WAIT_SECONDS="${MEMORY_WAIT_SECONDS:-180}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
IMAGE_TAG="${PIPELINE_IMAGE:-}"
CONTAINER_NAME="${PIPELINE_CONTAINER:-}"
OUTPUT_DIR="${PIPELINE_OUTPUT:-}"
CLEANUP=false

usage() {
  cat <<'EOF'
用法：
  HERMES_VERSION=0.19.0 ./pipeline.sh [选项]

完整执行：build → container → plugin → gateway → soak → L0-L3 → recall。

选项：
  --version <版本>          Hermes PyPI 版本（或 HERMES_VERSION）
  --plugin-version <版本>   memory-tencentdb npm 版本，默认 latest
  --rounds <N>              记忆对话轮数，默认 10
  --wait <秒>               等待 L1-L3 的最长时间，默认 180
  --image <标签>            自定义镜像标签
  --container <名称>        自定义容器名
  --output <目录>           结果目录
  --cleanup                 结束后删除本次容器
  -h, --help                显示帮助

凭证从 .env 或环境变量读取，脚本只报告“已设置/未设置”，不会打印值。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) HERMES_VERSION="${2:-}"; shift 2 ;;
    --plugin-version) MEMORY_PLUGIN_VERSION="${2:-}"; shift 2 ;;
    --rounds) SOAK_ROUNDS_VALUE="${2:-}"; shift 2 ;;
    --wait) MEMORY_WAIT_SECONDS="${2:-}"; shift 2 ;;
    --image) IMAGE_TAG="${2:-}"; shift 2 ;;
    --container) CONTAINER_NAME="${2:-}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --cleanup) CLEANUP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 未知参数 $1" >&2; usage >&2; exit 2 ;;
  esac
done

IMAGE_TAG="${IMAGE_TAG:-hermes-week3-full:${HERMES_VERSION:-unknown}-$RUN_ID}"
CONTAINER_NAME="${CONTAINER_NAME:-hermes-week3-full-$RUN_ID}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/results/pipeline-$RUN_ID}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
SUMMARY_PATH="$OUTPUT_DIR/pipeline-summary.json"
SOAK_DIR="$OUTPUT_DIR/soak"
VERIFY_PATH="$OUTPUT_DIR/memory-verification.json"

BUILD_STATUS=not_run
CONTAINER_STATUS=not_run
PLUGIN_STATUS=not_run
GATEWAY_STATUS=not_run
SOAK_STATUS=not_run
L0_STATUS=not_run
L1_STATUS=not_run
L2_STATUS=not_run
L3_STATUS=not_run
RECALL_STATUS=not_run
FAILURE_MESSAGE=""
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_summary() {
  local overall="$1"
  node - "$SUMMARY_PATH" "$overall" "$FAILURE_MESSAGE" "$STARTED_AT" \
    "$HERMES_VERSION" "$IMAGE_TAG" "$CONTAINER_NAME" "$OUTPUT_DIR" \
    "$BUILD_STATUS" "$CONTAINER_STATUS" "$PLUGIN_STATUS" "$GATEWAY_STATUS" \
    "$SOAK_STATUS" "$L0_STATUS" "$L1_STATUS" "$L2_STATUS" "$L3_STATUS" \
    "$RECALL_STATUS" <<'NODE'
const fs = require("node:fs");
const [file, status, error, startedAt, version, image, container, outputDir,
  build, containerStage, plugin, gateway, soak, l0, l1, l2, l3, recall] =
  process.argv.slice(2);
const summary = {
  status,
  error: error || null,
  startedAt,
  endedAt: new Date().toISOString(),
  hermesVersion: version,
  image,
  container,
  outputDir,
  stages: {
    build,
    container: containerStage,
    plugin,
    gateway,
    soak,
    l0,
    l1,
    l2,
    l3,
    recall
  }
};
fs.writeFileSync(file, `${JSON.stringify(summary, null, 2)}\n`);
NODE
}

on_exit() {
  local exit_code=$?
  trap - EXIT
  local overall=fail
  (( exit_code == 0 )) && overall=pass
  if ! write_summary "$overall"; then
    echo "ERROR: 无法写入流水线汇总：$SUMMARY_PATH" >&2
    exit_code=1
  fi
  if [[ "$CLEANUP" == true ]] && docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "[cleanup] 已删除容器 $CONTAINER_NAME"
  elif docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "[cleanup] 已保留容器用于排错：$CONTAINER_NAME"
    echo "[cleanup] 手动删除：docker rm -f $CONTAINER_NAME"
  fi
  echo "[summary] $SUMMARY_PATH"
  exit "$exit_code"
}
trap on_exit EXIT

fail() {
  FAILURE_MESSAGE="$1"
  echo "ERROR: $FAILURE_MESSAGE" >&2
  return 1
}

require_value() {
  local name="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    echo "[config] $name=已设置"
  else
    echo "[config] $name=未设置"
    fail "缺少 $name"
  fi
}

[[ "$HERMES_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([A-Za-z0-9._-]*)?$ ]] || \
  fail "HERMES_VERSION 必须是类似 0.19.0 的版本号"
[[ "$MEMORY_PLUGIN_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || \
  fail "MEMORY_PLUGIN_VERSION 格式不安全"
[[ "$SOAK_ROUNDS_VALUE" =~ ^[1-9][0-9]*$ ]] || fail "--rounds 必须是正整数"
[[ "$MEMORY_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "--wait 必须是正整数"

require_value HERMES_API_KEY "${HERMES_API_KEY:-}"
require_value HERMES_BASE_URL "${HERMES_BASE_URL:-}"
require_value HERMES_MODEL "${HERMES_MODEL:-}"

TDAI_LLM_API_KEY="${TDAI_LLM_API_KEY:-$HERMES_API_KEY}"
TDAI_LLM_BASE_URL="${TDAI_LLM_BASE_URL:-$HERMES_BASE_URL}"
TDAI_LLM_MODEL="${TDAI_LLM_MODEL:-$HERMES_MODEL}"
TDAI_DATA_DIR="/home/hermes/.memory-tencentdb/memory-tdai"
TDAI_GATEWAY_CONFIG="/home/hermes/.memory-tencentdb/tdai-gateway.json"
MEMORY_TENCENTDB_GATEWAY_HOST="127.0.0.1"
MEMORY_TENCENTDB_GATEWAY_PORT="8420"
export HERMES_API_KEY HERMES_BASE_URL HERMES_MODEL
export TDAI_LLM_API_KEY TDAI_LLM_BASE_URL TDAI_LLM_MODEL
export TDAI_DATA_DIR TDAI_GATEWAY_CONFIG
export MEMORY_TENCENTDB_GATEWAY_HOST MEMORY_TENCENTDB_GATEWAY_PORT

echo "[config] TDAI_LLM_API_KEY=已设置"
echo "[config] TDAI_LLM_BASE_URL=已设置"
echo "[config] TDAI_LLM_MODEL=已设置"

command -v docker >/dev/null 2>&1 || fail "找不到 docker"
docker info >/dev/null 2>&1 || fail "Docker Engine 未运行"

echo "[1/7] 构建 Hermes $HERMES_VERSION 镜像"
docker build \
  --build-arg "HERMES_VERSION=$HERMES_VERSION" \
  -t "$IMAGE_TAG" \
  "$SCRIPT_DIR" 2>&1 | tee "$OUTPUT_DIR/build.log"
BUILD_STATUS=pass

echo "[2/7] 启动空数据容器 $CONTAINER_NAME"
docker run -d \
  --name "$CONTAINER_NAME" \
  -e HERMES_API_KEY \
  -e HERMES_BASE_URL \
  -e HERMES_MODEL \
  -e TDAI_LLM_API_KEY \
  -e TDAI_LLM_BASE_URL \
  -e TDAI_LLM_MODEL \
  -e TDAI_DATA_DIR \
  -e TDAI_GATEWAY_CONFIG \
  -e MEMORY_TENCENTDB_GATEWAY_HOST \
  -e MEMORY_TENCENTDB_GATEWAY_PORT \
  --entrypoint sleep \
  "$IMAGE_TAG" infinity >/dev/null
CONTAINER_STATUS=pass

echo "[3/7] 安装 memory-tencentdb"
"$SCRIPT_DIR/install-memory.sh" \
  --container "$CONTAINER_NAME" \
  --plugin-version "$MEMORY_PLUGIN_VERSION" \
  2>&1 | tee "$OUTPUT_DIR/plugin-install.log"
PLUGIN_STATUS=pass

echo "[4/7] 启动并等待 Gateway"
docker exec -d -u hermes "$CONTAINER_NAME" sh -c \
  'cd /home/hermes/.memory-tencentdb/tdai-memory-openclaw-plugin && exec npx tsx src/gateway/server.ts >> /home/hermes/.memory-tencentdb/gateway.log 2>&1'

HEALTH_JS='fetch("http://127.0.0.1:8420/health").then(async r=>{const x=await r.json();if(!r.ok||!["ok","degraded"].includes(x.status))process.exit(1);console.log(JSON.stringify(x))}).catch(()=>process.exit(1))'
gateway_ready=false
for _ in $(seq 1 30); do
  if docker exec "$CONTAINER_NAME" node -e "$HEALTH_JS" \
    >"$OUTPUT_DIR/gateway-health.json" 2>/dev/null; then
    gateway_ready=true
    break
  fi
  sleep 2
done
[[ "$gateway_ready" == true ]] || fail "Gateway 在 60 秒内未就绪"

docker exec -u hermes "$CONTAINER_NAME" /opt/hermes-venv/bin/python -c '
from plugins.memory import discover_memory_providers
matches = [item for item in discover_memory_providers() if item[0] == "memory_tencentdb"]
assert matches and matches[0][2] is True, f"provider unavailable: {matches}"
print(matches)
' >"$OUTPUT_DIR/provider-discovery.txt"
GATEWAY_STATUS=pass

echo "[5/7] 运行 $SOAK_ROUNDS_VALUE 轮连续记忆对话"
set +e
SOAK_ENV_FILE="$SCRIPT_DIR/.pipeline-no-env" "$SCRIPT_DIR/run-soak.sh" \
  --container "$CONTAINER_NAME" \
  --prompts "$SCRIPT_DIR/memory-prompts.json" \
  --rounds "$SOAK_ROUNDS_VALUE" \
  --interval "${SOAK_INTERVAL_MS:-1000}" \
  --duration "${SOAK_DURATION_SECONDS:-1800}" \
  --timeout "${SOAK_TIMEOUT_SECONDS:-180}" \
  --output "$SOAK_DIR" \
  2>&1 | tee "$OUTPUT_DIR/soak.log"
soak_exit=${PIPESTATUS[0]}
set -e
if (( soak_exit != 0 )); then
  SOAK_STATUS=fail
  fail "soak 对话失败，查看 $OUTPUT_DIR/soak.log"
fi
SOAK_STATUS=pass

SESSION_ID="$(node -p 'require(process.argv[1]).sessionId || ""' "$SOAK_DIR/summary.json")"
[[ -n "$SESSION_ID" ]] || fail "soak 汇总中没有 sessionId"

echo "[6/7] 刷新会话并等待 L1-L3"
FLUSH_JS='const s=process.argv[1];fetch("http://127.0.0.1:8420/session/end",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({session_key:s})}).then(async r=>{const t=await r.text();console.log(t);if(!r.ok)process.exit(1)}).catch(e=>{console.error(e.message);process.exit(1)})'
docker exec "$CONTAINER_NAME" node -e "$FLUSH_JS" "$SESSION_ID" \
  >"$OUTPUT_DIR/session-end.json"

deadline=$(( $(date +%s) + MEMORY_WAIT_SECONDS ))
verify_exit=1
while (( $(date +%s) <= deadline )); do
  set +e
  "$SCRIPT_DIR/verify-memory.sh" \
    --container "$CONTAINER_NAME" \
    --session-key "$SESSION_ID" \
    --output "$VERIFY_PATH" >"$OUTPUT_DIR/verify.log" 2>&1
  verify_exit=$?
  set -e
  (( verify_exit == 0 )) && break
  sleep 5
done

if [[ -f "$VERIFY_PATH" ]]; then
  L0_STATUS="$(node -p 'require(process.argv[1]).checks.l0.status' "$VERIFY_PATH")"
  L1_STATUS="$(node -p 'require(process.argv[1]).checks.l1.status' "$VERIFY_PATH")"
  L2_STATUS="$(node -p 'require(process.argv[1]).checks.l2.status' "$VERIFY_PATH")"
  L3_STATUS="$(node -p 'require(process.argv[1]).checks.l3.status' "$VERIFY_PATH")"
  RECALL_STATUS="$(node -p 'require(process.argv[1]).checks.recall.status' "$VERIFY_PATH")"
fi

docker cp "$CONTAINER_NAME:/home/hermes/.memory-tencentdb/gateway.log" \
  "$OUTPUT_DIR/gateway.log" >/dev/null 2>&1 || true

(( verify_exit == 0 )) || fail "L0-L3 或 recall 未在 ${MEMORY_WAIT_SECONDS} 秒内全部通过"

echo "[7/7] 完成"
echo "[result] soak=$SOAK_STATUS L0=$L0_STATUS L1=$L1_STATUS L2=$L2_STATUS L3=$L3_STATUS recall=$RECALL_STATUS"

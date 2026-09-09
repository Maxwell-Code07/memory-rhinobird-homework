#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-}"
DATA_DIR="${TDAI_DATA_DIR:-}"
GATEWAY_URL="${MEMORY_GATEWAY_URL:-http://127.0.0.1:8420}"
MARKER="${MEMORY_MARKER:-rhinobird-memory-lighthouse-0907}"
SESSION_KEY="${MEMORY_SESSION_KEY:-week3-verification}"
OUTPUT_PATH="${MEMORY_VERIFY_OUTPUT:-$SCRIPT_DIR/evidence/memory-verification.json}"

usage() {
  cat <<'EOF'
用法：
  ./verify-memory.sh --container <容器名> [选项]
  ./verify-memory.sh --data-dir <本地目录> [选项]

选项：
  --container <名称>     在 Docker 容器内检查数据并调用 Gateway
  --data-dir <目录>      L0-L3 数据根目录
  --gateway-url <URL>    Gateway 地址，默认 http://127.0.0.1:8420
  --marker <文本>        recall 验收标记
  --session-key <键>     recall 请求使用的 session_key
  --output <文件>        验证摘要 JSON 输出路径
  -h, --help             显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER_NAME="${2:-}"; shift 2 ;;
    --data-dir) DATA_DIR="${2:-}"; shift 2 ;;
    --gateway-url) GATEWAY_URL="${2:-}"; shift 2 ;;
    --marker) MARKER="${2:-}"; shift 2 ;;
    --session-key) SESSION_KEY="${2:-}"; shift 2 ;;
    --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 未知参数 $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$CONTAINER_NAME" ]]; then
  DATA_DIR="${DATA_DIR:-/home/hermes/.memory-tencentdb/memory-tdai}"
  command -v docker >/dev/null 2>&1 || { echo "ERROR: 找不到 docker" >&2; exit 1; }
  docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || {
    echo "ERROR: 容器不存在：$CONTAINER_NAME" >&2
    exit 1
  }
else
  [[ -n "$DATA_DIR" ]] || { echo "ERROR: 本地模式必须提供 --data-dir" >&2; exit 2; }
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
RECALL_FILE="$TEMP_DIR/recall.json"

count_layer_files() {
  local relative_path="$1"
  local pattern="$2"
  if [[ -n "$CONTAINER_NAME" ]]; then
    docker exec "$CONTAINER_NAME" sh -c \
      'dir="$1/$2"; pattern="$3"; test -d "$dir" || { echo 0; exit; }; find "$dir" -type f -name "$pattern" -size +0c | wc -l | tr -d " "' \
      sh "$DATA_DIR" "$relative_path" "$pattern" 2>/dev/null || echo 0
  else
    local dir="$DATA_DIR/$relative_path"
    [[ -d "$dir" ]] || { echo 0; return; }
    find "$dir" -type f -name "$pattern" -size +0c | wc -l | tr -d ' '
  fi
}

check_persona() {
  if [[ -n "$CONTAINER_NAME" ]]; then
    docker exec "$CONTAINER_NAME" test -s "$DATA_DIR/persona.md" >/dev/null 2>&1
  else
    [[ -s "$DATA_DIR/persona.md" ]]
  fi
}

L0_COUNT="$(count_layer_files conversations '*.jsonl')"
L1_COUNT="$(count_layer_files records '*.jsonl')"
L2_COUNT="$(count_layer_files scene_blocks '*.md')"
L3_COUNT=0
check_persona && L3_COUNT=1

L0_STATUS=fail; [[ "$L0_COUNT" =~ ^[0-9]+$ ]] && (( L0_COUNT > 0 )) && L0_STATUS=pass
L1_STATUS=fail; [[ "$L1_COUNT" =~ ^[0-9]+$ ]] && (( L1_COUNT > 0 )) && L1_STATUS=pass
L2_STATUS=fail; [[ "$L2_COUNT" =~ ^[0-9]+$ ]] && (( L2_COUNT > 0 )) && L2_STATUS=pass
L3_STATUS=fail; (( L3_COUNT > 0 )) && L3_STATUS=pass

RECALL_STATUS=fail
RECALL_REASON="request_failed"
RECALL_NODE='const [url,marker,sessionKey]=process.argv.slice(1); fetch(url+"/recall",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({query:marker,session_key:sessionKey})}).then(async r=>{const text=await r.text(); if(!r.ok) throw new Error(`HTTP ${r.status}: ${text}`); process.stdout.write(text)}).catch(e=>{console.error(e.message);process.exit(1)})'

if [[ -n "$CONTAINER_NAME" ]]; then
  docker exec "$CONTAINER_NAME" node -e "$RECALL_NODE" \
    "$GATEWAY_URL" "$MARKER" "$SESSION_KEY" >"$RECALL_FILE" 2>/dev/null
  RECALL_EXIT=$?
else
  node -e "$RECALL_NODE" "$GATEWAY_URL" "$MARKER" "$SESSION_KEY" \
    >"$RECALL_FILE" 2>/dev/null
  RECALL_EXIT=$?
fi

if (( RECALL_EXIT == 0 )); then
  if node - "$RECALL_FILE" "$MARKER" <<'NODE'
const fs = require("node:fs");
const [file, marker] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, "utf8"));
const body = JSON.stringify(data);
const success = (data.code === undefined || data.code === 0) &&
  (Number(data.memory_count ?? 0) > 0 || String(data.context ?? "").trim() !== "") &&
  body.includes(marker);
process.exit(success ? 0 : 1);
NODE
  then
    RECALL_STATUS=pass
    RECALL_REASON="marker_found"
  else
    RECALL_REASON="marker_not_found"
  fi
fi

OVERALL_STATUS=pass
for status in "$L0_STATUS" "$L1_STATUS" "$L2_STATUS" "$L3_STATUS" "$RECALL_STATUS"; do
  [[ "$status" == pass ]] || OVERALL_STATUS=fail
done

node - "$OUTPUT_PATH" "$OVERALL_STATUS" "$DATA_DIR" \
  "$L0_STATUS" "$L0_COUNT" "$L1_STATUS" "$L1_COUNT" \
  "$L2_STATUS" "$L2_COUNT" "$L3_STATUS" "$L3_COUNT" \
  "$RECALL_STATUS" "$RECALL_REASON" "$MARKER" "$SESSION_KEY" <<'NODE'
const fs = require("node:fs");
const [output, status, dataDir, l0s, l0c, l1s, l1c, l2s, l2c,
  l3s, l3c, recalls, recallReason, marker, sessionKey] = process.argv.slice(2);
const result = {
  status,
  checkedAt: new Date().toISOString(),
  dataDir,
  marker,
  sessionKey,
  checks: {
    l0: { status: l0s, nonEmptyFiles: Number(l0c), path: `${dataDir}/conversations/*.jsonl` },
    l1: { status: l1s, nonEmptyFiles: Number(l1c), path: `${dataDir}/records/*.jsonl` },
    l2: { status: l2s, nonEmptyFiles: Number(l2c), path: `${dataDir}/scene_blocks/*.md` },
    l3: { status: l3s, nonEmptyFiles: Number(l3c), path: `${dataDir}/persona.md` },
    recall: { status: recalls, reason: recallReason }
  }
};
fs.writeFileSync(output, `${JSON.stringify(result, null, 2)}\n`);
NODE

printf '%-8s %-4s %s\n' 'L0' "$L0_STATUS" "files=$L0_COUNT"
printf '%-8s %-4s %s\n' 'L1' "$L1_STATUS" "files=$L1_COUNT"
printf '%-8s %-4s %s\n' 'L2' "$L2_STATUS" "files=$L2_COUNT"
printf '%-8s %-4s %s\n' 'L3' "$L3_STATUS" "files=$L3_COUNT"
printf '%-8s %-4s %s\n' 'recall' "$RECALL_STATUS" "$RECALL_REASON"
echo "summary=$OUTPUT_PATH"

[[ "$OVERALL_STATUS" == pass ]]

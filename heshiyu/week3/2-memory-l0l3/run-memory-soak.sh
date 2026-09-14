#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
ROUNDS_OVERRIDE=""
INTERVAL_OVERRIDE=""
DURATION_OVERRIDE=""
OUTPUT_OVERRIDE=""
DATA_DIR_OVERRIDE=""
GATEWAY_OVERRIDE=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || { echo "--env requires a file path" >&2; exit 2; }
      ENV_FILE="$2"
      shift 2
      ;;
    --rounds)
      [[ $# -ge 2 ]] || { echo "--rounds requires a value" >&2; exit 2; }
      ROUNDS_OVERRIDE="$2"
      shift 2
      ;;
    --interval)
      [[ $# -ge 2 ]] || { echo "--interval requires a value" >&2; exit 2; }
      INTERVAL_OVERRIDE="$2"
      shift 2
      ;;
    --duration)
      [[ $# -ge 2 ]] || { echo "--duration requires a value" >&2; exit 2; }
      DURATION_OVERRIDE="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a directory" >&2; exit 2; }
      OUTPUT_OVERRIDE="$2"
      shift 2
      ;;
    --data-dir)
      [[ $# -ge 2 ]] || { echo "--data-dir requires a directory" >&2; exit 2; }
      DATA_DIR_OVERRIDE="$2"
      shift 2
      ;;
    --gateway-url)
      [[ $# -ge 2 ]] || { echo "--gateway-url requires a URL" >&2; exit 2; }
      GATEWAY_OVERRIDE="$2"
      shift 2
      ;;
    --smoke)
      ROUNDS_OVERRIDE=2
      DURATION_OVERRIDE=5m
      shift
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: bash ./run-memory-soak.sh [options]

  --rounds <N>         Conversation rounds (default: 6)
  --interval <time>    Delay between rounds (default: 1s)
  --duration <time>    Total time limit (default: 15m)
  --data-dir <dir>     memory-tdai data directory
  --gateway-url <url>  Memory Gateway URL (default: http://127.0.0.1:8420)
  --output <dir>       Result directory
  --env <file>         Load a custom env file
  --smoke              Run two rounds with a five-minute limit
USAGE
      exit 0
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ -f "$ENV_FILE" ]]; then
  echo "Loading environment from: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
elif [[ "$ENV_FILE" != "$SCRIPT_DIR/.env" ]]; then
  echo "Environment file not found: $ENV_FILE" >&2
  exit 2
fi

command -v node >/dev/null 2>&1 || { echo "Node.js was not found in PATH." >&2; exit 1; }
HERMES_BIN="${HERMES_COMMAND:-hermes}"
command -v "$HERMES_BIN" >/dev/null 2>&1 || { echo "Hermes command was not found: $HERMES_BIN" >&2; exit 1; }

for name in HERMES_SOAK_BASE_URL HERMES_SOAK_MODEL HERMES_SOAK_API_KEY; do
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required. Set it in $ENV_FILE or export it." >&2
    exit 1
  fi
done

ROUNDS="${ROUNDS_OVERRIDE:-${SOAK_ROUNDS:-6}}"
INTERVAL="${INTERVAL_OVERRIDE:-${SOAK_INTERVAL:-1s}}"
DURATION="${DURATION_OVERRIDE:-${SOAK_DURATION:-15m}}"
DATA_DIR="${DATA_DIR_OVERRIDE:-${TDAI_DATA_DIR:-}}"
GATEWAY_URL="${GATEWAY_OVERRIDE:-${MEMORY_GATEWAY_URL:-http://127.0.0.1:8420}}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${OUTPUT_OVERRIDE:-${MEMORY_SOAK_OUTPUT_DIR:-$SCRIPT_DIR/results/memory-$STAMP}}"

[[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || { echo "--rounds must be a positive integer" >&2; exit 2; }
[[ -n "$DATA_DIR" ]] || { echo "TDAI_DATA_DIR or --data-dir is required" >&2; exit 1; }
[[ -d "$DATA_DIR" ]] || { echo "Memory data directory was not found: $DATA_DIR" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"

EXPECTED_VERSION_ARGS=()
if [[ -n "${HERMES_EXPECTED_VERSION:-}" ]]; then
  EXPECTED_VERSION_ARGS+=(--expected-version "$HERMES_EXPECTED_VERSION")
fi

GATEWAY_URL="${GATEWAY_URL%/}"
node --input-type=module -e '
const url = process.argv[1] + "/health";
try {
  const response = await fetch(url, { signal: AbortSignal.timeout(5000) });
  const body = await response.json();
  if (!response.ok || !["ok", "degraded"].includes(body.status)) process.exit(1);
  console.log("Gateway health:", JSON.stringify(body));
} catch (error) {
  console.error("Memory Gateway is unavailable:", error.message);
  process.exit(1);
}
' "$GATEWAY_URL"

echo "Starting Week3 L0-L3 memory soak"
echo "  Rounds:   $ROUNDS"
echo "  Interval: $INTERVAL"
echo "  Duration: $DURATION"
echo "  Data:     $DATA_DIR"
echo "  Gateway:  $GATEWAY_URL"
echo "  Output:   $OUTPUT_DIR"
echo

set +e
node "$SCRIPT_DIR/hermes-standalone-soak.mjs" \
  --hermes "$HERMES_BIN" \
  --rounds "$ROUNDS" \
  --interval "$INTERVAL" \
  --duration "$DURATION" \
  --round-timeout "${SOAK_ROUND_TIMEOUT:-180s}" \
  "${EXPECTED_VERSION_ARGS[@]}" \
  --scenario "$SCRIPT_DIR/scenarios/memory-soak.json" \
  --session "week3-memory-$STAMP" \
  --output "$OUTPUT_DIR/soak" \
  --round-retries "${SOAK_ROUND_RETRIES:-2}" \
  --memory-probe-every "$ROUNDS" \
  --probe-mode gateway \
  --gateway-url "$GATEWAY_URL" \
  --probe-wait "${SOAK_PROBE_WAIT:-300s}" \
  --probe-poll "${SOAK_PROBE_POLL:-3s}" \
  "${EXTRA_ARGS[@]}"
SOAK_CODE=$?

node "$SCRIPT_DIR/verify-memory.mjs" \
  --data-dir "$DATA_DIR" \
  --gateway-url "$GATEWAY_URL" \
  --session-key "week3-independent-$STAMP" \
  --expect LinXiao \
  --expect Python \
  --expect PowerShell \
  --wait "${MEMORY_VERIFY_WAIT:-240s}" \
  --poll "${MEMORY_VERIFY_POLL:-3s}" \
  --output "$OUTPUT_DIR/memory-verification.json"
MEMORY_CODE=$?
set -e

SOAK_CODE="$SOAK_CODE" MEMORY_CODE="$MEMORY_CODE" OUTPUT_DIR="$OUTPUT_DIR" node --input-type=module -e '
import { writeFileSync } from "node:fs";
import { join } from "node:path";
const soak = Number(process.env.SOAK_CODE);
const memory = Number(process.env.MEMORY_CODE);
const passed = soak === 0 && memory === 0;
const result = {
  status: passed ? "pass" : "fail",
  passed,
  soak_exit_code: soak,
  memory_verification_exit_code: memory,
  completed_at: new Date().toISOString(),
};
writeFileSync(join(process.env.OUTPUT_DIR, "memory-run-meta.json"), JSON.stringify(result, null, 2) + "\n");
console.log(JSON.stringify(result, null, 2));
'

if [[ "$SOAK_CODE" -eq 0 && "$MEMORY_CODE" -eq 0 ]]; then
  echo "Memory soak result: PASS"
  exit 0
fi

echo "Memory soak result: FAIL" >&2
exit 1

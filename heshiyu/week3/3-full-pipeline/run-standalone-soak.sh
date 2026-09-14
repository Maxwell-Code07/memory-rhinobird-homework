#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
EXTRA_ARGS=()
SMOKE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || { echo "--env requires a file path" >&2; exit 2; }
      ENV_FILE="$2"
      shift 2
      ;;
    --smoke)
      SMOKE=1
      shift
      ;;
    --help|-h)
      exec node "$SCRIPT_DIR/hermes-standalone-soak.mjs" --help
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

for name in HERMES_SOAK_BASE_URL HERMES_SOAK_MODEL HERMES_SOAK_API_KEY; do
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required. Set it in $ENV_FILE or export it." >&2
    exit 1
  fi
done

STAMP="$(date +%Y%m%d-%H%M%S)"
ROUNDS="${SOAK_ROUNDS:-6}"
DURATION="${SOAK_DURATION:-15m}"
if [[ "$SMOKE" -eq 1 ]]; then
  ROUNDS=2
  DURATION=5m
fi

DEFAULT_ARGS=(
  --rounds "$ROUNDS"
  --interval "${SOAK_INTERVAL:-1s}"
  --duration "$DURATION"
  --round-timeout "${SOAK_ROUND_TIMEOUT:-180s}"
  --scenario "${SOAK_SCENARIO:-$SCRIPT_DIR/scenarios/memory-soak.json}"
  --output "${SOAK_OUTPUT_DIR:-$SCRIPT_DIR/results/soak-$STAMP}"
  --round-retries "${SOAK_ROUND_RETRIES:-2}"
)

if [[ -n "${HERMES_EXPECTED_VERSION:-}" ]]; then
  DEFAULT_ARGS+=(--expected-version "$HERMES_EXPECTED_VERSION")
fi
if [[ -n "${SOAK_LOG_FILE:-}" ]]; then
  DEFAULT_ARGS+=(--log-file "$SOAK_LOG_FILE")
fi

echo "Starting Hermes standalone soak"
echo "  Rounds:   $ROUNDS"
echo "  Interval: ${SOAK_INTERVAL:-1s}"
echo "  Duration: $DURATION"
echo

exec node "$SCRIPT_DIR/hermes-standalone-soak.mjs" "${DEFAULT_ARGS[@]}" "${EXTRA_ARGS[@]}"

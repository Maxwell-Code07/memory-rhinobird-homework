#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
EXTRA_ARGS=()
INVALID_API_KEY=0
ROUNDS_OVERRIDE=""
INTERVAL_OVERRIDE=""
DURATION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || { echo "--env requires a file path" >&2; exit 2; }
      ENV_FILE="$2"
      shift 2
      ;;
    --smoke)
      ROUNDS_OVERRIDE=2
      DURATION_OVERRIDE=5m
      shift
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
    --invalid-api-key)
      INVALID_API_KEY=1
      shift
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: bash ./run-basic-soak.sh [options]

  --env <file>          Load a custom env file
  --smoke               Run two rounds with a five-minute limit
  --invalid-api-key     Demonstrate authentication failure handling
  --help                Show this help

Other options are passed to hermes-standalone-soak.mjs, including:
  --rounds <N> --interval <time> --duration <time> --output <dir>
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

for name in HERMES_SOAK_BASE_URL HERMES_SOAK_MODEL; do
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required. Set it in $ENV_FILE or export it." >&2
    exit 1
  fi
done

if [[ "$INVALID_API_KEY" -eq 1 ]]; then
  export HERMES_SOAK_API_KEY="week3-intentionally-invalid-api-key"
elif [[ -z "${HERMES_SOAK_API_KEY:-}" ]]; then
  echo "HERMES_SOAK_API_KEY is required. Set it in $ENV_FILE or export it." >&2
  exit 1
fi

ROUNDS="${ROUNDS_OVERRIDE:-${SOAK_ROUNDS:-6}}"
INTERVAL="${INTERVAL_OVERRIDE:-${SOAK_INTERVAL:-1s}}"
DURATION="${DURATION_OVERRIDE:-${SOAK_DURATION:-10m}}"
if [[ "$INVALID_API_KEY" -eq 1 ]]; then
  ROUNDS=1
  INTERVAL=0s
  DURATION=3m
fi
[[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || { echo "--rounds must be a positive integer" >&2; exit 2; }

# Use a task-local Hermes home so the basic test does not overwrite the
# user's normal Hermes config or accidentally enable a memory provider.
BASIC_HOME="${BASIC_SOAK_HOME:-$SCRIPT_DIR/.runtime/hermes-home}"
mkdir -p "$BASIC_HOME"
cp "$SCRIPT_DIR/config/hermes-basic-soak.yaml" "$BASIC_HOME/config.yaml"
export HERMES_HOME="$BASIC_HOME"
export HERMES_WRITE_SAFE_ROOT="$BASIC_HOME"

STAMP="$(date +%Y%m%d-%H%M%S)"
DEFAULT_ARGS=(
  --hermes "$HERMES_BIN"
  --rounds "$ROUNDS"
  --interval "$INTERVAL"
  --duration "$DURATION"
  --round-timeout "${SOAK_ROUND_TIMEOUT:-180s}"
  --scenario "$SCRIPT_DIR/scenarios/basic-soak.json"
  --output "${SOAK_OUTPUT_DIR:-$SCRIPT_DIR/results/basic-$STAMP}"
  --round-retries "${SOAK_ROUND_RETRIES:-2}"
  --memory-probe-every 0
)

if [[ -n "${HERMES_EXPECTED_VERSION:-}" ]]; then
  DEFAULT_ARGS+=(--expected-version "$HERMES_EXPECTED_VERSION")
fi

if [[ "$INVALID_API_KEY" -eq 1 ]]; then
  DEFAULT_ARGS+=(
    --transport oneshot
    --max-consecutive-failures 1
    --round-retries 0
  )
fi

echo "Starting Week3 basic Hermes soak"
echo "  Rounds:   $ROUNDS"
echo "  Interval: $INTERVAL"
echo "  Duration: $DURATION"
echo "  Negative: $([[ "$INVALID_API_KEY" -eq 1 ]] && echo yes || echo no)"
echo

exec node "$SCRIPT_DIR/hermes-standalone-soak.mjs" "${DEFAULT_ARGS[@]}" "${EXTRA_ARGS[@]}"

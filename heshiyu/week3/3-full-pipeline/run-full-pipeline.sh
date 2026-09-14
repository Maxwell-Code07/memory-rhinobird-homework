#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
EXTRA_ARGS=()
CLI_HERMES_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || { echo "--env requires a file path" >&2; exit 2; }
      ENV_FILE="$2"
      shift 2
      ;;
    --smoke)
      EXTRA_ARGS+=(--rounds 2 --duration 5m)
      shift
      ;;
    --hermes-version)
      [[ $# -ge 2 ]] || { echo "--hermes-version requires a value" >&2; exit 2; }
      CLI_HERMES_VERSION="$2"
      EXTRA_ARGS+=(--hermes-version "$2")
      shift 2
      ;;
    --help|-h)
      EXTRA_ARGS+=(--help)
      shift
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

if [[ -n "${PYTHON_BIN:-}" ]]; then
  PYTHON_CMD="$PYTHON_BIN"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
  PYTHON_CMD=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; raise SystemExit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
  PYTHON_CMD=python
else
  echo "Python 3.9 or newer was not found in PATH." >&2
  exit 1
fi

echo "Starting Week3 full memory pipeline"
echo "  Hermes version: ${CLI_HERMES_VERSION:-${HERMES_VERSION:-0.20.6}}"
echo "  Gateway port:   ${MEMORY_GATEWAY_PORT:-8473}"
echo "  Rounds:         ${SOAK_ROUNDS:-6}"
echo "  Interval:       ${SOAK_INTERVAL:-1s}"
echo "  Duration:       ${SOAK_DURATION:-15m}"
echo

exec "$PYTHON_CMD" "$SCRIPT_DIR/pipeline.py" --env-file "$ENV_FILE" "${EXTRA_ARGS[@]}"

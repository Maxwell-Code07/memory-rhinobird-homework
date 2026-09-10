#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SOAK_ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

PROMPTS_PATH="${SOAK_PROMPTS:-$SCRIPT_DIR/prompts.json}"
if [[ "$PROMPTS_PATH" != /* ]]; then
  PROMPTS_PATH="$SCRIPT_DIR/${PROMPTS_PATH#./}"
fi

DEFAULT_ARGS=(
  --rounds "${SOAK_ROUNDS:-10}"
  --interval "${SOAK_INTERVAL_MS:-1000}"
  --duration "${SOAK_DURATION_SECONDS:-300}"
  --timeout "${SOAK_TIMEOUT_SECONDS:-120}"
  --max-consecutive-failures "${SOAK_MAX_CONSECUTIVE_FAILURES:-3}"
  --prompts "$PROMPTS_PATH"
  --hermes-command "${HERMES_COMMAND:-hermes}"
)

if [[ -n "${SOAK_OUTPUT:-}" ]]; then
  OUTPUT_PATH="$SOAK_OUTPUT"
  if [[ "$OUTPUT_PATH" != /* ]]; then
    OUTPUT_PATH="$SCRIPT_DIR/${OUTPUT_PATH#./}"
  fi
  DEFAULT_ARGS+=(--output "$OUTPUT_PATH")
fi

exec node "$SCRIPT_DIR/hermes-soak.mjs" "${DEFAULT_ARGS[@]}" "$@"

#!/usr/bin/env sh
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/hermes-home}"
INSTALL_DIR="${TDAI_INSTALL_DIR:-$HERMES_HOME/tdai-memory-plugin}"
LOG_FILE="${GATEWAY_LOG_FILE:-/workspace/advanced/evidence/gateway.log}"

set -a
. "$HERMES_HOME/.env"
set +a

cd "$INSTALL_DIR"
exec node --import tsx/esm src/gateway/server.ts >>"$LOG_FILE" 2>&1


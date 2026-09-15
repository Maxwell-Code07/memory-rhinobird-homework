#!/usr/bin/env bash

set -euo pipefail

PACKAGE_SPEC="${MEMORY_PACKAGE_SPEC:-@tencentdb-agent-memory/memory-tencentdb@1.0.1}"
INSTALL_DIR="${TDAI_INSTALL_DIR:-/workspace/.memory-tencentdb/tdai-memory-openclaw-plugin}"
DATA_DIR="${TDAI_DATA_DIR:-/opt/data/.memory-tencentdb/memory-tdai}"
HERMES_SOURCE_DIR="${HERMES_AGENT_DIR:-/opt/hermes}"
HERMES_CONFIG="${HERMES_HOME:-/opt/data}/config.yaml"
CONFIG_SOURCE="${HERMES_CONFIG_SOURCE:-/week3/config/hermes-config.yaml}"
PLUGIN_SOURCE_REL="hermes-plugin/memory/memory_tencentdb"
PLUGIN_TARGET="$HERMES_SOURCE_DIR/plugins/memory/memory_tencentdb"

case "$INSTALL_DIR" in
  /workspace/.memory-tencentdb/*) ;;
  *) echo "Unsafe TDAI_INSTALL_DIR: $INSTALL_DIR" >&2; exit 1 ;;
esac
case "$PLUGIN_TARGET" in
  /opt/hermes/plugins/memory/*) ;;
  *) echo "Unsafe Hermes plugin target: $PLUGIN_TARGET" >&2; exit 1 ;;
esac

command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "npm is required" >&2; exit 1; }
[[ -d "$HERMES_SOURCE_DIR" ]] || { echo "Hermes source not found: $HERMES_SOURCE_DIR" >&2; exit 1; }
[[ -f "$CONFIG_SOURCE" ]] || { echo "Hermes config not found: $CONFIG_SOURCE" >&2; exit 1; }

TEMP_DOWNLOAD="$(mktemp -d /tmp/week3-memory-install-XXXXXX)"
cleanup() {
  rm -rf -- "$TEMP_DOWNLOAD"
}
trap cleanup EXIT

echo "[install-memory] package=$PACKAGE_SPEC"
echo "[install-memory] install_dir=$INSTALL_DIR"
echo "[install-memory] data_dir=$DATA_DIR"

cd "$TEMP_DOWNLOAD"
npm init -y --silent >/dev/null 2>&1
npm install "$PACKAGE_SPEC" --omit=dev --legacy-peer-deps

PACKAGE_DIR="$TEMP_DOWNLOAD/node_modules/@tencentdb-agent-memory/memory-tencentdb"
[[ -d "$PACKAGE_DIR" ]] || { echo "Downloaded package directory is missing" >&2; exit 1; }

rm -rf -- "$INSTALL_DIR"
mkdir -p "$(dirname "$INSTALL_DIR")"
cp -a "$PACKAGE_DIR" "$INSTALL_DIR"

# npm installs dependencies at the temporary project root. Copy that resolved
# dependency tree next to the extracted package instead of running the
# package's OpenClaw-only postinstall hook a second time.
mkdir -p "$INSTALL_DIR/node_modules"
cp -a "$TEMP_DOWNLOAD/node_modules/." "$INSTALL_DIR/node_modules/"
rm -rf -- "$INSTALL_DIR/node_modules/@tencentdb-agent-memory/memory-tencentdb"

PLUGIN_SOURCE="$INSTALL_DIR/$PLUGIN_SOURCE_REL"
for required in __init__.py plugin.yaml client.py supervisor.py; do
  [[ -f "$PLUGIN_SOURCE/$required" ]] || {
    echo "Missing Hermes provider file: $PLUGIN_SOURCE/$required" >&2
    exit 1
  }
done

rm -rf -- "$PLUGIN_TARGET"
mkdir -p "$PLUGIN_TARGET"
cp -a "$PLUGIN_SOURCE/." "$PLUGIN_TARGET/"

mkdir -p "$DATA_DIR/conversations" "$DATA_DIR/records" "$DATA_DIR/scene_blocks"
install -m 0644 "$CONFIG_SOURCE" "$HERMES_CONFIG"

if id hermes >/dev/null 2>&1; then
  chown -R hermes:hermes "$INSTALL_DIR" "$DATA_DIR" "${HERMES_HOME:-/opt/data}"
  if [[ -d "${NPM_CONFIG_CACHE:-/opt/npm-cache}" ]]; then
    chown -R hermes:hermes "${NPM_CONFIG_CACHE:-/opt/npm-cache}"
  fi
fi

[[ -f "$INSTALL_DIR/src/gateway/server.ts" ]] || {
  echo "Gateway entry point is missing" >&2
  exit 1
}
[[ -d "$INSTALL_DIR/node_modules" ]] || {
  echo "Gateway dependencies are missing" >&2
  exit 1
}

echo "[install-memory] PASS"

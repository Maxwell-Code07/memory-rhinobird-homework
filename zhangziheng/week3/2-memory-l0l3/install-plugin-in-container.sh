#!/usr/bin/env sh
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/hermes-home}"
HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-/opt/hermes}"
SOURCE_DIR="${TDAI_SOURCE_DIR:-/source/tdai}"
INSTALL_DIR="${TDAI_INSTALL_DIR:-$HERMES_HOME/tdai-memory-plugin}"
DATA_DIR="${TDAI_DATA_DIR:-/opt/tdai-data}"
ADVANCED_DIR="${ADVANCED_DIR:-/workspace/advanced}"

test -f "$SOURCE_DIR/package.json"
test -f "$SOURCE_DIR/hermes-plugin/memory/memory_tencentdb/plugin.yaml"
test -f "$ADVANCED_DIR/tdai-gateway.yaml"
test -f "$HERMES_HOME/config.yaml"

mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$HERMES_HOME/plugins"

if [ ! -f "$INSTALL_DIR/package.json" ]; then
  tar --exclude=node_modules --exclude=.git -C "$SOURCE_DIR" -cf - . | tar -C "$INSTALL_DIR" -xf -
fi

cd "$INSTALL_DIR"
if [ "${TDAI_SKIP_NPM_INSTALL:-0}" = "1" ]; then
  test -d node_modules
  printf '%s\n' "Skipping npm ci (offline dependencies supplied)"
else
  if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
    npm ci --omit=dev
  else
    printf '%s\n' "No npm lockfile found; falling back to npm install --omit=dev --legacy-peer-deps"
    npm install --omit=dev --legacy-peer-deps
  fi
fi
cp "$ADVANCED_DIR/tdai-gateway.yaml" "$INSTALL_DIR/tdai-gateway.yaml"

ln -sfn "$INSTALL_DIR/hermes-plugin/memory/memory_tencentdb" \
  "$HERMES_HOME/plugins/memory_tencentdb"

/opt/hermes-venv/bin/python - <<'PY'
import os
from pathlib import Path
import yaml

home = Path(os.environ.get("HERMES_HOME", "/opt/hermes-home"))
config_path = home / "config.yaml"
with config_path.open(encoding="utf-8") as handle:
    config = yaml.safe_load(handle) or {}
memory = config.setdefault("memory", {})
memory["memory_enabled"] = True
memory["user_profile_enabled"] = True
memory["provider"] = "memory_tencentdb"
with config_path.open("w", encoding="utf-8") as handle:
    yaml.safe_dump(config, handle, allow_unicode=True, sort_keys=False)
PY

/opt/hermes-venv/bin/python - <<'PY'
import os
from pathlib import Path

home = Path(os.environ.get("HERMES_HOME", "/opt/hermes-home"))
env_path = home / ".env"
lines = env_path.read_text(encoding="utf-8").splitlines() if env_path.exists() else []
updates = {
    "MEMORY_TENCENTDB_GATEWAY_CMD": f"node --import tsx/esm {home}/tdai-memory-plugin/src/gateway/server.ts",
    "MEMORY_TENCENTDB_GATEWAY_HOST": "127.0.0.1",
    "MEMORY_TENCENTDB_GATEWAY_PORT": "8420",
    "MEMORY_TENCENTDB_LOG_DIR": "/workspace/advanced/evidence/provider-logs",
    "TDAI_DATA_DIR": "/opt/tdai-data",
    "TDAI_GATEWAY_HOST": "127.0.0.1",
    "TDAI_GATEWAY_PORT": "8420",
}
kept = [line for line in lines if line.partition("=")[0].strip() not in updates]
for key, value in updates.items():
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    kept.append(f'{key}="{escaped}"')
env_path.write_text("\n".join(kept) + "\n", encoding="utf-8")
PY

mkdir -p "$ADVANCED_DIR/evidence/provider-logs"

cd "$HERMES_AGENT_DIR"
/opt/hermes-venv/bin/python - <<'PY'
from plugins.memory import discover_memory_providers

providers = {name: available for name, _, available in discover_memory_providers()}
if "memory_tencentdb" not in providers:
    raise SystemExit(f"memory_tencentdb discovery failed: {providers}")
print(f"memory_tencentdb discovered (available={providers['memory_tencentdb']})")
PY

printf '%s\n' "Plugin install complete"
printf 'install_dir=%s\n' "$INSTALL_DIR"
printf 'data_dir=%s\n' "$DATA_DIR"
printf 'provider=%s\n' "memory_tencentdb"

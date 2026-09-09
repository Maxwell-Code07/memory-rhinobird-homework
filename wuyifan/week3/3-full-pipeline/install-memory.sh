#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-}"
PLUGIN_VERSION="${MEMORY_PLUGIN_VERSION:-latest}"

usage() {
  cat <<'EOF'
用法：
  ./install-memory.sh --container <容器名> [--plugin-version <版本>]

作用：
  在一个正在运行的 Hermes 容器中安装 memory-tencentdb Gateway 与
  memory_tencentdb provider，并写入本目录自带的 Hermes/Gateway 配置。

选项：
  --container <名称>       目标 Docker 容器（也可用 CONTAINER_NAME）
  --plugin-version <版本>  npm 插件版本，默认 latest
  -h, --help               显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container)
      [[ $# -ge 2 ]] || { echo "ERROR: --container 缺少值" >&2; exit 2; }
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --plugin-version)
      [[ $# -ge 2 ]] || { echo "ERROR: --plugin-version 缺少值" >&2; exit 2; }
      PLUGIN_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: 未知参数 $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$CONTAINER_NAME" ]] || { echo "ERROR: 必须提供 --container" >&2; exit 2; }
[[ "$PLUGIN_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "ERROR: 插件版本格式不安全：$PLUGIN_VERSION" >&2
  exit 2
}
command -v docker >/dev/null 2>&1 || { echo "ERROR: 找不到 docker" >&2; exit 1; }
docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || {
  echo "ERROR: 容器不存在：$CONTAINER_NAME" >&2
  exit 1
}
[[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" == "true" ]] || {
  echo "ERROR: 容器未运行：$CONTAINER_NAME" >&2
  exit 1
}

echo "[plugin] 安装 @tencentdb-agent-memory/memory-tencentdb@$PLUGIN_VERSION"
docker exec -i -u root "$CONTAINER_NAME" sh -s -- "$PLUGIN_VERSION" <<'CONTAINER_SCRIPT'
set -eu
version="$1"
package='@tencentdb-agent-memory/memory-tencentdb'
root='/home/hermes/.memory-tencentdb'
plugin_dir="$root/tdai-memory-openclaw-plugin"
provider_dir='/home/hermes/.hermes/plugins/memory_tencentdb'
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cd "$work_dir"
npm init -y --silent >/dev/null
installed=false
for attempt in 1 2 3; do
  if npm install "${package}@${version}" --omit=dev --no-audit --no-fund; then
    installed=true
    break
  fi
  if [ "$attempt" -lt 3 ]; then
    wait_seconds=$((attempt * 5))
    echo "[plugin] npm 下载失败，第 $attempt 次重试将在 ${wait_seconds}s 后开始" >&2
    sleep "$wait_seconds"
  fi
done
[ "$installed" = true ] || { echo "[plugin] npm 安装连续失败 3 次" >&2; exit 1; }

rm -rf "$plugin_dir" "$provider_dir"
mkdir -p "$plugin_dir" "$(dirname "$provider_dir")"
cp -R node_modules/@tencentdb-agent-memory/memory-tencentdb/. "$plugin_dir/"
mv node_modules "$plugin_dir/node_modules"
test -x "$plugin_dir/node_modules/.bin/tsx"

cp -R "$plugin_dir/hermes-plugin/memory/memory_tencentdb" "$provider_dir"
test -f "$provider_dir/__init__.py"
test -f "$provider_dir/plugin.yaml"
test -f "$plugin_dir/src/gateway/server.ts"
chown -R hermes:hermes /home/hermes/.memory-tencentdb /home/hermes/.hermes
CONTAINER_SCRIPT

docker cp "$SCRIPT_DIR/tdai-gateway.json" \
  "$CONTAINER_NAME:/tmp/tdai-gateway.json" >/dev/null
docker cp "$SCRIPT_DIR/hermes-config.yaml.example" \
  "$CONTAINER_NAME:/tmp/hermes-config.yaml" >/dev/null

docker exec -u root "$CONTAINER_NAME" sh -c '
  set -eu
  mkdir -p /home/hermes/.hermes /home/hermes/.memory-tencentdb/memory-tdai
  mv /tmp/tdai-gateway.json /home/hermes/.memory-tencentdb/tdai-gateway.json
  mv /tmp/hermes-config.yaml /home/hermes/.hermes/config.yaml
  chown -R hermes:hermes /home/hermes/.hermes /home/hermes/.memory-tencentdb
'

docker exec -u hermes "$CONTAINER_NAME" /opt/hermes-venv/bin/python -c '
from plugins.memory import _iter_provider_dirs
names = [name for name, _ in _iter_provider_dirs()]
assert "memory_tencentdb" in names, f"provider not discovered: {names}"
print("[provider] discovered: memory_tencentdb")
'

echo "[plugin] 安装完成"

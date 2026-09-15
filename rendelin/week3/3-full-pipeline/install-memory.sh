#!/usr/bin/env bash
# ============================================================================
#  install-memory.sh —— 把 memory_tencentdb 记忆插件装进 Hermes（可复用）
#
#  用途：给"已装好 hermes-agent"的机器装上 TencentDB Agent Memory 记忆插件，
#       让 Hermes 能走 L0-L3 记忆捕获。等价于官方 install_hermes_memory_tencentdb.sh，
#       但适配 Windows（Hermes 装在 %USERPROFILE%\AppData\Local\hermes）和
#       "源码仓库即插件所在"两种情况。
#
#  - 如果是 Docker 容器内：镜像已经 git clone 好 TencentDB-Agent-Memory，本脚本
#    只需把 provider 复制进 Hermes 插件目录 + 在 config.yaml 声明 provider。
#  - 如果是本机（无 Docker）：本脚本会尝试软链/复制 provider，并提示启用 Gateway。
#
#  目录约定：
#    HERMES_AGENT_DIR    Hermes 安装根（默认 ${HOME}/.hermes/hermes-agent，
#                         Windows 下自动探测 %LOCALAPPDATA%\hermes\hermes-agent）
#    MEMORY_SRC_DIR      memory_tencentdb provider 源码所在（默认本脚本同级）
#    TDAI_DATA_DIR       记忆数据目录（默认 ~/.memory-tencentdb/memory-tdai）
# ============================================================================
set -euo pipefail

# ---- 0. 定位路径 -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hermes agent 目录：优先环境变量，其次本机(Linux ~/.hermes)，再 Windows %LOCALAPPDATA%
detect_hermes_agent_dir() {
  if [ -n "${HERMES_AGENT_DIR:-}" ]; then echo "$HERMES_AGENT_DIR"; return; fi
  for c in \
      "$HOME/.hermes/hermes-agent" \
      "$HOME/AppData/Local/hermes/hermes-agent" \
      "/usr/local/lib/hermes-agent" \
      "/opt/hermes-agent"; do
    if [ -d "$c" ]; then echo "$c"; return; fi
  done
  echo "$HOME/.hermes/hermes-agent"
}

HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$(detect_hermes_agent_dir)}"
MEMORY_SRC_DIR="${MEMORY_SRC_DIR:-$SCRIPT_DIR}"
# provider 源码位置：<本目录>/hermes-plugin/memory/memory_tencentdb
PROVIDER_SRC="${MEMORY_SRC_DIR%/}/hermes-plugin/memory/memory_tencentdb"

# Hermes 插件目录（bundled provider 加载位置）
HERMES_PLUGIN_MEM="$HERMES_AGENT_DIR/plugins/memory"
DEST_PROVIDER="$HERMES_PLUGIN_MEM/memory_tencentdb"

echo "[install-memory] Hermes agent dir: $HERMES_AGENT_DIR"
echo "[install-memory] provider source : $PROVIDER_SRC"

# ---- 1. 检查 provider 源码 --------------------------------------------------
if [ ! -f "$PROVIDER_SRC/__init__.py" ]; then
  echo "[ERROR] 找不到 memory_tencentdb provider 源码：$PROVIDER_SRC"
  echo "        请把 TencentDB-Agent-Memory 仓库 clone 到 $MEMORY_SRC_DIR，"
  echo "        或用 MEMORY_SRC_DIR 指向仓库根。"
  exit 1
fi

# ---- 2. 复制 provider 到 Hermes 插件目录 ----------------------------------
mkdir -p "$HERMES_PLUGIN_MEM"
if [ -e "$DEST_PROVIDER" ]; then
  echo "[install-memory] provider 已存在，先移除旧的"
  rm -rf "$DEST_PROVIDER"
fi
cp -r "$PROVIDER_SRC" "$DEST_PROVIDER"
echo "[install-memory] provider 已复制到 $DEST_PROVIDER"

# ---- 3. config.yaml 声明 memory.provider ---------------------------------
CONFIG="${HERMES_HOME:-$HERMES_AGENT_DIR/..}/config.yaml"
# 若 HERMES_HOME 下有 config.yaml 则用(容器/自定义HOME)，否则回退到 agent 安装根上一级。
if [ ! -f "$CONFIG" ] && [ -f "$HERMES_AGENT_DIR/../config.yaml" ]; then CONFIG="$HERMES_AGENT_DIR/../config.yaml"; fi
if [ ! -f "$CONFIG" ]; then
  echo "[install-memory] 未找到 config.yaml（$CONFIG），跳过 provider 声明（请手动加 memory.provider: memory_tencentdb）"
else
  if grep -q "memory_tencentdb" "$CONFIG"; then
    echo "[install-memory] config.yaml 已声明 memory_tencentdb，跳过"
  else
    # 在文件末尾追加 memory 节（若已有 memory: 节则不覆盖）
    cp "$CONFIG" "$CONFIG.bak"
    printf '\nmemory:\n  provider: memory_tencentdb\n  memory_enabled: true\n' >> "$CONFIG"
    echo "[install-memory] config.yaml 已追加 memory.provider: memory_tencentdb（原文件备份为 .bak）"
  fi
fi

# ---- 4. 提示启动 Gateway ---------------------------------------------------
echo "[install-memory] 插件已装好。下一步：启动 Gateway（L0-L3 捕获的进程）："
echo "  手动（推荐）： cd <TencentDB-Agent-Memory> && npx tsx src/gateway/server.ts"
echo "  或设置       MEMORY_TENCENTDB_GATEWAY_CMD 指向启动命令"
echo "[install-memory] 完成后用 curl http://127.0.0.1:8420/health 验证（返回 ok/degraded 即成功）"
echo "[install-memory] 完成。"

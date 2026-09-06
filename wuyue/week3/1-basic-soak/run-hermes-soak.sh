#!/bin/bash
# ============================================================================
# run-hermes-soak.sh — Hermes soak 入口（对齐参考 openclaw-soak-tool/
# run-standalone-soak.sh 的角色：加载 .env、提供常用简写参数、调 soak.js）
#
# 用法：
#   ./run-hermes-soak.sh --smoke               # 快速冒烟（3 分钟）
#   ./run-hermes-soak.sh --duration 30         # 30 分钟长稳
#   ./run-hermes-soak.sh --rounds 47 --probe-every 8 --message-file scenario.txt
#   ./run-hermes-soak.sh --rounds 3 --badkey   # 坏 Key 容错演示（需先自行改坏配置）
#
# .env 支持（与参考一致）：SOAK_ROUNDS / SOAK_INTERVAL_MS / SOAK_DURATION_SEC /
#   SOAK_TIMEOUT_MS / SOAK_HERMES / SOAK_SESSION_MODE / SOAK_PROBE_EVERY /
#   SOAK_LOG_FILES / SOAK_RESOURCE_INTERVAL_MS / SOAK_OUTPUT_DIR ...
#   命令行参数优先级高于 .env。
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# 加载 .env（若存在）
if [ -f "$HERE/.env" ]; then
  set -a; source "$HERE/.env"; set +a
fi

EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) EXTRA+=(--rounds 6 --duration-sec 180); shift ;;
    --rounds) EXTRA+=(--rounds "$2"); shift 2 ;;
    --duration) EXTRA+=(--duration-sec "$(( $2 * 60 ))"); shift 2 ;;
    --interval) EXTRA+=(--interval-ms "$2"); shift 2 ;;
    --output) EXTRA+=(--out "$2"); shift 2 ;;
    --probe-every) EXTRA+=(--probe-every "$2"); shift 2 ;;
    --message-file) EXTRA+=(--message-file "$2"); shift 2 ;;
    --session-mode) EXTRA+=(--session-mode "$2"); shift 2 ;;
    --log-files) EXTRA+=(--log-files "$2"); shift 2 ;;
    --badkey) EXTRA+=(--rounds 3 --interval-ms 2000); shift ;;  # 配合坏 Key 的容错演示
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

exec node "$HERE/soak.js" "${EXTRA[@]}"

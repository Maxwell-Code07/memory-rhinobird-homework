#!/bin/bash
# ============================================================================
# pipeline.sh — 第三周作业·进阶2：一键流水线
#   build → 拉起容器 → 装好记忆插件 → 跑 soak（事实剧本）→ 验证 L0-L3 → 出结果
#
# 一句话：输入一个 Hermes 版本号，输出"该版本 Hermes + 记忆插件"的
#         对话 soak 结果（JSON pass/fail）与 L0-L3 记忆生成证据。
#
# 复用：
#   - docker/Dockerfile   = 第二周交付物（HERMES_VERSION 参数化，含记忆插件与 Gateway）
#   - soak.js             = 第三周基础交付物（1-basic-soak，按引用路径查找）
#   - scenario-facts.txt  = 进阶1 事实剧本（富含可提取事实，驱动 L0-L3）
#   - verify-l0l3.py      = 进阶1 记忆验证（四层 + /recall）
#
# 用法：
#   export MODEL_API_KEY="sk-..."          # 必填（模型 Key；不进日志/不落盘）
#   export MODEL_BASE_URL="https://api.deepseek.com/v1"   # 可选，默认腾讯 LKE
#   export MODEL_NAME="deepseek-chat"                     # 可选
#   ./pipeline.sh --version v2026.8.31 \
#                 --rounds 47 --interval-ms 5000 \
#                 [--duration-sec 900] \
#                 [--image hermes-memory:hw] [--name hermes-pipe] \
#                 [--soak-dir ../1-basic-soak] \
#                 [--skip-build]           # 已有镜像时跳过 docker build（节省时间）
#
# 输出：results/<时间戳>/ 下
#   soak/                  soak 输出（rounds.jsonl / meta.json / report.txt）
#   evidence.json|txt      记忆四层验证证据
#   summary.txt            一句话汇总（两处 verdict + 关键统计）
# ============================================================================
set -euo pipefail

# ---------- 参数 ----------
VERSION="${VERSION:-v2026.8.31}"
IMAGE="${IMAGE:-hermes-memory:hw-$VERSION}"
CNAME="${NAME:-hermes-pipe}"
ROUNDS="${ROUNDS:-47}"
INTERVAL_MS="${INTERVAL_MS:-5000}"
DURATION_SEC="${DURATION_SEC:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SOAK_DIR="${SOAK_DIR:-$(cd "$(dirname "$0")/.." && pwd)/1-basic-soak}"
HEREDIR="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --name) CNAME="$2"; shift 2;;
    --rounds) ROUNDS="$2"; shift 2;;
    --interval-ms) INTERVAL_MS="$2"; shift 2;;
    --duration-sec) DURATION_SEC="$2"; shift 2;;
    --soak-dir) SOAK_DIR="$2"; shift 2;;
    --skip-build) SKIP_BUILD=1; shift;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

# ---------- 前置检查 ----------
command -v docker >/dev/null || { echo "需要 docker"; exit 2; }
: "${MODEL_API_KEY:?需要 MODEL_API_KEY 环境变量（模型 Key，不落盘）}"
# 默认模型参数：镜像内置腾讯 LKE，可通过环境变量换成任意 OpenAI 兼容服务
MODEL_BASE_URL="${MODEL_BASE_URL:-https://api.lkeap.cloud.tencent.com/v1}"
MODEL_NAME="${MODEL_NAME:-deepseek-v3.2}"
MODEL_PROVIDER="${MODEL_PROVIDER:-custom}"

mkdir -p "$HEREDIR/results"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HEREDIR/results/$TS"
mkdir -p "$OUT"
VOL="${CNAME}_data"
echo "== pipeline start ts=$TS version=$VERSION image=$IMAGE container=$CNAME =="

# ---------- 1. build ----------
if [ "$SKIP_BUILD" = "1" ]; then
  echo "== [1/6] skip build（使用已有镜像 ${IMAGE}）=="
else
  echo "== [1/6] docker build HERMES_VERSION=$VERSION =="
  docker build --build-arg HERMES_VERSION="$VERSION" -t "$IMAGE" -f "$HEREDIR/docker/Dockerfile" "$HEREDIR/docker"
fi

# ---------- 2. run ----------
echo "== [2/6] 拉起容器（后台常驻，Gateway :8420）=="
docker rm -f "$CNAME" >/dev/null 2>&1 || true
docker volume rm "$VOL" >/dev/null 2>&1 || true   # 每次干净数据，保证 L0 从零开始
docker run -d --name "$CNAME" \
  -e MODEL_API_KEY="$MODEL_API_KEY" \
  -e MODEL_BASE_URL="$MODEL_BASE_URL" \
  -e MODEL_NAME="$MODEL_NAME" \
  -e MODEL_PROVIDER="$MODEL_PROVIDER" \
  -v "$VOL":/opt/data \
  "$IMAGE" >/dev/null

echo "== 等待 Gateway 健康 =="
for i in $(seq 1 40); do
  if docker exec "$CNAME" curl -sf http://127.0.0.1:8420/health >/dev/null 2>&1; then
    echo "   Gateway healthy (${i}x2s)"; break
  fi
  [ "$i" = 40 ] && { echo "Gateway 未就绪" >&2; exit 1; }
  sleep 2
done

# ---------- 3. 记忆插件调参（加速 L0-L3 生成；soak 时逐轮沉淀） ----------
echo "== [3/6] 记忆 Gateway 加速配置（pipeline/persona 阈值调小 + keyword 召回）=="
# 注意：Gateway 的配置文件从自身 CWD（/opt/tdai-gateway）或 ~/.memory-tencentdb/
# 读取，不是 TDAI_DATA_DIR —— 镜像 WORKDIR 为 /opt/tdai-gateway
docker exec -i "$CNAME" sh -c 'cat > /opt/tdai-gateway/tdai-gateway.json' <<'JSON'
{
  "memory": {
    "pipeline": { "everyNConversations": 1, "enableWarmup": true, "l1IdleTimeoutSeconds": 15, "l2DelayAfterL1Seconds": 10, "l2MinIntervalSeconds": 60, "l2MaxIntervalSeconds": 240 },
    "persona": { "triggerEveryN": 6 },
    "extraction": { "maxMemoriesPerSession": 50 },
    "recall": { "strategy": "keyword", "maxResults": 5 }
  }
}
JSON
docker restart "$CNAME" >/dev/null
sleep 8

# ---------- 4. 装载脚本 ----------
echo "== [4/6] 装载 soak.js / 剧本 / verify 脚本 =="
docker cp "$SOAK_DIR/soak.js" "$CNAME":/root/soak.js
docker cp "$HEREDIR/../2-memory-l0l3/scenario-facts.txt" "$CNAME":/root/scenario-facts.txt
docker cp "$HEREDIR/../2-memory-l0l3/verify-l0l3.py" "$CNAME":/root/verify-l0l3.py

# ---------- 5. soak ----------
echo "== [5/6] 跑 soak（rounds=$ROUNDS interval=${INTERVAL_MS}ms duration=${DURATION_SEC}s，事实剧本）=="
SOAK_ARGS=(--rounds "$ROUNDS" --interval-ms "$INTERVAL_MS" --message-file /root/scenario-facts.txt --out /root/soak-out)
if [ "$DURATION_SEC" != "0" ]; then SOAK_ARGS+=(--duration-sec "$DURATION_SEC"); fi
set +e
docker exec -w /root "$CNAME" node soak.js "${SOAK_ARGS[@]}"
SOAK_EXIT=$?
set -e
docker cp "$CNAME":/root/soak-out "$OUT/soak" 2>/dev/null || true
echo "   soak exit=$SOAK_EXIT"

# ---------- 6. 等待 pipeline 沉降 + L0-L3 验证 ----------
echo "== [6/6] 等待记忆管线沉降（120s）后验证 L0-L3 =="
sleep 120
set +e
docker exec "$CNAME" /usr/bin/python3 /root/verify-l0l3.py --out /root/evidence > "$OUT/evidence.txt" 2>&1
VERIFY_EXIT=$?
set -e
docker cp "$CNAME":/root/evidence/evidence.json "$OUT/evidence.json" 2>/dev/null || true
cat "$OUT/evidence.txt"

# ---------- 汇总 ----------
SOAK_VERDICT="n/a"; SOAK_TOTAL="n/a"; SOAK_PASS="n/a"
if [ -f "$OUT/soak/meta.json" ]; then
  SOAK_VERDICT=$(python3 -c "import json;print(json.load(open('$OUT/soak/meta.json'))['verdict'])" 2>/dev/null || echo n/a)
  SOAK_TOTAL=$(python3 -c "import json;print(json.load(open('$OUT/soak/meta.json'))['results']['total'])" 2>/dev/null || echo n/a)
  SOAK_PASS=$(python3 -c "import json;print(json.load(open('$OUT/soak/meta.json'))['results']['passed'])" 2>/dev/null || echo n/a)
fi
EV_VERDICT=$(python3 -c "import json;print(json.load(open('$OUT/evidence.json'))['verdict'])" 2>/dev/null || echo n/a)
{
  echo "Hermes 一键流水线结果 ($TS)  version=$VERSION"
  echo "  soak    : verdict=$SOAK_VERDICT  ($SOAK_PASS/$SOAK_TOTAL pass)  详见 soak/meta.json"
  echo "  L0-L3   : verdict=$EV_VERDICT  详见 evidence.json / evidence.txt"
  echo "  整体    : $([ "$SOAK_VERDICT" = pass ] && [ "$EV_VERDICT" = pass ] && echo PASS || echo FAIL)"
} | tee "$OUT/summary.txt"

echo "== 输出目录: $OUT =="
[ "$SOAK_VERDICT" = pass ] && [ "$EV_VERDICT" = pass ]

#!/usr/bin/env bash
# 容器入口：起记忆 Gateway -> 跑事实 soak对话 -> 验证 L0-L3（进阶2 end）
# 模型凭证经 MODEL_* 环境变量注入；记忆插件 provider 已在 Dockerfile 装好。
set -e

# ---- 模型配置必须齐全（缺失即报错，不静默用错地址导致 401）----------------
missing=""
[ -z "${MODEL_API_KEY:-}" ]  && missing="$missing MODEL_API_KEY"
[ -z "${MODEL_BASE_URL:-}" ] && missing="$missing MODEL_BASE_URL"
[ -z "${MODEL_NAME:-}" ]     && missing="$missing MODEL_NAME"
if [ -n "$missing" ]; then
  echo "[ERROR] 缺少必填模型配置:$missing"
  echo "        docker run -e MODEL_API_KEY=.. -e MODEL_BASE_URL=.. -e MODEL_NAME=.. -e MODEL_PROVIDER=custom"
  exit 1
fi

HERMES_HOME="${HERMES_HOME:-/opt/data}"
mkdir -p "$HERMES_HOME" /opt/pipeline /results "$HOME/.hermes"
TDAI_DATA_DIR="${TDAI_DATA_DIR:-$HERMES_HOME}"
# 守卫：Windows 宿主机的 Git Bash 可能把 /opt/... 转成 C:/Program Files/Git/opt/...，
# 一旦发生就重置为容器内原生的 Unix 路径，否则记忆写错位置、L0-L3 检测找不到。
case "$TDAI_DATA_DIR" in
  /*) ;;                       # 原生 Unix 绝对路径，保留
  *) TDAI_DATA_DIR="$HERMES_HOME" ;; # 被污染(如 C:/...)，重置
esac
export TDAI_DATA_DIR HERMES_HOME
case "${TDAI_GATEWAY_SRC:-}" in *Program*|*Git*) TDAI_GATEWAY_SRC=/opt/tdai/src/gateway/server.ts ;; esac

# ---- 1. 起记忆 Gateway（后台）--------------------------------------------
# Gateway 源码在 /opt/tdai（流水线把 TencentDB-Agent-Memory 仓库 COPY 进来）。
GATEWAY_SRC="${TDAI_GATEWAY_SRC:-/opt/tdai/src/gateway/server.ts}"
if [ -f "$GATEWAY_SRC" ]; then
  echo "[pipeline] 启动记忆 Gateway ($GATEWAY_SRC)..."
  ( cd "$(dirname "$GATEWAY_SRC")/../.." && npx tsx src/gateway/server.ts >/results/gateway.log 2>&1 ) &
  GWPID=$!
  # 等 gateway ready（最多 30s）
  for i in $(seq 1 30); do
    if curl -fsS -m 2 http://127.0.0.1:8420/health >/dev/null 2>&1; then break; fi
    sleep 1
  done
  curl -fsS -m 2 http://127.0.0.1:8420/health && echo "  [pipeline] Gateway OK" || echo "  [pipeline] WARN: Gateway 未就绪（记忆可能不回写，L0-L3 可能为空）"
else
  echo "[pipeline] WARN: 未找到 Gateway 源码 $GATEWAY_SRC，跳过起 Gateway（模式=无记忆，只测对话）"
fi

# ---- 2. 生成模型配置 + 声明记忆 provider ---------------------------------
# Hermes 的主配置读 ~/.hermes/（HOME），不是 HERMES_HOME(/opt/data)。HERMES_HOME 只
# 管记忆数据目录。所以 model + memory.provider 都要写进 ~/.hermes/config.yaml，
# API key 写进 ~/.hermes/.env，否则 Hermes 报"没有配置 provider"秒退。
HERMES_CFG="${HERMES_CFG:-$HERMES_HOME/config.yaml}"
HERMES_ENV="${HERMES_ENV:-$HERMES_HOME/.env}"
printf 'model:\n  default: "%s"\n  provider: "%s"\n  base_url: "%s"\n  api_key: "%s"\nmemory:\n  provider: memory_tencentdb\n  memory_enabled: true\n' \
  "${MODEL_NAME}" "${MODEL_PROVIDER}" "${MODEL_BASE_URL}" "${MODEL_API_KEY}" > "$HERMES_CFG"
printf 'DEEPSEEK_API_KEY=%s\nOPENAI_API_KEY=%s\n' "${MODEL_API_KEY}" "${MODEL_API_KEY}" > "$HERMES_ENV"

# ---- 3. 跑事实 soak 对话（进阶2 目标：对话本身要能沉淀记忆）---------------
echo "[pipeline] 开始 soak 对话（事实剧本，${SOAK_ROUNDS:-10} 轮）..."
node /opt/pipeline/soak.mjs \
  --hermes hermes \
  --expected-version "${HERMES_VERSION:-}" \
  --conversation /opt/pipeline/conversation-facts.jsonl \
  --rounds "${SOAK_ROUNDS:-10}" \
  --interval "${SOAK_INTERVAL:-5}" \
  --max-total-seconds "${SOAK_MAX_TOTAL_SECONDS:-600}" \
  --wait-after "${SOAK_WAIT_AFTER:-120}" \
  --result-file /results/result.json 2>&1 | tee /results/soak.log; RC=${PIPESTATUS[0]}
RC="${RC:-0}"

# ---- 4. 验证 L0-L3 ---------------------------------------------------------
echo "[pipeline] 验证 L0-L3 ..."
if [ -f /opt/pipeline/check-l0l3.mjs ]; then
  node /opt/pipeline/check-l0l3.mjs --data-dir "$TDAI_DATA_DIR" --json > /results/l0l3.json 2>&1 || true
  echo "[pipeline] L0-L3 检查结果："
  cat /results/l0l3.json
fi

# ---- 5. /recall 召回验证（Gateway 起着时）-----------------------------------
# session_key 取自本轮 soak 会话（L0 首条记录），失败不阻塞流水线，仅缺证据。
if [ "$(curl -fsS -m 2 http://127.0.0.1:8420/health >/dev/null 2>&1; echo $?)" = "0" ]; then
  SESSION_KEY=$(head -n1 "$TDAI_DATA_DIR"/conversations/*.jsonl 2>/dev/null | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{console.log(JSON.parse(d).sessionKey||'')}catch{console.log('')}})")
  echo "[pipeline] /recall 召回验证 (session_key=$SESSION_KEY) ..."
  curl -s -X POST http://127.0.0.1:8420/recall \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"我的技术偏好和工作习惯\",\"session_key\":\"${SESSION_KEY:-soak-session}\",\"limit\":5}" \
    > /results/recall.json 2>/dev/null || true
  # 记录级召回：query 贴近 L1 记录原文
  curl -s -X POST http://127.0.0.1:8420/recall \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"用户平时使用 SQLite 做本地存储，偏好本地优先、简单够用的技术方案\",\"session_key\":\"${SESSION_KEY:-soak-session}\",\"limit\":5}" \
    > /results/recall-record.json 2>/dev/null || true
  node -e "for(const f of ['/results/recall.json','/results/recall-record.json']){try{const r=require(f);console.log('[pipeline] '+f.split('/').pop()+': strategy='+r.strategy+' memory_count='+r.memory_count+' context_len='+((r.context||'').length))}catch(e){console.log('[pipeline] WARN: '+f+' 召回失败')}}"
else
  echo "[pipeline] WARN: Gateway 未运行，跳过 /recall 验证"
fi

echo "[pipeline] 结果文件：/results/result.json  /results/l0l3.json"
[ -n "${GWPID:-}" ] && kill "$GWPID" 2>/dev/null || true
exit "$RC"

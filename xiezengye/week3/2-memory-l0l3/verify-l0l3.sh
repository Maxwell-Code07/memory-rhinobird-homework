#!/usr/bin/env bash
# =============================================================================
# verify-l0l3.sh — L0-L3 四层记忆生成验证（跑完 soak 之后执行）
#
# 检查四件事（对应验收要求的四张截图）：
#   ① Gateway 存活（/health）
#   ② 数据目录非空（L0 对话 / L1 抽取 / L2 场景块）
#   ③ L3 persona.md 有内容
#   ④ /recall 能召回
#
# 用法（在装好记忆插件、跑完 soak 的环境里，容器内或本机均可）：
#   bash verify-l0l3.sh
#
# 可用环境变量：
#   TDAI_DATA_DIR                      数据目录（默认 ~/.memory-tencentdb/memory-tdai）
#   MEMORY_TENCENTDB_GATEWAY_HOST/PORT  Gateway 地址（默认 127.0.0.1:8420）
#   RECALL_QUERY                       召回测试的查询语句
# =============================================================================
set -uo pipefail

DATA_DIR="${TDAI_DATA_DIR:-$HOME/.memory-tencentdb/memory-tdai}"
GATEWAY="http://${MEMORY_TENCENTDB_GATEWAY_HOST:-127.0.0.1}:${MEMORY_TENCENTDB_GATEWAY_PORT:-8420}"
QUERY="${RECALL_QUERY:-我叫什么名字？我养了什么宠物？}"

bar() { echo "============================================================"; }

bar
echo " L0-L3 记忆生成验证"
bar

echo ""
echo "== ① Gateway 健康检查 =="
if curl -sf --max-time 5 "$GATEWAY/health"; then
  echo ""
  echo "   [OK] Gateway 存活（$GATEWAY）"
else
  echo "   [FAIL] Gateway 无响应（$GATEWAY/health）—— 请确认 Gateway 已启动"
fi

echo ""
echo "== ② 数据目录内容（应能看到 L0/L1/L2 各层文件）=="
if [ -d "$DATA_DIR" ]; then
  echo "数据目录：$DATA_DIR"
  echo "--- 文件清单（前 40 项）---"
  find "$DATA_DIR" -type f 2>/dev/null | head -40
  echo "--- 各子目录大小 ---"
  du -sh "$DATA_DIR"/* 2>/dev/null | head -20
  FILE_COUNT="$(find "$DATA_DIR" -type f 2>/dev/null | wc -l)"
  if [ "$FILE_COUNT" -gt 0 ]; then
    echo "   [OK] 目录非空（$FILE_COUNT 个文件）"
  else
    echo "   [FAIL] 目录为空——soak 对话可能没有触发 capture，检查 Gateway 日志"
  fi
else
  echo "   [FAIL] 数据目录不存在：$DATA_DIR"
fi

echo ""
echo "== ③ L3 persona 检查 =="
PERSONA="$(find "$DATA_DIR" -type f \( -iname 'persona*' -o -iname '*persona*.md' \) 2>/dev/null | head -1)"
if [ -n "$PERSONA" ] && [ -s "$PERSONA" ]; then
  echo "   [OK] 找到非空 L3 persona 文件：$PERSONA"
  echo "--- 内容预览（前 25 行）---"
  head -25 "$PERSONA"
else
  echo "   [WARN] 未找到非空的 persona 文件——L3 是异步合成的，等 1-2 分钟后重跑本脚本"
fi

echo ""
echo "== ④ /recall 召回测试 =="
echo "查询：$QUERY"
RESP="$(curl -s --max-time 20 -X POST "$GATEWAY/recall" \
  -H 'Content-Type: application/json' \
  -d "{\"query\": \"$QUERY\"}" 2>/dev/null)"
if [ -n "$RESP" ]; then
  echo "$RESP" | head -c 2000
  echo ""
  echo "   [OK] /recall 有响应（上面内容含记忆上下文即代表召回正常）"
else
  echo "   [FAIL] /recall 无响应"
fi

echo ""
bar
echo " 截图要点：①health 输出  ②数据目录文件清单  ③persona 内容  ④recall 返回"
echo " 四张图合在一起，才能证明「记忆真的生成且可用」"
bar

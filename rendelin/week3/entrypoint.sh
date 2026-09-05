#!/usr/bin/env bash
# Hermes version-compat 容器入口：生成模型配置 -> 运行 soak（交付物 B）
# 模型凭证只经环境变量（MODEL_*）注入，本脚本不落盘任何密钥到镜像层。
set -e

# 模型配置必须由用户提供（脚本交互收集，或 docker run -e 传入任意模型/供应商）。
# 不绑定任何 provider 默认值——缺失时明确报错，而不是静默用错地址导致 401。
missing=""
[ -z "${MODEL_API_KEY:-}" ]  && missing="$missing MODEL_API_KEY"
[ -z "${MODEL_BASE_URL:-}" ] && missing="$missing MODEL_BASE_URL"
[ -z "${MODEL_NAME:-}" ]     && missing="$missing MODEL_NAME"
if [ -n "$missing" ]; then
  echo "[ERROR] 缺少必填模型配置:$missing"
  echo "        请通过一键脚本（build.bat / build.sh）交互输入，或 docker run -e 传入任意模型/供应商。"
  echo "        示例: -e MODEL_API_KEY=.. -e MODEL_BASE_URL=https://api.openai.com/v1 -e MODEL_NAME=gpt-4o -e MODEL_PROVIDER=custom"
  exit 1
fi

mkdir -p /opt/data /results
CFG=/opt/data/config.yaml
ENVFILE=/opt/data/.env

# 与仓库 docker/opensource/Dockerfile.hermes 一致的模型配置生成方式：
# config.yaml（Hermes 读取）+ .env（OPENAI_API_KEY，供 provider 认证）
printf 'model:\n  default: "%s"\n  provider: "%s"\n  base_url: "%s"\n  api_key: "%s"\n' \
  "${MODEL_NAME}" "${MODEL_PROVIDER}" "${MODEL_BASE_URL}" "${MODEL_API_KEY}" > "$CFG"
printf 'OPENAI_API_KEY=%s\n' "${MODEL_API_KEY}" > "$ENVFILE"

echo "=== Hermes version-compat soak starting: version=${HERMES_VERSION} model=${MODEL_NAME} ==="

# 构建 soak 调用参数。默认使用内置多轮剧本 conversation.jsonl —— 全是"纯闲聊"，
# 不会触发工具 / 任务 / 读写文件，只为验证 Hermes 能长时间正常对话。
# 只有显式设置 SOAK_PROMPT 才退化为"固定轻量问候"；SOAK_CONVERSATION 换成别的剧本路径。
ARGS=(--hermes hermes --expected-version "${HERMES_VERSION}")
if [ -n "${SOAK_PROMPT:-}" ]; then
  ARGS+=(--prompt "${SOAK_PROMPT}")
else
  ARGS+=(--conversation "${SOAK_CONVERSATION:-/opt/hermes-version-compat/conversation.jsonl}")
fi
ARGS+=(--rounds "${SOAK_ROUNDS}" --interval "${SOAK_INTERVAL}" \
       --max-total-seconds "${SOAK_MAX_TOTAL_SECONDS}" --result-file "${SOAK_RESULT_FILE}")

exec node /opt/hermes-version-compat/soak.mjs "${ARGS[@]}"

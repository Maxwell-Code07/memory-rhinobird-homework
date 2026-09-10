#!/usr/bin/env sh
#
# Standalone POSIX implementation of the Week 3 pipeline.
#
# This script is self-contained: it never shells out to the PowerShell or Python
# entry points. It reimplements the same stage graph, argument/env surface,
# validation, cleanup, evidence layout, summary schema, and exit-code contract:
#
#   0 = pipeline pass, 1 = pipeline failure, 2 = usage/argument error
#
# Requires: docker CLI, git, tar, sha256sum (or openssl), standard POSIX tools.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
  cat <<'EOF'
Cross-platform Week 3 Dockerfile + Hermes soak pipeline (standalone POSIX shell).

Usage: run-pipeline.sh [options]

Core options:
  --hermes-version X.Y.Z        Required (or set HERMES_VERSION in .env)
  --rounds N                    Soak rounds (default 8)
  --keep-container              Keep the container after the run
  --disable-thinking STRATEGY   Override the plugin thinking strategy
                                (false|vllm|deepseek|dashscope|openai|anthropic|kimi|gemini)

Configuration (usually via .env in the current or script directory):
  --model NAME                  HERMES_MODEL
  --model-provider STYLE        HERMES_API_STYLE (only "openai" is accepted)
  --model-base-url URL          HERMES_BASE_URL (OpenAI-compatible, ends with /v1)
  --llm-base-url URL            TDAI_LLM_BASE_URL (defaults to --model-base-url)
  --provider-api-key-env NAME   HERMES_PROVIDER_API_KEY_ENV (default OPENAI_API_KEY)
  --config-volume NAME          Use a pre-made config volume instead of generating one
  --week2-dir DIR               Directory holding the Week 2 Dockerfile
  --plugin-dir DIR              Use a local plugin checkout instead of cloning
  --plugin-repo URL             Plugin repository (default Tencent/TencentDB-Agent-Memory)
  --plugin-ref REF              Plugin branch/tag (default main)
  --models-endpoint URL         Accepted for compatibility; currently unused
  --offline-dependencies        Use pre-staged node_modules instead of npm install
  -h, --help                    Show this help
EOF
}

# ---------------------------------------------------------------- arguments
HERMES_VERSION=""; WEEK2_DIR=""; PLUGIN_DIR=""
PLUGIN_REPO="https://github.com/Tencent/TencentDB-Agent-Memory.git"; PLUGIN_REF="main"
CONFIG_VOLUME=""; MODEL=""; MODEL_PROVIDER=""; PROVIDER_API_KEY_ENV=""
MODEL_BASE_URL=""; LLM_BASE_URL=""; MODELS_ENDPOINT=""; DISABLE_THINKING=""
ROUNDS=8; KEEP_CONTAINER=0; OFFLINE_DEPENDENCIES=0

need_value() {
  if [ "$#" -lt 2 ]; then
    printf '[fail] %s requires a value\n' "$1" >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hermes-version) need_value "$@"; HERMES_VERSION=$2; shift 2 ;;
    --week2-dir) need_value "$@"; WEEK2_DIR=$2; shift 2 ;;
    --plugin-dir) need_value "$@"; PLUGIN_DIR=$2; shift 2 ;;
    --plugin-repo) need_value "$@"; PLUGIN_REPO=$2; shift 2 ;;
    --plugin-ref) need_value "$@"; PLUGIN_REF=$2; shift 2 ;;
    --config-volume) need_value "$@"; CONFIG_VOLUME=$2; shift 2 ;;
    --model) need_value "$@"; MODEL=$2; shift 2 ;;
    --model-provider|--api-style) need_value "$@"; MODEL_PROVIDER=$2; shift 2 ;;
    --provider-api-key-env) need_value "$@"; PROVIDER_API_KEY_ENV=$2; shift 2 ;;
    --model-base-url|--base-url) need_value "$@"; MODEL_BASE_URL=$2; shift 2 ;;
    --llm-base-url|--tdai-llm-base-url) need_value "$@"; LLM_BASE_URL=$2; shift 2 ;;
    --models-endpoint) need_value "$@"; MODELS_ENDPOINT=$2; shift 2 ;;
    --disable-thinking) need_value "$@"; DISABLE_THINKING=$2; shift 2 ;;
    --rounds) need_value "$@"; ROUNDS=$2; shift 2 ;;
    --keep-container) KEEP_CONTAINER=1; shift ;;
    --offline-dependencies) OFFLINE_DEPENDENCIES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[fail] unknown argument: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
done

case "$ROUNDS" in
  ''|*[!0-9]*) printf '[fail] --rounds must be a positive integer\n' >&2; exit 2 ;;
esac
if [ "$ROUNDS" -lt 1 ]; then
  printf '[fail] --rounds must be at least 1\n' >&2
  exit 2
fi

# ---------------------------------------------------------------- .env loading
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t week3) || { printf '[fail] cannot create temp dir\n' >&2; exit 2; }
RESOLVED_ENV="$TMP_DIR/dotenv"
PHASE_DIR="$TMP_DIR/phases"
mkdir -p "$PHASE_DIR"
: > "$RESOLVED_ENV"

load_dotenv() {
  file=$1
  [ -f "$file" ] || return 0
  tr -d '\r' < "$file" | while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      ''|*[!A-Za-z0-9_]*) continue ;;
    esac
    case "$key" in
      [A-Za-z_]*) : ;;
      *) continue ;;
    esac
    value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    printf '%s=%s\n' "$key" "$value" >> "$RESOLVED_ENV"
  done
}

load_dotenv "$(pwd)/.env"
load_dotenv "$SCRIPT_DIR/.env"

dotenv_get() {
  [ -s "$RESOLVED_ENV" ] || return 0
  sed -n "s/^$1=//p" "$RESOLVED_ENV" | head -n 1
}

setting() {
  explicit=$1; shift
  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"
    return 0
  fi
  for key in "$@"; do
    value=$(dotenv_get "$key")
    if [ -z "$value" ]; then
      value=$(printenv "$key" 2>/dev/null || true)
    fi
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  done
  printf ''
}

# ----------------------------------------------------- resolve configuration
HERMES_VERSION=$(setting "$HERMES_VERSION" HERMES_VERSION)
if ! printf '%s' "$HERMES_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  printf '[fail] Hermes version is required: use --hermes-version x.y.z or set HERMES_VERSION in .env\n' >&2
  exit 2
fi
MODEL=$(setting "$MODEL" HERMES_MODEL OPENAI_MODEL)
MODEL_PROVIDER=$(setting "$MODEL_PROVIDER" HERMES_API_STYLE HERMES_MODEL_PROVIDER)
PROVIDER_API_KEY_ENV=$(setting "$PROVIDER_API_KEY_ENV" HERMES_PROVIDER_API_KEY_ENV)
MODEL_BASE_URL=$(setting "$MODEL_BASE_URL" HERMES_BASE_URL HERMES_MODEL_BASE_URL)
LLM_BASE_URL=$(setting "$LLM_BASE_URL" TDAI_LLM_BASE_URL HERMES_LLM_BASE_URL OPENAI_BASE_URL)
MODELS_ENDPOINT=$(setting "$MODELS_ENDPOINT" HERMES_MODELS_ENDPOINT)
DISABLE_THINKING=$(setting "$DISABLE_THINKING" TDAI_LLM_DISABLE_THINKING)

# ---------------------------------------------------------------- helpers
host_of() {
  printf '%s' "$1" | sed -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#/.*$##' -e 's#:.*$##' | tr 'A-Z' 'a-z'
}

infer_thinking() {
  host=$(host_of "$1")
  case "$host" in
    *minimax*) printf 'anthropic' ;;
    *deepseek*) printf 'deepseek' ;;
    *dashscope*|*aliyun*) printf 'dashscope' ;;
    *anthropic*) printf 'anthropic' ;;
    *google*|*generativelanguage*) printf 'gemini' ;;
    *openai.com*|*openrouter*) printf 'openai' ;;
    *) printf 'false' ;;
  esac
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print toupper($1)}'
  else
    openssl dgst -sha256 "$1" | awk '{print toupper($NF)}'
  fi
}

iso_utc() {
  date -u '+%Y-%m-%dT%H:%M:%S+00:00'
}

now_ms() {
  # GNU date: %s%3N is milliseconds. BusyBox date silently ignores %3N and
  # returns seconds, so validate the width instead of trusting the format.
  stamp=$(date '+%s%3N' 2>/dev/null || printf '')
  case "$stamp" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
      printf '%s' "$stamp"; return 0 ;;
  esac
  nano=$(date '+%s%N' 2>/dev/null || printf '')
  case "$nano" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
      printf '%s' "$(( nano / 1000000 ))"; return 0 ;;
  esac
  printf '%s000' "$(date '+%s')"
}

json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r\t' '   '
}

phase() {
  name=$1; status=$2; detail=${3:-}
  printf '%s' "$status" > "$PHASE_DIR/$name.status"
  printf '%s' "$detail" > "$PHASE_DIR/$name.detail"
  if [ -n "$detail" ]; then
    printf '[%s] %s %s\n' "$status" "$name" "$detail"
  else
    printf '[%s] %s\n' "$status" "$name"
  fi
}

docker_checked() {
  docker "$@" || die "docker $* failed with exit code $?"
}

docker_retry() {
  attempt=1
  while :; do
    if docker "$@"; then
      return 0
    fi
    if [ "$attempt" -ge 3 ]; then
      die "docker $* failed after 3 attempts"
    fi
    printf 'Docker command failed (attempt %s/3); retrying in 5s\n' "$attempt"
    attempt=$((attempt + 1))
    sleep 5
  done
}

write_summary() {
  status=$1; out=$2; soak_json=${3:-}
  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "status": "%s",\n' "$status"
    printf '  "runId": "%s",\n' "$RUN_ID"
    printf '  "image": "%s",\n' "$IMAGE_TAG"
    printf '  "container": "%s",\n' "$CONTAINER"
    if [ "$status" = "pass" ]; then
      printf '  "hermesVersion": "%s",\n' "$HERMES_VERSION"
      printf '  "dockerfile": "%s",\n' "$(printf '%s' "$DOCKERFILE" | json_escape)"
      printf '  "dockerfileSha256": "%s",\n' "$DOCKERFILE_HASH"
      printf '  "startedAt": "%s",\n' "$STARTED_AT"
      printf '  "finishedAt": "%s",\n' "$FINISHED_AT"
      printf '  "elapsedMs": %s,\n' "$ELAPSED_MS"
    fi
    printf '  "phases": {\n'
    first=1
    for name in bootstrap build prepare install_plugin gateway soak verify_memory; do
      [ -f "$PHASE_DIR/$name.status" ] || continue
      if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
      printf '    "%s": {\n' "$name"
      printf '      "status": "%s",\n' "$(cat "$PHASE_DIR/$name.status")"
      printf '      "detail": "%s"\n' "$(json_escape < "$PHASE_DIR/$name.detail")"
      printf '    }'
    done
    if [ -f "$PHASE_DIR/error.status" ]; then
      if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
      printf '    "error": {\n'
      printf '      "status": "%s",\n' "$(cat "$PHASE_DIR/error.status")"
      printf '      "detail": "%s"\n' "$(json_escape < "$PHASE_DIR/error.detail")"
      printf '    }'
    fi
    printf '\n  }'
    if [ "$status" = "pass" ] && [ -n "$soak_json" ]; then
      printf ',\n  "soak": %s' "$soak_json"
      printf ',\n  "evidenceDir": "%s"' "$(printf '%s' "$EVIDENCE_DIR" | json_escape)"
      printf ',\n  "keptContainer": %s' "$([ "$KEEP_CONTAINER" = 1 ] && printf 'true' || printf 'false')"
    fi
    printf '\n}\n'
  } > "$out"
}

# ---------------------------------------------------------------- state
ADVANCED_SOURCE="$SCRIPT_DIR/../2-memory-l0l3"
BASIC_SOURCE="$SCRIPT_DIR/../1-basic-soak"
RUN_ID=$(date '+%Y%m%d_%H%M%S')
OUTPUT_DIR="$SCRIPT_DIR/runs/$RUN_ID"
EVIDENCE_DIR="$OUTPUT_DIR/evidence"
RUNTIME_DIR="$EVIDENCE_DIR/runtime-data"
WORK_DIR="$OUTPUT_DIR/_work"
GENERATED_CONFIG_DIR="$WORK_DIR/config"
CLONED_PLUGIN_DIR="$WORK_DIR/plugin"
SOURCE_ARCHIVE="$OUTPUT_DIR/tdai-source.tgz"
SUMMARY_PATH="$OUTPUT_DIR/pipeline-summary.json"
CONTAINER_CREATED=0
ERROR_DETAIL=""
STARTED_AT=$(iso_utc)
START_MS=$(now_ms)
IMAGE_TAG="hermes:week3-pipeline-$HERMES_VERSION"
CONTAINER="hermes-pipeline-$RUN_ID"
HOME_VOLUME="hermes-pipeline-home-$RUN_ID"
mkdir -p "$OUTPUT_DIR" "$EVIDENCE_DIR" "$RUNTIME_DIR"

if [ -n "$WEEK2_DIR" ]; then
  WEEK2_DIR=$(CDPATH= cd -- "$WEEK2_DIR" && pwd)
else
  WEEK2_DIR="$SCRIPT_DIR"
fi
DOCKERFILE="$WEEK2_DIR/Dockerfile"

cleanup() {
  if [ "$CONTAINER_CREATED" = 1 ]; then
    docker exec "$CONTAINER" sh -c 'rm -f /opt/hermes-home/.env' >/dev/null 2>&1 || true
    if [ "$KEEP_CONTAINER" != 1 ]; then
      docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
  fi
  if [ -f "$SOURCE_ARCHIVE" ]; then rm -f "$SOURCE_ARCHIVE" 2>/dev/null || true; fi
  if [ -d "$WORK_DIR" ]; then
    chmod -R u+w "$WORK_DIR" 2>/dev/null || true
    rm -rf "$WORK_DIR" 2>/dev/null || true
  fi
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then rm -rf "$TMP_DIR" 2>/dev/null || true; fi
}
trap cleanup EXIT

die() {
  ERROR_DETAIL=$1
  if [ "$CONTAINER_CREATED" = 1 ]; then
    docker cp "$CONTAINER:/workspace/advanced/evidence/." "$EVIDENCE_DIR" >/dev/null 2>&1 || true
  fi
  phase error fail "$ERROR_DETAIL" >/dev/null
  write_summary fail "$SUMMARY_PATH" || true
  printf '[fail] %s\n' "$ERROR_DETAIL" >&2
  printf 'Evidence: %s\n' "$SUMMARY_PATH" >&2
  exit 1
}

# ---------------------------------------------------------------- bootstrap
phase bootstrap running 'preparing plugin and Hermes config'

DOCKER_SERVER=$(docker version --format '{{.Server.Version}}' 2>/dev/null) || { printf ''; }
if [ -z "$DOCKER_SERVER" ]; then
  die 'Docker engine is not available'
fi

if [ -z "$PLUGIN_DIR" ]; then
  mkdir -p "$WORK_DIR"
  git clone --depth 1 --branch "$PLUGIN_REF" "$PLUGIN_REPO" "$CLONED_PLUGIN_DIR" || die "unable to clone plugin: $PLUGIN_REPO ref=$PLUGIN_REF"
  PLUGIN_DIR="$CLONED_PLUGIN_DIR"
fi

GENERATED_CONFIG=0
if [ -z "$CONFIG_VOLUME" ]; then
  API_KEY=$(setting "" HERMES_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY MINIMAX_CN_API_KEY)
  if [ -z "$API_KEY" ] && [ -t 0 ]; then
    printf 'Model API key is not set; enter it for this run: ' >&2
    stty -echo 2>/dev/null || true
    IFS= read -r API_KEY || API_KEY=""
    stty echo 2>/dev/null || true
    printf '\n' >&2
  fi
  [ -n "$API_KEY" ] || die 'A model API key is required; set HERMES_API_KEY in .env'
  [ -n "$MODEL_BASE_URL" ] || die 'HERMES_BASE_URL is required in .env'
  [ -n "$MODEL" ] || die 'HERMES_MODEL is required in .env'

  STYLE=$(printf '%s' "$MODEL_PROVIDER" | tr 'A-Z' 'a-z')
  case "$STYLE" in
    ''|openai|openai-api) : ;;
    *) die "HERMES_API_STYLE must be 'openai' (an OpenAI-compatible endpoint). Got: $MODEL_PROVIDER" ;;
  esac
  MODEL_PROVIDER=openai-api
  if [ -z "$LLM_BASE_URL" ]; then
    LLM_BASE_URL="$MODEL_BASE_URL"
  fi
  if [ -z "$PROVIDER_API_KEY_ENV" ]; then
    PROVIDER_API_KEY_ENV=OPENAI_API_KEY
  fi
  if [ -z "$DISABLE_THINKING" ]; then
    DISABLE_THINKING=$(infer_thinking "$LLM_BASE_URL")
  fi

  mkdir -p "$GENERATED_CONFIG_DIR"
  {
    printf 'HERMES_API_KEY="%s"\n' "$API_KEY"
    printf '%s="%s"\n' "$PROVIDER_API_KEY_ENV" "$API_KEY"
    printf 'TDAI_LLM_API_KEY="%s"\n' "$API_KEY"
    printf 'TDAI_LLM_BASE_URL="%s"\n' "$LLM_BASE_URL"
    printf 'TDAI_LLM_MODEL="%s"\n' "$MODEL"
    printf 'TDAI_LLM_TIMEOUT_MS="180000"\n'
    printf 'TDAI_LLM_DISABLE_THINKING="%s"\n' "$DISABLE_THINKING"
  } > "$GENERATED_CONFIG_DIR/.env"
  {
    printf 'model:\n'
    printf '  default: %s\n' "$MODEL"
    printf '  provider: %s\n' "$MODEL_PROVIDER"
    printf '  base_url: %s\n' "$MODEL_BASE_URL"
    printf '_config_version: 39\n'
    printf 'memory:\n'
    printf '  memory_enabled: false\n'
    printf '  user_profile_enabled: false\n'
  } > "$GENERATED_CONFIG_DIR/config.yaml"
  GENERATED_CONFIG=1
fi

phase bootstrap pass "docker=$DOCKER_SERVER plugin_ref=$PLUGIN_REF generated_config=$([ "$GENERATED_CONFIG" = 1 ] && printf 'True' || printf 'False')"

[ -f "$DOCKERFILE" ] || die "Week 2 Dockerfile not found: $DOCKERFILE"
[ -f "$PLUGIN_DIR/package.json" ] || die "Plugin source not found: $PLUGIN_DIR"
[ -f "$ADVANCED_SOURCE/fact-prompts.json" ] || die "Fact prompts not found: $ADVANCED_SOURCE"

# ---------------------------------------------------------------- build
phase build running "image=$IMAGE_TAG"
docker_retry build --progress=plain --build-arg "HERMES_VERSION=$HERMES_VERSION" -t "$IMAGE_TAG" "$WEEK2_DIR"
DOCKERFILE_HASH=$(file_sha256 "$DOCKERFILE")
phase build pass "dockerfile_sha256=$DOCKERFILE_HASH"

# ---------------------------------------------------------------- prepare
phase prepare running "container=$CONTAINER"
mkdir -p "$OUTPUT_DIR" "$EVIDENCE_DIR" "$RUNTIME_DIR"
tar --exclude=node_modules --exclude=.git -czf "$SOURCE_ARCHIVE" -C "$PLUGIN_DIR" .
docker_checked volume create "$HOME_VOLUME" >/dev/null

if [ -f "$GENERATED_CONFIG_DIR/.env" ]; then
  docker_checked run --rm --mount "type=bind,source=$GENERATED_CONFIG_DIR,target=/source,readonly" \
    -v "$HOME_VOLUME:/target" "$IMAGE_TAG" sh -c 'cp /source/.env /target/.env; cp /source/config.yaml /target/config.yaml'
else
  docker_checked run --rm -v "$CONFIG_VOLUME:/source:ro" -v "$HOME_VOLUME:/target" \
    "$IMAGE_TAG" sh -c 'cp /source/.env /target/.env; cp /source/config.yaml /target/config.yaml'
fi

docker_checked run --name "$CONTAINER" -dit -v "$HOME_VOLUME:/opt/hermes-home" \
  -v "$RUNTIME_DIR:/opt/tdai-data" -w /workspace/advanced "$IMAGE_TAG" sh >/dev/null
CONTAINER_CREATED=1
docker_checked cp "$ADVANCED_SOURCE/." "$CONTAINER:/workspace/advanced" >/dev/null
docker_checked cp "$BASIC_SOURCE/." "$CONTAINER:/workspace/soak" >/dev/null
docker_checked cp "$SOURCE_ARCHIVE" "$CONTAINER:/tmp/tdai-source.tgz" >/dev/null
docker_checked exec "$CONTAINER" sh -c 'mkdir -p /source/tdai /workspace/advanced; tar -xzf /tmp/tdai-source.tgz -C /source/tdai' >/dev/null
docker_checked exec "$CONTAINER" sh -c 'cp /workspace/advanced/npx-offline-wrapper.sh /usr/local/bin/npx; chmod +x /usr/local/bin/npx' >/dev/null
phase prepare pass 'fresh_container=true'

# ---------------------------------------------------------------- install_plugin
phase install_plugin running
if [ "$OFFLINE_DEPENDENCIES" = 1 ]; then
  OFFLINE_MODULES="$ADVANCED_SOURCE/linux-install/package/node_modules"
  [ -d "$OFFLINE_MODULES" ] || die "Offline dependencies requested but not found: $OFFLINE_MODULES"
  docker_checked exec "$CONTAINER" sh -c 'mkdir -p /opt/hermes-home/tdai-memory-plugin' >/dev/null
  docker_checked cp "$OFFLINE_MODULES" "$CONTAINER:/opt/hermes-home/tdai-memory-plugin/node_modules" >/dev/null
  docker_checked exec -e TDAI_SKIP_NPM_INSTALL=1 "$CONTAINER" sh /workspace/advanced/install-plugin-in-container.sh
else
  docker_checked exec "$CONTAINER" sh /workspace/advanced/install-plugin-in-container.sh
fi
phase install_plugin pass 'provider=memory_tencentdb'

# ---------------------------------------------------------------- gateway
phase gateway running
docker_checked exec -d "$CONTAINER" sh /workspace/advanced/start-gateway-in-container.sh
HEALTH=''
HEALTHY=0
attempt=1
while [ "$attempt" -le 30 ]; do
  if HEALTH=$(docker exec "$CONTAINER" node /workspace/advanced/health-check.mjs 2>/dev/null); then
    HEALTHY=1
    break
  fi
  attempt=$((attempt + 1))
  sleep 2
done
if [ "$HEALTHY" != 1 ]; then
  die "Gateway health check failed after 60s: $HEALTH"
fi
phase gateway pass "$HEALTH"

# ---------------------------------------------------------------- soak
phase soak running "rounds=$ROUNDS"
docker_checked exec "$CONTAINER" node /workspace/advanced/../soak/hermes-soak.mjs \
  --rounds "$ROUNDS" --interval-ms 1000 --duration-minutes 20 --request-timeout-ms 180000 \
  --toolsets context_engine,memory --prompts /workspace/advanced/fact-prompts.json \
  --output /workspace/advanced/evidence/soak
phase soak pass 'meta.json generated'

META_FIELDS=$(docker exec "$CONTAINER" node -e 'const m=require("/workspace/advanced/evidence/soak/meta.json");process.stdout.write(String(m.status)+"\n"+String(m.finalSessionId||""))') \
  || die 'unable to read soak meta.json'
META_STATUS=$(printf '%s' "$META_FIELDS" | sed -n '1p')
SESSION_ID=$(printf '%s' "$META_FIELDS" | sed -n '2p')
[ "$META_STATUS" = 'pass' ] || die "soak status=$META_STATUS"
SOAK_JSON=$(docker exec "$CONTAINER" sh -c 'cat /workspace/advanced/evidence/soak/meta.json')

phase verify_memory running "session=$SESSION_ID"
docker_checked exec "$CONTAINER" node /workspace/advanced/verify-memory.mjs --session "$SESSION_ID" --timeout-seconds 180
phase verify_memory pass 'L0-L3 and recall passed'

# ---------------------------------------------------------------- finish
docker_checked cp "$CONTAINER:/workspace/advanced/evidence/." "$EVIDENCE_DIR" >/dev/null
FINISHED_AT=$(iso_utc)
ELAPSED_MS=$(( $(now_ms) - START_MS ))
write_summary pass "$SUMMARY_PATH" "$SOAK_JSON"
printf 'PIPELINE PASS: %s\n' "$SUMMARY_PATH"
exit 0

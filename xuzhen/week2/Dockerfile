FROM node:22-bookworm-slim

ARG HERMES_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    HERMES_VERSION=${HERMES_VERSION} \
    HERMES_HOME=/opt/hermes-home \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/hermes-venv/bin:${PATH}"

RUN set -eux; \
    test -n "${HERMES_VERSION:-}" || { echo >&2 "ERROR: HERMES_VERSION is required (for example: 0.20.6)"; exit 1; }; \
    case "${HERMES_VERSION}" in 0.[0-9]*.[0-9]*) ;; *) echo >&2 "ERROR: HERMES_VERSION must use the 0.x.x format"; exit 1 ;; esac; \
    node -e "const [major, minor] = process.versions.node.split('.').map(Number); if (major < 22 || (major === 22 && minor < 16)) process.exit(1); console.log('Node.js ' + process.versions.node + ' satisfies >=22.16.0');"; \
    apt-get -o Acquire::Retries=5 update; \
    apt-get -o Acquire::Retries=5 install -y --no-install-recommends ca-certificates git python3 python3-venv; \
    rm -rf /var/lib/apt/lists/*

# 将语义版本（0.x.x）解析为 Hermes 官方日期式 Git tag。
RUN python3 - <<'PY'
import os, re, subprocess, tomllib, urllib.request

requested = os.environ["HERMES_VERSION"]
refs = subprocess.check_output(
    ["git", "ls-remote", "--tags", "--refs", "https://github.com/NousResearch/hermes-agent.git"],
    text=True, timeout=120,
)
tag_re = re.compile(r"^v(\d{4})\.(\d+)\.(\d+)(?:\.(\d+))?$")
tags = []
for line in refs.splitlines():
    _, ref = line.split(maxsplit=1)
    tag = ref.removeprefix("refs/tags/")
    match = tag_re.fullmatch(tag)
    if match:
        tags.append((tuple(int(part or 0) for part in match.groups()), tag))
tags.sort(reverse=True)

resolved = None
for _, tag in tags:
    try:
        with urllib.request.urlopen(f"https://raw.githubusercontent.com/NousResearch/hermes-agent/{tag}/pyproject.toml", timeout=30) as response:
            metadata = tomllib.loads(response.read().decode("utf-8"))
    except Exception:
        continue
    if str(metadata.get("project", {}).get("version", "")) == requested:
        resolved = tag
        break
if resolved is None:
    raise SystemExit(f"ERROR: no official Hermes tag found for version {requested}")
open("/tmp/hermes-release-tag", "w", encoding="utf-8").write(resolved)
print(f"Resolved Hermes {requested} to official tag {resolved}")
PY

RUN set -eux; \
    release_tag="$(cat /tmp/hermes-release-tag)"; \
    git clone --depth 1 --branch "${release_tag}" https://github.com/NousResearch/hermes-agent.git /opt/hermes; \
    rm -rf /opt/hermes/.git /tmp/hermes-release-tag; \
    python3 -m venv /opt/hermes-venv; \
    python -m pip install --no-cache-dir --upgrade pip; \
    python -m pip install --no-cache-dir -e /opt/hermes

RUN python - <<'PY'
import importlib.metadata as metadata, os
expected = os.environ["HERMES_VERSION"]
actual = metadata.version("hermes-agent")
if actual != expected:
    raise SystemExit(f"ERROR: installed Hermes {actual}, expected {expected}")
print(f"Hermes version check passed: {actual}")
for name in ("hindsight-client", "honcho-ai", "supermemory", "mem0ai"):
    try:
        found = metadata.version(name)
    except metadata.PackageNotFoundError:
        continue
    raise SystemExit(f"ERROR: optional memory package {name}=={found} is installed")
print("Memory plugin package check passed: none installed")
PY

WORKDIR /workspace
CMD ["hermes"]

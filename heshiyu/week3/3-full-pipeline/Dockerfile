# syntax=docker/dockerfile:1

FROM node:22-bookworm-slim

ARG HERMES_VERSION

LABEL org.opencontainers.image.title="Hermes Agent" \
      org.opencontainers.image.description="Hermes Agent core runtime on Debian 12 with Node.js 22" \
      org.opencontainers.image.source="https://github.com/NousResearch/hermes-agent.git" \
      org.opencontainers.image.version="${HERMES_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HERMES_HOME=/opt/data \
    HERMES_WRITE_SAFE_ROOT=/opt/data \
    HERMES_DISABLE_LAZY_INSTALLS=1 \
    PATH="/opt/hermes/.venv/bin:${PATH}"

RUN set -eux; \
    test -n "${HERMES_VERSION:-}" || (echo >&2 "ERROR: HERMES_VERSION is required. Use --build-arg HERMES_VERSION=0.x.x"; exit 1); \
    case "${HERMES_VERSION:-}" in \
      0.[0-9]*.[0-9]*) ;; \
      *) echo >&2 "ERROR: HERMES_VERSION must use the 0.x.x format"; exit 1 ;; \
    esac

RUN node -e "const v=process.versions.node.split('.').map(Number); if (v[0] < 22 || (v[0] === 22 && v[1] < 16)) { console.error('Node.js >= 22.16.0 is required, found ' + process.versions.node); process.exit(1); } console.log('Node.js version check passed: ' + process.versions.node);"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        openssh-client \
        python3 \
        python3-venv \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Hermes release tags are date-based, while the requested package version is
# semantic. Resolve the matching tag from the official Git refs and verify the
# version in that tag's pyproject.toml. This avoids GitHub API rate limits.
RUN python3 - <<'PY'
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

version = os.environ.get("HERMES_VERSION", "")
if not re.fullmatch(r"0\.\d+\.\d+", version):
    sys.exit(f"ERROR: invalid HERMES_VERSION: {version!r}")

repository = "https://github.com/NousResearch/hermes-agent.git"
refs = subprocess.check_output(
    ["git", "ls-remote", "--tags", "--refs", repository],
    text=True,
    timeout=120,
)

tag_pattern = re.compile(r"^v(\d{4})\.(\d+)\.(\d+)(?:\.(\d+))?$")
tags = []
for line in refs.splitlines():
    _, ref = line.split(maxsplit=1)
    tag = ref.removeprefix("refs/tags/")
    match = tag_pattern.fullmatch(tag)
    if match:
        sort_key = tuple(int(part or 0) for part in match.groups())
        tags.append((sort_key, tag))
tags.sort(reverse=True)

matched_tag = None
project_version_pattern = re.compile(
    r'^version\s*=\s*["\']([^"\']+)["\']\s*$', re.MULTILINE
)
for _, tag in tags:
    encoded_tag = urllib.parse.quote(tag, safe="")
    url = (
        "https://raw.githubusercontent.com/NousResearch/hermes-agent/"
        f"{encoded_tag}/pyproject.toml"
    )
    source = None
    for attempt in range(3):
        try:
            request = urllib.request.Request(
                url, headers={"User-Agent": "hermes-agent-docker-build"}
            )
            with urllib.request.urlopen(request, timeout=60) as response:
                source = response.read().decode("utf-8")
            break
        except urllib.error.HTTPError as error:
            if error.code == 404:
                break
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
        except urllib.error.URLError:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
    if source is None:
        continue
    match = project_version_pattern.search(source)
    if match and match.group(1) == version:
        matched_tag = tag
        break

if not matched_tag:
    sys.exit(
        "ERROR: no official Git tag contains Hermes version "
        f"{version}. Check https://github.com/NousResearch/hermes-agent/tags"
    )

pathlib.Path("/tmp/hermes-release-tag").write_text(matched_tag, encoding="utf-8")
print(f"Resolved Hermes {version} to GitHub tag {matched_tag}")
PY

RUN set -eux; \
    release_tag="$(cat /tmp/hermes-release-tag)"; \
    git clone --depth 1 --branch "${release_tag}" \
        https://github.com/NousResearch/hermes-agent.git /opt/hermes; \
    rm -rf /opt/hermes/.git /tmp/hermes-release-tag

RUN python3 - <<'PY'
import os
import pathlib
import sys
import tomllib

requested = os.environ["HERMES_VERSION"]
with pathlib.Path("/opt/hermes/pyproject.toml").open("rb") as handle:
    source_version = str(tomllib.load(handle)["project"]["version"])
if source_version != requested:
    sys.exit(
        f"ERROR: requested Hermes {requested}, but resolved source contains {source_version}"
    )
print(f"Hermes source version check passed: {source_version}")
PY

# Hermes 0.20.x intentionally blocks wheel/sdist creation and supports an
# editable source installation. Install only core dependencies: no [all]
# extra and no optional memory-provider extras.
RUN python3 -m venv /opt/hermes/.venv \
    && /opt/hermes/.venv/bin/python -m pip install --no-cache-dir --upgrade pip \
    && /opt/hermes/.venv/bin/python -m pip install --no-cache-dir -e /opt/hermes

RUN python - <<'PY'
import importlib.metadata
import os
import sys

requested = os.environ["HERMES_VERSION"]
installed = importlib.metadata.version("hermes-agent")
if installed != requested:
    sys.exit(f"ERROR: installed Hermes version is {installed}, expected {requested}")
print(f"Installed Hermes version check passed: {installed}")

for distribution in ("hindsight-client", "honcho-ai", "supermemory", "mem0ai"):
    try:
        found = importlib.metadata.version(distribution)
    except importlib.metadata.PackageNotFoundError:
        continue
    sys.exit(f"ERROR: optional memory package {distribution}=={found} was installed")
print("Optional memory package check passed")
PY

RUN useradd --uid 10000 --create-home --home-dir /opt/data --shell /bin/bash hermes \
    && mkdir -p /workspace \
    && chown -R hermes:hermes /opt/data /workspace \
    && chmod -R a+rX,go-w /opt/hermes

WORKDIR /workspace
VOLUME ["/opt/data"]
USER hermes:hermes

ENTRYPOINT ["hermes"]
CMD ["--cli"]

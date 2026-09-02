FROM node:22-bookworm-slim

ARG HERMES_VERSION

ENV HERMES_VERSION=${HERMES_VERSION} \
    HERMES_HOME=/opt/hermes-home \
    PATH="/opt/hermes-venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1

RUN test -n "${HERMES_VERSION}" || { \
      echo "HERMES_VERSION is required, for example: 0.20.6" >&2; exit 1; \
    } && \
    node -e "const v=process.env.HERMES_VERSION; if(!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(v)) { console.error('HERMES_VERSION must use x.y.z format'); process.exit(1) } const [m,n]=process.versions.node.split('.').map(Number); if(m<22 || (m===22 && n<16)) process.exit(1); console.log(process.version)" && \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates git python3 python3-venv && \
    rm -rf /var/lib/apt/lists/*

# Use Git's native protocol instead of the rate-limited GitHub REST API.
# The blobless clone downloads source files only when a matching tag is checked.
RUN git clone --filter=blob:none --no-checkout \
      https://github.com/NousResearch/hermes-agent.git /opt/hermes

RUN python3 - <<'PY'
import os
import re
import subprocess
import tomllib

repository = "/opt/hermes"
wanted = os.environ["HERMES_VERSION"]
refs = subprocess.check_output(
    [
        "git", "-C", repository, "for-each-ref",
        "--sort=-version:refname",
        "--format=%(refname:short)\t%(subject)",
        "refs/tags/v*",
    ],
    text=True,
).splitlines()

tags = []
resolved = None
for ref in refs:
    tag, _, subject = ref.partition("\t")
    tags.append(tag)
    release = re.search(r"\brelease v?(\d+\.\d+\.\d+)\b", subject, re.IGNORECASE)
    if release and release.group(1) == wanted:
        resolved = tag
        break

if resolved is None:
    for tag in tags:
        result = subprocess.run(
            ["git", "-C", repository, "show", f"{tag}:pyproject.toml"],
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            continue
        project = tomllib.loads(result.stdout).get("project", {})
        if project.get("version") == wanted:
            resolved = tag
            break

if resolved is None:
    raise SystemExit(f"No official Hermes release found for version {wanted}")

subprocess.run(
    ["git", "-C", repository, "checkout", "--detach", resolved],
    check=True,
)
print(f"Hermes {wanted} resolved to official tag {resolved}")
PY

RUN set -eux; \
    rm -rf /opt/hermes/.git; \
    python3 -m venv /opt/hermes-venv; \
    python -m pip install --no-cache-dir --upgrade pip; \
    python -m pip install --no-cache-dir -e /opt/hermes

# Verify both the package version and that common external memory packages
# were not pulled into this clean Hermes image.
RUN python3 - <<'PY'
import importlib.metadata as md
import os

expected = os.environ["HERMES_VERSION"]
actual = md.version("hermes-agent")
if actual != expected:
    raise SystemExit(f"Installed Hermes {actual}, expected {expected}")

blocked = {"hindsight-client", "honcho-ai", "supermemory", "mem0ai"}
installed = []
for name in blocked:
    try:
        md.version(name)
    except md.PackageNotFoundError:
        continue
    installed.append(name)
installed.sort()
if installed:
    raise SystemExit(f"Unexpected memory packages installed: {installed}")
print(f"Hermes {actual} and Node {os.popen('node --version').read().strip()} verified")
PY

WORKDIR /workspace
CMD ["hermes"]

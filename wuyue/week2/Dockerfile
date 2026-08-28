# Build an image containing only a selected Hermes Agent version.
# The assignment repository is never copied into the image; the upstream
# Hermes source is downloaded at build time from its public Git repository.
FROM node:22-bookworm-slim

ARG HERMES_VERSION

# Keep the selected version visible to image inspection tools.
ENV HERMES_VERSION=${HERMES_VERSION}
LABEL org.opencontainers.image.title="Hermes Agent" \
      org.opencontainers.image.version="${HERMES_VERSION}"

WORKDIR /opt

# Hermes is distributed from source.  Install only the runtime/build tools
# needed for a clean source installation; no TencentDB memory plugin is added.
RUN test -n "${HERMES_VERSION}" || (echo "HERMES_VERSION is required" >&2; exit 1) && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates git python3 python3-venv python3-pip build-essential && \
    rm -rf /var/lib/apt/lists/* && \
    git clone --depth 1 --branch "v${HERMES_VERSION}" \
      https://github.com/NousResearch/hermes-agent.git /opt/hermes-src && \
    python3 -m venv /opt/hermes-venv && \
    /opt/hermes-venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/hermes-venv/bin/pip install --no-cache-dir --editable /opt/hermes-src && \
    rm -rf /opt/hermes-src/.git && \
    apt-get purge -y --auto-remove git python3-pip build-essential && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/hermes-venv/bin:${PATH}"
WORKDIR /opt/data

# The default command starts Hermes.  For a non-interactive version check,
# override it with: docker run --rm hermes:<version> hermes --version
CMD ["hermes"]

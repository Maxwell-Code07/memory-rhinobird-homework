FROM node:22-bookworm-slim

ARG HERMES_VERSION

RUN test -n "$HERMES_VERSION" || \
    (echo "ERROR: HERMES_VERSION must be provided" >&2; exit 1)

ENV VIRTUAL_ENV=/opt/hermes-venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"
ENV HERMES_HOME=/home/hermes/.hermes
ENV PIP_NO_CACHE_DIR=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    python3 -m venv "$VIRTUAL_ENV" && \
    pip install --upgrade pip && \
    pip install "hermes-agent==${HERMES_VERSION}" && \
    python -c "import importlib.metadata as m; actual=m.version('hermes-agent'); expected='${HERMES_VERSION}'; assert actual == expected, f'expected {expected}, got {actual}'"

RUN useradd --create-home --shell /bin/bash hermes && \
    mkdir -p "$HERMES_HOME" && \
    chown -R hermes:hermes /home/hermes

USER hermes
WORKDIR /home/hermes

ENTRYPOINT ["hermes"]
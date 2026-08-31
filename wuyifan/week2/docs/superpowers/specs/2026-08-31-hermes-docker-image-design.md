# Hermes Docker Image Design

## Goal

Build a clean Docker image that contains a caller-selected, PyPI-published
version of Hermes Agent. The image must not contain the TencentDB memory
plugin or any files copied from this homework repository.

## Assignment Requirements

1. Accept the Hermes version through `ARG HERMES_VERSION`.
2. Install exactly that version and fail the build if it is missing or invalid.
3. Use `node:22-bookworm-slim`, which provides Debian 12 and Node.js 22.
4. Do not use `COPY` or `ADD`.
5. Do not install the TencentDB memory plugin.
6. Deliver both `Dockerfile` and `README.md`.

## Version Source and Support Boundary

Hermes is installed from the Python Package Index with an exact requirement:
`hermes-agent==${HERMES_VERSION}`. This gives a deterministic mapping from the
input version to the installed artifact.

Only versions published on PyPI are supported. At design time, the published
versions are `0.13.0` through `0.19.0`; `0.19.0` is the README example.
Source-only version `0.20.4` is deliberately out of scope because it has no
matching PyPI release or Git tag.

## Image Design

- Base: `node:22-bookworm-slim`.
- System packages: `python3`, `python3-venv`, and `ca-certificates`. The venv
  bootstraps pip, so a separate global Python environment is unnecessary.
- Python isolation: create `/opt/hermes-venv` and put its `bin` directory first
  in `PATH`.
- Installation: install the exact `hermes-agent` version with pip and disable
  pip's download cache.
- Build-time check: compare Python package metadata with `HERMES_VERSION`; the
  build fails on a mismatch.
- Runtime: use `hermes` as the image entrypoint so arguments such as
  `--version` are passed directly to Hermes.
- User: run Hermes as an unprivileged `hermes` user with a writable home
  directory.

## Data Flow

```text
docker build --build-arg HERMES_VERSION=0.19.0
  -> Docker ARG
  -> pip installs hermes-agent==0.19.0
  -> build verifies installed metadata is 0.19.0
  -> image tagged hermes:0.19.0
  -> docker run hermes:0.19.0 --version
  -> Hermes reports 0.19.0
```

## Failure Behavior

- Missing `HERMES_VERSION`: fail early with a clear message.
- Unknown or unpublished version: pip fails instead of silently installing the
  latest release.
- Installed version mismatch: an explicit build-time assertion fails.
- Runtime credentials are never baked into the image; users provide provider
  configuration only when running a container.

## Verification

The README will document commands that verify:

1. A build with `HERMES_VERSION=0.19.0` succeeds.
2. `hermes --version` reports the requested version.
3. Node.js is at least 22.16.0.
4. The image starts the Hermes executable.
5. No TencentDB memory plugin is installed.
6. The Dockerfile contains no `COPY` or `ADD` instruction.

## Deliverables

- `Dockerfile`: reproducible image definition.
- `README.md`: beginner-oriented build, verification, and troubleshooting
  instructions, including the PyPI version support boundary.

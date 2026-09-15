#!/bin/sh
# The Docker network is intentionally offline during evidence runs. Hermes only
# probes npx --version while deciding whether optional browser tools exist.
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
  printf '%s\n' '10.9.4'
  exit 0
fi
exit 127

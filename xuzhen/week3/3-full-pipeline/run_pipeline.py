#!/usr/bin/env python3
"""Run the verified Week 3 Hermes + memory pipeline with one command."""

import argparse
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def main() -> int:
    here = Path(__file__).resolve().parent
    week3 = here.parent
    p = argparse.ArgumentParser(description="Build Hermes, install memory, then run the fact soak")
    p.add_argument("--version", default="0.20.6", help="Hermes version passed to the Week 2 Dockerfile")
    p.add_argument("--env-file", type=Path, default=week3 / ".env", help="shared Hermes/Gateway environment file")
    p.add_argument("--rounds", type=int, default=30, help="number of fact-script dialogue rounds")
    p.add_argument("--interval", type=float, default=1.0, help="seconds between dialogue rounds")
    p.add_argument("--duration", type=float, default=1800.0, help="total soak time budget in seconds")
    p.add_argument("--timeout", type=float, default=180.0, help="per-round Hermes timeout in seconds")
    p.add_argument("--memory-settle", type=float, default=120.0,
                   help="seconds to wait for asynchronous L1-L3 extraction after soak")
    p.add_argument("--output-dir", type=Path, default=None, help="host directory for exported evidence")
    p.add_argument("--keep", action="store_true", help="keep the temporary container for debugging")
    args = p.parse_args()

    if not args.env_file.is_file():
        p.error(f"environment file does not exist: {args.env_file}")
    if args.rounds <= 0 or args.interval < 0 or args.duration <= 0 or args.timeout <= 0 or args.memory_settle < 0:
        p.error("rounds > 0, interval >= 0, duration > 0, timeout > 0, memory-settle >= 0 are required")

    output = args.output_dir or here / "evidence" / f"run-{datetime.now():%Y%m%d-%H%M%S}"
    output.mkdir(parents=True, exist_ok=True)
    plugin = (
        "set -eux; "
        "mkdir -p /opt/memory-tencentdb /opt/week3 /opt/hermes-home /opt/hermes/plugins/memory; "
        "/opt/hermes-venv/bin/python -m pip install --no-cache-dir boto3==1.42.89; "
        "cd /opt/memory-tencentdb; "
        "npm install --no-audit --no-fund @tencentdb-agent-memory/memory-tencentdb@1.0.1; "
        "ln -sfn /opt/memory-tencentdb/node_modules/@tencentdb-agent-memory/memory-tencentdb/"
        "hermes-plugin/memory/memory_tencentdb /opt/hermes/plugins/memory/memory_tencentdb"
    )
    gateway = (
        "cd /opt/memory-tencentdb; "
        "exec node --import tsx node_modules/@tencentdb-agent-memory/memory-tencentdb/src/gateway/server.ts "
        "> /opt/week3/gateway.log 2>&1"
    )
    soak = (
        "/opt/hermes-venv/bin/python /opt/week3/soak.py "
        f"--rounds {args.rounds} --interval {args.interval} --duration {args.duration} --timeout {args.timeout} "
        "--prompt-file /opt/week3/facts.json "
        "--hermes-command /opt/hermes-venv/bin/hermes --output /opt/week3/soak-results; "
        f"status=$?; sleep {args.memory_settle}; exit $status"
    )
    command = [
        sys.executable,
        str(here / "pipeline.py"),
        "--version", args.version,
        "--image", f"hermes:pipeline-{args.version}",
        "--env-file", str(args.env_file),
        "--plugin-command", plugin,
        "--gateway-command", gateway,
        "--soak-command", soak,
        "--gateway-wait", "10",
        "--copy", f"{week3 / '1-basic-soak' / 'soak.py'}=/opt/week3/soak.py",
        "--copy", f"{week3 / '2-memory-l0l3' / 'facts.json'}=/opt/week3/facts.json",
        "--copy", f"{week3 / '2-memory-l0l3' / 'hermes-config.yaml'}=/opt/hermes-home/config.yaml",
        "--copy", f"{week3 / '2-memory-l0l3' / 'tdai-gateway.yaml'}=/opt/memory-tencentdb/tdai-gateway.yaml",
        "--copy-out", f"/opt/week3/soak-results={output / 'soak-results'}",
        "--copy-out", f"/opt/hermes-home/memory-data={output / 'memory-data'}",
        "--copy-out", f"/opt/week3/gateway.log={output / 'gateway.log'}",
    ]
    if args.keep:
        command.append("--keep")
    print("Evidence directory:", output, flush=True)
    pipeline_result = subprocess.run(command)
    if pipeline_result.returncode != 0:
        return pipeline_result.returncode

    memory_report = output / "memory-report.json"
    return subprocess.run([
        sys.executable,
        str(week3 / "2-memory-l0l3" / "memory_probe.py"),
        "--root", str(output / "memory-data"),
        "--output", str(memory_report),
    ]).returncode


if __name__ == "__main__":
    raise SystemExit(main())

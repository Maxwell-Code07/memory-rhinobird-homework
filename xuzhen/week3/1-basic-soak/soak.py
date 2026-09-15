#!/usr/bin/env python3
"""Hermes --oneshot soak runner. Standard library only."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


PROMPTS = [
    "请简短回答：我正在进行第{round}轮稳定性测试，请回复 OK。",
    "请用一句话说明你能帮助用户做什么。",
    "请简短复述：自动化测试需要记录成功、失败和耗时。",
]

ERROR_MARKERS = (
    "traceback (most recent call last)",
    "authenticationerror",
    "authentication fails",
    "authentication failed",
    "api key not valid",
    "invalid api key",
    "http 401",
    "401 unauthorized",
    "429 too many requests",
    "connection refused",
    "request failed",
)


def latency_summary(records: list[dict]) -> dict:
    values = sorted(record["latency_ms"] for record in records)
    if not values:
        return {}
    def percentile(percent: float) -> int:
        index = round((len(values) - 1) * percent)
        return values[index]
    return {
        "min": values[0], "max": values[-1],
        "avg": round(sum(values) / len(values)),
        "p50": percentile(0.50), "p95": percentile(0.95),
    }


def load_dotenv(path: Path) -> None:
    """Load simple KEY=VALUE entries without requiring python-dotenv."""
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip().strip("'\"")
        if key:
            os.environ.setdefault(key, value)


def parse_args() -> argparse.Namespace:
    default_env = os.environ.get("HERMES_ENV_FILE")
    if default_env:
        load_dotenv(Path(default_env).expanduser())
    else:
        load_dotenv(Path(__file__).resolve().parents[1] / ".env")
        load_dotenv(Path.cwd() / ".env")
    parser = argparse.ArgumentParser(description="Run a resilient Hermes multi-round soak test")
    parser.add_argument("--rounds", type=int, default=3, help="maximum conversation rounds")
    parser.add_argument("--interval", type=float, default=1.0, help="seconds between rounds")
    parser.add_argument("--duration", type=float, default=60.0, help="total time budget in seconds")
    parser.add_argument("--timeout", type=float, default=30.0, help="per-round timeout in seconds")
    parser.add_argument("--output", type=Path, default=Path("soak-results"), help="result directory")
    parser.add_argument("--env-file", type=Path, help="shared .env file for Hermes and memory Gateway")
    parser.add_argument("--prompt-file", type=Path, help="UTF-8 text file (one prompt per line) or JSON string array")
    parser.add_argument("--model", default=None, help="optional Hermes model name")
    parser.add_argument("--hermes-command", default=os.environ.get("HERMES_COMMAND", "hermes"),
                        help="Hermes executable or command prefix (default: hermes)")
    parser.add_argument("--dry-run", action="store_true", help="record simulated replies without invoking Hermes")
    args = parser.parse_args()
    if args.env_file:
        load_dotenv(args.env_file.expanduser())
    if args.rounds < 1 or args.interval < 0 or args.duration <= 0 or args.timeout <= 0:
        parser.error("rounds >= 1, interval >= 0, duration > 0, timeout > 0 are required")
    return args


def invoke_hermes(prompt: str, args: argparse.Namespace) -> tuple[bool, str, int | None, int]:
    if args.dry_run:
        return True, "dry-run response", 0, 0
    command = shlex.split(args.hermes_command, posix=(os.name != "nt"))
    command += ["--oneshot", prompt]
    if args.model:
        command += ["--model", args.model]
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=args.timeout,
            env=os.environ.copy(),
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        elapsed = round((time.monotonic() - started) * 1000)
        output = (exc.stdout or exc.stderr or "timeout").strip()
        return False, f"timeout: {output}"[:2000], None, elapsed
    except OSError as exc:
        elapsed = round((time.monotonic() - started) * 1000)
        return False, f"unable to start Hermes: {exc}"[:2000], None, elapsed
    elapsed = round((time.monotonic() - started) * 1000)
    output = (completed.stdout or completed.stderr or "").strip()
    if completed.returncode != 0:
        return False, f"exit {completed.returncode}: {output}"[:2000], completed.returncode, elapsed
    if not output:
        return False, "empty response", completed.returncode, elapsed
    lowered = output.lower()
    if any(marker in lowered for marker in ERROR_MARKERS):
        return False, f"error response: {output}"[:2000], completed.returncode, elapsed
    return True, output[-2000:], completed.returncode, elapsed


def main() -> int:
    args = parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    started_at = datetime.now(timezone.utc)
    started = time.monotonic()
    rounds: list[dict] = []
    prompts = PROMPTS
    if args.prompt_file:
        raw = args.prompt_file.read_text(encoding="utf-8")
        try:
            loaded = json.loads(raw)
            prompts = [str(item) for item in loaded] if isinstance(loaded, list) else []
        except json.JSONDecodeError:
            prompts = [line.strip() for line in raw.splitlines() if line.strip()]
        if not prompts:
            raise SystemExit("--prompt-file must contain a JSON string array or one prompt per line")
    deadline = started + args.duration
    jsonl_path = args.output / "rounds.jsonl"
    with jsonl_path.open("w", encoding="utf-8") as jsonl:
        for number in range(1, args.rounds + 1):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            prompt = prompts[(number - 1) % len(prompts)].format(round=number)
            ok, response, exit_code, latency_ms = invoke_hermes(prompt, args)
            record = {
                "round": number,
                "ok": ok,
                "prompt": prompt,
                "response": response,
                "exit_code": exit_code,
                "latency_ms": latency_ms,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
            rounds.append(record)
            jsonl.write(json.dumps(record, ensure_ascii=False) + "\n")
            jsonl.flush()
            print(f"round {number}/{args.rounds}: {'PASS' if ok else 'FAIL'} ({latency_ms} ms)")
            if number < args.rounds:
                time.sleep(min(args.interval, max(0, deadline - time.monotonic())))

    elapsed_ms = round((time.monotonic() - started) * 1000)
    passed = sum(1 for record in rounds if record["ok"])
    failed = len(rounds) - passed
    result = {
        "status": "PASS" if rounds and failed == 0 and len(rounds) == args.rounds else "FAIL",
        "started_at": started_at.isoformat(),
        "finished_at": datetime.now(timezone.utc).isoformat(),
        "config": {"rounds": args.rounds, "interval_seconds": args.interval,
                   "duration_seconds": args.duration, "timeout_seconds": args.timeout,
                   "hermes_command": args.hermes_command, "dry_run": args.dry_run},
        "statistics": {"requested_rounds": args.rounds, "completed_rounds": len(rounds),
                       "passed_rounds": passed, "failed_rounds": failed,
                       "elapsed_ms": elapsed_ms,
                       "latency_ms": [r["latency_ms"] for r in rounds],
                       "latency_summary_ms": latency_summary(rounds)},
        "rounds_file": str(jsonl_path),
    }
    (args.output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report = (f"Hermes soak: {result['status']}\n"
              f"Rounds: {len(rounds)}/{args.rounds} (pass={passed}, fail={failed})\n"
              f"Elapsed: {elapsed_ms} ms\n")
    (args.output / "report.txt").write_text(report, encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


for stream in (sys.stdout, sys.stderr):
    reconfigure = getattr(stream, "reconfigure", None)
    if reconfigure is not None:
        reconfigure(encoding="utf-8", errors="replace")


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def print_layer(verification: dict[str, Any], name: str, preview_lines: int) -> None:
    layer = verification["layers"][name]
    print(f"[{name}] passed={layer.get('passed')}")
    if "records" in layer:
        print(f"records={layer.get('records')} invalid_records={layer.get('invalid_records')}")
    for item in layer.get("files", []):
        print(f"- {item.get('path')} ({item.get('bytes')} bytes)")
        preview = str(item.get("preview", "")).splitlines()
        for line in preview[:preview_lines]:
            print(f"  {line}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Show Week3 memory pipeline results")
    parser.add_argument("--result-dir", required=True, type=Path)
    parser.add_argument(
        "--view",
        choices=("summary", "l0l1", "l2", "l3", "recall"),
        default="summary",
    )
    args = parser.parse_args()
    result_dir = args.result_dir.expanduser().resolve()
    verification = read_json(result_dir / "memory-verification.json")

    if args.view == "summary":
        meta = read_json(result_dir / "pipeline-meta.json")
        baseline = read_json(result_dir / "fresh-data-baseline.json")
        for key in (
            "status",
            "hermes_version",
            "image",
            "container",
            "soak_exit_code",
            "memory_verification_exit_code",
        ):
            print(f"{key}: {meta.get(key)}")
        print(f"fresh: {baseline.get('fresh')} ({baseline.get('phase')})")
        print()
        print((result_dir / "soak" / "report.txt").read_text(encoding="utf-8-sig").rstrip())
    elif args.view == "l0l1":
        print_layer(verification, "L0", 2)
        print_layer(verification, "L1", 2)
    elif args.view == "l2":
        print_layer(verification, "L2", 20)
    elif args.view == "l3":
        print_layer(verification, "L3", 22)
    else:
        health = verification["gateway"]["health"]
        recall = verification["gateway"]["recall"]
        print(f"health: ok={health.get('ok')} status={health.get('status')}")
        print(f"recall: passed={recall.get('passed')} http_status={recall.get('http_status')}")
        for keyword in recall.get("expected_keywords", []):
            print(f"- {keyword.get('keyword')}: {keyword.get('found')}")
        print()
        context = str(recall.get("response", {}).get("context", ""))
        print("\n".join(context.splitlines()[:18]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Check that L0-L3 artifacts exist and optionally verify recall text."""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def non_empty(path: Path) -> bool:
    return path.is_file() and path.stat().st_size > 0 or path.is_dir() and any(path.iterdir())


def main() -> int:
    p = argparse.ArgumentParser(description="Verify Hermes memory L0-L3 artifacts")
    p.add_argument("--root", type=Path, required=True, help="memory data root")
    p.add_argument("--recall-file", type=Path, help="file containing /recall output")
    p.add_argument("--keywords", nargs="+", default=[], help="keywords expected in recall output")
    p.add_argument("--output", type=Path, default=Path("memory-report.json"))
    args = p.parse_args()
    root = args.root
    candidates = {
        "L0": [root / "L0", root / "l0", root / "raw", root / "conversations"],
        "L1": [root / "L1", root / "l1", root / "facts", root / "records"],
        "L2": [root / "L2", root / "l2", root / "scenes", root / "scene", root / "scene_blocks"],
        "L3": [root / "L3", root / "l3", root / "persona.md"],
    }
    layers = {}
    for layer, paths in candidates.items():
        found = next((path for path in paths if non_empty(path)), None)
        layers[layer] = {"present": found is not None, "path": str(found) if found else None}
    recall_text = args.recall_file.read_text(encoding="utf-8", errors="replace") if args.recall_file and args.recall_file.exists() else ""
    missing_keywords = [word for word in args.keywords if word not in recall_text]
    result = {
        "status": "PASS" if all(item["present"] for item in layers.values()) and not missing_keywords else "FAIL",
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "root": str(root), "layers": layers,
        "recall": {"file": str(args.recall_file) if args.recall_file else None,
                   "keywords": args.keywords, "missing_keywords": missing_keywords},
    }
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())

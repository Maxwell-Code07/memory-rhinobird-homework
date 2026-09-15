"""
verify-memory.py — 验证 Hermes 记忆系统的 L0/L1/L2/L3 四层是否真的落库

跑完 soak-facts.js 之后跑这个脚本，对照根记忆目录逐层确认非空，
并尝试 /recall 召回特定事实。如果四层都非空 + /recall 能召回 → 进阶1 通过。

数据来源（按你的 .env）：
  MEMORY_TENCENTDB_GATEWAY_HOST=127.0.0.1
  MEMORY_TENCENTDB_GATEWAY_PORT=8420

用法：
  python verify-memory.py [--gateway-url http://127.0.0.1:8420] [--out-dir ../soak-out/facts-2026xxxx]

退出码：
  0 = 四层非空 + recall 命中关键词
  1 = 有层缺失或 recall 未命中
"""

import argparse
import json
import os
import sys
import urllib.request
import urllib.error
from pathlib import Path


# ---------- 默认记忆根目录 ----------
# v0.20.5 的 memory_tencentdb provider 把数据放在 ~/.hermes/memories/<user>/<session>/
# 但稳妥起见，我们扫几个常见位置，找到第一个非空的就用它。

CANDIDATE_DIRS = [
    Path("C:/Users/35348/.memory-tencentdb/memory-tdai"),
    Path.home() / ".memory-tencentdb" / "memory-tdai",
    Path.home() / ".hermes" / "memories",
    Path("C:/Users/35348/.hermes/memories"),
    Path("C:/Users/35348/AppData/Local/hermes/memories"),
    Path.home() / ".hermes" / "memory",
    Path("C:/Users/35348/AppData/Local/hermes/memory"),
]

# memory_tencentdb 的四层实际子目录（不是按 L0/L1/L2/L3 数字命名）
L0_GLOB = "**/conversations/*.json*"   # L0 原始对话事件
L1_GLOB = "**/records/*.json*"          # L1 抽取事实
L2_GLOB = "**/scene_blocks/*"            # L2 scene 块（.md 文件）
L3_FILES = ("persona.md", "user_profile.md")  # L3 用户画像（在根目录）

RECALL_KEYWORDS = [
    "董博文",
    "海南大学",
    "Hermes",
    "Python",
    "周杰伦",
]


def find_memory_root() -> Path:
    """在候选目录里挑第一个存在的；都不存在返回 None。"""
    for d in CANDIDATE_DIRS:
        if d.exists():
            return d
    return None


def scan_layer(root: Path, glob: str) -> list[Path]:
    return [p for p in root.glob(glob) if p.is_file()]


def check_l0_l1_l2(root: Path) -> dict:
    """扫文件，给出每一层的文件数和总字节数。"""
    out = {}
    for layer, glob in [("L0", L0_GLOB), ("L1", L1_GLOB), ("L2", L2_GLOB)]:
        files = scan_layer(root, glob)
        total = sum((p.stat().st_size for p in files), 0)
        out[layer] = {"files": len(files), "bytes": total, "samples": [str(p) for p in files[:3]]}
    return out


def check_l3(root: Path) -> dict:
    files = [root / name for name in L3_FILES if (root / name).is_file()]
    total = sum((p.stat().st_size for p in files), 0)
    preview = []
    for p in files:
        try:
            txt = p.read_text(encoding="utf-8", errors="replace")
            preview.append({"path": str(p), "preview": txt[:400]})
        except Exception as e:
            preview.append({"path": str(p), "error": str(e)})
    return {"files": len(files), "bytes": total, "samples": preview}


def http_recall(gateway_url: str, query: str) -> dict:
    """POST /recall — 需要 query + session_key（来自 sessions 表）。"""
    candidates = ["/recall"]
    for path in candidates:
        url = gateway_url.rstrip("/") + path
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps({"query": query, "session_key": "dongbowen-soak-session", "top_k": 5}).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                return {"url": path, "status": resp.status, "body": body}
        except urllib.error.HTTPError as e:
            return {"url": path, "status": e.code,
                    "body": e.read().decode("utf-8", errors="replace")[:500]}
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            continue
    return {"url": "(none)", "status": 0,
            "body": "no /recall endpoint reachable at " + gateway_url}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--gateway-url", default="http://127.0.0.1:8420",
                   help="记忆插件 Gateway 地址（默认 127.0.0.1:8420，与 .env 一致）")
    p.add_argument("--out-dir", default=None,
                   help="可选：把验证结果写到 soak-out/<dir>/verify-memory.json")
    args = p.parse_args()

    print("=== Hermes Memory Verification (L0/L1/L2/L3) ===")
    print("gateway :", args.gateway_url)

    root = find_memory_root()
    if root is None:
        print("\n[!] 没找到记忆根目录。请确认 .env 里 MEMORY_TENCENTDB_GATEWAY_* 配置正确，"
              "并且 Hermes gateway 已经把对话转写到磁盘。")
        print("    候选目录：")
        for d in CANDIDATE_DIRS:
            print("     -", d)
        return 1

    print("memory-root:", root)
    layers = check_l0_l1_l2(root)
    layers["L3"] = check_l3(root)

    print("\n--- Layer file counts ---")
    for layer, info in layers.items():
        print(f"  {layer}: {info['files']} 个文件, {info['bytes']} 字节")
        if info["files"] == 0:
            print(f"       [!] {layer} 是空的 —— 记忆没沉淀到这里")

    print("\n--- /recall 召回测试 ---")
    recall_results = {}
    for kw in RECALL_KEYWORDS:
        r = http_recall(args.gateway_url, kw)
        recall_results[kw] = r
        ok = r.get("status") == 200 and kw in r.get("body", "")
        print(f"  query='{kw}': status={r.get('status')} hit={ok}")

    # ---- 汇总 ----
    all_layers_nonempty = all(layers[L]["files"] > 0 for L in ["L0", "L1", "L2", "L3"])
    any_recall_ok = any(r.get("status") == 200 and kw in r.get("body", "")
                        for kw, r in recall_results.items())
    overall = "pass" if (all_layers_nonempty and any_recall_ok) else "fail"

    result = {
        "memory_root": str(root),
        "gateway_url": args.gateway_url,
        "layers": layers,
        "recall": recall_results,
        "overall": overall,
        "all_layers_nonempty": all_layers_nonempty,
        "any_recall_ok": any_recall_ok,
    }

    print("\n=== overall:", overall, "===")

    if args.out_dir:
        out_path = Path(args.out_dir) / "verify-memory.json"
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        print("写入：", out_path)

    return 0 if overall == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
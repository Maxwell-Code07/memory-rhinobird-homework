#!/usr/bin/env python3
"""
verify-l0l3.py — 记忆四层 (L0-L3) 生成验证（第三周作业·进阶1）

在装好 memory_tencentdb 的 Hermes 容器内运行，soak 跑完之后调用：
  1. L0   : conversations/*.jsonl 有原始对话记录
  2. L1   : records/ 有提取出的事实记忆
  3. L2   : scene_blocks/*.md 有场景块
  4. L3   : persona.md 有用户画像
  5. 召回 : POST /recall 能用关键词召回记忆

输出：
  <out>/evidence.json   结构化结果（各层 ok/count/snippet + recall 命中）
  <out>/evidence.txt    人类可读证据（可直接截图）

用法：
  python3 verify-l0l3.py [--tdai /opt/data/tdai-memory] [--port 8420]
                         [--out /root/evidence] [--query "小巫 后端 咖啡"]
                         [--anchors 小巫,后端开发,Go]
零第三方依赖（只用标准库），容器内 /usr/bin/python3 即可运行。
"""
import argparse, json, os, sys, time, urllib.request

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tdai", default="/opt/data/tdai-memory")
    ap.add_argument("--port", type=int, default=8420)
    ap.add_argument("--out", default="/root/evidence")
    ap.add_argument("--query", default="小巫 后端开发 Go 咖啡 羽毛球")
    ap.add_argument("--anchors", default="小巫,后端,Go,咖啡,羽毛球")
    args = ap.parse_args()

    anchors = [a.strip() for a in args.anchors.split(",") if a.strip()]
    os.makedirs(args.out, exist_ok=True)
    ev = {"checked_at": time.strftime("%Y-%m-%d %H:%M:%S"), "levels": {}}

    def head(path, n=10):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return "".join(f.readlines()[:n])
        except Exception as e:
            return f"(read error: {e})"

    # ---------- L0 ----------
    l0_files = sorted(__import__("glob").glob(os.path.join(args.tdai, "conversations", "*.jsonl")))
    l0_lines = 0
    l0_sample = ""
    for f in l0_files:
        n = sum(1 for _ in open(f, encoding="utf-8"))
        l0_lines += n
        if not l0_sample:
            l0_sample = head(f, 4)
    ok_l0 = l0_lines > 0
    ev["levels"]["L0"] = {"ok": ok_l0, "jsonl_files": len(l0_files), "conversation_lines": l0_lines,
                          "sample": l0_sample[:500]}

    # ---------- L1 ----------
    l1_files = sorted(__import__("glob").glob(os.path.join(args.tdai, "records", "*.json*")))
    l1_text = ""
    for f in l1_files[:3]:
        try:
            if f.endswith(".jsonl"):
                objs = [json.loads(l) for l in open(f, encoding="utf-8") if l.strip()]
                obj = objs[0] if objs else None
            else:
                obj = json.load(open(f, encoding="utf-8"))
        except Exception:
            obj = None
        # 兼容多种形态：{"content": ...} / {"text": ...} / {"data": {...}} / 数组
        def extract(o):
            if isinstance(o, dict):
                for k in ("content", "text", "memory"):
                    if isinstance(o.get(k), str):
                        return o[k]
                for v in o.values():
                    r = extract(v)
                    if r: return r
            return ""
        l1_text += (extract(obj) or "") + "\n"
    ok_l1 = len(l1_files) > 0
    ev["levels"]["L1"] = {"ok": ok_l1, "memory_files": len(l1_files), "sample": l1_text[:500]}

    # ---------- L2 ----------
    l2_files = sorted(__import__("glob").glob(os.path.join(args.tdai, "scene_blocks", "*.md")))
    l2_sample = "".join(head(f, 12) for f in l2_files[:2])
    ok_l2 = len(l2_files) > 0
    ev["levels"]["L2"] = {"ok": ok_l2, "scene_files": len(l2_files), "sample": l2_sample[:600]}

    # ---------- L3 ----------
    persona_path = os.path.join(args.tdai, "persona.md")
    persona_lines = 0
    persona_text = ""
    if os.path.exists(persona_path):
        with open(persona_path, encoding="utf-8") as f:
            persona_text = f.read()
        persona_lines = persona_text.count("\n") + 1
    anchor_hits = {a: (a in persona_text) for a in anchors}
    ok_l3 = persona_lines >= 8 and any(anchor_hits.values())
    ev["levels"]["L3"] = {"ok": ok_l3, "persona_lines": persona_lines,
                          "anchor_hits": anchor_hits, "sample": persona_text[:600]}

    # ---------- recall ----------
    try:
        req = urllib.request.Request(
            f"http://127.0.0.1:{args.port}/recall",
            data=json.dumps({"query": args.query, "session_key": "soak-verify"}).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=20) as r:
            recall = json.loads(r.read().decode())
        if recall.get("code") not in (None, 0, 10000):
            ev["recall"] = {"ok": False, "error": f"code={recall.get('code')} {recall.get('message','')}"}
        else:
            # 响应结构：context(注入的记忆片段+persona)、memory_count(召回到的记忆条数)
            memory_count = recall.get("memory_count", 0)
            ctx = recall.get("context", "") or ""
            blob = ctx
            hit_anchor = [a for a in anchors if a in blob]
            ok_recall = memory_count > 0 and len(ctx) > 0
            ev["recall"] = {"ok": ok_recall, "query": args.query, "hit_count": memory_count,
                            "strategy": recall.get("strategy", ""),
                            "anchor_hits": hit_anchor,
                            "context_chars": len(ctx),
                            "context_snippet": ctx[:400]}
    except Exception as e:
        ev["recall"] = {"ok": False, "error": str(e)}

    ok_all = all(ev["levels"][k]["ok"] for k in ("L0", "L1", "L2", "L3")) and ev["recall"]["ok"]
    ev["verdict"] = "pass" if ok_all else "fail"

    with open(os.path.join(args.out, "evidence.json"), "w", encoding="utf-8") as f:
        json.dump(ev, f, ensure_ascii=False, indent=2)

    # ---------- 人类可读证据 ----------
    L = []
    L.append("=" * 72)
    L.append("Hermes 记忆 L0-L3 生成验证 (memory_tencentdb)")
    L.append("=" * 72)
    L.append(f"时间 : {ev['checked_at']}   数据目录: {args.tdai}")
    L.append(f"判定 : {ev['verdict'].upper()}   (需 L0+L1+L2+L3 与 recall 全部非空)")
    for k in ("L0", "L1", "L2", "L3"):
        d = ev["levels"][k]
        ok = "PASS" if d["ok"] else "FAIL"
        L.append("")
        L.append(f"── [{ok}] L{k}  {d.get('jsonl_files', d.get('memory_files', d.get('scene_files', '')))}")
        if k == "L0":
            L.append(f"    jsonl 文件 {d['jsonl_files']} 个，对话记录 {d['conversation_lines']} 行")
        elif k == "L1":
            L.append(f"    记忆文件 {d['memory_files']} 个")
        elif k == "L2":
            L.append(f"    场景块 {d['scene_files']} 个")
        elif k == "L3":
            L.append(f"    persona.md {d['persona_lines']} 行，锚点命中: {d['anchor_hits']}")
        L.append("    内容样例:")
        for ln in d["sample"].strip().splitlines()[:6]:
            L.append("      " + ln[:110])
    r = ev["recall"]
    L.append("")
    L.append(f"── [{'PASS' if r['ok'] else 'FAIL'}] /recall 召回  query={r.get('query','')}")
    if r.get("error"):
        L.append(f"    error: {r['error']}")
    else:
        L.append(f"    strategy={r.get('strategy','')}  命中记忆 {r['hit_count']} 条（context {r['context_chars']} 字），锚点命中: {r.get('anchor_hits', [])}")
        L.append("    context 开头:")
        for ln in r.get("context_snippet", "").splitlines()[:4]:
            L.append("      " + ln[:120])
    L.append("")
    L.append("=" * 72)
    txt = "\n".join(L)
    with open(os.path.join(args.out, "evidence.txt"), "w", encoding="utf-8") as f:
        f.write(txt + "\n")
    print(txt)
    sys.exit(0 if ok_all else 1)

if __name__ == "__main__":
    main()

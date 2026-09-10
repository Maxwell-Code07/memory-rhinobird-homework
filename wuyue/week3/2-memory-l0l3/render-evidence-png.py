#!/usr/bin/env python3
"""
render-evidence-png.py — 把 verify-l0l3 的 evidence.txt 渲染成 PNG 证据图
（评审要求"截图证明 L0-L3 生成"，本脚本把四层 + recall 的证据变成一张可直接贴的图）

用法:
  python3 render-evidence-png.py <evidence.txt> <out.png> [--title "Hermes L0-L3 ..."]
零第三方依赖不可用时的替代: 本机 macOS 有 PIL 时用苹方/冬青黑体渲染。
"""
import argparse, os, sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("需要 Pillow: pip3 install --user pillow")

FONT_CANDIDATES = [
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Songti.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
]

def pick_font(size):
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return ImageFont.load_default()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("txt")
    ap.add_argument("png")
    ap.add_argument("--title", default="Hermes 记忆 L0-L3 生成验证证据")
    args = ap.parse_args()

    text = open(args.txt, encoding="utf-8").read()
    lines = text.rstrip("\n").split("\n")

    PAD = 28
    FONT_SIZE = 21
    LINE_H = 32
    TITLE_H = 64
    font = pick_font(FONT_SIZE)
    title_font = pick_font(30)
    # 画布宽度按最长行估算
    widths = [PAD]
    for ln in lines:
        widths.append(PAD + max(font.getlength(ln), 10))
    W = max(1500, int(max(widths) + PAD))
    H = TITLE_H + PAD * 2 + len(lines) * LINE_H

    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    d.text((PAD, 18), args.title, font=title_font, fill=(20, 30, 60))
    d.line([(PAD, TITLE_H - 6), (W - PAD, TITLE_H - 6)], fill=(30, 90, 160), width=3)
    y = TITLE_H + PAD
    for ln in lines:
        color = (0, 0, 0)
        if ln.startswith("判定") or ln.startswith("── ["):
            color = (0, 90, 20) if "PASS" in ln or "pass" in ln or "判定 : pass" in ln else (170, 40, 20)
        if ln.startswith("="):
            color = (120, 120, 120)
        d.text((PAD, y), ln, font=font, fill=color)
        y += LINE_H
    img.save(args.png)
    print(f"saved {args.png} ({W}x{H})")

if __name__ == "__main__":
    main()

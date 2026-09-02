#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从透明底/不规则 logo 生成 macOS AppIcon.icns。

- 支持非正方形源图：居中放到正方形透明画布（不拉伸、不变形）
- 保留 alpha 透明区域（不规则形状图标）
- LANCZOS 高质量缩放，输出标准 iconset 后由 iconutil 打包 icns

用法: generate_icon.py <logo.png> <输出AppIcon.icns路径>
"""
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image

SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def build(src_path: str, out_icns: str) -> None:
    im = Image.open(src_path)
    if im.mode != "RGBA":
        im = im.convert("RGBA")

    w, h = im.size
    side = max(w, h)
    # 源图四周补透明边距：让图形在画布中约占 82%（其余为透明，符合 macOS 图标视觉）
    pad_ratio = 0.82
    canvas_side = int(round(side / pad_ratio))
    canvas = Image.new("RGBA", (canvas_side, canvas_side), (0, 0, 0, 0))
    canvas.paste(im, ((canvas_side - w) // 2, (canvas_side - h) // 2), im)

    tmp_base = tempfile.mkdtemp(prefix="appicon_")
    tmp_dir = os.path.join(tmp_base, "AppIcon.iconset")
    os.makedirs(tmp_dir)
    try:
        for name, px in SIZES:
            resized = canvas.resize((px, px), Image.LANCZOS)
            resized.save(os.path.join(tmp_dir, name))
        result = subprocess.run(["iconutil", "-c", "icns", tmp_dir, "-o", out_icns],
                                capture_output=True, text=True)
        if result.returncode != 0:
            print("iconutil 失败:", result.stderr, file=sys.stderr)
            sys.exit(1)
        print(f"OK: {out_icns}（画布 {canvas_side}px，含透明）")
    finally:
        shutil.rmtree(tmp_base, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    build(sys.argv[1], sys.argv[2])

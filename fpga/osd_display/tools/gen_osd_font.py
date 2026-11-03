"""生成 OSD 设置面板字库：rtl/video/osd_font16.dat（2048 x 16 bit，$readmemb 格式）。

布局（与 rtl/video/osd_font_rom.v、osd_settings_panel.v 一致）：
  地址   0 ..  511 : 32 个 16x16 汉字，addr = idx*16 + row，bit15 = 最左像素
  地址 512 .. 2047 : 96 个 8x16 ASCII（0x20..0x7F），addr = 512 + (code-0x20)*16 + row，
                     字形在 bit15..bit8，bit7..0 恒 0

字体用宋体 16px：simsun.ttc 自带 16px 内嵌点阵，非抗锯齿模式下直接取到点阵字，
不需要阈值化，笔画清晰。ASCII 用 Consolas Bold 14px 非抗锯齿渲染：宋体 ASCII 笔画只有
1px，叠在图片上偏细，而在 8px 格子里人工加粗会把 M/W/m/@ 糊成块。CJK 列表的顺序就是汉字编号，
改动后要同步改 RTL 里的编号表。

用法：python tools/gen_osd_font.py [--font C:/Windows/Fonts/simsun.ttc] [--preview out.png]
"""
import argparse
import os

from PIL import Image, ImageDraw, ImageFont

# 汉字编号表：顺序即 RTL 中的编号（osd_settings_panel.v 的 CJK_* 常量）
CJK = "设置亮度对比音量背景乐轮播"

ASCII_FONT = "consolab.ttf"
ASCII_SIZE = 14
ASCII_DY = 1          # 下移 1 行，和宋体汉字基线大致对齐

FONT_CANDIDATES = [
    "C:/Windows/Fonts/simsun.ttc",
    os.path.join(os.environ.get("WINDIR", "C:/Windows"), "Fonts", "simsun.ttc"),
    "C:/Windows/Fonts/simsun.ttc",
]

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "rtl", "video", "osd_font16.dat")


def render(font, ch, width, dy=0):
    img = Image.new("1", (width, 16), 0)
    d = ImageDraw.Draw(img)
    d.fontmode = "1"
    d.text((0, dy), ch, font=font, fill=1)
    return [[img.getpixel((x, y)) for x in range(width)] for y in range(16)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--font", default=None, help="默认依次尝试 FONT_CANDIDATES")
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--preview", default=None, help="可选：输出放大 4 倍的预览 PNG")
    args = ap.parse_args()

    assert len(CJK) <= 32, "最多 32 个汉字"
    path = args.font or next(p for p in FONT_CANDIDATES if os.path.exists(p))
    font = ImageFont.truetype(path, 16)
    afont = ImageFont.truetype(os.path.join(os.path.dirname(path), ASCII_FONT), ASCII_SIZE)

    words = [0] * 2048
    for i, ch in enumerate(CJK):
        g = render(font, ch, 16)
        for row in range(16):
            v = 0
            for x in range(16):
                v = (v << 1) | g[row][x]
            words[i * 16 + row] = v
    for code in range(0x20, 0x80):
        g = render(afont, chr(code), 8, ASCII_DY)
        for row in range(16):
            v = 0
            for x in range(8):
                v = (v << 1) | g[row][x]
            words[512 + (code - 0x20) * 16 + row] = v << 8

    with open(args.out, "w", newline="\n") as f:
        for w in words:
            f.write(format(w, "016b") + "\n")
    print("wrote", os.path.normpath(args.out), "(%d CJK + 96 ASCII)" % len(CJK))

    if args.preview:
        # 直接从 words 解码，预览即上板效果（含 ASCII 加粗）
        cells = [(i * 16, 16) for i in range(len(CJK))] +                 [(512 + k * 16, 8) for k in range(96)]
        cols = 16
        rows = (len(cells) + cols - 1) // cols
        pv = Image.new("L", (cols * 18, rows * 18), 40)
        for n, (base, w) in enumerate(cells):
            ox, oy = (n % cols) * 18 + 1, (n // cols) * 18 + 1
            for y in range(16):
                for x in range(w):
                    if (words[base + y] >> (15 - x)) & 1:
                        pv.putpixel((ox + x, oy + y), 255)
        pv.resize((pv.width * 4, pv.height * 4), Image.NEAREST).save(args.preview)


if __name__ == "__main__":
    main()

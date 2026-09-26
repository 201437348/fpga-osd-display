#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_bmp.py —— 生成/校验严格 24 位非压缩 BMP（供 HX4S20C 工程直接读取）

为什么需要这个工具
------------------
"16x16 的 BMP" 本身是 BMP 规范里完全合法的尺寸，不常见的原因是常见的画图工具
（画图 / Photoshop / 在线转换站）在小尺寸下会：
  * 默认存成 32 位带 alpha（biBitCount=32）-> 本工程 header_match 要求 ==24
  * 存成 BI_BITFIELDS（biCompression=3）-> 本工程要求 ==0
  * 存成顶朝下（biHeight 为负）-> 本工程按正值处理，负数会被当成超大高度拒绝
  * 加上 ICC 色彩配置块或 V5 头（biSize=124）-> 本工程要求 biSize>=40 但像素偏移会被推到 54 之后
所以最省事的办法是直接用 20 行代码把字节写死，保证每个字段都符合 fat32_bmp_loader
的 header_match。

本工具做什么
------------
  --size 16x16              生成 16x16 的辨认图（角标 + 边框，用来一眼看出翻转/镜像）
  --from logo.png           把任意图片缩放到指定尺寸后转成合规 BMP
  --check x.bmp             读回 BMP，逐条打印 header_match 的判定结果

用法
----
  python tools/make_bmp.py --size 16x16 --out tiny16.bmp
  python tools/make_bmp.py --size 640x480 --pattern bars --out bars.bmp
  python tools/make_bmp.py --size 160x120 --from photo.jpg --out thumb.bmp
  python tools/make_bmp.py --check tiny16.bmp
"""

import argparse
import struct
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# 控制台中文输出
#   Windows 控制台默认是 GBK(cp936)，被重定向/管道捕获时又常按 UTF-8 解码，
#   两边不一致就会满屏乱码。按"是否终端"选编码：
#     真终端 -> 保持系统编码（GBK 控制台正常显示）
#     被重定向 -> 改 UTF-8（管道/日志/CI 正常显示）
# ---------------------------------------------------------------------------
if not sys.stdout.isatty():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# ---------------------------------------------------------------------------
# 本工程 fat32_bmp_loader.v 的 header_match 条件（2026-09 版）
# ---------------------------------------------------------------------------
MAX_SRC_WIDTH = 1920          # MAX_SRC_WIDTH
MAX_SRC_HEIGHT = 1080         # MAX_SRC_HEIGHT
MIN_SRC_PIXELS = 1            # MIN_SRC_PIXELS（已从 32000 放宽到 1）


def write_bmp24(path, width, height, rows_top_down):
    """写 24 位非压缩 BMP。

    rows_top_down: 长度为 height 的列表，每项是长度为 width 的 [(r,g,b), ...]，
                   rows_top_down[0] 是**最上面**那一行（人眼顺序）。
    BMP 文件内的像素是自底向上存的，函数内部会反转行序。
    """
    if len(rows_top_down) != height:
        raise ValueError(f"行数 {len(rows_top_down)} != height {height}")
    for y, row in enumerate(rows_top_down):
        if len(row) != width:
            raise ValueError(f"第 {y} 行像素数 {len(row)} != width {width}")

    row_bytes = width * 3
    stride = (row_bytes + 3) & ~3          # 每行补齐到 4 字节边界
    pad = stride - row_bytes
    size_image = stride * height

    off_bits = 54                          # 14 字节文件头 + 40 字节信息头
    file_size = off_bits + size_image

    # ---- 14 字节 BMPFILEHEADER ----
    hdr = bytearray()
    hdr += b"BM"
    hdr += struct.pack("<I", file_size)    # bfSize        偏移 2  —— loader 读这个做 header_file_len
    hdr += struct.pack("<HH", 0, 0)        # bfReserved1/2
    hdr += struct.pack("<I", off_bits)     # bfOffBits     偏移 10 —— loader 要求 >=54

    # ---- 40 字节 BITMAPINFOHEADER ----
    hdr += struct.pack("<I", 40)           # biSize        偏移 14 —— loader 要求 >=40
    hdr += struct.pack("<i", width)        # biWidth       偏移 18
    hdr += struct.pack("<i", height)       # biHeight      偏移 22 —— **必须为正**（自底向上）
    hdr += struct.pack("<H", 1)            # biPlanes      偏移 26 —— loader 要求 ==1
    hdr += struct.pack("<H", 24)           # biBitCount    偏移 28 —— loader 要求 ==24
    hdr += struct.pack("<I", 0)            # biCompression 偏移 30 —— loader 要求 ==0
    hdr += struct.pack("<I", size_image)   # biSizeImage
    hdr += struct.pack("<i", 2835)         # biXPelsPerMeter (72 dpi)
    hdr += struct.pack("<i", 2835)         # biYPelsPerMeter
    hdr += struct.pack("<I", 0)            # biClrUsed
    hdr += struct.pack("<I", 0)            # biClrImportant
    assert len(hdr) == 54, len(hdr)

    # ---- 像素数据：自底向上 + BGR 顺序 ----
    body = bytearray()
    for row in reversed(rows_top_down):
        for (r, g, b) in row:
            body += bytes((b & 0xFF, g & 0xFF, r & 0xFF))
        body += b"\x00" * pad

    Path(path).write_bytes(bytes(hdr) + bytes(body))
    return {"width": width, "height": height, "stride": stride,
            "row_bytes": row_bytes, "pad": pad, "file_size": file_size}


# ---------------------------------------------------------------------------
# 图案生成
# ---------------------------------------------------------------------------
def pattern_corners(w, h):
    """四角异色 + 白边框 —— 用来一眼看出上下翻转 / 左右镜像。

    左上=白  右上=红
    左下=绿  右下=蓝
    边框=黄
    """
    k = max(1, min(w, h) // 4)             # 角块边长
    img = []
    for y in range(h):
        row = []
        for x in range(w):
            on_border = (x == 0 or y == 0 or x == w - 1 or y == h - 1)
            tl = (x < k and y < k)
            tr = (x >= w - k and y < k)
            bl = (x < k and y >= h - k)
            br = (x >= w - k and y >= h - k)
            if tl:
                row.append((255, 255, 255))
            elif tr:
                row.append((255, 0, 0))
            elif bl:
                row.append((0, 255, 0))
            elif br:
                row.append((0, 0, 255))
            elif on_border:
                row.append((255, 255, 0))
            else:
                row.append((0, 0, 0))
        img.append(row)
    return img


def pattern_bars(w, h):
    """8 条竖彩条 + 顶部/底部各 1 行标记，用于看缩放与采样。"""
    palette = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
               (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
    img = []
    for y in range(h):
        row = []
        for x in range(w):
            if y == 0:
                row.append((255, 255, 255))
            elif y == h - 1:
                row.append((128, 128, 128))
            else:
                row.append(palette[(x * len(palette)) // w])
        img.append(row)
    return img


def pattern_gradient(w, h):
    """R 随 x 变、G 随 y 变 —— 用来验证双线性插值是否平滑（有没有台阶）。"""
    img = []
    for y in range(h):
        row = []
        for x in range(w):
            r = (x * 255) // max(1, w - 1)
            g = (y * 255) // max(1, h - 1)
            row.append((r, g, 64))
        img.append(row)
    return img


PATTERNS = {"corners": pattern_corners, "bars": pattern_bars, "gradient": pattern_gradient}


def load_and_resize(path, w, h):
    """用 PIL 读入任意图片，缩放到 w x h，返回 top-down RGB 行列表。"""
    try:
        from PIL import Image
    except ImportError:
        sys.exit("需要 Pillow：pip install Pillow")
    im = Image.open(path).convert("RGB").resize((w, h), Image.LANCZOS)
    px = im.load()
    return [[px[x, y] for x in range(w)] for y in range(h)]


# ---------------------------------------------------------------------------
# 校验：逐条复现 fat32_bmp_loader.v 的 header_match
# ---------------------------------------------------------------------------
def check(path):
    data = Path(path).read_bytes()
    n = len(data)
    if n < 54:
        print(f"  [FAIL] 文件只有 {n} 字节，不足 54 字节头")
        return False

    bf_type = data[0:2]
    bf_size = struct.unpack_from("<I", data, 2)[0]
    off_bits = struct.unpack_from("<I", data, 10)[0]
    dib_size = struct.unpack_from("<I", data, 14)[0]
    width = struct.unpack_from("<i", data, 18)[0]
    height = struct.unpack_from("<i", data, 22)[0]
    planes = struct.unpack_from("<H", data, 26)[0]
    bits = struct.unpack_from("<H", data, 28)[0]
    comp = struct.unpack_from("<I", data, 30)[0]

    row_bytes = width * 3
    stride = (row_bytes + 3) & ~3
    expected = off_bits + stride * height

    checks = [
        ("magic 'BM'",              bf_type == b"BM",                    bf_type),
        ("biSize >= 40",            dib_size >= 40,                      dib_size),
        ("biPlanes == 1",           planes == 1,                         planes),
        ("biBitCount == 24",        bits == 24,                          bits),
        ("biCompression == 0",      comp == 0,                           comp),
        ("bfSize != 0",             bf_size != 0,                        bf_size),
        ("bfOffBits >= 54",         off_bits >= 54,                      off_bits),
        ("bfOffBits < bfSize",      off_bits < bf_size,                  f"{off_bits} < {bf_size}"),
        ("bfSize <= 实际文件大小",  bf_size <= n,                        f"{bf_size} <= {n}"),
        ("width != 0",              width != 0,                          width),
        ("width <= 1920",           0 < width <= MAX_SRC_WIDTH,          width),
        ("height != 0",             height != 0,                         height),
        ("height > 0 (自底向上)",   height > 0,                          height),
        ("height <= 1080",          0 < height <= MAX_SRC_HEIGHT,        height),
        ("width*height >= 1",       width * height >= MIN_SRC_PIXELS,    width * height),
        ("bfSize == 头+像素(推算)", bf_size == expected,                 f"{bf_size} vs {expected}"),
    ]

    print(f"\n  {path}   ({n} 字节)")
    print(f"  {'=' * 62}")
    ok_all = True
    for name, ok, val in checks:
        ok_all &= ok
        print(f"  [{'OK  ' if ok else 'FAIL'}] {name:<26} = {val}")
    print(f"  {'-' * 62}")
    print(f"  行字节 = {row_bytes}，对齐后 = {stride}，行尾填充 = {stride - row_bytes} 字节")
    print(f"  像素区 = {stride * height} 字节，文件应为 {expected} 字节（实际 {n}）")
    print(f"  => {'符合 fat32_bmp_loader 的 header_match' if ok_all else '不符合，工程会判 header 失败'}")
    return ok_all


# ---------------------------------------------------------------------------
def parse_size(s):
    try:
        w, h = s.lower().replace("*", "x").split("x")
        return int(w), int(h)
    except Exception:
        raise argparse.ArgumentTypeError(f"尺寸格式应为 WxH，例如 16x16，收到 {s!r}")


def main():
    ap = argparse.ArgumentParser(
        description="生成/校验严格 24 位非压缩 BMP",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    ap.add_argument("--size", type=parse_size, default=(16, 16), help="WxH，默认 16x16")
    ap.add_argument("--out", help="输出 BMP 路径")
    ap.add_argument("--pattern", choices=sorted(PATTERNS), default="corners",
                    help="内置图案，默认 corners（四角异色，可看出翻转/镜像）")
    ap.add_argument("--from", dest="src", help="从任意图片转换")
    ap.add_argument("--check", help="校验一个已有 BMP")
    args = ap.parse_args()

    if args.check:
        sys.exit(0 if check(args.check) else 1)

    w, h = args.size
    if not (0 < w <= MAX_SRC_WIDTH and 0 < h <= MAX_SRC_HEIGHT):
        sys.exit(f"尺寸 {w}x{h} 超出工程限制：宽<= {MAX_SRC_WIDTH}，高<= {MAX_SRC_HEIGHT}")

    rows = load_and_resize(args.src, w, h) if args.src else PATTERNS[args.pattern](w, h)
    out = args.out or f"img_{w}x{h}_{args.pattern if not args.src else 'converted'}.bmp"
    info = write_bmp24(out, w, h, rows)

    print(f"已写入 {out}")
    print(f"  {w}x{h} 24bpp 非压缩，单行 {info['row_bytes']} 字节"
          f"（填充 {info['pad']} 字节），共 {info['file_size']} 字节")
    print(f"  放到 TF 卡上，扩展名只要是 .BMP 就会被扫描到（基名随意）")
    check(out)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
to_bmp24.py —— 把任意 BMP 归一化成 fat32_bmp_loader.v 能接受的严格 24 位 BMP

为什么需要
----------
画图 / Photoshop / 在线转换站导出的 "24 位" BMP 经常仍然过不了工程的
header_match，常见坑：
  * 存成 32 位 BGRA（biBitCount=32）—— 本工程要求 ==24
  * 存成 BI_BITFIELDS（biCompression=3）+ 三个掩码 —— 本工程要求 ==0，
    而且掩码会把 bfOffBits 推到 54 之后
  * 存成 V4/V5 头（biSize=108/124）—— 像素偏移/字段长度都对不上
  * 存成顶朝下（biHeight 为负）—— 本工程按正值处理，负数会被当成超大高度拒绝
  * biSizeImage 留 0 或行尾填充没补齐
所以不要指望图形工具，直接按字节重写最稳。

本工具做什么
------------
按 BMP 规范**真正解析**输入文件，取出像素，再按本工程要求**重新写头**：
  biSize=40, biPlanes=1, biBitCount=24, biCompression=0,
  biHeight>0（自底向上）, bfOffBits=54, bfSize=54+stride*height,
  每行补齐到 4 字节边界。

支持输入：1/4/8 位（含调色板）、16 位、24 位、32 位的 BI_RGB / BI_BITFIELDS，
自底向上和顶朝上（biHeight<0）都能读。

用法
----
  python to_bmp24.py in.bmp                      # 生成 in_24bpp.bmp
  python to_bmp24.py in.bmp -o out.bmp
  python to_bmp24.py in.bmp --check              # 转换后顺便校验
  python to_bmp24.py --check-only in.bmp         # 只校验不转换
"""

import argparse
import struct
import sys
from pathlib import Path

if not sys.stdout.isatty():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# 与 rtl/storage/fat32_bmp_loader.v 的 MIN/MAX_SRC_* 一致（32x32 .. 1280x960）
MIN_SRC_WIDTH = 32
MIN_SRC_HEIGHT = 32
MAX_SRC_WIDTH = 1280
MAX_SRC_HEIGHT = 960


# ---------------------------------------------------------------------------
# 读：把任意 BMP 解析成 top-down 的 [(r,g,b), ...] 行列表
# ---------------------------------------------------------------------------
def read_bmp_any(path):
    d = Path(path).read_bytes()
    if len(d) < 54:
        raise ValueError(f"文件只有 {len(d)} 字节，连 BMP 头都不够")
    if d[0:2] != b"BM":
        raise ValueError(f"不是 BMP：magic = {d[0:2]!r}")

    bf_size, off_bits = struct.unpack_from("<II", d, 2)[0], struct.unpack_from("<I", d, 10)[0]
    dib = struct.unpack_from("<I", d, 14)[0]
    if dib < 40:
        raise ValueError(f"biSize={dib} < 40，是 BITMAPCOREHEADER，暂不支持")

    w, h = struct.unpack_from("<ii", d, 18)
    planes, bpp = struct.unpack_from("<HH", d, 26)
    comp = struct.unpack_from("<I", d, 30)[0]
    clr_used = struct.unpack_from("<I", d, 46)[0] if dib >= 40 else 0

    if planes != 1:
        raise ValueError(f"biPlanes={planes} != 1")
    if w <= 0:
        raise ValueError(f"biWidth={w} 非法")

    top_down = h < 0
    H = abs(h)

    # --- 位掩码 ---
    masks = None
    if comp == 3:                                    # BI_BITFIELDS
        if dib >= 52:
            masks = struct.unpack_from("<III", d, 54)
        else:
            masks = struct.unpack_from("<III", d, 14 + dib)
    elif comp == 6:                                  # BI_ALPHABITFIELDS
        if dib >= 56:
            masks = struct.unpack_from("<IIII", d, 54)[:3]
        else:
            masks = struct.unpack_from("<III", d, 14 + dib)
    elif comp != 0:
        raise ValueError(f"biCompression={comp}，RLE 压缩 BMP 不支持，请先另存为非压缩")

    # --- 调色板 ---
    palette = None
    if bpp <= 8:
        n = clr_used or (1 << bpp)
        base = 14 + dib
        palette = [struct.unpack_from("<BBBB", d, base + i * 4)[:3] for i in range(n)]

    # --- 逐行取像素 ---
    stride = ((w * bpp + 31) // 32) * 4
    need = off_bits + stride * H
    if len(d) < need:
        raise ValueError(f"像素数据不完整：需要 {need} 字节，实际 {len(d)} 字节")

    def mask_shift_bits(m):
        if m == 0:
            return None
        s = (m & -m).bit_length() - 1
        return s, bin(m >> s).count("1")

    rows = []
    for y in range(H):
        src_y = y if top_down else (H - 1 - y)
        o = off_bits + src_y * stride
        line = d[o:o + stride]
        row = []
        if bpp == 24:
            for x in range(w):
                b, g, r = line[x * 3], line[x * 3 + 1], line[x * 3 + 2]
                row.append((r, g, b))
        elif bpp == 32:
            for x in range(w):
                q = line[x * 4:x * 4 + 4]
                if masks:
                    v = q[0] | (q[1] << 8) | (q[2] << 16) | (q[3] << 24)
                    out = []
                    for m in masks:
                        sb = mask_shift_bits(m)
                        if sb is None:
                            out.append(0)
                        else:
                            s, nb = sb
                            raw = (v & m) >> s
                            out.append((raw * 255) // ((1 << nb) - 1))
                    row.append((out[0], out[1], out[2]))
                else:                                # BI_RGB 32bpp: BGRA
                    row.append((q[2], q[1], q[0]))
        elif bpp == 8:
            for x in range(w):
                row.append(palette[line[x]])
        elif bpp == 4:
            for x in range(w):
                v = line[x // 2]
                row.append(palette[(v >> 4) if x % 2 == 0 else (v & 0xF)])
        elif bpp == 1:
            for x in range(w):
                row.append(palette[(line[x // 8] >> (7 - x % 8)) & 1])
        elif bpp in (16, 15):
            if not masks:
                masks = (0x7C00, 0x03E0, 0x001F) if bpp == 15 else (0xF800, 0x07E0, 0x001F)
            for x in range(w):
                v = line[x * 2] | (line[x * 2 + 1] << 8)
                out = []
                for m in masks:
                    s, nb = mask_shift_bits(m)
                    out.append((((v & m) >> s) * 255) // ((1 << nb) - 1))
                row.append((out[0], out[1], out[2]))
        else:
            raise ValueError(f"不支持的 biBitCount={bpp}")
        rows.append(row)

    return {"width": w, "height": H, "bpp": bpp, "comp": comp,
            "top_down": top_down, "off_bits": off_bits,
            "bf_size": bf_size, "dib": dib, "rows": rows}


# ---------------------------------------------------------------------------
# 写：严格 24 位非压缩 BMP
# ---------------------------------------------------------------------------
def write_bmp24(path, width, height, rows_top_down):
    if len(rows_top_down) != height:
        raise ValueError(f"行数 {len(rows_top_down)} != height {height}")
    stride = (width * 3 + 3) & ~3
    pad = stride - width * 3
    size_image = stride * height
    off_bits = 54
    file_size = off_bits + size_image

    hdr = bytearray()
    hdr += b"BM"
    hdr += struct.pack("<I", file_size)
    hdr += struct.pack("<HH", 0, 0)
    hdr += struct.pack("<I", off_bits)
    hdr += struct.pack("<I", 40)
    hdr += struct.pack("<i", width)
    hdr += struct.pack("<i", height)          # 正数 = 自底向上
    hdr += struct.pack("<H", 1)
    hdr += struct.pack("<H", 24)
    hdr += struct.pack("<I", 0)               # BI_RGB
    hdr += struct.pack("<I", size_image)
    hdr += struct.pack("<i", 2835)
    hdr += struct.pack("<i", 2835)
    hdr += struct.pack("<I", 0)
    hdr += struct.pack("<I", 0)
    assert len(hdr) == 54, len(hdr)

    body = bytearray()
    for row in reversed(rows_top_down):
        px = bytearray(width * 3)
        px[0::3] = bytes(p[2] for p in row)
        px[1::3] = bytes(p[1] for p in row)
        px[2::3] = bytes(p[0] for p in row)
        body += px
        body += b"\x00" * pad

    Path(path).write_bytes(bytes(hdr) + bytes(body))
    return {"width": width, "height": height, "stride": stride,
            "pad": pad, "file_size": file_size}


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

    stride = (width * 3 + 3) & ~3
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
        ("32 <= width <= 1280",     MIN_SRC_WIDTH <= width <= MAX_SRC_WIDTH, width),
        ("height != 0",             height != 0,                         height),
        ("height > 0 (自底向上)",   height > 0,                          height),
        ("32 <= height <= 960",     MIN_SRC_HEIGHT <= height <= MAX_SRC_HEIGHT, height),
        ("width*height >= 1",       width * height >= 1,                 width * height),
        ("bfSize == 头+像素(推算)", bf_size == expected,                 f"{bf_size} vs {expected}"),
    ]

    print(f"\n  {path}   ({n} 字节)")
    print(f"  {'=' * 62}")
    ok_all = True
    for name, ok, val in checks:
        ok_all &= ok
        print(f"  [{'OK  ' if ok else 'FAIL'}] {name:<26} = {val}")
    print(f"  {'-' * 62}")
    print(f"  行字节 = {width * 3}，对齐后 = {stride}，行尾填充 = {stride - width * 3} 字节")
    print(f"  像素区 = {stride * height} 字节，文件应为 {expected} 字节（实际 {n}）")
    print(f"  => {'符合 fat32_bmp_loader 的 header_match' if ok_all else '不符合，工程会判 header 失败'}")
    return ok_all


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="把任意 BMP 归一化成严格 24 位非压缩 BMP")
    ap.add_argument("src", help="输入 BMP")
    ap.add_argument("-o", "--out", help="输出 BMP（默认 <名字>_24bpp.bmp）")
    ap.add_argument("--check", action="store_true", help="转换后顺便跑 header_match 校验")
    ap.add_argument("--check-only", action="store_true", help="只校验输入，不转换")
    args = ap.parse_args()

    if args.check_only:
        sys.exit(0 if check(args.src) else 1)

    info = read_bmp_any(args.src)
    print(f"读入 {args.src}")
    print(f"  {info['width']}x{info['height']}  biBitCount={info['bpp']}  "
          f"biCompression={info['comp']}  {'顶朝下' if info['top_down'] else '自底向上'}  "
          f"biSize={info['dib']}  bfOffBits={info['off_bits']}")

    w, h = info["width"], info["height"]
    if not (MIN_SRC_WIDTH <= w <= MAX_SRC_WIDTH and MIN_SRC_HEIGHT <= h <= MAX_SRC_HEIGHT):
        sys.exit(f"尺寸 {w}x{h} 超出工程限制：宽 {MIN_SRC_WIDTH}..{MAX_SRC_WIDTH}，高 {MIN_SRC_HEIGHT}..{MAX_SRC_HEIGHT}")

    out = args.out or str(Path(args.src).with_name(Path(args.src).stem + "_24bpp.bmp"))
    winfo = write_bmp24(out, w, h, info["rows"])
    print(f"已写入 {out}")
    print(f"  {w}x{h} 24bpp 非压缩，单行 {w * 3} 字节（填充 {winfo['pad']} 字节），"
          f"共 {winfo['file_size']} 字节")
    print(f"  原始文件 {Path(args.src).stat().st_size} 字节 -> 省下 "
          f"{Path(args.src).stat().st_size - winfo['file_size']} 字节")

    if args.check:
        check(out)


if __name__ == "__main__":
    main()

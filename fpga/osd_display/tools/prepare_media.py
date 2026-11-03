#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
prepare_media.py —— 演示素材一键准备：6 张图 -> TF 卡 BMP + 串口屏预览 + 安全区检查图

输入目录放 6 张图（PNG/JPG/BMP 都行），文件名以序号开头即可（如 1.png、01.png、2_新品.jpg）。
可选再放两段音频 BGM.WAV / BGM2.WAV（或任意名字的 .wav，用 --bgm/--bgm2 指定）。

输出（默认 <输入目录>/out/）：
  tf/AD01.BMP .. AD06.BMP   严格 24 位 BMP，直接给 FPGA 用（会按 to_bmp24.py 的规则逐条校验）
  tf/BGM.WAV, tf/BGM2.WAV   原样复制（先检查是否为 48 kHz / 16 bit / 立体声 PCM）
  preview/01.png .. 06.png  640x480，与 HDMI 上看到的一样（等比缩放 + 黑边），
                            复制到 VisualTFT工程/PreviewImages/ 再运行 生成当前播放图标.ps1
  check/01.png .. 06.png    同上，再画出会被 OSD 遮挡的区域（红色半透明），用来检查文字有没有被盖住

尺寸：每张图的目标尺寸见 SLOTS（与《作品包装与拍摄脚本 V2》1.2 节一致）。
  输入正好是目标尺寸 -> 原样使用；
  比例一致只是大小不同 -> 高质量缩放到目标尺寸；
  比例不一致 -> 默认居中裁切到目标比例再缩放，并打印提示（--no-crop 改为报错）。

写卡：--copy-to E:\\  按 AD01..AD06、BGM、BGM2 的顺序逐个复制并落盘，写完读回目录顺序校验。
      --copy-only  不重新生成图片，直接写 out/tf 里现有的文件（保留手工调整过的 BMP）。
  FPGA 的播放顺序 = 文件在 FAT 目录里的先后 = 复制先后，所以必须逐个复制。
  写卡前请先把卡格式化为 FAT32，卡里不要留别的 BMP。

用法：
  python prepare_media.py 素材目录
  python prepare_media.py 素材目录 --copy-to E:\\
"""

import argparse
import os
import re
import shutil
import struct
import sys
import wave
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import to_bmp24  # noqa: E402  复用它的写文件与 header 校验

# 播放顺序 -> (目标宽, 目标高, 说明)
SLOTS = [
    (640, 480, "品牌主视觉"),
    (800, 480, "新品横幅"),
    (480, 640, "竖版早餐海报"),
    (160, 120, "会员日小图标（扁平插画）"),
    (960, 540, "门店环境"),
    (1280, 960, "高清细节特写"),
]

OUT_W, OUT_H = 640, 480

# HDMI 640x480 上会被 OSD 盖住的区域（x0, y0, x1, y1），与 rtl/video 下的版面一致
OSD_COVER = [
    (0, 0, 640, 24, "顶栏信息"),
    (64, 360, 576, 424, "音频波形"),
    (0, 432, 640, 456, "滚动字幕"),
    (0, 456, 640, 480, "状态栏"),
]
OSD_POPUP = (176, 132, 464, 336, "设置面板（调参时弹出 5 秒）")


def find_inputs(src):
    files = [p for p in Path(src).iterdir()
             if p.suffix.lower() in (".png", ".jpg", ".jpeg", ".bmp", ".webp")]
    picked = {}
    for p in files:
        # 文件名开头的数字就是序号：1.png、01.png、2_新品.jpg 都行
        m = re.match(r"\s*0*([1-6])(?!\d)", p.stem)
        if m:
            n = int(m.group(1))
            if n in picked:
                sys.exit(f"第 {n} 张有两个文件：{picked[n].name} 和 {p.name}")
            picked[n] = p
    missing = [i for i in range(1, 7) if i not in picked]
    if missing:
        sys.exit(f"缺少第 {missing} 张图（文件名要以 1..6 开头）")
    return [picked[i] for i in range(1, 7)]


def fit_to_slot(img, tw, th, allow_crop, name):
    w, h = img.size
    if (w, h) == (tw, th):
        return img
    if w * th != h * tw:
        if not allow_crop:
            sys.exit(f"{name}: {w}x{h} 与目标 {tw}x{th} 比例不同（去掉 --no-crop 可自动居中裁切）")
        if w * th > h * tw:                      # 太宽，裁左右
            nw = h * tw // th
            x0 = (w - nw) // 2
            img = img.crop((x0, 0, x0 + nw, h))
        else:                                    # 太高，裁上下
            nh = w * th // tw
            y0 = (h - nh) // 2
            img = img.crop((0, y0, w, y0 + nh))
        print(f"  [提示] {name}: {w}x{h} 比例不对，已居中裁切到 {img.size[0]}x{img.size[1]}")
    if img.size[0] < tw or img.size[1] < th:
        print(f"  [提示] {name}: 源图 {img.size[0]}x{img.size[1]} 比目标小，放大后会偏软，建议用更大的原图")
    return img.resize((tw, th), Image.LANCZOS)


def hdmi_view(img):
    """模拟 FPGA 缩放器：统一缩放比 = min(640/W, 480/H)，居中，四周黑边。"""
    w, h = img.size
    s = min(OUT_W / w, OUT_H / h)
    dw, dh = max(1, round(w * s)), max(1, round(h * s))
    canvas = Image.new("RGB", (OUT_W, OUT_H), (0, 0, 0))
    canvas.paste(img.resize((dw, dh), Image.BILINEAR), ((OUT_W - dw) // 2, (OUT_H - dh) // 2))
    return canvas, s


def check_view(view):
    ov = Image.new("RGBA", view.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    for x0, y0, x1, y1, _ in OSD_COVER:
        d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=(255, 40, 40, 110))
    x0, y0, x1, y1, _ = OSD_POPUP
    d.rectangle([x0, y0, x1 - 1, y1 - 1], outline=(255, 210, 0, 255), width=2)
    return Image.alpha_composite(view.convert("RGBA"), ov).convert("RGB")


def check_wav(path):
    try:
        with wave.open(str(path), "rb") as w:
            ch, sw, fr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    except wave.Error as e:
        return False, f"不是标准 PCM WAV（{e}）"
    ok = (ch == 2 and sw == 2 and fr == 48000)
    info = f"{fr} Hz / {sw * 8} bit / {ch} 声道 / {n / fr:.1f} 秒"
    return ok, info


def copy_in_order(files, dest):
    dest = Path(dest)
    if not dest.exists():
        sys.exit(f"写卡目标 {dest} 不存在")
    old = [p.name for p in dest.iterdir() if p.suffix.upper() in (".BMP", ".WAV")]
    if old:
        sys.exit(f"{dest} 里已有 {old}。请先把卡格式化为 FAT32 再写，否则播放顺序会乱")
    for f in files:
        target = dest / f.name
        with open(f, "rb") as fi, open(target, "wb") as fo:
            shutil.copyfileobj(fi, fo, 1 << 20)
            fo.flush()
            os.fsync(fo.fileno())
        print(f"  已写入 {target}")
    # 读回校验：Windows 列 FAT32 目录时按目录项的物理顺序返回，这就是 FPGA 扫描的顺序
    order = [n for n in os.listdir(dest) if Path(n).suffix.upper() in (".BMP", ".WAV")]
    want = [f.name for f in files]
    print(f"  卡上目录顺序：{' -> '.join(order)}")
    if order != want:
        sys.exit("  [错误] 卡上顺序和预期不一致，请重新格式化后再写一次")
    print("  目录顺序校验通过：FPGA 会按 AD01 -> AD06 播放")


def collect_existing(src, out, args):
    """--copy-only：不重新生成，直接用 out/tf 里已有的 BMP（保留手工调整过的版本）。"""
    files = []
    for i in range(1, 7):
        p = out / "tf" / f"AD{i:02d}.BMP"
        if not p.exists():
            sys.exit(f"缺少 {p}，先不带 --copy-only 运行一次生成 BMP")
        if not to_bmp24.check(p):
            sys.exit(f"{p.name} 没通过校验")
        files.append(p)
    for label, opt, default in (("第 1 首", args.bgm, "BGM.WAV"), ("第 2 首", args.bgm2, "BGM2.WAV")):
        cands = [Path(opt)] if opt else [out / "tf" / default] + [q for q in src.iterdir() if q.name.upper() == default]
        p = next((q for q in cands if q.exists()), None)
        if p is None:
            print(f"  {label}：未找到 {default}（跳过）")
            continue
        ok, info = check_wav(p)
        print(f"  {label} {p}：{info}")
        if not ok:
            sys.exit("  格式不对，需要 48000 Hz / 16 bit / 立体声 PCM WAV")
        if p.parent != out / "tf" or p.name != default:   # 卡上文件名必须是 BGM.WAV / BGM2.WAV
            dst = out / "tf" / default
            shutil.copyfile(p, dst)
            p = dst
        files.append(p)
    return files


def main():
    ap = argparse.ArgumentParser(description="6 张图 -> TF 卡 BMP + 串口屏预览 + 安全区检查图")
    ap.add_argument("src", help="素材目录（6 张图以 1..6 开头命名）")
    ap.add_argument("-o", "--out", help="输出目录，默认 <src>/out")
    ap.add_argument("--bgm", help="第 1 首 WAV，默认取 src/BGM.WAV")
    ap.add_argument("--bgm2", help="第 2 首 WAV，默认取 src/BGM2.WAV")
    ap.add_argument("--no-crop", action="store_true", help="比例不对时报错而不是自动裁切")
    ap.add_argument("--copy-to", help="按顺序写入 TF 卡根目录（如 E:\\）")
    ap.add_argument("--copy-only", action="store_true",
                    help="不重新生成，直接把 out/tf 里现有的 BMP（含手工调整过的）按顺序写卡，需配合 --copy-to")
    args = ap.parse_args()

    src = Path(args.src)
    out = Path(args.out) if args.out else src / "out"
    if args.copy_only:
        if not args.copy_to:
            sys.exit("--copy-only 需要同时给 --copy-to <盘符>")
        print("== 使用 out/tf 里现有的文件")
        files = collect_existing(src, out, args)
        print(f"\n== 按顺序写入 {args.copy_to}")
        copy_in_order(files, args.copy_to)
        print("写卡完成。安全弹出后再拔卡。")
        return
    for sub in ("tf", "preview", "check"):
        (out / sub).mkdir(parents=True, exist_ok=True)

    print("== 图片")
    tf_files = []
    all_ok = True
    for i, (path, (tw, th, desc)) in enumerate(zip(find_inputs(src), SLOTS), start=1):
        name = f"第 {i} 张 {path.name}"
        img = fit_to_slot(Image.open(path).convert("RGB"), tw, th, not args.no_crop, name)
        raw = img.tobytes()
        rows = [[tuple(raw[(y * tw + x) * 3:(y * tw + x) * 3 + 3]) for x in range(tw)] for y in range(th)]
        bmp = out / "tf" / f"AD{i:02d}.BMP"
        to_bmp24.write_bmp24(bmp, tw, th, rows)
        ok = to_bmp24.check(bmp)
        all_ok &= ok
        view, s = hdmi_view(img)
        view.save(out / "preview" / f"{i:02d}.png")
        check_view(view).save(out / "check" / f"{i:02d}.png")
        # 顶栏 SCALE 显示的是缩放比 x100 向下取整（960x540 -> 0.66，不是 0.67）
        s100 = min(OUT_W * 100 // tw, OUT_H * 100 // th)
        print(f"  第 {i} 张（{desc}）：{tw}x{th} -> SCALE {s100 // 100}.{s100 % 100:02d}  {'OK' if ok else '校验失败'}")
        tf_files.append(bmp)

    print("== 音频")
    for label, opt, default in (("第 1 首", args.bgm, "BGM.WAV"), ("第 2 首", args.bgm2, "BGM2.WAV")):
        p = Path(opt) if opt else next((q for q in src.iterdir() if q.name.upper() == default), None)
        if p is None or not p.exists():
            print(f"  {label}：未提供（跳过）")
            continue
        ok, info = check_wav(p)
        print(f"  {label} {p.name}：{info}  {'OK' if ok else '格式不对，需要 48000 Hz / 16 bit / 立体声'}")
        all_ok &= ok
        dst = out / "tf" / default
        shutil.copyfile(p, dst)
        tf_files.append(dst)

    print(f"\n输出目录：{out}")
    print("  tf/       -> TF 卡根目录（顺序很重要，见下）")
    print("  preview/  -> VisualTFT工程/PreviewImages/，再运行 生成当前播放图标.ps1")
    print("  check/    -> 红色区域会被 OSD 盖住，黄框是调参时弹出的设置面板")
    if not all_ok:
        sys.exit("\n有文件没通过检查，先处理上面标出的问题。")

    if args.copy_to:
        print(f"\n== 按顺序写入 {args.copy_to}")
        copy_in_order(tf_files, args.copy_to)
        print("写卡完成。安全弹出后再拔卡。")
    else:
        print("\n写卡：格式化为 FAT32 后运行  python prepare_media.py <素材目录> --copy-to <盘符>")


if __name__ == "__main__":
    main()

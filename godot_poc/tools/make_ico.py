# -*- coding: utf-8 -*-
"""把 _store/icon_*.rgba 拼成 Windows 的 .ico（BMP 条目，含 1bpp 掩码）。

为什么不直接用 PNG-in-ICO：Vista 之后其实支持 PNG 条目，但 Godot 注入图标
走的是 rcedit / Windows 资源 API 那条路，对 PNG 条目兼容性不稳；BMP 条目
是 1993 年就定下来的格式，任何环节都认。

为什么不读 PNG：这台机器没有 PIL，装了也未必有。所以上游（tools/store_art.gd）
让 Godot 直接吐 RGBA 原始像素，这里只干"拼文件头 + 上下翻转 + 补掩码"三件事。

用法：
    python tools/make_ico.py                       # 读 _store/icon_*.rgba
    python tools/make_ico.py --out assets/icon.ico
"""
import argparse
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
STORE = os.path.join(ROOT, "_store")
SIZES = [256, 128, 64, 48, 32, 16]


def bmp_entry(path, size):
    rgba = open(path, "rb").read()
    if len(rgba) != size * size * 4:
        raise SystemExit("%s 大小不对：%d != %d" % (path, len(rgba), size * size * 4))

    # BMP 是自下而上、BGRA
    rows = []
    for y in range(size - 1, -1, -1):
        row = bytearray()
        base = y * size * 4
        for x in range(size):
            r, g, b, a = rgba[base + x * 4: base + x * 4 + 4]
            row += bytes((b, g, r, a))
        rows.append(bytes(row))
    xor = b"".join(rows)

    # AND 掩码：32 位图里 alpha 已经足够，掩码全 0 即可。每行按 4 字节对齐。
    stride = ((size + 31) // 32) * 4
    and_mask = b"\x00" * (stride * size)

    header = struct.pack(
        "<IiiHHIIiiII",
        40,          # biSize
        size,        # biWidth
        size * 2,    # biHeight（XOR + AND 两段）
        1,           # biPlanes
        32,          # biBitCount
        0,           # biCompression = BI_RGB
        len(xor) + len(and_mask),
        0, 0, 0, 0,
    )
    return header + xor + and_mask


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "assets", "icon.ico"))
    a = ap.parse_args()

    entries = []
    for s in SIZES:
        p = os.path.join(STORE, "icon_%d.rgba" % s)
        if not os.path.exists(p):
            raise SystemExit("缺 %s（先跑 tools/store_art.tscn）" % p)
        entries.append((s, bmp_entry(p, s)))

    # ICONDIR: reserved=0, type=1, count
    out = bytearray(struct.pack("<HHH", 0, 1, len(entries)))
    offset = 6 + 16 * len(entries)
    for s, blob in entries:
        # 宽高字段：256 记作 0
        w = 0 if s >= 256 else s
        out += struct.pack("<BBBBHHII", w, w, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    for _s, blob in entries:
        out += blob

    with open(a.out, "wb") as f:
        f.write(bytes(out))
    print("make_ico: %s  %d 档  %.1f KB"
          % (a.out, len(entries), len(out) / 1024.0))


if __name__ == "__main__":
    main()

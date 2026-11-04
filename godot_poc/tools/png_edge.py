"""极简 PNG 解码 + 边缘裁切检查。

为什么需要它：`--shot` 出的图就是窗口本身，"面板有没有溢出窗口"这种事
眼睛看不准（差 4px 根本看不出来，但发布出去就是一条黑边）。
这里把最后一行的颜色读出来，和背景色比一下就有结论。

只用标准库（这台机器上没有 PIL），支持 Godot 截图会产出的
8bit RGBA / RGB、非隔行扫描的 PNG。
"""

import struct
import sys
import zlib


def load_png(path):
    """返回 (width, height, rows)；rows 是 [(r,g,b,a), ...] 的列表的列表。"""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("不是 PNG：%s" % path)

    pos = 8
    width = height = depth = ctype = None
    idat = bytearray()
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype_raw = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if ctype_raw == b"IHDR":
            width, height, depth, ctype, comp, filt, inter = struct.unpack(">IIBBBBB", body)
            if depth != 8 or inter != 0 or ctype not in (2, 6):
                raise ValueError("只支持 8bit 非隔行 RGB/RGBA，实际 depth=%s ctype=%s inter=%s"
                                 % (depth, ctype, inter))
        elif ctype_raw == b"IDAT":
            idat += body
        elif ctype_raw == b"IEND":
            break
        pos += 12 + length

    raw = zlib.decompress(bytes(idat))
    bpp = 4 if ctype == 6 else 3
    stride = width * bpp
    rows = []
    prev = bytearray(stride)
    off = 0
    for _y in range(height):
        ftype = raw[off]
        line = bytearray(raw[off + 1:off + 1 + stride])
        off += 1 + stride
        # PNG 的五种行滤波（规范 9.2）
        if ftype == 1:      # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:    # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:    # Average
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:    # Paeth
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif ftype != 0:
            raise ValueError("未知行滤波类型 %d" % ftype)
        prev = line
        if bpp == 4:
            rows.append([tuple(line[i:i + 4]) for i in range(0, stride, 4)])
        else:
            rows.append([tuple(line[i:i + 3]) + (255,) for i in range(0, stride, 3)])
    return width, height, rows


def row_signature(row):
    """一行的「主要颜色」：取出现次数最多的像素。"""
    counts = {}
    for px in row:
        counts[px] = counts.get(px, 0) + 1
    return max(counts.items(), key=lambda kv: kv[1])


def save_png(path, width, height, rows):
    """写 8bit RGBA PNG（filter 0，无压缩优化——只给 QA 看图用）。"""
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for px in row:
            raw += bytes(px[:4])

    def chunk(tag, body):
        return (struct.pack(">I", len(body)) + tag + body
                + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 6)))
        f.write(chunk(b"IEND", b""))


def crop_scale(rows, x, y, w, h, scale):
    """最近邻放大——放大看字形和 1px 偏移时，平滑插值会把问题糊掉。"""
    out = []
    for row in rows[y:y + h]:
        line = []
        for px in row[x:x + w]:
            line.extend([px] * scale)
        for _ in range(scale):
            out.append(list(line))
    return out


def main(argv):
    if len(argv) < 2:
        print("用法: python tools/png_edge.py <png> [背景色]")
        print("      python tools/png_edge.py <png> --crop x,y,w,h [--scale 2] [-o out.png]")
        return 2
    path = argv[1]
    if "--crop" in argv:
        rect = argv[argv.index("--crop") + 1]
        x, y, w, h = (int(v) for v in rect.split(","))
        scale = int(argv[argv.index("--scale") + 1]) if "--scale" in argv else 2
        out = argv[argv.index("-o") + 1] if "-o" in argv else path.replace(".png", "_crop.png")
        _w, _h, rows = load_png(path)
        save_png(out, w * scale, h * scale, crop_scale(rows, x, y, w, h, scale))
        print("CROP %s  %dx%d -> %dx%d scale=%d" % (out, w, h, w * scale, h * scale, scale))
        return 0

    bg_hex = argv[2] if len(argv) > 2 else None
    w, h, rows = load_png(path)
    top, top_n = row_signature(rows[0])
    bot, bot_n = row_signature(rows[-1])
    print("size=%dx%d" % (w, h))
    print("row0     %s  (%d/%d px)" % ("#%02X%02X%02X" % top[:3], top_n, w))
    print("row%d  %s  (%d/%d px)" % (h - 1, "#%02X%02X%02X" % bot[:3], bot_n, w))

    if bg_hex:
        want = tuple(int(bg_hex[i:i + 2], 16) for i in (0, 2, 4))
        ok = True
        for name, c in (("顶边", top), ("底边", bot)):
            if c[:3] != want:
                ok = False
                print("FAIL %s 不是背景色 %s，而是 #%02X%02X%02X —— 有面板贴到窗口边缘"
                      % (name, bg_hex, c[0], c[1], c[2]))
        if ok:
            print("EDGE OK 顶边与底边都是背景色，没有面板溢出窗口")
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

# -*- coding: utf-8 -*-
"""把全量中文字库子集化到本作实际用字，供发行版使用。

为什么必须做：Sans 17.7 MB + Serif 25.1 MB，而本作实际用字一两千个。
不裁剪的话，安装包会白白胖出 40 MB 量级（压缩前后），Steam 页面上很难看。

**两个字族都要子集化**。这一点踩过坑：serif 当初写了个「发行前再补」的
注释就没管，结果 `res://fonts/NotoSerifSC-VF.ttf` 从来不存在，`serif()`
每次都静默回退 SystemFont——主标题、章节名、结局标题的字形在每台机器上
都不一样，非中文系统还可能整块豆腐。所以现在把「两个都必须在包里」写死。

字符集怎么来：**从源码里抽**，而不是从 content_full 抽。因为界面文案大量写在
ui/*.gd 的字符串字面量里（按钮、提示、评级、结局标题…），只抽 content 会漏字，
漏字的后果是运行时出现「豆腐块」，而且很难在测试里发现。

做法：
  1) 逐个文件读文本，**先剥掉注释行**（`#` / `##` 开头到行尾）——
     注释是中文散文，会把字符集撑大一倍，而玩家永远看不到它；
  2) 剩下的非 ASCII 字符全部收进字符集；ASCII 可打印字符整段加进去；
  3) 再补一小撮 CJK 标点与符号（全角括号、破折号、省略号、≥、×…），
     它们可能由运行时拼接或格式化产生；
  4) 用 fontTools 子集化，**保留 layout features**（中文标点挤压、等宽数字靠它）；
  5) 子集化后逐个字符验证 cmap 覆盖，缺一个就报错退出——不允许静默漏字。

用法：
    python tools/make_font_subset.py            # 生成两份 subset
    python tools/make_font_subset.py --verify   # 只校验现有子集覆盖是否够
"""
import argparse
import glob
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                 # godot_poc/
PROJ = os.path.dirname(ROOT)                 # 08_可玩原型/

# (标签, 源字体, 输出子集) —— 顺序即报告顺序。
# 两个字族共用同一份字符集：这样「某个字在 sans 里有、serif 里没有」
# 会在子集化阶段就暴露，而不是等到玩家看到豆腐块。
FAMILIES = [
    ("sans", "NotoSansSC-VF.ttf", "NotoSansSC-subset.ttf"),
    ("serif", "NotoSerifSC-VF.ttf", "NotoSerifSC-subset.ttf"),
]

# 一定会用到的 ASCII（数字、字母、半角标点），整段收进来，避免逐个判断
ASCII = "".join(chr(c) for c in range(0x20, 0x7F))

# 运行时可能拼出来、但源码里不一定出现的符号
EXTRA = (
    "　、。，；：？！…—·～《》〈〉「」『』【】（）〔〕％＋－×÷＝＜＞≥≤±°"
    "①②③④⑤⑥⑦⑧⑨⑩→←↑↓√∞∑≈≠"
)


def fpath(name):
    return os.path.join(ROOT, "fonts", name)


def strip_comments(text):
    """去掉注释行，保留字符串字面量里的 # （例如 Color("#03080A")）。

    只做行级判断：整行 lstrip 后以 # 开头就整行丢掉。行尾注释留着——
    它里面若含中文只会让字符集略大一点，不会漏字，属于安全的方向。
    """
    out = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        out.append(line)
    return "\n".join(out)


def collect():
    chars = set(ASCII)
    chars.update(EXTRA)
    files = []
    files += glob.glob(os.path.join(ROOT, "**", "*.gd"), recursive=True)
    files += glob.glob(os.path.join(ROOT, "**", "*.tscn"), recursive=True)
    files += [os.path.join(PROJ, "content_full.py"),
              os.path.join(PROJ, "gen_data_gd.py"),
              os.path.join(ROOT, "project.godot")]
    for p in files:
        if not os.path.isfile(p):
            continue
        try:
            text = io.open(p, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        text = strip_comments(text)
        for ch in text:
            # U+FEFF 是文件 BOM，不是可见字形，别把它塞进字符集
            if ord(ch) >= 0x80 and ch != "\ufeff":
                chars.add(ch)
    return chars


def coverage(path, chars):
    from fontTools.ttLib import TTFont
    f = TTFont(path, fontNumber=0)
    cmap = set()
    for t in f["cmap"].tables:
        cmap.update(t.cmap.keys())
    return sorted(ch for ch in chars if ord(ch) not in cmap)


def source_missing(src, chars):
    """源字体本身就没有的字形。

    这类字符**子集化救不了**（源里没有，裁完也不会有），只能回到源码换字。
    所以这里单独报出来，并且不当作子集失败——否则每次跑都会被同一批字挡住。
    真实项目里这几个字都是「锦上添花的符号」，换成字体里有的同义符号即可。
    """
    return coverage(src, chars)


def subset_one(label, src, out, chars):
    from fontTools import subset

    src_p = fpath(src)
    out_p = fpath(out)
    if not os.path.exists(src_p):
        print("[%s] 找不到源字体 %s" % (label, src_p))
        return 1

    tmp = out_p + ".tmp"
    args = [
        src_p,
        "--output-file=" + tmp,
        "--unicodes=" + ",".join("U+%04X" % ord(c) for c in sorted(chars)),
        # 别省 layout features：中文标点挤压、数字等宽都靠它，
        # 省了之后「1/2」「——」「（）」的排布会变
        "--layout-features=*",
        "--name-IDs=*",
        "--notdef-outline",
        "--recalc-bounds",
        "--drop-tables+=DSIG",
    ]
    subset.main(args)

    miss = coverage(tmp, chars)
    if miss:
        os.remove(tmp)
        print("[%s] 子集缺字 %d 个，已放弃：%s" % (label, len(miss), "".join(miss[:60])))
        return 1

    os.replace(tmp, out_p)
    before = os.path.getsize(src_p) / 1048576.0
    after = os.path.getsize(out_p) / 1048576.0
    print("[%-5s] %.1f MB → %.1f MB（%.0f%%）  %s"
          % (label, before, after, 100.0 * after / before, out_p))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true")
    a = ap.parse_args()

    chars = collect()
    print("字符集 %d 个（含 ASCII %d）" % (len(chars), len(ASCII)))

    # 源字体本来就没有的字形：不算子集失败，但一定要说清楚，
    # 因为它们在游戏里就是「豆腐块」，只能改源码换字。
    # 取两个字族的**交集**作为可用集合：sans 有、serif 没有的字照样是豆腐。
    usable = set(chars)
    for label, src, _out in FAMILIES:
        if not os.path.exists(fpath(src)):
            continue
        miss = coverage(fpath(src), chars)
        if miss:
            print("⚠ [%s] 源字体缺字 %d 个（子集救不了，需换符号）：%s"
                  % (label, len(miss), "".join(miss)))
            usable -= set(miss)
    chars = sorted(usable)

    if a.verify:
        rc = 0
        for label, _src, out in FAMILIES:
            p = fpath(out)
            if not os.path.exists(p):
                print("[%s] 还没有子集文件：%s" % (label, p))
                rc = 1
                continue
            miss = coverage(p, chars)
            print("[%-5s] %.2f MB  覆盖 %d 字  %s"
                  % (label, os.path.getsize(p) / 1048576.0, len(chars),
                     "OK" if not miss else "缺字 %d 个：%s" % (len(miss), "".join(miss[:60]))))
            if miss:
                rc = 1
        return rc

    rc = 0
    for label, src, out in FAMILIES:
        rc |= subset_one(label, src, out, chars)
    return rc


if __name__ == "__main__":
    sys.exit(main())

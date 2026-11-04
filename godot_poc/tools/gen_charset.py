# -*- coding: utf-8 -*-
"""从 content_full.py 抽出游戏实际用到的字符集，供字体子集化使用。

为什么要这一步：Noto Sans SC 全量 17.7 MB，而本作正文用字大概只有一两千个。
按实际字符集子集化能压到 1 MB 量级，这是发行版必须做的事（否则安装包白胖 40 MB）。

用法：
    python tools/gen_charset.py                 # 写到 fonts/charset.txt
    python tools/gen_charset.py --stats         # 只看统计，不写文件
然后（需要 pip install fonttools，在正常网络环境跑）：
    pyftsubset fonts/NotoSansSC-VF.ttf --text-file=fonts/charset.txt \\
        --layout-features='*' --flavor=woff2 --output-file=fonts/NotoSansSC-subset.woff2

注意 --layout-features='*' 别省：中文标点挤压、数字等宽都靠这些特性，
省掉之后「1/2」「——」「（）」的排布会变。
"""
import argparse
import io
import os
import string
import sys

HERE = os.path.dirname(os.path.abspath(__file__))  # godot_poc/tools/
SRC = os.path.dirname(os.path.dirname(HERE))  # 08_可玩原型/
if SRC not in sys.path:
    sys.path.insert(0, SRC)

# 界面上写死、但不在 content_full 里的文案（按钮、提示、标签）
UI_LITERALS = """
存档 读档 音效 开 关 简报 值班 结果 抉择 结算 通关 下一班 重试 重新开始
已用 刻 换签 待处理 没有待处理工单 刻数不够 试试 等一刻 或换签 本班换签次数用完了
正解 可行 欠妥 事故 状态 无 报修 情绪 红旗 生活 观察 转诊 沟通 家庭 偏方
精力 睡眠债 压力 代谢负荷 炎症水平 身体信任 第 班 目标 分 评级 徽章
继续 返回 确定 取消 关闭 提示 完成 失败 胜利 已解决 已处理
"""


def collect(obj, out):
    if isinstance(obj, str):
        out.update(obj)
    elif isinstance(obj, dict):
        for v in obj.values():
            collect(v, out)
    elif isinstance(obj, (list, tuple, set)):
        for v in obj:
            collect(v, out)


def build_charset():
    import content_full as D

    chars = set()
    for name in dir(D):
        if name.startswith("_") or not name.isupper():
            continue
        collect(getattr(D, name), chars)
    chars.update(UI_LITERALS)
    # 数字、英文字母、常用标点兜底（数值显示、快捷键提示、英文术语）
    chars.update(string.printable)
    chars.update("　·—…“”‘’《》〈〉、。，；：！？（）【】〔〕／％＋－×÷＝")
    chars.discard("\r")
    chars.discard("\x0b")
    chars.discard("\x0c")
    return chars


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stats", action="store_true", help="只打印统计")
    ap.add_argument("-o", "--out", default=os.path.join(HERE, "..", "fonts", "charset.txt"))
    args = ap.parse_args()

    chars = build_charset()
    ordered = "".join(sorted(chars))
    cjk = sum(1 for c in chars if "\u4e00" <= c <= "\u9fff")
    print("字符 %d 个（其中汉字 %d 个）" % (len(chars), cjk))
    print("预估子集体积：约 %.1f MB（全量 17.7 MB）" % (len(chars) / 1200.0))

    if args.stats:
        return 0
    out = os.path.normpath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with io.open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(ordered)
    print("已写入 %s（%d 字节）" % (out, os.path.getsize(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

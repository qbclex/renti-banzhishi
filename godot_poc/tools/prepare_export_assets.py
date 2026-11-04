# -*- coding: utf-8 -*-
"""导出前把「必须按原始字节读」的资源复制一份 .raw 副本。

为什么需要这一步：
    Godot 的导出只认两种东西 —— 导入过的资源（.ctex / .fontdata 等）和
    include_filter 命中的**非资源文件**。`.svg` / `.ttf` / `.png` 都会被
    当成资源先导入，于是包里只剩导入产物，原始文件根本不在。
    而这个项目的图标是**运行时**用 Image.load_svg_from_string() 现场
    光栅化的（每个尺寸重画线宽，才不糊），拿到的必须是 SVG 源码文本。

    `.raw` 不在任何导入器的扩展名清单里，所以它是"非资源文件"，
    能被 include_filter="*.raw" 原样打进包里。

    实测证据（tools/pck_list.py 之前那轮）：包里 res://assets/icons/gear.svg
    只出现过 1 次，来自 gear.svg.import 的 source_file 字段；原始 SVG 的
    内容一个字节都没有 —— 于是导出后所有图标静默消失。

只处理 icons：立绘/背景/卡面/字体已经改成"优先 load()、回退现读文件"，
不需要副本。图标必须留源码，只能走这条路。

用法：
    python tools/prepare_export_assets.py          # 生成/刷新副本
    python tools/prepare_export_assets.py --check  # 只检查是否过期（CI 用）
"""
import argparse
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ICON_DIR = os.path.join(ROOT, "assets", "icons")
SUFFIX = ".raw"


def targets():
    return sorted(glob.glob(os.path.join(ICON_DIR, "*.svg")))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    made = 0
    stale = 0
    for src in targets():
        dst = src + SUFFIX
        blob = open(src, "rb").read()
        if os.path.exists(dst):
            if open(dst, "rb").read() == blob:
                continue
            stale += 1
        if a.check:
            print("  过期/缺失：%s" % os.path.basename(dst))
            continue
        with open(dst, "wb") as f:
            f.write(blob)
        made += 1

    if a.check:
        if stale:
            print("prepare_export_assets: %d 个图标副本缺失或过期，请重跑本脚本" % stale)
            return 1
        print("prepare_export_assets: 全部最新")
        return 0

    # 源 svg 删掉后遗留的副本也要清掉，否则包里会多出"幽灵图标"
    keep = set(p + SUFFIX for p in targets())
    removed = 0
    for old in glob.glob(os.path.join(ICON_DIR, "*.svg" + SUFFIX)):
        if old not in keep:
            os.remove(old)
            removed += 1

    print("prepare_export_assets: 生成 %d 个，刷新 %d 个，清理 %d 个"
          % (made - stale, stale, removed))
    return 0


if __name__ == "__main__":
    sys.exit(main())

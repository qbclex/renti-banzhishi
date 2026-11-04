# -*- coding: utf-8 -*-
"""双端一致性回归：同一批种子下，Python engine.py 与 Godot engine.gd 的轨迹必须逐行相同。

为什么需要它：GDScript 是「逐行翻译」出来的第二份实现，只要一端改了规则而另一端
没跟上，就会悄悄分叉——这正是移植项目最常见的隐性债务。轨迹里含每次出牌、抉择、
结算与六个指标，任何一处偏差都会让 diff 非空。

用法（在 08_可玩原型 目录下）：
    python tools/parity_check.py                 # 默认 8 个种子
    python tools/parity_check.py 7 11 13         # 指定种子
    python tools/parity_check.py --seeds 20      # 前 20 个种子

Godot 路径优先级：环境变量 GODOT / GODOT_BIN > PATH > 常见安装目录。
找不到就跳过（返回 2），以便在没有 Godot 的机器上仍能跑其它测试。
"""
import io
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
GAME_DIR = os.path.dirname(HERE)
sys.path.insert(0, GAME_DIR)

import engine  # noqa: E402


def _scan_dir(root):
    """在 root 下找名字带 godot 的子目录/文件，返回第一个可执行文件。

    只往下探一层再 rglob，避免在 Program Files 上做全盘递归。
    """
    if not root.is_dir():
        return None
    try:
        subs = [p for p in root.iterdir() if "godot" in p.name.lower()]
    except OSError:
        return None
    for sub in subs:
        if sub.is_file() and sub.suffix.lower() == ".exe":
            return str(sub)
        if not sub.is_dir():
            continue
        for pat in ("Godot*win64*console.exe", "Godot*win64*.exe",
                    "Godot.app/Contents/MacOS/Godot", "Godot", "godot"):
            hits = sorted(sub.rglob(pat))
            if hits:
                return str(hits[0])
    return None


def find_godot():
    for key in ("GODOT", "GODOT_BIN", "GODOT4"):
        cand = os.environ.get(key)
        if cand and os.path.exists(cand):
            return cand
    for name in ("godot", "godot4", "godot4.7"):
        hit = shutil.which(name)
        if hit:
            return hit
    home = Path.home()
    roots = [
        home / "AppData" / "Local",
        Path("C:/Program Files"),
        Path("C:/Program Files (x86)") / "Steam" / "steamapps" / "common",
        home / "Applications",
        Path("/Applications"),
        Path("/opt"),
        Path("/usr/local/bin"),
    ]
    for root in roots:
        hit = _scan_dir(root)
        if hit:
            return hit
    return None


def py_trace(seed):
    _g, st = engine.simulate(seed=seed)
    return st["trace"], st


def gd_run(godot, seed):
    cmd = [godot, "--headless", "--path", "godot_poc", "--script", "main.gd",
           "--", str(seed), "--check"]
    r = subprocess.run(cmd, cwd=GAME_DIR, capture_output=True, text=True, timeout=180)
    out = r.stdout + r.stderr
    if "SELF_CHECK_OK" not in out:
        raise RuntimeError("Godot 自检未通过：\n%s" % out[-2000:])
    lines, inside = [], False
    for line in out.splitlines():
        line = line.rstrip("\r")
        if line == "TRACE_BEGIN":
            inside = True
            continue
        if line == "TRACE_END":
            inside = False
            continue
        if inside:
            lines.append(line)
    return lines, out


def first_diff(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    if len(a) != len(b):
        return n
    return -1


def main(argv):
    if "--seeds" in argv:
        k = int(argv[argv.index("--seeds") + 1])
        seeds = list(range(1, k + 1))
    elif argv:
        seeds = [int(x) for x in argv if x.isdigit()]
    else:
        seeds = [20261030, 7, 11, 3, 5, 9, 13, 21]

    godot = find_godot()
    if not godot:
        print("SKIP: 未找到 Godot 可执行文件（设置 GODOT 环境变量后重试）")
        return 2

    print("Godot: %s" % godot)
    print("比对 %d 个种子：%s\n" % (len(seeds), seeds))

    bad = 0
    for seed in seeds:
        pt, st = py_trace(seed)
        gt, out = gd_run(godot, seed)
        i = first_diff(pt, gt)
        if i < 0:
            print("  seed %-9d OK   %3d 行轨迹一致 · 通关=%s · 评级=%s"
                  % (seed, len(pt), st["cleared"], "".join(st["ratings"])))
        else:
            bad += 1
            print("  seed %-9d DIFF 第 %d 行" % (seed, i + 1))
            print("       py: %s" % (pt[i] if i < len(pt) else "<缺行>"))
            print("       gd: %s" % (gt[i] if i < len(gt) else "<缺行>"))
            print("       py 行数=%d  gd 行数=%d" % (len(pt), len(gt)))

    print()
    if bad:
        print("FAIL：%d / %d 个种子轨迹不一致" % (bad, len(seeds)))
        return 1
    print("PASS：%d 个种子的双端轨迹逐行一致" % len(seeds))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

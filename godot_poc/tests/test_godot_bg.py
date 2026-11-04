#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Godot 背景与章节过场接线测试。

这些用例通过真实启动 Godot（headless）来验收：

* 三张烘焙背景（``assets/bg/*.webp``）的亮度曲线——背景在界面里只从 16px 外边距和
  12px 面板缝隙里透出（可见面积约 12%），所以验收标准是**亮度曲线**而不是构图；
* 章节过场界面接线（``engine.advance`` 跨章把新章 dict 带回 / 终章直接通关 /
  ``BgArt.scene_for`` 三分支指向正确）；
* autoplay 端到端跑完全部班次（数量从 content_full.py 计算，不写死；跨章会弹过场
  并在循环头 dismiss，证明接线不卡死）。

纯静态断言（不依赖 Godot）：三张 webp 文件存在、``ui/bg_art.gd`` 缺图返回 null、
背景节点 stretch=cover 且 mouse_filter=IGNORE、``IDS`` 清单与磁盘 / 烘焙脚本一致。

运行（在 ``godot_poc/`` 目录下）::

    python -m unittest tests.test_godot_bg          # 有 Godot 时全跑
    python tests/test_godot_bg.py                   # 同上，自带 __main__

Godot 找不到时，依赖 Godot 的用例自动 skip，静态用例照常跑。
"""

import os
import re
import struct
import subprocess
import sys
import unittest
from pathlib import Path

# godot_poc/ 是项目根；本文件在 godot_poc/tests/ 下。
ROOT = Path(__file__).resolve().parent.parent
# 内容单源在 08_可玩原型/content_full.py：班次总数从数据算，不在测试里写死
sys.path.insert(0, str(ROOT.parent))
import content_full as C  # noqa: E402

TOTAL_SHIFTS = sum(len(ch["shifts"]) for ch in C.CHAPTERS)
ASSETS_BG = ROOT / "assets" / "bg"
UI_BG_ART = ROOT / "ui" / "bg_art.gd"
TOOLS_BG_ART = ROOT / "tools" / "bg_art.gd"
MAIN_UI = ROOT / "ui" / "main_ui.gd"

EXPECTED_IDS = ["bg_nurse_station", "bg_corridor_night", "bg_ward"]


# --------------------------------------------------------------------------- #
# Godot 定位与启动
# --------------------------------------------------------------------------- #
def _discover_godot() -> str | None:
    """按 环境变量 -> PATH -> 常见安装目录 的顺序找 Godot 可执行文件。

    不写死任何人的本机路径——陌生机器 clone 下来只要 Godot 在 PATH 里就能跑。
    """
    for key in ("GODOT_BIN", "GODOT", "GODOT4"):
        env = os.environ.get(key)
        if env and os.path.exists(env):
            return env
    from shutil import which

    for name in ("godot", "godot4", "godot4.7"):
        hit = which(name)
        if hit:
            return hit
    # 常见安装位置：只往下一层再 glob，避免在 Program Files 上做全盘递归
    home = Path.home()
    roots = [
        home / "AppData" / "Local",
        Path("C:/Program Files"),
        Path("C:/Program Files (x86)") / "Steam" / "steamapps" / "common",
        home / "Applications",
        Path("/Applications"),
        Path("/opt"),
    ]
    for root in roots:
        if not root.is_dir():
            continue
        try:
            subs = [p for p in root.iterdir() if "godot" in p.name.lower()]
        except OSError:
            continue
        for sub in subs:
            if not sub.is_dir():
                continue
            for pat in ("Godot*win64*console.exe", "Godot*win64*.exe",
                        "Godot.app/Contents/MacOS/Godot", "Godot"):
                hits = sorted(sub.rglob(pat))
                if hits:
                    return str(hits[0])
    return None


GODOT = _discover_godot()
HAVE_GODOT = GODOT is not None


def run_godot(script_args, timeout=180):
    """启动 Godot headless，返回 (rc, stdout_text)。

    ``script_args`` 形如 ``["--script", "tools/bg_probe.gd", "--", "assets/bg/x.webp"]``
    或 ``["--", "--autoplay"]``。
    """
    cmd = [GODOT, "--headless", "--path", str(ROOT)] + list(script_args)
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout + proc.stderr


# --------------------------------------------------------------------------- #
# 输出解析
# --------------------------------------------------------------------------- #
_STATS_RE = re.compile(
    r"BG_PROBE STATS w=(\d+) h=(\d+) mean=([\d.]+) p50=([\d.]+) p90=([\d.]+) "
    r"p99=([\d.]+) max=([\d.]+) center=([\d.]+) edge=([\d.]+) "
    r"corner_max=([\d.]+) hot=([\d.]+)"
)
_INTRO_RE = re.compile(
    r"INTRO_PROBE crossed=(\w+) new_no=(\S+) cleared=(\w+)"
)
_INTRO_FINAL_RE = re.compile(r"INTRO_PROBE final crossed=(\w+) cleared=(\w+)")
_INTRO_SCENE_RE = re.compile(
    r"INTRO_PROBE scene nurse=(\S+) ward=(\S+) corridor=(\S+)"
)
_AUTOPLAY_RE = re.compile(
    r"AUTOPLAY_OK cleared=(\w+) shifts=(\d+) plays=(\d+) waits=(\d+) "
    r"rerolls=(\d+) dilemmas=(\d+) incidents=(\d+) save=(\w+) ratings=(\S+)"
)
_SAVE_RT_RE = re.compile(r"SAVE_ROUNDTRIP OK")
_REFER_RE = re.compile(
    r"REFER_PROBE open_refs=(\d+) emergency_reds=(\d+) refs_after=(\d+) "
    r"restore_ok=(\w+) restored_refs=(\d+) restored_reds=(\d+) playable=(\w+)"
)
_REFER_RESULT_RE = re.compile(r"REFER_PROBE_RESULT (\w+)")
_CHAOS_RE = re.compile(
    r"CHAOS_OK cleared=(\w+) retries=(\d+) bad_plays=(\d+) shifts=(\d+) "
    r"incidents=(\d+) save=(\w+)"
)


def parse_bg_stats(text):
    m = _STATS_RE.search(text)
    if not m:
        raise AssertionError("BG_PROBE STATS 行未出现；完整输出：\n" + text[-2000:])
    keys = ["w", "h", "mean", "p50", "p90", "p99", "max",
            "center", "edge", "corner_max", "hot"]
    out = {}
    for i, k in enumerate(keys, start=1):
        out[k] = float(m.group(i)) if k != "w" and k != "h" else int(m.group(i))
    return out


# 模块级缓存，避免每个用例都重开 Godot。
_CACHE = {}


def probe_bg(id_):
    if id_ not in _CACHE:
        rc, out = run_godot(
            ["--script", "tools/bg_probe.gd", "--", f"assets/bg/{id_}.webp"]
        )
        assert "BG_PROBE OK" in out, f"bg_probe 未成功：\n{out[-1500:]}"
        _CACHE[id_] = parse_bg_stats(out)
    return _CACHE[id_]


def probe_intro():
    if "intro" not in _CACHE:
        rc, out = run_godot(["--script", "tools/intro_probe.gd"])
        a = _INTRO_RE.search(out)
        b = _INTRO_FINAL_RE.search(out)
        c = _INTRO_SCENE_RE.search(out)
        assert a and b and c, f"intro_probe 输出不完整：\n{out[-1500:]}"
        _CACHE["intro"] = (a, b, c)
    return _CACHE["intro"]


def probe_refer():
    if "refer" not in _CACHE:
        rc, out = run_godot(["--script", "tools/refer_probe.gd"])
        a = _REFER_RE.search(out)
        b = _REFER_RESULT_RE.search(out)
        assert a and b, f"refer_probe 输出不完整：\n{out[-1500:]}"
        _CACHE["refer"] = (a, b)
    return _CACHE["refer"]


def probe_chaos(seed=5):
    key = f"chaos{seed}"
    if key not in _CACHE:
        rc, out = run_godot(["--", "--autoplay", "--chaos", f"--seed={seed}"])
        m = _CHAOS_RE.search(out)
        assert m, f"chaos 巡演输出不完整：\n{out[-2000:]}"
        _CACHE[key] = m
    return _CACHE[key]


def probe_autoplay():
    if "autoplay" not in _CACHE:
        rc, out = run_godot(["--", "--autoplay"])
        ap = _AUTOPLAY_RE.search(out)
        srt = _SAVE_RT_RE.search(out)
        assert ap, f"autoplay 未输出 AUTOPLAY_OK：\n{out[-2000:]}"
        _CACHE["autoplay"] = (ap, bool(srt))
    return _CACHE["autoplay"]


def read_ids_from(src):
    m = re.search(r'IDS\s*:?=\s*\[(.*?)\]', src.read_text(encoding="utf-8"), re.S)
    if not m:
        return None
    return re.findall(r'"([^"]+)"', m.group(1))


def read_crop_ids_from(src):
    txt = src.read_text(encoding="utf-8")
    i = txt.find("const CROP")
    if i < 0:
        return None
    # CROP 含嵌套 {}，用括号配平取出整个块（而非第一个 } 就停）
    j = txt.find("{", i)
    depth = 0
    k = j
    while k < len(txt):
        ch = txt[k]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    block = txt[j:k + 1]
    # 只取顶层键：键名后面紧跟「{」（嵌套的 "zoom"/"anchor_y" 后面是数字，不匹配）
    return re.findall(r'"([^"]+)"\s*:\s*\{', block)


# --------------------------------------------------------------------------- #
# 跳过装饰：无 Godot 时把动态用例挂起（静态用例仍运行）
# --------------------------------------------------------------------------- #
skip_without_godot = unittest.skipUnless(
    HAVE_GODOT, "未找到 Godot 可执行文件（设 GODOT_BIN 后重试）"
)


# --------------------------------------------------------------------------- #
# 静态结构断言（永远运行，不依赖 Godot）
# --------------------------------------------------------------------------- #
class TestStaticStructure(unittest.TestCase):
    def test_baked_webp_files_exist(self):
        for id_ in EXPECTED_IDS:
            p = ASSETS_BG / f"{id_}.webp"
            self.assertTrue(p.exists(), f"缺少烘焙背景：{p}")

    def test_tex_returns_null_on_missing(self):
        src = UI_BG_ART.read_text(encoding="utf-8")
        self.assertIn("static func tex(id: String) -> Texture2D:", src)
        # 找不到文件时必须是 null（调用方退回 BG0 纯色底），不能抛错、不能返回空纹理。
        # 现在走的是 Kit.texture_at 统一入口（导出包里只有导入过的贴图，
        # 开发机上只有原文件），所以判"空路径直接给 null"这条分支。
        self.assertIn('_tex = null if p == "" else Kit.texture_at(p)', src)

    def test_bg_rect_covers_and_ignores_mouse(self):
        src = MAIN_UI.read_text(encoding="utf-8")
        self.assertIn("STRETCH_KEEP_ASPECT_COVERED", src)   # cover，不拉伸
        self.assertIn("MOUSE_FILTER_IGNORE", src)           # 不吃鼠标

    def test_ids_consistent_with_disk(self):
        ids = read_ids_from(UI_BG_ART)
        self.assertIsNotNone(ids, "ui/bg_art.gd 未找到 IDS 清单")
        self.assertEqual(set(ids), set(EXPECTED_IDS))
        for id_ in ids:
            self.assertTrue(
                (ASSETS_BG / f"{id_}.webp").exists(),
                f"IDS 里的 {id_} 在磁盘上找不到对应 webp",
            )

    def test_cover_not_stretch(self):
        crop = read_crop_ids_from(TOOLS_BG_ART)
        self.assertIsNotNone(crop, "tools/bg_art.gd 未找到 CROP 覆盖")
        self.assertEqual(set(crop), set(EXPECTED_IDS))
        for id_ in EXPECTED_IDS:
            # 逐图取景：zoom 必须 > 1（cover 放大），不是 stretch 拉满
            m = re.search(
                r'"%s":\s*\{[^}]*?"zoom":\s*([\d.]+)' % re.escape(id_),
                TOOLS_BG_ART.read_text(encoding="utf-8"),
            )
            self.assertIsNotNone(m, f"{id_} 缺少 zoom 取景参数")
            self.assertGreater(float(m.group(1)), 1.0, f"{id_} 的 zoom 应 >1（cover）")


# --------------------------------------------------------------------------- #
# 烘焙背景亮度曲线（依赖 Godot）
# --------------------------------------------------------------------------- #
class TestBakedBrightness(unittest.TestCase):
    # 验收带：基于实测烘焙产物（1920×1230）
    #   center 0.07–0.10、edge 0.03–0.05、max<0.30、corner_max<0.10、hot≈0
    CENTER_BAND = (0.05, 0.13)
    EDGE_BAND = (0.02, 0.09)
    MAX_LIMIT = 0.30
    CORNER_LIMIT = 0.10
    HOT_LIMIT_PCT = 0.5

    def _check(self, id_):
        s = probe_bg(id_)
        self.assertEqual((s["w"], s["h"]), (1920, 1230), f"{id_} 尺寸应 1920×1230")
        self.assertGreaterEqual(s["center"], self.CENTER_BAND[0])
        self.assertLessEqual(s["center"], self.CENTER_BAND[1])
        self.assertGreaterEqual(s["edge"], self.EDGE_BAND[0])
        self.assertLessEqual(s["edge"], self.EDGE_BAND[1])
        self.assertLess(s["max"], self.MAX_LIMIT, f"{id_} 出现白块（max≥0.30）")
        self.assertLess(s["corner_max"], self.CORNER_LIMIT, f"{id_} 右下角疑似水印残留")
        self.assertLess(s["hot"], self.HOT_LIMIT_PCT, f"{id_} 过亮像素占比异常")
        return s

    @skip_without_godot
    def test_nurse_station(self):
        self._check("bg_nurse_station")

    @skip_without_godot
    def test_corridor_night(self):
        self._check("bg_corridor_night")

    @skip_without_godot
    def test_ward(self):
        self._check("bg_ward")


# --------------------------------------------------------------------------- #
# 章节过场接线（依赖 Godot）
# --------------------------------------------------------------------------- #
@skip_without_godot
class TestChapterIntroWiring(unittest.TestCase):
    def test_advance_crosses_chapter(self):
        a, b, c = probe_intro()
        self.assertEqual(a.group(1), "true", "advance 跨章应带回新章 dict")
        # 第一章最后一班 advance -> 进入第二章（no=2）
        self.assertEqual(a.group(2), "2")
        self.assertEqual(a.group(3), "false")

    def test_final_chapter_clears_without_intro(self):
        a, b, c = probe_intro()
        self.assertEqual(b.group(1), "false", "终章 advance 不应再弹过场")
        self.assertEqual(b.group(2), "true", "终章 advance 应直接通关")

    def test_scene_for_three_branches(self):
        a, b, c = probe_intro()
        self.assertEqual(c.group(1), "bg_nurse_station")
        self.assertEqual(c.group(2), "bg_ward")
        self.assertEqual(c.group(3), "bg_corridor_night")


# --------------------------------------------------------------------------- #
# autoplay 端到端（依赖 Godot）
# --------------------------------------------------------------------------- #
@skip_without_godot
class TestAutoplay(unittest.TestCase):
    def test_runs_full_campaign(self):
        ap, srt = probe_autoplay()
        self.assertEqual(ap.group(1), "true", "应通关")
        self.assertEqual(int(ap.group(2)), TOTAL_SHIFTS,
                         "应走完 %d 班" % TOTAL_SHIFTS)
        self.assertEqual(int(ap.group(7)), 0, "incidents 应为 0")
        self.assertEqual(ap.group(8), "true", "应完成存档往返")
        # ratings 串每班一个评级，长度必须等于总班次
        self.assertEqual(len(ap.group(9)), TOTAL_SHIFTS)

    def test_save_roundtrip_present(self):
        ap, srt = probe_autoplay()
        self.assertTrue(srt, "autoplay 应夹一次存档→读档往返")


# --------------------------------------------------------------------------- #
# 红旗可解性（第 3 班的红旗是「班中突发」插入的，最易漏）
# --------------------------------------------------------------------------- #
@skip_without_godot
class TestRedflagPlayable(unittest.TestCase):
    def test_probe_result_ok(self):
        a, b = probe_refer()
        self.assertEqual(b.group(1), "true", "红旗应始终可解")

    def test_emergency_redflag_gets_refer_card(self):
        a, b = probe_refer()
        reds = int(a.group(2))
        refs = int(a.group(3))
        self.assertGreaterEqual(reds, 1, "第 3 班应突发一张红旗")
        self.assertGreaterEqual(refs, reds, "突发红旗插入后手里应有等量转诊牌")

    def test_old_save_is_repaired_on_restore(self):
        a, b = probe_refer()
        self.assertEqual(a.group(4), "true", "旧档应能正常读回")
        self.assertGreaterEqual(int(a.group(5)), int(a.group(6)),
                                "旧档读回后转诊牌数应覆盖红旗数")
        self.assertEqual(a.group(7), "true", "补出来的转诊牌必须真的可打")


# --------------------------------------------------------------------------- #
# 混沌巡演：故意踩事故，验证「事故 → 本班作废 → 重打」不会软锁、且事故会被记账
# --------------------------------------------------------------------------- #
@skip_without_godot
class TestChaosRecovery(unittest.TestCase):
    def test_incident_does_not_softlock(self):
        m = probe_chaos()
        self.assertEqual(m.group(1), "true", "踩了事故之后整场仍应能打完")
        self.assertEqual(int(m.group(4)), TOTAL_SHIFTS,
                         "仍应走完 %d 班" % TOTAL_SHIFTS)
        self.assertEqual(m.group(6), "true", "存档往返仍应正常")

    def test_incident_path_was_actually_exercised(self):
        m = probe_chaos()
        self.assertGreaterEqual(int(m.group(2)), 1, "应至少重打过一次")
        self.assertGreaterEqual(int(m.group(3)), 1, "应至少故意打错过一次")

    def test_incident_is_counted_not_whitewashed(self):
        # 事故发生过就必须记进整场账本，否则「重打本班」可以无限洗白，
        # 真结局门槛（total_incidents <= 2）形同虚设。
        m = probe_chaos()
        self.assertGreaterEqual(int(m.group(5)), 1,
                                "事故数应 > 0（重打不能清零整场账本）")


# --------------------------------------------------------------------------- #
# 启动入口一致性：防止「双击的入口」和「实际在做的游戏」分叉
# --------------------------------------------------------------------------- #
class TestEntryConsistency(unittest.TestCase):
    """用户双击的 .bat 必须都指向 Godot 版，且脚本内容必须是纯 ASCII。

    cmd.exe 按系统 ANSI 代码页（zh-CN = GBK）解析 .bat，与 chcp 无关，
    脚本里出现中文会被吃成乱码并破坏 set 语句——这是本项目真实踩过的坑。
    """

    PROTO = ROOT.parent

    def _read(self, name):
        p = self.PROTO / name
        self.assertTrue(p.exists(), f"缺少启动入口：{p}")
        return p.read_bytes()

    def test_launchers_are_pure_ascii(self):
        for name in ("launch_godot.bat", "启动Godot版.bat", "启动游戏.bat"):
            raw = self._read(name)
            bad = [b for b in raw if b > 0x7F]
            self.assertEqual(bad, [], f"{name} 含非 ASCII 字节，cmd 会解析成乱码")

    def test_both_entries_delegate_to_single_launcher(self):
        for name in ("启动Godot版.bat", "启动游戏.bat"):
            txt = self._read(name).decode("ascii", "replace").lower()
            self.assertIn("launch_godot.bat", txt,
                          f"{name} 没有委托给 launch_godot.bat，入口会与游戏分叉")

    def test_launcher_targets_godot_project(self):
        txt = self._read("launch_godot.bat").decode("ascii", "replace")
        self.assertIn("godot_poc", txt, "启动器应指向 godot_poc 工程")
        self.assertIn("project.godot", txt, "启动器应校验 project.godot 存在")

    def test_no_entry_still_runs_python_remnant(self):
        for name in ("启动Godot版.bat", "启动游戏.bat", "launch_godot.bat"):
            raw = self._read(name).decode("ascii", "replace").splitlines()
            # 只看可执行行：rem 注释里提到 game.py（说明历史）是允许的。
            code = [ln.strip().lower() for ln in raw
                    if ln.strip() and not ln.strip().lower().startswith("rem")]
            self.assertNotIn("game.py", "\n".join(code),
                             f"{name} 仍会启动 Python 残本 game.py")


class TestSettings(unittest.TestCase):
    """设置系统：默认值 / 存取往返 / 音频总线，全部由 tools/settings_probe.gd 验。"""

    def test_probe_passes(self):
        rc, out = run_godot(["--script", "tools/settings_probe.gd"])
        m = re.search(r"SETTINGS_OK (true|false)", out)
        self.assertIsNotNone(m, f"settings_probe 没有输出结论：\n{out[-1200:]}")
        self.assertEqual(m.group(1), "true", f"设置探针报错：\n{out[-1500:]}")
        self.assertEqual(rc, 0, "设置探针应正常退出")

    def test_settings_ui_is_ascii_safe_path(self):
        """设置里引用的资源必须存在：图标或字体缺了会静默变成空白按钮。"""
        src = (ROOT / "ui" / "main_ui.gd").read_text(encoding="utf-8")
        self.assertIn('"gear"', src, "顶栏设置按钮应带齿轮图标")
        self.assertTrue((ROOT / "assets" / "icons" / "gear.svg").exists(),
                        "gear.svg 缺失，设置按钮会没有图标")


if __name__ == "__main__":
    unittest.main(verbosity=2)


# --------------------------------------------------------------------------- #
# 发行包：这一整轮踩过的坑，逐条钉住
# --------------------------------------------------------------------------- #
class TestReleasePack(unittest.TestCase):
    """导出包里"资源静默缺失"是这类项目最难发现的故障形态。

    游戏缺图不崩、只降级，`--autoplay` 依然一路绿灯。这里把修复方案钉死：
    图标必须有 `.raw` 副本（原始 SVG 会被导入管线吃掉），加载器必须先找副本，
    导出过滤必须放行 `.raw` 且排除 `_store/`。
    """

    ICONS = ROOT / "assets" / "icons"
    PRESET = ROOT / "export_presets.cfg"

    def test_every_svg_has_raw_copy(self):
        for svg in sorted(self.ICONS.glob("*.svg")):
            raw = svg.with_suffix(".svg.raw")
            self.assertTrue(raw.exists(), f"缺 .raw 副本：{raw.name}（跑 tools/prepare_export_assets.py）")
            self.assertEqual(svg.read_bytes(), raw.read_bytes(),
                             f"{raw.name} 和源文件不一致（改完图标没刷新副本）")

    def test_icon_loader_prefers_raw(self):
        src = (ROOT / "ui" / "icons.gd").read_text(encoding="utf-8")
        # 先找 .svg.raw，再退回 .svg
        self.assertLess(src.index('".svg.raw"'), src.index('".svg"'), "加载顺序反了：副本要优先")

    def test_export_preset_includes_raw_and_excludes_store(self):
        cfg = self.PRESET.read_text(encoding="utf-8")
        inc = re.search(r'include_filter="([^"]*)"', cfg).group(1)
        exc = re.search(r'exclude_filter="([^"]*)"', cfg).group(1)
        self.assertIn("*.raw", inc, "include_filter 没放行 .raw，图标会整批消失")
        self.assertIn("_store/*", exc, "商店素材会被打进发行包")
        self.assertIn("assets/chars_src/*", exc, "立绘原图（100MB+）不能进包")

    def test_ico_has_all_sizes(self):
        ico = ROOT / "assets" / "icon.ico"
        self.assertTrue(ico.exists(), "缺 assets/icon.ico（跑 tools/make_ico.py）")
        blob = ico.read_bytes()
        reserved, kind, count = struct.unpack("<HHH", blob[:6])
        self.assertEqual((reserved, kind), (0, 1), "ICONDIR 头不对")
        self.assertEqual(count, 6, "应有 6 档尺寸")
        # 每条的 offset/size 必须落在文件内，否则 Windows 会静默不显示图标
        for i in range(count):
            w, h, _c, _r, planes, bits, size, off = struct.unpack(
                "<BBBBHHII", blob[6 + i * 16: 6 + (i + 1) * 16])
            self.assertLessEqual(off + size, len(blob), f"第 {i} 档越界")
            self.assertEqual((planes, bits), (1, 32))

    def test_bat_is_pure_ascii(self):
        # cmd 用系统 ANSI 代码页解析 .bat，UTF-8 中文会把行首的 rem 吃掉
        for p in [ROOT.parent / "build_win.bat"]:
            blob = p.read_bytes()
            self.assertTrue(all(b < 128 for b in blob), f"{p.name} 含非 ASCII 字节，cmd 会解析错")


# --------------------------------------------------------------------------- #
# 第二轮复查（三轮体检）修掉的问题，逐条钉住
# --------------------------------------------------------------------------- #
class TestSecondPass(unittest.TestCase):
    """这一轮的四个 bug 都属于「界面看着正常、指标全绿、实际是错的」。

    共同点是**闸门本身有洞**：自检只打印不判定、巡演指标不进 ok、
    循环顺序写反后少覆盖 6 个抉择却照样打印 OK。所以这几条测试全都
    断在「判据」上，而不是断在「功能」上——功能本来就是好的。
    """

    UI = ROOT / "ui" / "main_ui.gd"
    KIT = ROOT / "ui" / "ui_kit.gd"

    def test_serif_subset_ships_with_project(self):
        """衬线子集必须在工程里，且 ui_kit 指向它。

        原 bug：EMBEDDED_SERIF 指着 fonts/NotoSerifSC-VF.ttf，而这个文件
        从没进过仓库。serif() 每次静默回退 SystemFont，标题字形随机器漂。
        """
        kit = self.KIT.read_text(encoding="utf-8")
        self.assertIn('const EMBEDDED_SERIF := "res://fonts/NotoSerifSC-subset.ttf"', kit)
        subset = ROOT / "fonts" / "NotoSerifSC-subset.ttf"
        self.assertTrue(subset.exists(), "缺衬线子集（跑 tools/make_font_subset.py）")
        self.assertGreater(subset.stat().st_size, 100_000, "衬线子集小得不像话")

    def test_both_fonts_are_subsetted_not_packed_whole(self):
        """全量字库必须被 exclude_filter 挡住，两份子集都要能进包。"""
        cfg = (ROOT / "export_presets.cfg").read_text(encoding="utf-8")
        exc = re.search(r'exclude_filter="([^"]*)"', cfg).group(1)
        for full in ["fonts/NotoSansSC-VF.ttf", "fonts/NotoSerifSC-VF.ttf"]:
            self.assertIn(full, exc, f"{full} 会被打进发行包（多 17–25 MB）")
        for sub in ["NotoSansSC-subset.ttf", "NotoSerifSC-subset.ttf"]:
            self.assertNotIn(sub, exc, f"{sub} 被子集规则误伤")

    def test_selfcheck_judges_serif_and_counts(self):
        """自检必须把衬线、图标数、卡面数纳入判定，而不是只打印。

        原 bug：serif 只打印 serif_system=...；图标清单为空时循环不转，
        miss 一条不加；卡面 cards=0/43 也是零条 miss。
        """
        src = self.UI.read_text(encoding="utf-8")
        start = src.index("func _selfcheck()")
        body = src[start:start + 3000]
        self.assertIn("serif_ok", body, "自检没判衬线字体")
        self.assertIn("if not serif_ok:", body)
        self.assertIn("var ok: bool = miss.is_empty() and sans_ok and serif_ok and save_ok",
                      body, "serif_ok 没进最终判定")
        self.assertIn("图标清单为空", body, "图标全丢时闸门不会红")
        self.assertIn("卡面缺失", body, "卡面全丢时闸门不会红")

    def test_char_hosts_is_single_source(self):
        """立绘宿主清单只能有一份，自检不能另写 range(1,6)。"""
        art = (ROOT / "ui" / "char_art.gd").read_text(encoding="utf-8")
        self.assertIn("const HOSTS := [1, 2, 3, 4, 5]", art)
        src = self.UI.read_text(encoding="utf-8")
        start = src.index("func _selfcheck()")
        body = src[start:start + 3000]
        self.assertIn("CharArt.HOSTS", body)
        self.assertNotIn("range(1, 6)", body, "自检还在用写死的宿主编号")

    def test_autoplay_resolves_dilemma_before_settle(self):
        """巡演循环里抉择必须排在 settle 之前，和 _refresh_overlay 一致。

        原 bug：先判 settle 再判 pending_dilemma，于是「最后一张牌同时触发
        抉择与结算」时抉择被 _next_shift 冲掉——25 班只弹 19 个抉择。
        """
        src = self.UI.read_text(encoding="utf-8")
        start = src.index("func _autoplay(")
        body = src[start:start + 6000]
        i_dil = body.index("if game.pending_dilemma != null:")
        i_set = body.index('if game.phase == "settle":')
        self.assertLess(i_dil, i_set, "抉择判断被排在结算之后，会被吞掉")

    def test_autoplay_detects_swallowed_dilemma(self):
        """巡演必须能发现「抉择被结算冲掉」，否则少弹几个也是全绿。

        判据不能写成「抉择数 == 班次数」：1 个工单的短班次常常在 clock 走到
        过半之前就打完了，本来就不该弹抉择（实测 100 局里有 17 个班次这样）。
        所以判的是**引擎已触发（dilemma_fired）但 UI 一次都没处理**。
        这条判据经过反向验证：把顺序改回 settle 优先，它会准确报出 6 个班次。
        """
        src = self.UI.read_text(encoding="utf-8")
        start = src.index("func _autoplay(")
        body = src[start:start + 9000]
        self.assertIn("if game.dilemma_fired and not shift_had_dilemma:", body)
        self.assertIn("swallowed += 1", body)
        self.assertIn("if not chaos and swallowed > 0:", body)
        # 反向断：不能再退回「数量相等」那种会误报的写法
        self.assertNotIn("dilemmas < _total_shifts()", body)

    def test_automation_modes_never_touch_player_save(self):
        """--autoplay / --shot 必须写假槽位，不能覆盖 slot1。"""
        save = (ROOT / "ui" / "save_sys.gd").read_text(encoding="utf-8")
        self.assertIn("static var SLOT := SLOT_MAIN", save)
        self.assertIn("static func use_probe_slot()", save)
        self.assertIn("_probe.sav", save)
        src = self.UI.read_text(encoding="utf-8")
        self.assertIn("Save.use_probe_slot()", src)
        # 调用必须发生在两个自动化分支之前
        i_call = src.index("Save.use_probe_slot()")
        i_auto = src.index('if "--autoplay" in args:')
        i_shot = src.index('if "--shot" in args:')
        self.assertLess(i_call, i_auto)
        self.assertLess(i_call, i_shot)

    def test_resolution_is_clamped_to_screen(self):
        """窗口尺寸必须夹到屏幕可用区域内。

        原 bug：1366×768 的笔记本选 1920×1080，窗口比屏幕大，
        设置面板跑出屏幕，底部「完成」按钮点不到。
        """
        s = (ROOT / "ui" / "app_settings.gd").read_text(encoding="utf-8")
        self.assertIn("screen_get_usable_rect", s)
        self.assertIn("mini(size.x, usable.size.x)", s)
        self.assertIn("mini(size.y, usable.size.y)", s)


class TestQuackReachability(unittest.TestCase):
    """偏方牌必须真的能到手，否则它们在工单的 bad 里就是死数据。

    原 bug：c_pill / c_detox / c_alkaline / c_herb / c_patch 既不在初始牌组，
    也不在任何一班的奖励里，却被 55 个工单列为 bad——玩家永远抽不到，
    「选错会被惩罚」的设计等于不存在。修法是让宿主在特定班次**强行带回**
    一张偏方（gift），当班可用、赢了也甩不掉。
    """

    QUACKS = ["c_pill", "c_detox", "c_alkaline", "c_herb", "c_patch"]

    def _gifts(self):
        out = []
        for ch in C.CHAPTERS:
            for sd in ch["shifts"]:
                for cid in sd.get("gift", []):
                    out.append((ch["no"], sd["n"], cid, sd))
        return out

    def test_every_card_is_obtainable(self):
        """43 张牌每一张都要有获得途径，不能有永远抽不到的死数据。"""
        reachable = set(C.STARTER_DECK)
        for ch in C.CHAPTERS:
            for sd in ch["shifts"]:
                reachable |= set(sd.get("reward", [])) | set(sd.get("gift", []))
        dead = [c["id"] for c in C.CARDS if c["id"] not in reachable]
        self.assertEqual(dead, [], f"这些牌永远拿不到：{dead}")

    def test_all_quacks_reachable(self):
        """五张偏方牌全部要在 gift 或初始牌组里。"""
        reachable = set(C.STARTER_DECK)
        for _, _, cid, _ in self._gifts():
            reachable.add(cid)
        for cid in self.QUACKS:
            self.assertIn(cid, reachable, f"偏方牌 {cid} 拿不到")

    def test_gift_shifts_explain_themselves(self):
        """塞干扰牌的班次必须写 gift_note，否则玩家以为牌组出 bug 了。"""
        for no, n, cid, sd in self._gifts():
            note = str(sd.get("gift_note", "")).strip()
            self.assertTrue(note, f"第 {no} 章第 {n} 班塞了 {cid} 却没写 gift_note")

    def test_gift_never_duplicates_reward(self):
        """同一张牌不能既是奖励又是干扰（会让人分不清它的身份）。"""
        for no, n, _, sd in self._gifts():
            overlap = set(sd.get("gift", [])) & set(sd.get("reward", []))
            self.assertEqual(overlap, set(), f"第 {no} 章第 {n} 班奖励与干扰重叠：{overlap}")

    def test_gift_ids_exist(self):
        for no, n, cid, _ in self._gifts():
            self.assertIn(cid, C.CARD_MAP, f"第 {no} 章第 {n} 班引用了不存在的牌 {cid}")

    def test_both_engines_treat_gift_like_reward(self):
        """gift 必须走与 reward 同一套入牌组逻辑，两端都不能漏。

        漏了任何一端，gift 就只在简报里显示、实际拿不到——比原来更糟。
        """
        py = (ROOT.parent / "engine.py").read_text(encoding="utf-8")
        gd = (ROOT / "engine.gd").read_text(encoding="utf-8")
        self.assertIn("def _shift_cards(self):", py)
        self.assertIn('list(sd.get("reward", [])) + list(sd.get("gift", []))', py)
        self.assertIn("func _shift_cards() -> Array:", gd)
        self.assertIn('sd.get("gift", [])', gd)
        # 装载与结算两处都必须走这个入口（Python 侧签名带 self，`()` 只出现在调用处）
        self.assertEqual(py.count("self._shift_cards()"), 2,
                         "engine.py 里 _shift_cards 调用次数不对（应 2 处：装载 + 结算）")
        self.assertEqual(gd.count("_shift_cards()"), 3,
                         "engine.gd 里 _shift_cards 次数不对（应定义 1 + 调用 2）")

    def test_brief_shows_the_gift(self):
        """简报必须把带回来的牌摆出来，否则就是偷偷加难度。"""
        src = (ROOT / "ui" / "main_ui.gd").read_text(encoding="utf-8")
        start = src.index("func _ov_brief() -> Control:")
        body = src[start:start + 2600]
        self.assertIn('sd.get("gift", [])', body)
        self.assertIn("_gift_row(", body)
        self.assertIn("func _gift_row(", src)

# -*- coding: utf-8 -*-
"""
《人体值班室》垂直切片原型 · 桌面版 (tkinter)
运行：python game.py
5 章 × 3 班 = 15 关 · 42 张处置签 · 牌组构筑 · 班次目标
"""
import os
import sys
import math
import random
import tkinter as tk
import tkinter.font as tkfont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import content_full as D
from audio import Sfx
from engine import Game, clamp          # 规则引擎与界面分离

if sys.platform == "win32":
    try:
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass

DW, DH = 1600, 900

BG_0      = "#060F12"
BG_1      = "#0A181C"
PANEL     = "#102529"
PANEL_HI  = "#143036"
LINE      = "#1C3A40"
LINE_SOFT = "#163035"
PAPER     = "#F7F2E6"
PAPER_2   = "#EDE4D2"
PAPER_3   = "#E0D5BE"
INK       = "#14262A"
INK_2     = "#3E5257"
INK_3     = "#6C7E82"
TEAL      = "#38A0A8"
TEAL_D    = "#1F6F78"
CORAL     = "#D95E42"
GOLD      = "#C9A227"
VIOLET    = "#8E74AC"
GREEN     = "#54A374"
GREY      = "#8CA0A4"
MUTED     = "#4C666C"
WHITE     = "#FFFFFF"

# 五章主题色（与网页版一致）
THEMES = {
    1: dict(accent="#46C0C8", accent_d="#1B7A84", accent_2="#7BD8DE", scene="ch1"),
    2: dict(accent="#E0A93B", accent_d="#8C6410", accent_2="#F5CE72", scene="ch2"),
    3: dict(accent="#9A8AE0", accent_d="#5B4C9C", accent_2="#C0B4F0", scene="ch3"),
    4: dict(accent="#E08AA6", accent_d="#94425C", accent_2="#F3B6C8", scene="ch4"),
    5: dict(accent="#D89A5E", accent_d="#8A5A2A", accent_2="#F0C48C", scene="ch5"),
}
SCENE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scenes")

SCHOOL_COLOR = {k: v[1] for k, v in D.SCHOOLS.items()}
SCHOOL_NAME = {k: v[0] for k, v in D.SCHOOLS.items()}


def pick_font(cands, fallback="TkDefaultFont"):
    try:
        avail = set(tkfont.families())
    except Exception:
        return fallback
    for c in cands:
        if c in avail:
            return c
    return fallback


def mix(c1, c2, t):
    c1 = c1.lstrip("#"); c2 = c2.lstrip("#")
    r1, g1, b1 = int(c1[0:2], 16), int(c1[2:4], 16), int(c1[4:6], 16)
    r2, g2, b2 = int(c2[0:2], 16), int(c2[2:4], 16), int(c2[4:6], 16)
    return "#%02x%02x%02x" % (
        int(r1 + (r2 - r1) * t), int(g1 + (g2 - g1) * t), int(b1 + (b2 - b1) * t))
# =====================================================================
#                            规则引擎
# =====================================================================
class App(tk.Tk):
    def __init__(self):
        super().__init__()
        try:
            self.tk.call("tk", "scaling", 1.0)
        except Exception:
            pass
        self.title("人体值班室")
        self.configure(bg=BG_0)
        self.minsize(1120, 640)

        self.f_serif = pick_font(["Noto Serif SC", "Source Han Serif SC", "思源宋体 CN", "SimSun"])
        self.f_sans = pick_font(["Microsoft YaHei UI", "Microsoft YaHei", "微软雅黑", "SimHei"])

        self.game = Game(seed=20261030)
        self.hover_card = None
        self.toast = None
        self.toast_job = None
        self.result_modal = None
        self.picks = []          # 构筑三选一已选
        self.hotspots = []
        self.card_rects = []
        self._photo = {}         # 场景图缓存
        self._scene_key = None   # 当前场景 key
        self.theme = THEMES[1]   # 当前主题
        self.sfx = Sfx()         # 程序化音效（来自 audio.py）

        self.attributes("-fullscreen", True)
        self.bind("<F11>", lambda e: self.attributes(
            "-fullscreen", not self.attributes("-fullscreen")))
        self.bind("<Escape>", self.on_escape)

        self.canvas = tk.Canvas(self, bg=BG_0, highlightthickness=0, bd=0)
        self.canvas.pack(fill="both", expand=True)
        self.canvas.bind("<Button-1>", self.on_click)
        self.canvas.bind("<Button-3>", self.on_rclick)
        self.canvas.bind("<Motion>", self.on_motion)
        self.canvas.bind("<Configure>", lambda e: self.refresh())

        self.bind("<Key-1>", lambda e: self.hotkey_order(0))
        self.bind("<Key-2>", lambda e: self.hotkey_order(1))
        self.bind("<Key-3>", lambda e: self.hotkey_order(2))
        self.bind("<Key-4>", lambda e: self.hotkey_order(3))
        self.bind("<Key-w>", lambda e: self.do_wait())
        self.bind("<Key-s>", lambda e: self.do_settle())
        self.bind("<Return>", lambda e: self.on_enter())
        self.bind("<Key-m>", lambda e: self.toggle_sfx())
        self.focus_set()

        self.refresh()

    # ---------------- 自适应 ----------------
    def calc_scale(self):
        w = self.canvas.winfo_width() or DW
        h = self.canvas.winfo_height() or DH
        self.s = min(w / DW, h / DH)
        self.ox = (w - DW * self.s) / 2
        self.oy = (h - DH * self.s) / 2

    def S(self, v):
        return v * self.s

    def P(self, x, y):
        return self.ox + x * self.s, self.oy + y * self.s

    def on_escape(self, e=None):
        if self.attributes("-fullscreen"):
            self.attributes("-fullscreen", False)
        elif self.result_modal:
            self.close_result()
        else:
            self.destroy()

    def hotkey_order(self, i):
        # 抉择弹窗优先吃掉 1/2 键
        if self.game.pending_dilemma:
            self.on_dilemma_key(i)
            return
        act = sorted(self.game.active_orders(),
                     key=lambda o: 0 if o.get("is_emergency") else 1)
        if 0 <= i < len(act):
            self.select_order(act[i])

    def on_enter(self):
        if self.result_modal:
            self.close_result()
        elif self.game.phase == "brief":
            self.start_shift()

    # ---------------- 基元 ----------------
    def font(self, size, bold=False, serif=False):
        fam = self.f_serif if serif else self.f_sans
        return (fam, max(7, int(round(self.S(size)))), "bold") if bold \
            else (fam, max(7, int(round(self.S(size)))))

    def rrect(self, x, y, w, h, r, fill, outline="", width=0):
        x1, y1 = self.P(x, y)
        x2, y2 = self.P(x + w, y + h)
        rr = max(0.0, min(self.S(r), (x2 - x1) / 2.0, (y2 - y1) / 2.0))
        if rr < 0.6:
            return self.canvas.create_rectangle(
                x1, y1, x2, y2, fill=fill, outline=outline,
                width=max(1, self.S(width)) if width else 0)
        seg = 4
        pts = []
        for cx, cy, a0, a1 in [(x2-rr, y1+rr, -90, 0), (x2-rr, y2-rr, 0, 90),
                               (x1+rr, y2-rr, 90, 180), (x1+rr, y1+rr, 180, 270)]:
            for i in range(seg + 1):
                a = math.radians(a0 + (a1 - a0) * i / seg)
                pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
        return self.canvas.create_polygon(
            pts, fill=fill, outline=outline,
            width=max(1, self.S(width)) if width else 0)

    def txt(self, x, y, s, size=14, color=INK, bold=False, serif=False,
            anchor="nw", width=None):
        px, py = self.P(x, y)
        kw = dict(text=s, fill=color, anchor=anchor, font=self.font(size, bold, serif))
        if width:
            kw["width"] = int(self.S(width))
        return self.canvas.create_text(px, py, **kw)

    def wrap(self, text, width, font):
        f = tkfont.Font(family=font[0], size=font[1],
                        weight="bold" if len(font) > 2 else "normal")
        maxw = max(10, int(self.S(width)))
        lines, cur = [], ""
        for ch in text:
            if ch == "\n":
                lines.append(cur); cur = ""; continue
            if f.measure(cur + ch) > maxw and cur:
                lines.append(cur); cur = ch
            else:
                cur += ch
        if cur:
            lines.append(cur)
        return "\n".join(lines)

    def clip(self, text, width, font, n):
        ls = self.wrap(text, width, font).split("\n")
        if len(ls) > n:
            ls = ls[:n]
            ls[-1] = ls[-1][:-1] + "…" if len(ls[-1]) > 1 else ls[-1]
        return "\n".join(ls)

    def button(self, x, y, w, h, label, cb, fill, fs=11, theme=False):
        """渐变按钮：多段竖条填充 + 顶部高光 + 细边。"""
        if theme:
            top = self.theme["accent_2"]
            bot = self.theme["accent_d"]
            fg = "#04181A"
        else:
            top = mix(fill, "#FFFFFF", 0.20)
            bot = mix(fill, "#000000", 0.26)
            fg = WHITE
        seg = 12
        for i in range(seg):
            t = (i + 0.5) / seg
            cc = mix(top, bot, t)
            self.rrect(x, y + h * i / seg, w, h / seg + 1, 0, cc, "")
        # 外框
        self.rrect(x, y, w, h, 4, "", mix(bot, "#000000", 0.3), 1)
        # 顶部高光
        x1, y1 = self.P(x + 6, y + 2)
        x2, _ = self.P(x + w - 6, y + 2)
        self.canvas.create_line(x1, y1, x2, y1, fill="#FFFFFF", width=1,
                                stipple="gray50")
        self.txt(x + w / 2, y + h / 2, label, fs, fg, True, anchor="center")
        self.hotspots.append((x, y, x + w, y + h, cb))

    def refresh(self):
        self.calc_scale()
        self.set_theme()
        self.canvas.delete("all")
        self.hotspots = []
        self.card_rects = []
        self.draw_bg()

        ph = self.game.phase
        if self.game.campaign["cleared"]:
            self.draw_campaign_end()
            if self.toast:
                self.draw_toast()
            return
        if ph == "brief":
            self.draw_brief()
        else:
            self.draw_hud()
            self.draw_vitals()
            self.draw_orders()
            self.draw_hand()
            self.draw_side()
            if self.game.pending_dilemma:
                self.draw_dilemma_modal()
            elif self.result_modal:
                self.draw_result_modal()
            elif ph == "settle":
                self.draw_settle()
            elif ph == "over":
                self.draw_incident()
        if self.toast:
            self.draw_toast()

    def set_theme(self):
        """按当前章节切换主题色与场景图。"""
        no = self.game.chapter["no"]
        self.theme = THEMES.get(no, THEMES[1])

    def _scene_image(self, key, w, h):
        """把场景图缩放到画布尺寸并缓存（PIL 缺失时返回 None）。"""
        ck = (key, w, h)
        if ck in self._photo:
            return self._photo[ck]
        path = os.path.join(SCENE_DIR, key + ".jpg")
        if not os.path.exists(path):
            self._photo[ck] = None
            return None
        try:
            from PIL import Image, ImageTk
            im = Image.open(path).convert("RGB").resize((w, h), Image.LANCZOS)
            ph = ImageTk.PhotoImage(im)
        except Exception:
            ph = None
        self._photo[ck] = ph
        return ph

    def draw_bg(self):
        w = self.canvas.winfo_width() or DW
        h = self.canvas.winfo_height() or DH

        # ① 兜底渐变
        for i in range(40):
            cc = mix("#0A1A20", "#03080A", i / 40)
            y0 = i * h / 40
            self.canvas.create_rectangle(0, y0, w, y0 + h / 40 + 1, fill=cc, outline="")

        # ② 场景实拍
        key = self.theme["scene"]
        ph = self._scene_image(key, w, h)
        if ph is not None:
            self.canvas.create_image(0, 0, image=ph, anchor="nw")

        acc = self.theme["accent"]

        # ④ 细网格
        gx1, gy1 = self.P(0, 0)
        gx2, gy2 = self.P(DW, DH)
        g = self.S(80)
        gc = mix("#000000", acc, 0.16)
        x = gx1
        while x < gx2:
            self.canvas.create_line(x, gy1, x, gy2, fill=gc, width=1,
                                    stipple="gray12")
            x += g
        y = gy1
        while y < gy2:
            self.canvas.create_line(gx1, y, gx2, y, fill=gc, width=1,
                                    stipple="gray12")
            y += g



    # ---------------- 关卡简报 ----------------
    def draw_brief(self):
        ch = self.game.chapter
        sd = self.game.shift_def
        c = self.game.campaign
        acc = self.theme["accent"]
        acc2 = self.theme["accent_2"]

        # 顶部章节导航
        self.txt(60, 44, "人体值班室", 30, "#FFFFFF", True, serif=True)
        self.txt(60, 86, "%s · %s" % (ch["code"], ch["title"]), 12.5, acc2, True)

        # 章节进度条
        for i, chapter in enumerate(D.CHAPTERS):
            x = 60 + i * 300
            done = i < c["chapter"]
            cur = i == c["chapter"]
            if cur:
                self.rrect(x, 116, 270, 5, 2.5, acc2, acc)
            elif done:
                self.rrect(x, 116, 270, 5, 2.5, mix("#000000", acc, 0.45))
            else:
                self.rrect(x, 116, 270, 5, 2.5, "#12252B")
            self.txt(x, 130, chapter["code"], 10,
                     "#FFFFFF" if cur else ("#C6D2D5" if done else "#3E5559"), cur)

        # 主卡片
        pw, ph2 = 1000, 646
        px, py = (DW - pw) / 2, 162
        bd = mix("#000000", acc, 0.38)
        self.rrect(px, py, pw, ph2, 10, "#050F14", bd, 1)
        self.rrect(px + 1, py + 1, pw - 2, ph2 - 2, 9, mix("#061218", acc, 0.06))
        self.rrect(px, py, pw, 4, 2, acc, acc)
        # 顶部主色条渐变
        for i in range(40):
            t = i / 40.0
            self.rrect(px + pw * t, py, pw / 40.0 + 1, 4, 0,
                       mix(acc, acc2, t), mix(acc, acc2, t))

        self.txt(px + 44, py + 30, ch["host"], 27, "#FFFFFF", True, serif=True)
        self.txt(px + 44, py + 70, "%d 岁 · %s" % (ch["age"], ch["job"]), 11, "#C6D2D5")
        self.txt(px + 44, py + 96, ch["theme"], 11.5, GOLD, serif=True)

        self.canvas.create_line(*self.P(px + 44, py + 126), *self.P(px + pw - 44, py + 126),
                                fill=mix("#000000", acc, 0.32), width=1)

        self.txt(px + 44, py + 144, "第 %d 班 · %s" % (sd["n"], sd["name"]),
                 20, "#FFFFFF", True)
        self.txt(px + 44, py + 176, sd["intro"], 11.5, "#C6D2D5", serif=True,
                 width=pw - 88)

        # 班次环境
        env = self.game.env
        ex = px + 44
        ey = py + 214
        self.txt(ex, ey + 4, "本班环境", 8.5, mix("#000000", acc, 0.45), True)
        self.rrect(ex + 62, ey - 3, 100, 22, 3, "#0A1A20", env["color"], 1)
        self.txt(ex + 112, ey + 8, env["name"], 9.5, env["color"], True, anchor="center")
        self.txt(ex + 172, ey + 4, env["desc"], 9, "#C6D2D5")

        # 三个信息块
        bw = (pw - 88 - 24) / 3
        blocks = [
            ("时间", "%d 刻" % self.game.max_clock, "每张签都消耗刻数"),
            ("工单", "%d 张" % sd["order_count"], "含红旗与情绪工单"),
            ("目标", sd["goal"]["text"], "达成即可通关"),
        ]
        for i, (lab, val, sub) in enumerate(blocks):
            bx = px + 44 + i * (bw + 12)
            by = py + 248
            self.rrect(bx, by, bw, 86, 5, "#07141A", mix("#000000", acc, 0.30), 1)
            self.rrect(bx, by, 2.5, 86, 1.2, acc2, acc)
            self.txt(bx + 16, by + 11, lab, 9, mix("#000000", acc, 0.45))
            vcol = acc2 if i == 2 else "#FFFFFF"
            self.txt(bx + 16, by + 27, val, 15, vcol, True, width=bw - 32)
            self.txt(bx + 16, by + 62, sub, 8.5, "#6E8285", width=bw - 32)

        # 奖励预告
        self.txt(px + 44, py + 352, "通关奖励", 9, mix("#000000", acc, 0.45), True)
        rx = px + 44
        for cid in sd["reward"]:
            card = D.CARD_MAP[cid]
            col = SCHOOL_COLOR[card["s"]]
            tw = 130
            self.rrect(rx, py + 368, tw, 46, 4, "#07141A", col, 1)
            self.txt(rx + 10, py + 377, SCHOOL_NAME[card["s"]], 8, col)
            self.txt(rx + 10, py + 391, self.clip(card["n"], tw - 20, self.font(9), 1),
                     9, "#FFFFFF", width=tw - 20)
            rx += tw + 10

        # 超时风险
        risky = []
        for oid in sd["pool"]:
            key = D.ORDER_STATUS.get(oid)
            if key and key not in risky:
                risky.append(key)
        if risky:
            self.txt(px + 44, py + 428, "超时风险", 8.5, CORAL, True)
            rx2 = px + 110
            for key in risky[:4]:
                st = D.STATUS[key]
                tw = 66
                self.rrect(rx2, py + 421, tw, 22, 3, "#1E1013", st["color"], 1)
                self.txt(rx2 + tw / 2, py + 432,
                         (st.get("icon", "") + " " + st["name"]).strip(),
                         8.5, st["color"], True, anchor="center")
                rx2 += tw + 6

        # 上一章来信（第 2-5 章显示，替换静态玩法提示）
        ch_no = self.game.chapter["no"]
        letter = D.LETTERS.get(ch_no - 1) if ch_no > 1 else None
        if letter:
            bx, by, bw2 = px + 44, py + 456, pw - 88
            self.rrect(bx, by, bw2, 72, 4, "#0B1A14", "#C9A227", 1)
            self.rrect(bx, by, 2.5, 72, 1.2, GOLD, GOLD)
            self.txt(bx + 12, by + 9, "上一封信", 8.5, GOLD, True)
            self.txt(bx + 12, by + 26,
                     self.clip(letter.replace("\n", "　"), bw2 - 24, self.font(9), 3),
                     9, "#C8D5B8", width=bw2 - 24)
        else:
            # 玩法提示
            tips = [
                ("组合技", GOLD, "上一张牌与这一张能接上时，处置签右下角出现「连」，按顺序打出可额外加成。"),
                ("状态异常", CORAL, "工单超时未处理，身体会挂上状态：心悸加刻、反流减半、失眠少牌。"),
                ("对症解除", GREEN, "打出对应处置签即可解除状态。右键处置签可换一张，本班两次，不耗刻。"),
            ]
            tw3 = (pw - 88 - 16) / 3
            for i, (nm, col, tx) in enumerate(tips):
                bx = px + 44 + i * (tw3 + 8)
                by = py + 456
                self.rrect(bx, by, tw3, 72, 4, "#07141A", "#173035", 1)
                self.rrect(bx, by, 2.5, 72, 1.2, col, col)
                self.txt(bx + 12, by + 10, nm, 8.5, col, True)
                self.txt(bx + 12, by + 27, self.clip(tx, tw3 - 24, self.font(8.5), 3),
                         8.5, "#8FA3A6", width=tw3 - 24)

        # 牌组
        self.txt(px + 44, py + 548, "当前牌组 %d 张" % len(self.game.campaign["deck"]),
                 10, "#8FA3A6")

        # 按钮
        self.button(px + pw - 300, py + ph2 - 62, 256, 44,
                    "接班（Enter）", self.start_shift, TEAL_D, 12, theme=True)

    def start_shift(self):
        if self.game.phase != "brief":
            return
        self.sfx.play("shift")
        self.game.start_shift()
        self.refresh()

    # ---------------- HUD ----------------
    def draw_hud(self):
        ch = self.game.chapter
        sd = self.game.shift_def
        acc = self.theme["accent"]
        acc2 = self.theme["accent_2"]

        self.txt(26, 14, "人体值班室", 27, "#FFFFFF", True, serif=True)

        self.txt(26, 52, "%s · %s" % (ch["code"], ch["title"]), 11.5, acc2, True)
        self.txt(26, 70, "%s　/　第 %d 班 · %s" % (ch["host"], sd["n"], sd["name"]),
                 10, "#C6D2D5")
        env = self.game.env
        self.txt(26, 86, "环境 · " + env["name"] + "（" + env["desc"] + "）",
                 8.5, env["color"])

        # 顶栏底线（主题色渐变感）
        for i in range(60):
            t = i / 60.0
            x1 = 26 + (DW - 52) * t
            x2 = 26 + (DW - 52) * (t + 1 / 60.0)
            a = math.sin(t * math.pi) ** 0.6
            self.canvas.create_line(*self.P(x1, 100), *self.P(x2, 100),
                                    fill=mix("#0A1A20", acc, 0.55 * a), width=1)

        # 时间轴
        tx = DW - 512
        self.txt(tx - 74, 30, "本班时间", 9.5, mix("#000000", acc, 0.5))
        for i in range(self.game.max_clock):
            x = tx + i * 25
            used = i < self.game.clock
            now = (i == self.game.clock and self.game.phase == "shift")
            if used:
                self.rrect(x, 24, 21, 15, 3, acc2, acc, 1)
                self.rrect(x + 2, 26, 17, 5, 2, mix(acc2, "#FFFFFF", 0.35))
            elif now:
                self.rrect(x, 24, 21, 15, 3, "#0E2126", GOLD, 2)
            else:
                self.rrect(x, 24, 21, 15, 3, "#0E1E24", mix("#000000", acc, 0.3), 1)
        self.txt(tx + self.game.max_clock * 25 + 10, 31,
                 "%d/%d" % (self.game.clock, self.game.max_clock), 13, "#FFFFFF", True)

        # 误导
        mx = DW - 184
        self.txt(mx - 32, 31, "误导", 9.5, mix("#000000", acc, 0.5))
        for i in range(5):
            on = i < self.game.misleading
            cx, cy = self.P(mx + i * 13, 32)
            r = self.S(4.2)
            self.canvas.create_oval(cx - r, cy - r, cx + r, cy + r,
                                    fill=CORAL if on else "#0E1E24",
                                    outline="#FF9A7E" if on else mix("#000000", acc, 0.3))

        # 目标
        cur, tgt, ok = self.game.goal_progress()
        gx = DW - 184
        self.txt(gx, 56, "目标", 9, mix("#000000", acc, 0.5))
        gtxt = self.game.shift_def["goal"]["text"]
        self.txt(gx + 30, 56, ("✓ " if ok else "") + gtxt, 9.5,
                 "#5FBE8A" if ok else "#C6D2D5")
        detail = ("事故 %d 次" % self.game.incidents) if sd["goal"]["kind"] == "no_incident" \
            else ("%d / %d" % (cur, tgt))
        self.txt(gx + 30, 72, detail, 9, acc2)

    def panel(self, x, y, w, h):
        acc = self.theme["accent"]
        bd = mix("#000000", acc, 0.34)
        self.rrect(x, y, w, h, 8, "#0A1A20", bd, 1)
        # 内层：略亮的面 + 顶部高光
        self.rrect(x + 1, y + 1, w - 2, h - 2, 7, mix("#08161B", acc, 0.055))
        x1, y1 = self.P(x + 8, y + 1.6)
        x2, _ = self.P(x + w - 8, y + 1.6)
        self.canvas.create_line(x1, y1, x2, y1, fill=mix("#000000", acc, 0.42), width=1)

    def panel_head(self, x, y, w, title, hint=""):
        acc = self.theme["accent"]
        self.rrect(x + 15, y + 12, 3, 13, 1.5, self.theme["accent_2"], acc)
        self.txt(x + 26, y + 10, title, 12, "#F2F7F6", True)
        if hint:
            self.txt(x + w - 15, y + 13, hint, 9, mix("#000000", acc, 0.45), anchor="ne")

    # ---------------- 左栏 ----------------
    def draw_vitals(self):
        px, py, pw, ph = 26, 100, 226, 774
        self.panel(px, py, pw, ph)
        self.panel_head(px, py, pw, "生理指标", "实时")

        vy = py + 50
        for key, name, direction, init in D.VITALS:
            v = self.game.vitals[key]
            bad = (direction == "better" and v < 35) or (direction == "worse" and v > 68)
            self.txt(px + 16, vy, name, 11, "#FFB29B" if bad else "#C6D2D5")
            self.txt(px + pw - 16, vy - 3, str(v), 14,
                     "#FFB29B" if bad else "#FFFFFF", True, anchor="ne")
            bx, by, bw = px + 16, vy + 22, pw - 32
            self.rrect(bx, by, bw, 6, 3, "#04101A", mix("#000000", self.theme["accent"], 0.22), 1)
            health = v / 100.0 if direction == "better" else 1 - v / 100.0
            if health > .62:
                c1, c2 = "#2E8C5E", "#7BE0A8"
            elif health > .38:
                c1, c2 = "#B0821A", "#F5D26B"
            else:
                c1, c2 = "#B03A20", "#FF9A7E"
            wfill = max(4, bw * v / 100.0)
            self.rrect(bx, by, wfill, 6, 3, c1)
            self.rrect(bx, by, wfill, 3, 1.5, c2)
            vy += 52

        # 状态异常
        sty = py + 372
        self.txt(px + 16, sty - 15, "状态", 8.5, mix("#000000", self.theme["accent"], 0.45), True)
        if not self.game.statuses:
            self.txt(px + 16, sty + 2, "正常", 9, "#2E4247")
        sx, syy = px + 16, sty
        for key in list(self.game.statuses.keys())[:4]:
            st = D.STATUS.get(key)
            if not st:
                continue
            tw = 54
            self.rrect(sx, syy, tw, 21, 3, "#1E1013", st["color"], 1)
            self.txt(sx + tw / 2, syy + 10, (st.get("icon", "") + " " + st["name"]).strip(),
                     8.5, st["color"], True, anchor="center")
            sx += tw + 6
            if sx > px + pw - 62:
                sx, syy = px + 16, syy + 27

        sy = py + ph - 92
        acc = self.theme["accent"]
        self.rrect(px + 14, sy, pw - 28, 78, 6, "#07141A", mix("#000000", acc, 0.35), 1)
        self.rrect(px + 14, sy, 3, 78, 1.5, self.theme["accent_2"], acc)
        self.txt(px + 30, sy + 12, "身体状态评分", 10, "#C6D2D5")
        self.txt(px + 30, sy + 32, "满分 100 · 六项综合", 8.5, mix("#000000", acc, 0.42))
        self.txt(px + pw - 26, sy + 18, str(self.game.score()), 33,
                 self.theme["accent_2"], True, serif=True, anchor="ne")

    # ---------------- 中栏：工单 ----------------
    def draw_orders(self):
        px, py, pw, ph = 266, 100, DW - 266 - 286, 534
        self.panel(px, py, pw, ph)
        self.panel_head(px, py, pw, "值班台", "点击工单 → 再点处置签")

        act = sorted(self.game.active_orders(),
                     key=lambda o: 0 if o.get("is_emergency") else 1)
        gap = 13
        cw = (pw - 30 - gap) / 2
        ch = (ph - 50 - gap) / 2
        for i in range(4):
            cx = px + 15 + (i % 2) * (cw + gap)
            cy = py + 44 + (i // 2) * (ch + gap)
            if i < len(act):
                self.draw_order(cx, cy, cw, ch, act[i])
            else:
                self.rrect(cx, cy, cw, ch, 5, "#0B1F24", LINE, 1)
                self.txt(cx + cw / 2, cy + ch / 2, "空 槽", 10, "#20393F", anchor="center")

    def draw_order(self, x, y, w, h, o):
        is_red = o["kind"] == "redflag"
        is_emo = o["kind"] == "emotion"
        sel = self.game.selected_order == o["uid"]
        bar = CORAL if is_red else (VIOLET if is_emo else TEAL_D)

        self.rrect(x, y, w, h, 5, PAPER, TEAL if sel else PAPER_3, 2 if sel else 1)
        if o.get("is_emergency"):
            bar = GOLD
        self.rrect(x, y + 3, 3, h - 6, 1.5, bar, bar)
        self.rrect(x + 3, y + 1, w - 3, 27, 4, PAPER_2)
        self.canvas.create_rectangle(*self.P(x + 3, y + 20), *self.P(x + w, y + 28),
                                     fill=PAPER_2, outline="")
        tag = "突发" if o.get("is_emergency") else (
            "红旗" if is_red else ("情绪" if is_emo else "报修"))
        tcol = GOLD if o.get("is_emergency") else (
            CORAL if is_red else (VIOLET if is_emo else TEAL_D))
        self.rrect(x + 12, y + 7, 34, 15, 2, tcol, tcol)
        self.txt(x + 29, y + 14, tag, 8.5, WHITE, True, anchor="center")
        self.txt(x + 52, y + 13, o["organ"], 8.5, INK_3)

        self.txt(x + 13, y + 34, self.clip(o["title"], w - 26, self.font(14, True), 1),
                 14, INK, True)

        # 症状标签
        tx, ty = x + 13, y + 57
        for ti, t in enumerate(o.get("tags", [])[:4]):
            tw = max(28, len(t) * 8 + 11)
            if tx + tw > x + w - 13:
                break
            hot = is_red and ti < 2
            self.rrect(tx, ty, tw, 16, 2,
                       "#F2DAD3" if hot else "#E4DBC6",
                       "#DDB3A8" if hot else "#D3C7AC")
            self.txt(tx + tw / 2, ty + 8, t, 7.5,
                     "#A8402A" if hot else INK_3, anchor="center")
            tx += tw + 4

        # 描述
        self.txt(x + 13, ty + 24,
                 self.clip(o["body"], w - 26, self.font(10), 3),
                 10, INK_2, width=w - 26)

        # 身体原话
        wq = self.clip(o.get("whisper", ""), w - 44, self.font(9, serif=True), 2)
        nl = wq.count("\n") + 1
        wh = 16 + nl * 14
        wy = y + h - 28 - wh - 4
        self.rrect(x + 13, wy, w - 26, wh, 3, "#EFF6F4" if not is_red else "#FBEDE8")
        self.rrect(x + 13, wy, 2.5, wh, 1.2, bar, bar)
        self.txt(x + 22, wy + 7, wq, 9, INK_2, serif=True, width=w - 44)

        # 时限
        lim = self.game.eff_limit(o)
        left = max(0, lim - (self.game.clock - o["arrival"]))
        left = min(left, o["limit"])
        urgent = left <= 1
        fy = y + h - 24
        self.txt(x + 13, fy, "剩余 %d 刻" % left, 8.5,
                 CORAL if urgent else INK_3, urgent)
        bx, bw = x + 74, w - 74 - 14
        self.rrect(bx, fy + 5, bw, 4, 2, "#D9D0BC")
        self.rrect(bx, fy + 5, max(4, bw * left / max(1, o["limit"])), 4, 2,
                   CORAL if urgent else TEAL)

        self.hotspots.append((x, y, x + w, y + h, lambda o=o: self.select_order(o)))

    def select_order(self, o):
        self.game.selected_order = o["uid"]
        self.refresh()

    # ---------------- 手牌 ----------------
    def draw_hand(self):
        px, py = 266, 650
        self.rrect(px + 3, py - 2, 3, 11, 1.5, TEAL, TEAL)
        self.txt(px + 14, py - 5, "处置签", 12, PAPER, True)
        self.txt(px + 66, py - 2, "左键打出 · 右键换签（不耗刻）", 9, MUTED)
        self.txt(DW - 286 - 14, py - 2, "牌库 %d · 弃牌 %d · 换签 %d" % (
            len(self.game.deck), len(self.game.discard), self.game.rerolls),
            9, MUTED, anchor="ne")

        cards = self.game.hand
        if not cards:
            return
        n = len(cards)
        gap = 10
        cw = min(158, (DW - 266 - 286 - (n - 1) * gap) / max(1, n))
        ch = 208
        total = n * cw + (n - 1) * gap
        start = px + (DW - 266 - 286 - total) / 2
        for i, cid in enumerate(cards):
            self.draw_card(start + i * (cw + gap), py + 18, cw, ch, cid)

    def draw_card(self, x, y, w, h, cid):
        c = D.CARD_MAP[cid]
        col = SCHOOL_COLOR[c["s"]]
        hover = self.hover_card == cid
        yy = y + (-8 if hover else 0)

        self.rrect(x, yy, w, h, 5, "#FCF9F0", col if hover else PAPER_3, 2 if hover else 1)
        self.rrect(x, yy, w, 25, 5, col, col)
        self.canvas.create_rectangle(*self.P(x, yy + 17), *self.P(x + w, yy + 26),
                                     fill=col, outline="")
        self.txt(x + 9, yy + 7, SCHOOL_NAME[c["s"]], 8.5, WHITE, True)
        cx, cy = self.P(x + w - 14, yy + 12)
        r = self.S(9)
        self.canvas.create_oval(cx - r, cy - r, cx + r, cy + r, fill="#FCF9F0")
        real_cost = self.game.cost_of(cid)
        penal = real_cost > c["cost"]
        self.txt(x + w - 14, yy + 12, str(real_cost), 10,
                 CORAL if penal else col, True, anchor="center")

        # 组合技提示：这张牌能否接上一张
        combo_hint = None
        if self.game.last_card:
            cb = D.COMBO_BY_PAIR.get((self.game.last_card, cid))
            if cb and cb["id"] not in self.game.combos_done:
                combo_hint = cb

        nm = self.clip(c["n"], w - 18, self.font(12, True), 2)
        self.txt(x + 9, yy + 32, nm, 12, INK, True, width=w - 18)

        ey = yy + 32 + (16 if "\n" in nm else 0) + 24
        for k, dv in list(c["eff"].items())[:4]:
            vname = D.VITAL_MAP[k][1]
            direction = D.VITAL_MAP[k][2]
            good = (direction == "better" and dv > 0) or (direction == "worse" and dv < 0)
            cc = "#3D8A5F" if good else "#C24E36"
            c2, c3 = self.P(x + 13, ey + 6)
            rr = self.S(2)
            self.canvas.create_oval(c2 - rr, c3 - rr, c2 + rr, c3 + rr, fill=cc)
            self.txt(x + 19, ey, "%s %s%d" % (vname, "+" if dv > 0 else "", dv), 9, cc)
            ey += 16

        ny = yy + h - 54
        self.canvas.create_line(*self.P(x + 9, ny - 5), *self.P(x + w - 9, ny - 5),
                                fill="#E2DACA", width=1)
        self.txt(x + 9, ny, self.clip(c["d"], w - 18, self.font(8), 3),
                 8, INK_3, width=w - 18)

        self.rrect(x, yy + h - 3, w, 3, 1.5, col, col)
        if combo_hint:
            self.rrect(x + w - 30, yy + h - 26, 24, 18, 3, "#2A3F1E", GOLD, 1)
            self.txt(x + w - 18, yy + h - 17, "连", 9, GOLD, True, anchor="center")
        self.hotspots.append((x, yy, x + w, yy + h, lambda cid=cid: self.play_card(cid)))
        self.card_rects.append((cid, x, yy, x + w, yy + h))

    def play_card(self, cid):
        g = self.game
        if g.phase != "shift":
            return
        if not g.selected_order:
            self.show_toast("先选一张工单",
                            "值班台上还有 %d 张单子。" % len(g.active_orders()))
            return
        order = next((o for o in g.orders if o["uid"] == g.selected_order), None)
        if order is None or order["resolved"]:
            self.show_toast("这张单已经处理过了", "换一张还在值班台上的工单。")
            return
        if not g.can_play(cid):
            self.show_toast("时间不够了", "这一班只剩 %d 刻。" % (g.max_clock - g.clock))
            return
        g.play_card(cid, order["uid"])
        g.selected_order = None
        fb = g.pending_feedback
        if fb and fb[0] == "result":
            self.result_modal = fb[1:]
            g.pending_feedback = None
        self.refresh()

    # ---------------- 右栏 ----------------
    def draw_side(self):
        px, pw = DW - 270, 244

        oy, oh = 100, 340
        self.panel(px, oy, pw, oh)
        self.panel_head(px, oy, pw, "器官频道")
        order = None
        if self.game.selected_order:
            order = next((o for o in self.game.orders
                          if o["uid"] == self.game.selected_order), None)
        if order:
            cx, cy = self.P(px + 21, oy + 50)
            r = self.S(3)
            self.canvas.create_oval(cx - r, cy - r, cx + r, cy + r, fill=TEAL)
            self.txt(px + 29, oy + 44, order["organ"], 9.5, TEAL)
            q = self.clip(order.get("whisper", ""), pw - 32,
                          self.font(11, serif=True), 4)
            self.txt(px + 16, oy + 66, q, 11, "#E4E9E4", serif=True, width=pw - 32)
            if order.get("hint"):
                hy = oy + 186
                self.canvas.create_line(*self.P(px + 16, hy), *self.P(px + pw - 16, hy),
                                        fill=LINE, width=1)
                self.txt(px + 16, hy + 9, "线索", 8.5, GOLD, True)
                self.txt(px + 16, hy + 24,
                         self.clip(order["hint"], pw - 32, self.font(9), 3),
                         9, "#A8B8BB", width=pw - 32)
        else:
            self.txt(px + 16, oy + 44, "还没有选中工单。", 10.5, MUTED)
            self.txt(px + 16, oy + 64, "点一张工单，听听它想说什么。",
                     10.5, MUTED, width=pw - 32)

        ly, lh = 452, 422
        self.panel(px, ly, pw, lh)
        self.panel_head(px, ly, pw, "身体日志")
        logs = self.game.log[:6]
        yy = ly + 42
        if not logs:
            self.txt(px + 16, yy, "还没有记录。", 9.5, MUTED)
        for grade, o, card in logs:
            cc = GREEN if grade == "best" else (GOLD if grade == "good" else CORAL)
            cx, cy = self.P(px + 20, yy + 6)
            r = self.S(3)
            self.canvas.create_oval(cx - r, cy - r, cx + r, cy + r, fill=cc)
            self.txt(px + 29, yy, self.clip(card["n"], pw - 44, self.font(9), 1),
                     9, "#B8C6C9", width=pw - 44)
            yy += 28

        by = ly + lh - 50
        bw = (pw - 30 - 8) / 2
        self.button(px + 15, by, bw, 34, "观察等待", self.do_wait, "#3E8E7E", 9.5)
        self.button(px + 15 + bw + 8, by, bw, 34, "交班", self.do_settle, TEAL_D, 9.5)

    def do_wait(self):
        if self.game.phase != "shift":
            return
        self.game.wait()
        self.sfx.play("ui")
        self.refresh()

    def do_settle(self):
        if self.game.phase == "shift":
            self.game.phase = "settle"
        if self.game.rating is None:
            self.game.rating = self.game.compute_rating()
        self.game.save_rating()
        self.result_modal = None
        self.sfx.play("settle")
        self.refresh()

    # ---------------- 遮罩 ----------------
    def overlay(self):
        w = self.canvas.winfo_width() or DW
        h = self.canvas.winfo_height() or DH
        self.canvas.create_rectangle(0, 0, w, h, fill="#04090B", stipple="gray50", outline="")
        self.canvas.create_rectangle(0, 0, w, h, fill="#04090B", stipple="gray12", outline="")

    # ---------------- 班中抉择 ----------------
    def pick_dilemma(self, idx):
        if self.game.pending_dilemma and self.game.choose_dilemma(idx):
            self.sfx.play("select")
            if self.game.phase == "settle" and self.game.rating is None:
                self.game.rating = self.game.compute_rating()
                self.game.save_rating()
            self.refresh()

    def draw_dilemma_modal(self):
        d = self.game.pending_dilemma
        if not d:
            return
        self.overlay()
        pw = 640
        x = (DW - pw) / 2
        body = self.clip(d["text"], pw - 64, self.font(10.5), 3)
        blines = body.count("\n") + 1
        opt_h = 54
        ph = 26 + 34 + 28 + blines * 19 + 14 + len(d["options"]) * (opt_h + 10) + 18
        y = (DH - ph) / 2

        self.rrect(x, y, pw, ph, 9, "#FAF5EA", "#C9BDA3", 1)
        self.rrect(x, y, pw, 4, 2, "#C9A227", "#C9A227")

        cy = y + 26
        self.txt(x + 32, cy, u"抉　择", 25, "#8A6A10", True, serif=True)
        self.txt(x + pw - 32, cy + 8, self.game.shift_def["name"], 9, "#7A8688", anchor="ne")
        cy += 34
        self.txt(x + 32, cy, d["title"], 12.5, "#1F3A3E", True)
        cy += 28
        self.txt(x + 32, cy, body, 10.5, "#3E5257", width=pw - 64)
        cy += blines * 19 + 14

        for i, opt in enumerate(d["options"]):
            self.rrect(x + 32, cy, pw - 64, opt_h, 5, "#FFFDF8", "#C9BDA3", 1)
            self.txt(x + 48, cy + 10, u"%d　%s" % (i + 1, opt["label"]), 11, "#1F3A3E", True)
            self.txt(x + 48, cy + 30, opt["desc"], 9, "#6B7A7C", width=pw - 200)
            self.button(x + pw - 128, cy + 13, 80, 28, u"选择",
                        (lambda idx=i: self.pick_dilemma(idx)), TEAL_D, 9, theme=True)
            cy += opt_h + 10

    # ---------------- 结果弹窗 ----------------
    def draw_result_modal(self):
        order, card, grade = self.result_modal
        self.overlay()
        pw = 620
        x = (DW - pw) / 2

        accent = {"best": "#3D8A5F", "good": "#A8851F", "bad": "#C24E36"}.get(grade, CORAL)
        label = {"best": "正解", "good": "有效", "bad": "不太对"}.get(grade, "")

        quote = (order["gt"] if grade in ("best", "good") else order["bt"]) \
            or ("你做了当下唯一正确的选择。" if grade == "best" else "身体没有变好。")
        qtxt = self.clip(quote, pw - 64, self.font(11), 2)
        qlines = qtxt.count("\n") + 1
        ktxt = self.clip(card["k"], pw - 96, self.font(9.5), 3)
        klines = ktxt.count("\n") + 1

        cured = getattr(self.game, "cured_flash", None)
        streak = self.game.streak_flash
        combo = self.game.combo_flash

        # ---- 逐段累加真实高度 ----
        h = 26                       # 上留白
        h += 34                      # 标题
        h += qlines * 19 + 12        # 引文
        h += 18 + 24                 # 「指标变化」
        h += 26                      # chips
        if cured:  h += 30
        if streak: h += 30
        if combo:  h += 46
        h += 10                      # 间距
        h += 22 + klines * 17 + 14   # 机制块
        h += 20 + 38                 # 按钮
        ph = h
        y = (DH - ph) / 2

        self.rrect(x, y, pw, ph, 9, "#FAF5EA", "#C9BDA3", 1)
        self.rrect(x, y, pw, 4, 2, accent, accent)

        cy = y + 26
        self.txt(x + 32, cy, label, 25, accent, True, serif=True)
        self.txt(x + pw - 32, cy + 8, order["organ"], 9, "#7A8688", anchor="ne")
        cy += 34

        self.txt(x + 32, cy, qtxt, 11, "#3E5257", width=pw - 64)
        cy += qlines * 19 + 12

        self.txt(x + 32, cy, "指标变化", 8.5, "#7A8688", True)
        cy += 18
        cx = x + 32
        for k, dv in card["eff"].items():
            direction = D.VITAL_MAP[k][2]
            good = (direction == "better" and dv > 0) or (direction == "worse" and dv < 0)
            cc = "#2F7A55" if good else "#B03A20"
            s = "%s %s%d" % (D.VITAL_MAP[k][1], "+" if dv > 0 else "", dv)
            tw = max(84, len(s) * 7.5 + 20)
            if cx + tw > x + pw - 32:
                break
            self.rrect(cx, cy, tw, 22, 3, "#E3F1EC" if good else "#FBE6E0",
                       "#B9DBCB" if good else "#EFC8BC")
            self.txt(cx + tw / 2, cy + 11, s, 8.5, cc, anchor="center")
            cx += tw + 8
        cy += 24

        if cured:
            names = "、".join(D.STATUS[s]["name"] for s in cured if s in D.STATUS)
            self.rrect(x + 32, cy, pw - 64, 24, 3, "#E0F0E8", "#7FC8A2", 1)
            self.txt(x + 44, cy + 8, "状态解除 · " + names, 9, "#2F7A55", True)
            cy += 30

        if streak:
            sn, sb = streak
            self.rrect(x + 32, cy, pw - 64, 24, 3, "#FBF2D6", "#D9B84A", 1)
            self.txt(x + 44, cy + 8, "连续 %d 次正解 · 信任 +%d" % (sn, sb), 9.5, "#8A6A10", True)
            cy += 30

        if combo:
            self.rrect(x + 32, cy, pw - 64, 40, 4, "#F4F0DC", "#C9A227", 1)
            self.txt(x + 44, cy + 7, "组合技 · " + combo["name"], 10, "#8A6A10", True)
            self.txt(x + 44, cy + 21, combo["desc"], 8.5, "#6E5E2A", width=pw - 96)
            cy += 46

        cy += 10
        kh = 22 + klines * 17 + 14
        self.rrect(x + 32, cy, pw - 64, kh, 5, "#E4F2ED")
        self.rrect(x + 32, cy, 3, kh, 1.5, TEAL_D, TEAL_D)
        self.txt(x + 46, cy + 10, "机制", 8.5, TEAL_D, True)
        self.txt(x + 46, cy + 26, ktxt, 9.5, "#26424A", width=pw - 96)
        cy += kh

        cy += 20
        self.button(x + pw - 152, cy, 120, 38, "继续", self.close_result, TEAL_D, 10, theme=True)

    def close_result(self):
        if self.result_modal:
            self.result_modal = None
            self.refresh()

    # ---------------- 事故回放 ----------------
    def draw_incident(self):
        self.overlay()
        inc = None
        for e in self.game.log:
            if e[0] == "incident":
                inc = e
                break
        pw, ph = 640, 440
        x, y = (DW - pw) / 2, (DH - ph) / 2
        self.rrect(x, y, pw, ph, 8, PAPER, PAPER_3, 1)
        self.rrect(x, y, pw, 5, 3, CORAL, CORAL)
        self.txt(x + 32, y + 26, "事故回放", 24, "#B34530", True, serif=True)
        self.txt(x + 32, y + 64, "第 3 帧 · 身体的真实反应", 9.5, INK_3)

        if inc:
            _, order, card = inc
            self.txt(x + 32, y + 88, order["title"], 15, INK, True)
            self.txt(x + 32, y + 114, "你打出的签：" + card["n"], 10.5, INK_2)
            self.txt(x + 32, y + 138,
                     self.clip(order.get("danger") or order["f"], pw - 64, self.font(10.5), 2),
                     10.5, INK_2, width=pw - 64)

            ay = y + 190
            self.rrect(x + 32, ay, pw - 64, 100, 4, "#FBEAE4")
            self.rrect(x + 32, ay, 3, 100, 1.5, CORAL, CORAL)
            self.txt(x + 46, ay + 11, "如果当时这么做", 8.5, "#B34530", True)
            self.txt(x + 46, ay + 28,
                     "立即拨打 120，说清地址、症状、发病时间，保持电话畅通。",
                     10, "#5A2E22", width=pw - 96)
            self.txt(x + 46, ay + 58,
                     self.clip(order["f"], pw - 96, self.font(8.5), 2),
                     8.5, "#7A4A3C", width=pw - 96)

            ky = y + 306
            self.rrect(x + 32, ky, pw - 64, 56, 4, "#E7F2EE")
            self.rrect(x + 32, ky, 3, 56, 1.5, TEAL_D, TEAL_D)
            self.txt(x + 46, ky + 10, "带走这一条", 8.5, TEAL_D, True)
            self.txt(x + 46, ky + 26,
                     "出现胸痛伴冷汗、呼吸困难时，立即拨打 120，不要自行驾车。",
                     9.5, "#2A4145", width=pw - 96)

        self.txt(x + pw / 2, y + ph - 74, "— 复盘不是惩罚，是下一次的起点 —",
                 8.5, "#8A9A9E", anchor="center")
        self.button(x + 32, y + ph - 52, 124, 34, "重新值班", self.retry_shift, "#B34530", 10)
        self.button(x + pw - 156, y + ph - 52, 124, 34, "退出", self.destroy, "#3E4C50", 10)

    def retry_shift(self):
        self.result_modal = None
        self.game.load_shift()
        self.game.start_shift()
        self.refresh()

    # ---------------- 交班结算 ----------------
    def draw_settle(self):
        self.overlay()
        g = self.game
        cur, tgt, ok = g.goal_progress()
        acc = self.theme["accent"]
        acc2 = self.theme["accent_2"]

        pw, ph = 660, 600
        x, y = (DW - pw) / 2, (DH - ph) / 2
        self.rrect(x, y, pw, ph, 10, "#FAF5EA", "#C9BDA3", 1)
        vcol = "#2F7A55" if ok else "#B03A20"
        self.rrect(x, y, pw, 4, 2, vcol, vcol)

        self.txt(x + 34, y + 26, "交　班", 27, "#182628", True, serif=True)
        verdict = "达成" if ok else "未达成"
        vw = 62
        self.rrect(x + pw - 34 - vw, y + 30, vw, 24, 3,
                   "#E0F0E8" if ok else "#FBE6E0",
                   "#7FC8A2" if ok else "#EFC8BC")
        self.txt(x + pw - 34 - vw / 2, y + 42, verdict, 10, vcol, True, anchor="center")

        goal_text = g.shift_def["goal"]["text"]
        if g.shift_def["goal"]["kind"] == "no_incident":
            detail = "事故 %d 次" % g.incidents
        else:
            detail = "%d / %d" % (cur, tgt)
        self.txt(x + 34, y + 72, "目标：%s　（%s）" % (goal_text, detail),
                 10.5, "#3E5257", width=pw - 68)

        # 班次评级
        rt = g.rating or g.compute_rating()
        rcol = {"S": "#C9A227", "A": "#2F7A55", "B": "#A8851F", "C": "#B03A20"}.get(rt["grade"], "#3E5257")
        self.txt(x + 34, y + 88, "评级 %s" % rt["grade"], 11.5, rcol, True)
        self.txt(x + 94, y + 90, "%d 分 · %s" % (rt["score"], rt["comment"]),
                 8.5, "#6B7A7C", width=pw - 150)

        # 六项指标
        self.txt(x + 34, y + 106, "六项指标", 8.5, "#7A8688", True)
        yy = y + 128
        for key, name, direction, init in D.VITALS:
            v = g.vitals[key]
            self.txt(x + 34, yy, name, 9.5, "#5E6E70")
            bx, bw = x + 120, 320
            self.rrect(bx, yy + 5, bw, 7, 3.5, "#E2DACA")
            health = v / 100.0 if direction == "better" else 1 - v / 100.0
            if health > .62:
                c1, c2 = "#2E8C5E", "#7BE0A8"
            elif health > .38:
                c1, c2 = "#B0821A", "#F5D26B"
            else:
                c1, c2 = "#B03A20", "#FF9A7E"
            self.rrect(bx, yy + 5, max(4, bw * v / 100.0), 7, 3.5, c1)
            self.rrect(bx, yy + 5, max(4, bw * v / 100.0), 3, 1.5, c2)
            self.txt(x + 456, yy, str(v), 10.5, "#182628", True)
            yy += 28

        # 本班统计
        sy = y + 310
        self.rrect(x + 34, sy, pw - 68, 56, 5, "#F0EAE0")
        stats = [("正解", g.stats["best"], "#2F7A55"), ("有效", g.stats["good"], "#8A6A10"),
                 ("失误", g.stats["bad"], "#B03A20"), ("偏方", g.stats["quack"], "#B03A20"),
                 ("组合技", len(g.combos_done), "#8A6A10"),
                 ("最高连击", g.best_streak, "#8A6A10")]
        for i, (lab, val, col) in enumerate(stats):
            bx = x + 48 + i * 96
            self.txt(bx, sy + 12, lab, 8, "#7A8688")
            self.txt(bx, sy + 26, str(val), 15, col, True)

        # 知识
        ky = y + 382
        self.rrect(x + 34, ky, pw - 68, 92, 5, "#E4F2ED")
        self.rrect(x + 34, ky, 3, 92, 1.5, TEAL_D, TEAL_D)
        self.txt(x + 48, ky + 11, "今晚带走的一条知识", 8.5, TEAL_D, True)
        k = g.shift_def["goal"].get("k") or "身体的信号从来不是噪声，是同事在求救。"
        if g.incidents:
            k = "胸痛伴冷汗、呼吸困难、恶心或放射至左臂/下颌，应立即拨打急救电话。"
        self.txt(x + 48, ky + 30, self.clip(k, pw - 112, self.font(9.5), 3),
                 9.5, "#26424A", width=pw - 112)

        # 按钮
        by = y + ph - 62
        if ok:
            self.button(x + 34, by, 156, 42, "继续", self.next_shift, TEAL_D, 11, theme=True)
            self.button(x + pw - 190, by, 156, 42, "重打本班", self.retry_shift, "#5A6A6E", 11)
        else:
            self.button(x + 34, by, 156, 42, "重打本班", self.retry_shift, CORAL, 11, theme=True)
            self.button(x + pw - 190, by, 156, 42, "退出", self.destroy, "#5A6A6E", 11)

    def next_shift(self):
        done, _ = self.game.advance()
        self.result_modal = None
        if done:
            self.refresh()
        else:
            self.refresh()

    # ---------------- 通关画面 ----------------
    def draw_campaign_end(self):
        acc = self.theme["accent"]
        acc2 = self.theme["accent_2"]
        c = self.game.campaign
        true_end = self.game.true_ending()
        pw, ph = 940, 600
        x, y = (DW - pw) / 2, (DH - ph) / 2
        bd = mix("#000000", acc, 0.38)
        self.rrect(x, y, pw, ph, 10, "#050F14", bd, 1)
        self.rrect(x + 1, y + 1, pw - 2, ph - 2, 9, mix("#061218", acc, 0.06))
        accent = GOLD if true_end else acc
        self.rrect(x, y, pw, 4, 2, accent, accent)

        self.txt(x + 50, y + 44, "交　班" if true_end else "五章完结", 34,
                 "#FFFFFF", True, serif=True)
        self.txt(x + 50, y + 94,
                 D.TRUE_ENDING["name"] if true_end else "你值完了这五个人的夜班",
                 14, accent, serif=True)

        body = D.TRUE_ENDING["text"] if true_end else (
            "五个人的身体，五段不同的夜。\n"
            "你没有治好任何人——你只是在他们忽略自己的时候，替他们听了一会儿。\n\n"
            "总事故 %d 次　·　误导值合计 %d\n"
            "这不算完美。但你已经知道该怎么听了。" % (
                c["total_incidents"], sum(c["chapter_mis"]) if c["chapter_mis"] else 0))
        self.txt(x + 50, y + 136, body, 12, "#C6D2D5", serif=True, width=pw - 100)

        # 章节结果
        yy = y + 340
        for i, ch in enumerate(D.CHAPTERS):
            done = i < len(c["chapter_trust"])
            t = c["chapter_trust"][i] if done else 0
            col = "#5FBE8A" if t >= 60 else ("#F5D26B" if t >= 45 else "#FF9A7E")
            self.txt(x + 50 + i * 176, yy, ch["code"], 9, mix("#000000", acc, 0.45))
            self.txt(x + 50 + i * 176, yy + 20,
                     ("信任 %d" % t) if done else "未完成", 13,
                     col if done else "#3E5559", True)

        self.button(x + 50, y + ph - 62, 156, 42, "重新开始",
                    self.restart_campaign, TEAL_D, 11, theme=True)
        self.button(x + pw - 206, y + ph - 62, 156, 42, "退出",
                    self.destroy, "#5A6A6E", 11)

    def toggle_sfx(self):
        on = self.sfx.toggle()
        self.show_toast("音效" + ("已开启" if on else "已静音"), "按 M 切换")
        if on:
            self.sfx.play("ui")

    def on_dilemma_key(self, i):
        if self.game.pending_dilemma and self.game.choose_dilemma(i):
            self.sfx.play("select")
            self.refresh()

    def restart_campaign(self):
        self.game = Game(seed=None)
        self.result_modal = None
        self.refresh()

    # ---------------- Toast ----------------
    def show_toast(self, title, body):
        self.toast = (title, body)
        self.refresh()
        if self.toast_job:
            self.after_cancel(self.toast_job)
        self.toast_job = self.after(2200, self.clear_toast)

    def clear_toast(self):
        self.toast = None
        self.toast_job = None
        self.refresh()

    def draw_toast(self):
        title, body = self.toast
        pw, ph = 340, 66
        x, y = (DW - pw) / 2, DH - 120
        self.rrect(x, y, pw, ph, 5, "#1B3A40", CORAL, 1)
        self.txt(x + 16, y + 12, title, 10.5, PAPER, True)
        self.txt(x + 16, y + 32, self.clip(body, pw - 32, self.font(9), 2),
                 9, "#A8B8BB", width=pw - 32)

    # ---------------- 事件 ----------------
    def on_click(self, e):
        dx = (e.x - self.ox) / self.s
        dy = (e.y - self.oy) / self.s
        for (x1, y1, x2, y2, cb) in reversed(self.hotspots):
            if x1 <= dx <= x2 and y1 <= dy <= y2:
                cb()
                return

    def on_rclick(self, e):
        dx = (e.x - self.ox) / self.s
        dy = (e.y - self.oy) / self.s
        for (cid, x1, y1, x2, y2) in reversed(self.card_rects):
            if x1 <= dx <= x2 and y1 <= dy <= y2:
                if self.game.phase != "shift":
                    return
                if self.game.rerolls <= 0:
                    self.show_toast("换签用完了", "本班两次换签已经用完。")
                    return
                self.game.reroll(cid)
                self.refresh()
                return

    def on_motion(self, e):
        dx = (e.x - self.ox) / self.s
        dy = (e.y - self.oy) / self.s
        old = self.hover_card
        self.hover_card = None
        for (cid, x1, y1, x2, y2) in self.card_rects:
            if x1 <= dx <= x2 and y1 <= dy <= y2:
                self.hover_card = cid
                break
        if old != self.hover_card:
            self.refresh()


if __name__ == "__main__":
    App().mainloop()

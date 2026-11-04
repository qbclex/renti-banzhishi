# -*- coding: utf-8 -*-
"""把 game.py 拆成 engine.py（纯规则引擎，无 tkinter）+ game.py（tkinter 界面）。

用法：python tools/split_desktop.py
重构当期一次性脚本，保留作记录；拆分后 engine.py / game.py 独立演进。
"""
import io
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(HERE, "game.py")
ENGINE = os.path.join(HERE, "engine.py")

lines = io.open(SRC, encoding="utf-8-sig").read().split("\n")


def find(pred, start=0):
    for i in range(start, len(lines)):
        if pred(lines[i]):
            return i
    return -1


i_game = find(lambda s: s.startswith("class Game:"))
i_phantom = find(lambda s: s.strip() == "def toggle_sfx(self):", i_game)
i_app = find(lambda s: s.startswith("class App("), i_game)
i_pick = find(lambda s: s.startswith("def pick_font("))
i_clamp = find(lambda s: s.startswith("def clamp("))
i_mix = find(lambda s: s.startswith("def mix("))
assert min(i_game, i_phantom, i_app, i_pick, i_clamp, i_mix) > 0

# ---- engine.py：clamp + Game（丢掉误插进引擎的 3 个界面方法）----
engine_body = lines[i_game:i_phantom]
engine_head = u'''# -*- coding: utf-8 -*-
"""
《人体值班室》垂直切片原型 · 规则引擎（纯逻辑，不 import tkinter）

界面层（game.py）与测试（tests/）都只通过本模块的 Game 类操作对局，
因此引擎可以在无显示环境（CI / 无头测试）下完整跑完 5 章 15 班。
"""
import random

import content_full as D


def clamp(v, lo=0, hi=100):
    return max(lo, min(hi, v))


'''

engine_tail = u'''

# =====================================================================
#                     无头对局驱动（CI / 平衡性统计）
# =====================================================================
def pick_card(g, order):
    """模拟一个「会看单子」的玩家：红旗单只认转诊，其余优先正解。"""
    usable = [c for c in g.hand if g.can_play(c)]
    if not usable:
        return None

    def school(c):
        return D.CARD_MAP[c]["s"]

    if order["kind"] == "redflag":
        for c in usable:
            if school(c) == "refer":
                return c
        return None
    for bucket in ("best", "good"):
        for c in usable:
            if c in order[bucket]:
                return c
    return usable[0]


def simulate(seed=20261030, on_step=None, max_shifts=300):
    """无头跑通整场战役。

    on_step(g, event) 可选回调，event 取 'play' / 'settle'，供测试逐步校验。
    返回 (game, stats)。
    """
    g = Game(seed=seed)
    rng = random.Random(seed)
    st = {"retries": 0, "plays": 0, "dilemmas": 0,
          "combos": 0, "cures": 0, "emergencies": 0}

    def emit(ev):
        if on_step:
            on_step(g, ev)

    for _ in range(max_shifts):
        if g.campaign["cleared"]:
            break
        g.start_shift()
        for _ in range(120):
            if g.pending_dilemma:
                st["dilemmas"] += 1
                g.choose_dilemma(rng.randrange(len(g.pending_dilemma["options"])))
                emit("dilemma")
                continue
            if g.phase != "shift":
                break
            orders = g.active_orders()
            if not orders:
                break
            target = next((o for o in orders if o["kind"] == "redflag"), orders[0])
            cid = pick_card(g, target)
            if cid is None:
                if g.rerolls > 0 and g.hand:
                    g.reroll(g.hand[0])
                    continue
                if g.clock + 1 <= g.max_clock:
                    g.wait()
                    continue
                break
            g.play_card(cid, target["uid"])
            st["plays"] += 1
            st["combos"] += 1 if g.combo_flash else 0
            st["cures"] += 1 if g.cured_flash else 0
            st["emergencies"] += 1 if g.emergency_flash else 0
            g.combo_flash = None
            g.cured_flash = None
            g.emergency_flash = None
            emit("play")

        if g.phase == "over":                 # 事故：重打本班
            st["retries"] += 1
            g.pending_feedback = None
            g.load_shift()
            g.start_shift()
            emit("retry")
            continue

        g.phase = "settle"
        if g.rating is None:
            g.rating = g.compute_rating()
        g.save_rating()
        emit("settle")
        done, _ = g.advance()
        if done:
            break

    c = g.campaign
    st.update({
        "cleared": c["cleared"],
        "incidents": c["total_incidents"],
        "misleading": sum(c["chapter_mis"]),
        "ratings": [r for r in c["ratings"] if r],
        "true_ending": g.true_ending(),
    })
    return g, st
'''

io.open(ENGINE, "w", encoding="utf-8", newline="\n").write(
    engine_head + "\n".join(engine_body) + engine_tail)

# ---- game.py：只剩界面层 ----
ui_head = "\n".join(lines[:i_pick])
ui_head = ui_head.replace(
    "from audio import Sfx\n",
    "from audio import Sfx\nfrom engine import Game, clamp          # 规则引擎与界面分离\n")

# pick_font（用 tkfont）+ mix（纯颜色工具）+ App，中间的 clamp 与 Game 已移入 engine.py
ui_rest = "\n".join(lines[i_pick:i_clamp] + lines[i_mix:i_game] + lines[i_app:])

out = ui_head.rstrip() + "\n\n\n" + ui_rest.lstrip("\n")
io.open(SRC, "w", encoding="utf-8", newline="\n").write(out)

print("engine.py %d 行 / game.py %d 行" % (len(engine_head.split("\n")) + len(engine_body) + len(engine_tail.split("\n")), len(out.split("\n"))))

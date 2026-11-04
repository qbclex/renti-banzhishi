# -*- coding: utf-8 -*-
"""
《人体值班室》垂直切片原型 · 规则引擎（纯逻辑，不 import tkinter）

界面层（game.py）与测试（tests/）都只通过本模块的 Game 类操作对局，
因此引擎可以在无显示环境（CI / 无头测试）下完整跑完 5 章 15 班。
"""
import content_full as D

MASK32 = 0xFFFFFFFF


def clamp(v, lo=0, hi=100):
    return max(lo, min(hi, v))


def round_div(a, b):
    """a / b 四舍五入（.5 远离零），只用整数运算。

    为什么不用 int(round(d * mult))：Python 的 round 是银行家舍入
    （round(-2.5) == -2），GDScript 的 round 是远离零（-3），跨端比对时
    会稳定地差 1。这里改成整数有理数预算，两端结果逐位相同。
    """
    if b < 0:
        a, b = -a, -b
    q = (abs(a) * 2 + b) // (2 * b)
    return q if a >= 0 else -q


class Rng:
    """确定性伪随机数（xorshift32）。

    为什么不用 random.Random：Godot 端要做「同种子逐位一致」的对照验证，
    而 Python 的 MT19937 与 Godot 的 PCG 无法对齐。这里用 32 位 xorshift，
    两端（Python int / GDScript int）都是无符号 32 位内运算，`>>` 等价，
    因此同一个 seed 在两端产生完全相同的序列。
    """

    def __init__(self, seed=None):
        s = 0 if seed is None else int(seed)
        self.state = (s ^ 0x9E3779B9) & MASK32
        if self.state == 0:
            self.state = 0x1F123BB5

    def next_u32(self):
        x = self.state
        x ^= (x << 13) & MASK32
        x ^= x >> 17
        x ^= (x << 5) & MASK32
        self.state = x & MASK32
        return self.state

    def randrange(self, n):
        """[0, n) 的整数；n <= 0 时返回 0。"""
        if n <= 0:
            return 0
        return self.next_u32() % n

    def shuffle(self, arr):
        """Fisher-Yates（从尾向头），与 engine.gd 的实现逐行对应。"""
        for i in range(len(arr) - 1, 0, -1):
            j = self.randrange(i + 1)
            arr[i], arr[j] = arr[j], arr[i]
        return arr


class Game:
    """关卡推进 + 牌组构筑 + 班次结算。"""

    def __init__(self, seed=None):
        self.rng = Rng(seed)
        self.campaign = {
            "chapter": 0,          # 当前章索引 0-4
            "shift": 0,            # 当前班索引 0-2
            "deck": list(D.STARTER_DECK),
            "total_incidents": 0,
            "chapter_trust": [],   # 每章结算时的 trust
            "chapter_mis": [],
            "ratings": [],         # 每班评级 S/A/B/C
            "cleared": False,
        }
        self.load_shift()

    # ---------- 关卡装载 ----------
    @property
    def chapter(self):
        return D.CHAPTERS[self.campaign["chapter"]]

    @property
    def shift_def(self):
        return self.chapter["shifts"][self.campaign["shift"]]

    def load_shift(self):
        sd = self.shift_def
        self.vitals = {k: init for k, _, _, init in D.VITALS}
        self.clock = 0
        self.max_clock = sd["clock"]
        self.orders = []
        self.hand = []
        self.deck = []
        self.discard = []
        self.log = []
        self.misleading = 0
        self.incidents = 0
        self.phase = "brief"     # brief / shift / settle / over
        self.selected_order = None
        self.pending_feedback = None
        self.stats = {"best": 0, "good": 0, "bad": 0,
                      "observe": 0, "refer": 0, "quack": 0}
        # 玩法系统状态
        self.statuses = {}          # 状态 key -> 剩余班次数（1=本班）
        self.last_card = None       # 上一张打出的牌（组合技用）
        self.combos_done = []       # 本班已触发的组合技
        self.combo_flash = None     # 刚触发的组合技（用于弹窗）
        self.cured_flash = None     # 刚解除的状态
        self.emergency_flash = None # 刚插入的突发工单
        self.fatigue = 0            # 连续出牌造成的疲劳（手牌压力）
        self.streak = 0             # 连续正解次数
        self.best_streak = 0        # 本班最高连击
        self.streak_flash = None    # 刚触发的连击
        self.rerolls = 2            # 本班剩余换签次数
        self.escalated = set()      # 已恶化的工单
        # 本轮新增：班中抉择与评级
        self.dilemma_fired = False
        self.pending_dilemma = None  # 等待展示的抉择
        self.dilemma_flash = None    # 刚做出的选择（用于提示）
        self.rating = None
        self.rating_saved = False
        self.dilemma = self._dilemma_for(self.chapter["no"], self.campaign["shift"])

        # 突发工单 id（第 3 班）——从常规池里剔除，改为中途插入
        # 「最后一班」按实际班数判断，不再硬编码第 3 班
        eid = (D.EMERGENCY.get(self.chapter["no"])
               if sd["n"] == len(self.chapter["shifts"]) else None)

        # 生成工单
        pool = [x for x in sd["pool"] if x != eid]
        self.rng.shuffle(pool)
        take = pool[:sd["order_count"]]
        if eid and eid not in take:
            self.max_clock += 1      # 多一张单，多给一刻
        for i, oid in enumerate(take):
            src = D.ORDER_MAP[oid]
            o = dict(src)
            # 统一字段名（数据源用简写，界面用全称）
            o["title"] = src["t"]
            o["body"] = src["b"]
            o["good_text"] = src.get("gt", "")
            o["bad_text"] = src.get("bt", "")
            o["fact"] = src["f"]
            o["uid"] = "%s_%d" % (oid, i)
            o["arrival"] = i
            o["resolved"] = False
            self.orders.append(o)

        # 突发工单（每章末班中途插入）
        self.emergency = None
        if sd["n"] == len(self.chapter["shifts"]):
            if eid and eid not in take:
                self.emergency = dict(D.ORDER_MAP[eid])
                self.emergency["title"] = self.emergency["t"]
                self.emergency["body"] = self.emergency["b"]
                self.emergency["good_text"] = self.emergency.get("gt", "")
                self.emergency["bad_text"] = self.emergency.get("bt", "")
                self.emergency["fact"] = self.emergency["f"]
                self.emergency["uid"] = eid + "_emg"
                self.emergency["arrival"] = 0
                self.emergency["resolved"] = False
                self.emergency["is_emergency"] = True
        self.emergency_fired = False

        # 班次环境
        envs = D.SHIFT_ENV.get(self.chapter["no"], [])
        self.env_key = envs[self.campaign["shift"]] if len(envs) > self.campaign["shift"] else "calm"
        self.env = D.ENV[self.env_key]
        if self.env_key == "busy":
            self.max_clock = max(5, self.max_clock - 1)

        # 牌库：接班前先领本班的处置签（reward / gift 当班即可用）
        self.deck = list(self.campaign["deck"])
        for cid in self._shift_cards():
            if cid not in self.deck:
                self.deck.append(cid)
        self.rng.shuffle(self.deck)

    def _shift_cards(self):
        """本班新增的牌：reward（你学到的）+ gift（宿主自己带回来的）。

        两者在牌组里待遇一样——当班可用、班末永久留下。分开只是为了让人
        看清楚牌是从哪来的：reward 是奖励，gift 是干扰。
        """
        sd = self.shift_def
        return list(sd.get("reward", [])) + list(sd.get("gift", []))

    def start_shift(self):
        self.phase = "shift"
        self.last_card = None
        self.combos_done = []
        self.combo_flash = None
        self.cured_flash = None
        self.streak_flash = None
        self.fatigue = 0
        self.dilemma_flash = None
        n = 5
        if "insomnia" in self.statuses:
            n -= 1              # 失眠：开局手牌 -1
        if self.env_key == "calm":
            n += 1              # 平静的夜：开局手牌 +1
        elif self.env_key == "alone":
            n -= 1              # 独自值班：手牌 -1
        self.draw(max(2, n))
        self._ensure_redflag_refer()

    def _ensure_redflag_refer(self):
        """红旗必须可解：本班若含 N 张红旗，保证开局手牌里至少有 N 张转诊(refer)牌。
        与 engine.gd 的 _ensure_redflag_refer 逐字对应。"""
        red_count = sum(1 for o in self.orders
                        if o["kind"] == "redflag" and not o["resolved"])
        if red_count == 0:
            return
        have = sum(1 for c in self.hand if D.CARD_MAP[c]["s"] == "refer")
        need = red_count - have
        if need <= 0:
            return
        injected = 0
        for o in self.orders:
            if injected >= need:
                break
            if o["kind"] != "redflag" or o["resolved"]:
                continue
            if not o["best"]:
                continue
            self.hand.append(o["best"][0])
            injected += 1

    def draw(self, n):
        for _ in range(n):
            if not self.deck:
                if not self.discard:
                    return
                self.deck = self.discard
                self.discard = []
                self.rng.shuffle(self.deck)
            self.hand.append(self.deck.pop())

    # ---------- 查询 ----------
    def active_orders(self):
        return [o for o in self.orders if not o["resolved"]]

    def goal_progress(self):
        """返回 (当前值, 目标值, 是否达成)。"""
        g = self.shift_def["goal"]
        k = g["kind"]
        if k == "trust":
            return self.vitals["trust"], g["value"], self.vitals["trust"] >= g["value"]
        if k == "no_incident":
            return self.incidents, 0, self.incidents == 0
        if k == "observe":
            return self.stats["observe"], g["value"], self.stats["observe"] >= g["value"]
        if k == "refer":
            return self.stats["refer"], g["value"], self.stats["refer"] >= g["value"]
        return 0, 0, True

    def score(self):
        return int(sum(
            self.vitals[k] if d == "better" else 100 - self.vitals[k]
            for k, _, d, _ in D.VITALS) / len(D.VITALS))

    # ---------- 核心动作 ----------
    def vital_cap(self, key):
        """指标上限：脱水的身体装不下那么多精力。"""
        if key == "energy" and "dehydration" in self.statuses:
            return 50
        return 100

    def _fix_caps(self):
        for k in self.vitals:
            cap = self.vital_cap(k)
            if self.vitals[k] > cap:
                self.vitals[k] = cap

    def eff_limit(self, order):
        """实际时限：炎症让一切都变得更急。"""
        return max(1, order["limit"] - (1 if "inflammation" in self.statuses else 0))

    def cost_of(self, cid):
        """实际消耗刻数：基础消耗 + 心悸惩罚。"""
        base = D.CARD_MAP[cid]["cost"]
        if "palpitation" in self.statuses and base > 0:
            base += 1
        return base

    def can_play(self, cid):
        return self.clock + self.cost_of(cid) <= self.max_clock

    def play_card(self, cid, uid):
        if self.phase != "shift" or cid not in self.hand:
            return
        card = D.CARD_MAP[cid]
        order = next((o for o in self.orders if o["uid"] == uid and not o["resolved"]), None)
        if order is None or not self.can_play(cid):
            return
        # 拦「对这张单无效的转诊牌」：转诊牌本身就是部分普通单的正解（如 c_clinic），
        # 只有既不是红旗单、又不是该单正解时才拒——防止把 c_er 这类唯一救命牌浪费掉。
        # 与 engine.gd 的 play_card 逐字对应。
        if (card["s"] == "refer" and order["kind"] != "redflag"
                and cid not in order["best"] and cid not in order["good"]):
            return

        cost = self.cost_of(cid)
        self.clock += cost
        self.hand.remove(cid)
        self.discard.append(cid)

        # ---- 组合技判定：上一张牌 + 这一张 ----
        combo = None
        if self.last_card:
            combo = D.COMBO_BY_PAIR.get((self.last_card, cid))
            if combo and combo["id"] not in self.combos_done:
                self.combos_done.append(combo["id"])
                self.combo_flash = combo
                for k, d in combo["effect"].items():
                    self.vitals[k] = clamp(self.vitals[k] + d)
                self.vitals["trust"] = clamp(self.vitals["trust"] + combo.get("trust", 0))
        self.last_card = cid

        # ---- 对症解除状态 ----
        cured = []
        for st in D.CURE_TO_STATUS.get(cid, []):
            if st in self.statuses:
                del self.statuses[st]
                cured.append(st)
        self.cured_flash = cured if cured else None

        if cid in order["best"]:
            grade = "best"
        elif cid in order["good"]:
            grade = "good"
        elif cid in order["bad"]:
            grade = "bad"
        elif card["s"] == "quack":
            grade = "bad"
        else:
            grade = "off"

        if order["kind"] == "redflag":
            if card["s"] == "refer":
                grade = "best"
            else:
                grade = "incident"
                self.incidents += 1

        self.apply(card, grade)
        order["resolved"] = True

        # 统计
        if grade in self.stats:
            self.stats[grade] += 1
        if card["s"] == "observe":
            self.stats["observe"] += 1
        if card["s"] == "refer":
            self.stats["refer"] += 1
        if card["s"] == "quack":
            self.misleading += 1
            self.stats["quack"] += 1
            if self.env_key == "rumor":
                self.misleading += 1   # 谣言四起：偏方额外 +1

        self.log.insert(0, (grade, order, card))

        # ---- 连击：连续正解累积信任 ----
        self.streak_flash = None
        if grade == "best":
            self.streak += 1
            self.best_streak = max(self.best_streak, self.streak)
            bonus = {2: 4, 3: 7}.get(self.streak, 10 if self.streak >= 4 else 0)
            if bonus:
                self.vitals["trust"] = clamp(self.vitals["trust"] + bonus)
                self.streak_flash = (self.streak, bonus)
                self.log.insert(0, ("status", None,
                                    dict(n="连续 %d 次正解 · 信任 +%d" % (self.streak, bonus))))
        else:
            self.streak = 0

        if grade == "incident":
            self.phase = "over"
            self.pending_feedback = ("incident", order, card)
            return

        self.pending_feedback = ("result", order, card, grade)
        self.check_overdue_status()
        self.maybe_emergency()
        self.maybe_dilemma()
        self.draw(1)
        self._fix_caps()
        if self.clock >= self.max_clock or not self.active_orders():
            self.phase = "settle"

    def apply(self, card, grade):
        if card["s"] == "quack":
            for k, d in card["eff"].items():
                self.vitals[k] = clamp(self.vitals[k] + d)
            return
        # 效果倍率用「分子/分母」的整数有理数表示，避免浮点舍入差异：
        # best=1、good=1/2、bad=-3/5、incident=-1
        # off=0：牌与本病单没对上，不造成正向或负向后果（不编造「有效」的叙事）
        num, den = {"best": (1, 1), "good": (1, 2), "off": (0, 1),
                    "bad": (-3, 5), "incident": (-1, 1)}[grade]
        if self.vitals["energy"] < 25:
            den *= 2                # 精力见底：效果减半
        if self.env_key == "alone" and num > 0:
            num, den = num * 23, den * 20   # 独自值班：处置效果 +15%
        # 反流：生活处方效果减半
        if "reflux" in self.statuses and card["s"] == "life":
            den *= 2
        for k, d in card["eff"].items():
            self.vitals[k] = clamp(self.vitals[k] + round_div(d * num, den))

    def add_status(self, key):
        if key in D.STATUS and key not in self.statuses:
            self.statuses[key] = 1
            self._fix_caps()
            self.log.insert(0, ("status", None, dict(n="身体出现「%s」" % D.STATUS[key]["name"])))

    def maybe_emergency(self):
        """第 3 班处理掉两张单之后，插入一张突发工单。"""
        if self.emergency_fired or not self.emergency:
            return
        if len(self.orders) - len(self.active_orders()) >= 2:
            self.emergency_fired = True
            e = dict(self.emergency)
            e["arrival"] = self.clock
            self.orders.append(e)
            self.log.insert(0, ("status", None,
                                dict(n="突发工单：「%s」" % e["title"])))
            self.emergency_flash = e
            # 突发单可能是红旗（开局池里没有它，start_shift 的保底看不到）：
            # 插入后立刻补一次转诊牌，否则本班无解。
            self._ensure_redflag_refer()

    # ---------- 班中抉择 ----------
    @staticmethod
    def _dilemma_for(chapter_no, shift_idx):
        items = D.DILEMMAS.get(chapter_no) or D.DILEMMAS.get(str(chapter_no)) or []
        if not items:
            return None
        return items[shift_idx % len(items)]

    def maybe_dilemma(self):
        """时间过半时插入一次抉择，每个班次只触发一次。"""
        if self.dilemma_fired or not self.dilemma:
            return
        if self.clock < self.max_clock // 2:
            return
        self.dilemma_fired = True
        self.pending_dilemma = self.dilemma
        self.log.insert(0, ("status", None, dict(n="值班中出现抉择：「%s」" % self.dilemma["title"])))

    def choose_dilemma(self, index):
        """处理抉择选项：改指标、挂状态、调整刻数或抽牌。"""
        d = self.pending_dilemma or self.dilemma
        if not d:
            return False
        options = d["options"]
        if index < 0 or index >= len(options):
            return False
        opt = options[index]
        self.pending_dilemma = None

        for k, dv in (opt.get("eff") or {}).items():
            if k in self.vitals:
                self.vitals[k] = clamp(self.vitals[k] + dv)
        if opt.get("status"):
            self.add_status(opt["status"])
        if opt.get("mis"):
            self.misleading += opt["mis"]
        if opt.get("clock"):
            self.clock = max(0, self.clock + opt["clock"])
        if opt.get("draw"):
            self.draw(opt["draw"])
        if opt.get("log"):
            self.log.insert(0, ("bad" if opt.get("mis") else "good", None, dict(n=opt["log"])))
        self.dilemma_flash = {"title": d["title"], "label": opt["label"]}

        self._fix_caps()
        if self.clock >= self.max_clock:
            self.phase = "settle"
        return True

    # ---------- 班次评级 ----------
    def compute_rating(self):
        left = max(0, self.max_clock - self.clock)
        raw = (58
               + self.stats["best"] * 7 + self.stats["good"] * 3
               - self.stats["bad"] * 6 - self.stats["quack"] * 9
               - self.incidents * 22
               + left * 3 + self.best_streak * 2
               + len(self.combos_done) * 3)
        score = max(0, min(120, raw))
        for floor, grade, comment in D.RATING_TIERS:
            if score >= floor:
                return {"score": score, "grade": grade, "comment": comment}
        return {"score": score, "grade": "C", "comment": ""}

    def save_rating(self):
        if self.rating_saved:
            return
        if self.rating is None:
            self.rating = self.compute_rating()
        self.rating_saved = True
        # 评级槽位按「前面各章班数之和 + 本章班内序号」计算，不假设每章 3 班
        idx = self.campaign["shift"] + sum(
            len(D.CHAPTERS[i]["shifts"]) for i in range(self.campaign["chapter"]))
        ratings = self.campaign["ratings"]
        while len(ratings) <= idx:
            ratings.append(None)
        ratings[idx] = self.rating["grade"]

    def check_overdue_status(self):
        """超时未处理的工单，会给身体挂上状态。"""
        for o in self.orders:
            if o["resolved"]:
                continue
            key = D.ORDER_STATUS.get(o["id"])
            if not key:
                continue
            overdue = self.clock - o["arrival"] - self.eff_limit(o)
            if overdue >= 1:
                self.add_status(key)
            if overdue >= 2 and o["uid"] not in self.escalated:
                self.escalated.add(o["uid"])
                self.vitals["energy"] = clamp(self.vitals["energy"] - 6)
                self.vitals["stress"] = clamp(self.vitals["stress"] + 8)
                self.log.insert(0, ("bad", None,
                                    dict(n="「%s」拖久了，身体在代偿" % o["title"])))

    def reroll(self, cid):
        """换签：弃掉一张手牌换一张新的，本班限 2 次，不消耗刻数。"""
        if self.phase != "shift" or cid not in self.hand or self.rerolls <= 0:
            return False
        self.hand.remove(cid)
        self.discard.append(cid)
        self.rerolls -= 1
        self.draw(1)
        return True

    def wait(self):
        if self.phase != "shift":
            return
        if self.clock + 1 > self.max_clock:
            return
        self.clock += 1
        self.fatigue += 1          # 空耗也在累积疲劳
        self.check_overdue_status()
        self.maybe_emergency()
        self.maybe_dilemma()
        self._fix_caps()
        if self.clock >= self.max_clock:
            self.phase = "settle"

    # ---------- 关卡推进 ----------
    def advance(self):
        """通关后进入下一班/下一章，返回 (是否通关, 提示文本)。"""
        cur = self.campaign
        ch = self.chapter

        # 记录本章数据
        if cur["shift"] == len(self.chapter["shifts"]) - 1:
            cur["chapter_trust"].append(self.vitals["trust"])
            cur["chapter_mis"].append(self.misleading)

        cur["total_incidents"] += self.incidents

        # 加入奖励牌 + 干扰牌（干扰牌赢不了这一班也甩不掉）
        for cid in self._shift_cards():
            if cid not in cur["deck"]:
                cur["deck"].append(cid)

        if cur["shift"] < len(self.chapter["shifts"]) - 1:
            cur["shift"] += 1
            self.load_shift()
            return False, ""
        if cur["chapter"] < len(D.CHAPTERS) - 1:
            cur["chapter"] += 1
            cur["shift"] = 0
            self.load_shift()
            return False, ""
        cur["cleared"] = True
        return True, ""

    def true_ending(self):
        c = self.campaign
        return (c["cleared"] and c["total_incidents"] <= 2
                and sum(c["chapter_mis"]) <= 2
                and all(t >= 60 for t in c["chapter_trust"]))


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
    # 兜底也不能挑「对这张单无效的转诊牌」（play_card 会拒），否则模拟器会空转。
    # 与 engine.gd / main.gd 的选牌逻辑对齐。
    for c in usable:
        if school(c) == "refer" and c not in order["best"] and c not in order["good"]:
            continue
        return c
    return None


def combo_partner(g, order):
    """如果手上的某张牌能接住上一张牌形成组合，且对当前工单也是正解，就优先打它。"""
    if not g.last_card:
        return None
    for cid in g.hand:
        cb = D.COMBO_BY_PAIR.get((g.last_card, cid))
        if not cb or cb["id"] in g.combos_done:
            continue
        if not g.can_play(cid):
            continue
        if cid in order["best"] or cid in order["good"]:
            return cid
    return None


def simulate(seed=20261030, on_step=None, max_shifts=300):
    """无头跑通整场战役。

    on_step(g, event) 可选回调，event 取 'play' / 'settle'，供测试逐步校验。
    返回 (game, stats)。
    """
    g = Game(seed=seed)
    rng = Rng(seed)
    st = {"retries": 0, "plays": 0, "dilemmas": 0,
          "combos": 0, "cures": 0, "emergencies": 0}

    # 轨迹：与 engine.gd 的 main.gd 输出同格式，用于跨语言逐位比对。
    # 只记录整数与 id，避免浮点格式化差异。
    trace = []

    def vit():
        return ",".join(str(g.vitals[k]) for k, _, _, _ in D.VITALS)

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
                _opt = rng.randrange(len(g.pending_dilemma["options"]))
                g.choose_dilemma(_opt)
                trace.append("D|%d|%d|%d|%s" % (g.campaign["chapter"], g.campaign["shift"],
                                                _opt, vit()))
                emit("dilemma")
                continue
            if g.phase != "shift":
                break
            orders = g.active_orders()
            if not orders:
                break
            # 红旗单优先；但如果手上答不了红旗单，就退而处理别的单，
            # 而不是干等到超时（否则整班会 0 出牌，统计与评级全部失真）。
            target, cid = None, None
            for want_red in (True, False):
                for o in orders:
                    if (o["kind"] == "redflag") != want_red:
                        continue
                    c = combo_partner(g, o) or pick_card(g, o)
                    if c:
                        target, cid = o, c
                        break
                if target is not None:
                    break
            if cid is None:
                if g.rerolls > 0 and g.hand:
                    g.reroll(g.hand[0])
                    continue
                if g.clock + 1 <= g.max_clock:
                    g.wait()
                    continue
                break
            g.play_card(cid, target["uid"])
            trace.append("P|%d|%d|%d|%s|%s|%s"
                         % (g.campaign["chapter"], g.campaign["shift"], g.clock,
                            cid, target["uid"], vit()))
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
            trace.append("R|%d|%d" % (g.campaign["chapter"], g.campaign["shift"]))
            g.pending_feedback = None
            g.load_shift()
            g.start_shift()
            emit("retry")
            continue

        g.phase = "settle"
        if g.rating is None:
            g.rating = g.compute_rating()
        g.save_rating()
        trace.append("S|%d|%d|%d|%s" % (g.campaign["chapter"], g.campaign["shift"],
                                        g.rating["score"], g.rating["grade"]))
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
        "trace": trace,
    })
    return g, st


if __name__ == "__main__":
    import sys
    _seed = int(sys.argv[1]) if len(sys.argv) > 1 else 20261030
    _g, _st = simulate(seed=_seed)
    print("种子 %d · 通关 %s · 事故 %d 次 · 误信 %d 次 · 真结局 %s"
          % (_seed, _st["cleared"], _st["incidents"], _st["misleading"],
             "达成" if _st["true_ending"] else "未达成"))
    print("评级 %s" % " ".join(_st["ratings"]))
    print("出牌 %d 次 · 抉择 %d 次 · 组合 %d 次 · 对症 %d 次 · 突发 %d 次 · 重打 %d 次"
          % (_st["plays"], _st["dilemmas"], _st["combos"], _st["cures"],
             _st["emergencies"], _st["retries"]))

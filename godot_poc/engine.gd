# 人体值班室 · 规则引擎（GDScript 移植自 engine.py）
# 纯逻辑，不依赖任何节点/UI；可被 Godot 场景或 main.gd 直接驱动。
# 数据来自 data.gd（preload 后作为 D 访问其顶层 const）。

const D = preload("res://data.gd")

const MASK32 = 0xFFFFFFFF


# 确定性伪随机数（xorshift32），与 engine.py 的 Rng 逐位对应。
# 因为 Python 的 MT19937 与 Godot 的 PCG 无法对齐，所以两端共用这套实现，
# 以便「同 seed 双端逐位一致」的对照验证成立。
class Rng:
    var state = 0

    func _init(p_seed = null):
        var s = 0 if p_seed == null else int(p_seed)
        state = (s ^ 0x9E3779B9) & MASK32
        if state == 0:
            state = 0x1F123BB5

    func next_u32() -> int:
        var x = state
        x ^= (x << 13) & MASK32
        x ^= x >> 17
        x ^= (x << 5) & MASK32
        state = x & MASK32
        return state

    func randrange(n) -> int:
        if n <= 0:
            return 0
        return next_u32() % n

    func shuffle(arr) -> void:
        for i in range(arr.size() - 1, 0, -1):
            var j = randrange(i + 1)
            var tmp = arr[i]
            arr[i] = arr[j]
            arr[j] = tmp


class Game:
    # ---- 实例状态（GDScript 要求先声明）----
    var rng = null
    var campaign = {}
    var vitals = {}
    var clock = 0
    var max_clock = 0
    var orders = []
    var hand = []
    var deck = []
    var discard = []
    var log = []
    var misleading = 0
    var incidents = 0
    var phase = "brief"
    var selected_order = null
    var pending_feedback = null
    var stats = {}
    var statuses = {}
    var last_card = null
    var combos_done = []
    var combo_flash = null
    var cured_flash = null
    var emergency_flash = null
    var fatigue = 0
    var streak = 0
    var best_streak = 0
    var streak_flash = null
    var rerolls = 0
    var escalated = {}
    var dilemma_fired = false
    var pending_dilemma = null
    var dilemma_flash = null
    ## 跨章时由 `advance()` 填成「新章的 dict」，UI 据此弹出章节过场；非跨章时为 {}。
    ## 和 `pending_dilemma` 同性质：瞬态、不进存档（restore 里清掉）。
    var pending_chapter_intro = {}
    var rating = null
    var rating_saved = false
    var dilemma = null
    var emergency = null
    var emergency_fired = false
    var env_key = "calm"
    var env = {}

    # ---------- 构造 ----------
    func _init(p_seed = null):
        rng = Rng.new(p_seed)
        campaign = {
            "chapter": 0, "shift": 0,
            "deck": D.STARTER_DECK.duplicate(),
            "total_incidents": 0,
            "chapter_trust": [], "chapter_mis": [],
            "ratings": [], "cleared": false,
        }
        load_shift()

    # ---------- 章节/班次查询 ----------
    func get_chapter() -> Dictionary:
        return D.CHAPTERS[campaign["chapter"]]

    func get_shift_def() -> Dictionary:
        return D.CHAPTERS[campaign["chapter"]]["shifts"][campaign["shift"]]

    func _shuffle(arr):
        var n = arr.size()
        for i in range(n - 1, 0, -1):
            var j = rng.randrange(i + 1)
            var tmp = arr[i]
            arr[i] = arr[j]
            arr[j] = tmp

    func load_shift():
        var sd = get_shift_def()
        vitals = {}
        for v in D.VITALS:
            vitals[v[0]] = v[3]
        clock = 0
        max_clock = sd["clock"]
        orders = []
        hand = []
        deck = []
        discard = []
        log = []
        misleading = 0
        incidents = 0
        phase = "brief"
        selected_order = null
        pending_feedback = null
        stats = {"best": 0, "good": 0, "bad": 0, "observe": 0, "refer": 0, "quack": 0}
        statuses = {}
        last_card = null
        combos_done = []
        combo_flash = null
        cured_flash = null
        emergency_flash = null
        fatigue = 0
        streak = 0
        best_streak = 0
        streak_flash = null
        rerolls = 2
        escalated = {}
        dilemma_fired = false
        pending_dilemma = null
        dilemma_flash = null
        rating = null
        rating_saved = false
        dilemma = dilemma_for(get_chapter()["no"], campaign["shift"])

        var eid = null
        # 「最后一班」按实际班数判断，不再硬编码第 3 班
        if sd.has("n") and sd["n"] == get_chapter()["shifts"].size():
            eid = D.EMERGENCY.get(get_chapter()["no"], null)
        var pool = []
        for x in sd["pool"]:
            if x != eid:
                pool.append(x)
        _shuffle(pool)
        var take = pool.slice(0, sd["order_count"])
        if eid != null and eid not in take:
            max_clock += 1
        for i in range(take.size()):
            var oid = take[i]
            var src = D.ORDER_MAP[oid]
            var o = src.duplicate()
            o["title"] = src["t"]
            o["body"] = src["b"]
            o["good_text"] = src.get("gt", "")
            o["bad_text"] = src.get("bt", "")
            o["fact"] = src["f"]
            o["uid"] = oid + "_" + str(i)
            o["arrival"] = i
            o["resolved"] = false
            orders.append(o)

        emergency = null
        if sd.has("n") and sd["n"] == get_chapter()["shifts"].size() and eid != null and eid not in take:
            emergency = D.ORDER_MAP[eid].duplicate()
            emergency["title"] = emergency["t"]
            emergency["body"] = emergency["b"]
            emergency["good_text"] = emergency.get("gt", "")
            emergency["bad_text"] = emergency.get("bt", "")
            emergency["fact"] = emergency["f"]
            emergency["uid"] = eid + "_emg"
            emergency["arrival"] = 0
            emergency["resolved"] = false
            emergency["is_emergency"] = true
        emergency_fired = false

        var envs = D.SHIFT_ENV.get(get_chapter()["no"], [])
        if campaign["shift"] < envs.size():
            env_key = envs[campaign["shift"]]
        else:
            env_key = "calm"
        env = D.ENV[env_key]
        if env_key == "busy":
            max_clock = maxi(5, max_clock - 1)

        deck = campaign["deck"].duplicate()
        for cid in _shift_cards():
            if cid not in deck:
                deck.append(cid)
        _shuffle(deck)

    ## 本班新增的牌：reward（你学到的）+ gift（宿主自己带回来的）。
    ## 两者在牌组里待遇一样——当班可用、班末永久留下。分开只是为了让人
    ## 看清楚牌是从哪来的：reward 是奖励，gift 是干扰。
    func _shift_cards() -> Array:
        var sd: Dictionary = get_shift_def()
        var out: Array = []
        out.append_array(sd.get("reward", []))
        out.append_array(sd.get("gift", []))
        return out

    func start_shift():
        phase = "shift"
        last_card = null
        combos_done = []
        combo_flash = null
        cured_flash = null
        streak_flash = null
        fatigue = 0
        dilemma_flash = null
        var n = 5
        if statuses.has("insomnia"):
            n -= 1
        if env_key == "calm":
            n += 1
        elif env_key == "alone":
            n -= 1
        draw(maxi(2, n))
        _ensure_redflag_refer()

    # 红旗必须可解：本班若含 N 张红旗，保证开局手牌里至少有 N 张转诊(refer)牌。
    # 否则玩家看到红旗却无牌可打，任何非转诊牌都会立刻判事故并结束本班（死锁）。
    # 缺的牌用该红旗的首选牌 best[0]（均为 refer：c_er / c_urgent / c_clinic）补进手牌。
    # 与 engine.py 的 _ensure_redflag_refer 逐字对应。
    func _ensure_redflag_refer():
        var red_count = 0
        for o in orders:
            if o["kind"] == "redflag" and not o["resolved"]:
                red_count += 1
        if red_count == 0:
            return
        var have = 0
        for c in hand:
            if D.CARD_MAP[c]["s"] == "refer":
                have += 1
        var need = red_count - have
        if need <= 0:
            return
        var injected = 0
        for o in orders:
            if injected >= need:
                break
            if o["kind"] != "redflag" or o["resolved"]:
                continue
            if o["best"].size() == 0:
                continue
            hand.append(o["best"][0])
            injected += 1

    func draw(n):
        for _i in range(n):
            if deck.is_empty():
                if discard.is_empty():
                    return
                deck = discard.duplicate()
                discard = []
                _shuffle(deck)
            hand.append(deck.pop_back())

    # ---------- 查询 ----------
    func active_orders():
        var res = []
        for o in orders:
            if not o["resolved"]:
                res.append(o)
        return res

    func goal_progress():
        var g = get_shift_def()["goal"]
        var k = g["kind"]
        if k == "trust":
            return [vitals["trust"], g["value"], vitals["trust"] >= g["value"]]
        if k == "no_incident":
            return [incidents, 0, incidents == 0]
        if k == "observe":
            return [stats["observe"], g["value"], stats["observe"] >= g["value"]]
        if k == "refer":
            return [stats["refer"], g["value"], stats["refer"] >= g["value"]]
        return [0, 0, true]

    func score() -> int:
        var s = 0
        for v in D.VITALS:
            var k = v[0]
            var d = v[2]
            s += vitals[k] if d == "better" else 100 - vitals[k]
        return int(s / D.VITALS.size())

    # ---------- 核心动作 ----------
    func vital_cap(key) -> int:
        if key == "energy" and statuses.has("dehydration"):
            return 50
        return 100

    func _fix_caps():
        for k in vitals:
            var cap = vital_cap(k)
            if vitals[k] > cap:
                vitals[k] = cap

    func eff_limit(order) -> int:
        var dec = 1 if statuses.has("inflammation") else 0
        return maxi(1, order["limit"] - dec)

    func cost_of(cid) -> int:
        var base = D.CARD_MAP[cid]["cost"]
        if statuses.has("palpitation") and base > 0:
            base += 1
        return base

    func can_play(cid) -> bool:
        return clock + cost_of(cid) <= max_clock

    func play_card(cid, uid):
        if phase != "shift" or not hand.has(cid):
            return
        var card = D.CARD_MAP[cid]
        var order = null
        for o in orders:
            if o["uid"] == uid and not o["resolved"]:
                order = o
                break
        if order == null or not can_play(cid):
            return
        # 拦「对这张单无效的转诊牌」：转诊牌本身就是部分普通单的正解（如 c_clinic），
        # 只有既不是红旗单、又不是该单正解时才拒——防止把 c_er 这类唯一救命牌浪费掉。
        # 与 engine.py 的 play_card 逐字对应。
        if card["s"] == "refer" and order["kind"] != "redflag" \
                and not (cid in order["best"]) and not (cid in order["good"]):
            return

        var cost = cost_of(cid)
        clock += cost
        hand.erase(cid)
        discard.append(cid)

        var combo = null
        if last_card != null:
            combo = D.COMBO_BY_PAIR.get(last_card + "|" + cid, null)
            if combo != null and not combos_done.has(combo["id"]):
                combos_done.append(combo["id"])
                combo_flash = combo
                for k in combo["effect"]:
                    vitals[k] = clamp(vitals[k] + combo["effect"][k], 0, 100)
                vitals["trust"] = clamp(vitals["trust"] + combo.get("trust", 0), 0, 100)
        last_card = cid

        var cured = []
        var cures = D.CURE_TO_STATUS.get(cid, [])
        for st in cures:
            if statuses.has(st):
                statuses.erase(st)
                cured.append(st)
        cured_flash = cured if cured.size() > 0 else null

        var grade = ""
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
                incidents += 1

        apply(card, grade)
        order["resolved"] = true

        if grade in stats:
            stats[grade] += 1
        if card["s"] == "observe":
            stats["observe"] += 1
        if card["s"] == "refer":
            stats["refer"] += 1
        if card["s"] == "quack":
            misleading += 1
            stats["quack"] += 1
            if env_key == "rumor":
                misleading += 1

        log.push_front([grade, order, card])

        streak_flash = null
        if grade == "best":
            streak += 1
            best_streak = maxi(best_streak, streak)
            var bonus = {2: 4, 3: 7}.get(streak, 10 if streak >= 4 else 0)
            if bonus != 0:
                vitals["trust"] = clamp(vitals["trust"] + bonus, 0, 100)
                streak_flash = [streak, bonus]
                log.push_front(["status", null,
                    {"n": "连续 %d 次正解 · 信任 +%d" % [streak, bonus]}])
        else:
            streak = 0

        if grade == "incident":
            phase = "over"
            pending_feedback = ["incident", order, card]
            return

        pending_feedback = ["result", order, card, grade]
        check_overdue_status()
        maybe_emergency()
        maybe_dilemma()
        draw(1)
        _fix_caps()
        if clock >= max_clock or active_orders().is_empty():
            phase = "settle"

    # a/b 四舍五入（.5 远离零），纯整数；与 engine.py 的 round_div 逐位一致。
    # Godot 的 round() 对 .5 远离零、Python 的 round() 是银行家舍入，直接混用会差 1。
    func _round_div(a, b) -> int:
        if b < 0:
            a = -a
            b = -b
        var q = (absi(a) * 2 + b) / (2 * b)
        return q if a >= 0 else -q

    func apply(card, grade):
        if card["s"] == "quack":
            for k in card["eff"]:
                vitals[k] = clamp(vitals[k] + card["eff"][k], 0, 100)
            return
        # off=[0,1]：牌与本病单没对上，不造成正向或负向后果（不编造「有效」的叙事）
        var r = {"best": [1, 1], "good": [1, 2], "off": [0, 1],
                 "bad": [-3, 5], "incident": [-1, 1]}[grade]
        var num = int(r[0])
        var den = int(r[1])
        if vitals["energy"] < 25:
            den *= 2
        if env_key == "alone" and num > 0:
            num *= 23
            den *= 20
        if statuses.has("reflux") and card["s"] == "life":
            den *= 2
        for k in card["eff"]:
            vitals[k] = clamp(vitals[k] + _round_div(card["eff"][k] * num, den), 0, 100)

    func add_status(key):
        if D.STATUS.has(key) and not statuses.has(key):
            statuses[key] = 1
            _fix_caps()
            log.push_front(["status", null,
                {"n": "身体出现「%s」" % D.STATUS[key]["name"]}])

    func maybe_emergency():
        if emergency_fired or emergency == null:
            return
        if (orders.size() - active_orders().size()) >= 2:
            emergency_fired = true
            var e = emergency.duplicate()
            e["arrival"] = clock
            orders.append(e)
            log.push_front(["status", null,
                {"n": "突发工单：「%s」" % e["title"]}])
            emergency_flash = e
            # 突发单可能是红旗（开局池里没有它，start_shift 的保底看不到）：
            # 插入后立刻补一次转诊牌，否则本班无解。
            _ensure_redflag_refer()

    # ---------- 班中抉择 ----------
    func dilemma_for(chapter_no, shift_idx):
        var items = D.DILEMMAS.get(chapter_no, [])
        if items == null or items.size() == 0:
            return null
        return items[shift_idx % items.size()]

    func maybe_dilemma():
        if dilemma_fired or dilemma == null:
            return
        if clock < int(max_clock / 2):
            return
        dilemma_fired = true
        pending_dilemma = dilemma
        log.push_front(["status", null,
            {"n": "值班中出现抉择：「%s」" % dilemma["title"]}])

    func choose_dilemma(index) -> bool:
        var d = pending_dilemma if pending_dilemma != null else dilemma
        if d == null:
            return false
        var options = d["options"]
        if index < 0 or index >= options.size():
            return false
        var opt = options[index]
        pending_dilemma = null
        if opt.has("eff"):
            for k in opt["eff"]:
                if k in vitals:
                    vitals[k] = clamp(vitals[k] + opt["eff"][k], 0, 100)
        if opt.has("status") and opt["status"] != "":
            add_status(opt["status"])
        if opt.has("mis"):
            misleading += opt["mis"]
        if opt.has("clock"):
            clock = maxi(0, clock + opt["clock"])
        if opt.has("draw"):
            draw(opt["draw"])
        if opt.has("log"):
            log.push_front(["bad" if opt.has("mis") else "good", null,
                {"n": opt["log"]}])
        dilemma_flash = {"title": d["title"], "label": opt["label"]}
        _fix_caps()
        if clock >= max_clock:
            phase = "settle"
        return true

    # ---------- 班次评级 ----------
    func compute_rating():
        var left = maxi(0, max_clock - clock)
        var raw = 58 + stats["best"] * 7 + stats["good"] * 3 \
            - stats["bad"] * 6 - stats["quack"] * 9 - incidents * 22 \
            + left * 3 + best_streak * 2 + combos_done.size() * 3
        var score_val = clamp(raw, 0, 120)
        for tier in D.RATING_TIERS:
            if score_val >= tier[0]:
                return {"score": score_val, "grade": tier[1], "comment": tier[2]}
        return {"score": score_val, "grade": "C", "comment": ""}

    func save_rating():
        if rating_saved:
            return
        if rating == null:
            rating = compute_rating()
        rating_saved = true
        # 评级槽位按「前面各章班数之和 + 本章班内序号」计算，不假设每章 3 班
        var idx = campaign["shift"]
        for i in range(campaign["chapter"]):
            idx += D.CHAPTERS[i]["shifts"].size()
        var ratings = campaign["ratings"]
        while ratings.size() <= idx:
            ratings.append(null)
        ratings[idx] = rating["grade"]

    func check_overdue_status():
        for o in orders:
            if o["resolved"]:
                continue
            var key = D.ORDER_STATUS.get(o["id"], null)
            if key == null:
                continue
            var overdue = clock - o["arrival"] - eff_limit(o)
            if overdue >= 1:
                add_status(key)
            if overdue >= 2 and not escalated.has(o["uid"]):
                escalated[o["uid"]] = true
                vitals["energy"] = clamp(vitals["energy"] - 6, 0, 100)
                vitals["stress"] = clamp(vitals["stress"] + 8, 0, 100)
                log.push_front(["bad", null,
                    {"n": "「%s」拖久了，身体在代偿" % o["title"]}])

    func reroll(cid) -> bool:
        if phase != "shift" or not hand.has(cid) or rerolls <= 0:
            return false
        hand.erase(cid)
        discard.append(cid)
        rerolls -= 1
        draw(1)
        return true

    func wait():
        if phase != "shift":
            return
        if clock + 1 > max_clock:
            return
        clock += 1
        fatigue += 1
        check_overdue_status()
        maybe_emergency()
        maybe_dilemma()
        _fix_caps()
        if clock >= max_clock:
            phase = "settle"

    # ---------- 存档：整局快照 ----------
    # 设计原则：只存「纯数据」，不存对象、不存派生值（env 由 env_key 重算）。
    # rng.state 必须一起存——否则读档后的洗牌序列会换一条线，
    # 玩家会发现「同样的操作，抽到的牌不一样」。
    # 用 var_to_str / str_to_var 往返（而不是 JSON）：JSON 会把整数读成浮点，
    # clock / 刻数一旦变成 3.0，range() 与 %d 都会出问题。
    const SAVE_VERSION = 1

    func snapshot() -> Dictionary:
        return {
            "v": SAVE_VERSION,
            "rng": int(rng.state),
            "campaign": campaign.duplicate(true),
            "shift": {
                "vitals": vitals.duplicate(true),
                "clock": clock,
                "max_clock": max_clock,
                "orders": orders.duplicate(true),
                "hand": hand.duplicate(),
                "deck": deck.duplicate(),
                "discard": discard.duplicate(),
                "log": log.duplicate(true),
                "misleading": misleading,
                "incidents": incidents,
                "phase": phase,
                "stats": stats.duplicate(true),
                "statuses": statuses.duplicate(true),
                "last_card": last_card,
                "combos_done": combos_done.duplicate(),
                "fatigue": fatigue,
                "streak": streak,
                "best_streak": best_streak,
                "rerolls": rerolls,
                "escalated": escalated.duplicate(true),
                "dilemma_fired": dilemma_fired,
                "dilemma": dilemma,
                "pending_dilemma": pending_dilemma,
                "emergency": emergency,
                "emergency_fired": emergency_fired,
                "env_key": env_key,
                "rating": rating,
                "rating_saved": rating_saved,
            },
        }

    ## 恢复快照。返回 false 表示存档版本/结构不认识，调用方应保持原状。
    func restore(data) -> bool:
        if typeof(data) != TYPE_DICTIONARY:
            return false
        if int(data.get("v", 0)) != SAVE_VERSION:
            return false
        if not data.has("shift") or typeof(data["shift"]) != TYPE_DICTIONARY:
            return false
        var s = data["shift"]
        for need in ["vitals", "clock", "max_clock", "orders", "hand", "deck",
                     "statuses", "phase", "env_key"]:
            if not s.has(need):
                return false

        campaign = data["campaign"].duplicate(true)
        rng.state = int(data["rng"]) & MASK32
        if rng.state == 0:
            rng.state = 0x1F123BB5

        vitals = s["vitals"].duplicate(true)
        clock = int(s["clock"])
        max_clock = int(s["max_clock"])
        orders = s["orders"].duplicate(true)
        hand = s["hand"].duplicate()
        deck = s["deck"].duplicate()
        discard = s["discard"].duplicate()
        log = s["log"].duplicate(true)
        misleading = int(s["misleading"])
        incidents = int(s["incidents"])
        phase = str(s["phase"])
        stats = s["stats"].duplicate(true)
        statuses = s["statuses"].duplicate(true)
        last_card = s["last_card"]
        combos_done = s["combos_done"].duplicate()
        fatigue = int(s["fatigue"])
        streak = int(s["streak"])
        best_streak = int(s["best_streak"])
        rerolls = int(s["rerolls"])
        escalated = s["escalated"].duplicate(true)
        dilemma_fired = bool(s["dilemma_fired"])
        dilemma = s["dilemma"]
        pending_dilemma = s["pending_dilemma"]
        emergency = s["emergency"]
        emergency_fired = bool(s["emergency_fired"])
        env_key = str(s["env_key"])
        env = D.ENV[env_key] if D.ENV.has(env_key) else D.ENV["calm"]
        rating = s.get("rating", null)
        rating_saved = bool(s.get("rating_saved", false))

        # 瞬时提示不跨档：读进来就弹上一班的结果条会很怪。
        selected_order = null
        pending_feedback = null
        pending_chapter_intro = {}
        combo_flash = null
        cured_flash = null
        emergency_flash = null
        streak_flash = null
        dilemma_flash = null
        # 旧档可能是在「红旗保底」之前存的（手里没有转诊牌），读档时补一次，
        # 避免用户读到无解的班次只能重开。
        _ensure_redflag_refer()
        return true

    # ---------- 关卡推进（POC 单班次用不到，保留以便后续扩展）----------
    ## 返回 [已通关?, 新章 dict]。跨章时第二项是对应的章节 dict（供 UI 弹过场），
    ## 否则为 {}。终章最后一班返回 [true, {}]（不弹过场，直接进结局）。
    func advance():
        var cur = campaign
        if cur["shift"] == get_chapter()["shifts"].size() - 1:
            cur["chapter_trust"].append(vitals["trust"])
            cur["chapter_mis"].append(misleading)
        cur["total_incidents"] += incidents
        for cid in _shift_cards():
            if cid not in cur["deck"]:
                cur["deck"].append(cid)
        if cur["shift"] < get_chapter()["shifts"].size() - 1:
            cur["shift"] += 1
            load_shift()
            return [false, {}]
        if cur["chapter"] < D.CHAPTERS.size() - 1:
            cur["chapter"] += 1
            cur["shift"] = 0
            load_shift()
            return [false, D.CHAPTERS[cur["chapter"]]]
        cur["cleared"] = true
        return [true, {}]

    func true_ending() -> bool:
        var c = campaign
        if not c["cleared"]:
            return false
        if c["total_incidents"] > 2:
            return false
        var mis = 0
        for m in c["chapter_mis"]:
            mis += m
        if mis > 2:
            return false
        for t in c["chapter_trust"]:
            if t < 60:
                return false
        return true

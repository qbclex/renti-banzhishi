extends SceneTree

# 无头对局驱动：与 engine.py 的 simulate() 逐行对应。
# 目的不是「能跑」，而是「与 Python 端输出逐位一致」——因此策略、顺序、
# 随机数消耗点都必须完全对齐，轨迹也只记录整数与 id。
#
# 用法：
#   godot --headless --path . --script main.gd            # 默认种子
#   godot --headless --path . --script main.gd -- 20261030
#   加 --check 时同时做不变式自检（失败则以非 0 退出）

const E = preload("res://engine.gd")

var trace := []
var g = null


func _vitals_line() -> String:
    var parts = []
    for v in E.D.VITALS:
        parts.append(str(g.vitals[v[0]]))
    return ",".join(parts)


func _pick_card(order) -> String:
    """与 engine.py 的 pick_card 一致：红旗单只认转诊，其余 best -> good -> 任意。"""
    var usable = []
    for c in g.hand:
        if g.can_play(c):
            usable.append(c)
    if usable.is_empty():
        return ""
    if order["kind"] == "redflag":
        for c in usable:
            if E.D.CARD_MAP[c]["s"] == "refer":
                return c
        return ""
    for bucket in ["best", "good"]:
        for c in usable:
            if c in order[bucket]:
                return c
    # 兜底也不能挑「对这张单无效的转诊牌」（play_card 会拒），否则自动对局会空转。
    # 与 engine.py 的 pick_card 对齐。
    for c in usable:
        if E.D.CARD_MAP[c]["s"] == "refer" and not (c in order["best"]) and not (c in order["good"]):
            continue
        return c
    return ""


func _combo_partner(order) -> String:
    """与 engine.py 的 combo_partner 一致：优先接住上一张牌的组合。"""
    if g.last_card == null:
        return ""
    for cid in g.hand:
        var cb = E.D.COMBO_BY_PAIR.get(str(g.last_card) + "|" + str(cid), null)
        if cb == null or g.combos_done.has(cb["id"]):
            continue
        if not g.can_play(cid):
            continue
        if cid in order["best"] or cid in order["good"]:
            return cid
    return ""


func _run(seed_value, check_mode: bool) -> void:
    g = E.Game.new(seed_value)
    var rng = E.Rng.new(seed_value)
    var max_shifts = 300
    var st = {"retries": 0, "plays": 0, "dilemmas": 0,
              "combos": 0, "cures": 0, "emergencies": 0}

    for _outer in range(max_shifts):
        if g.campaign["cleared"]:
            break
        g.start_shift()

        for _inner in range(120):
            if g.pending_dilemma != null:
                st["dilemmas"] += 1
                var opt = rng.randrange(g.pending_dilemma["options"].size())
                g.choose_dilemma(opt)
                trace.append("D|%d|%d|%d|%s" % [g.campaign["chapter"],
                    g.campaign["shift"], opt, _vitals_line()])
                continue
            if g.phase != "shift":
                break
            var orders = g.active_orders()
            if orders.is_empty():
                break

            # 红旗单优先；答不了红旗单就退而处理别的单，而不是干等到超时。
            # 与 engine.py 的 simulate 逐字对应（两趟：先红旗，后其余）。
            var target = null
            var cid = ""
            for want_red in [true, false]:
                for o in orders:
                    if (o["kind"] == "redflag") != want_red:
                        continue
                    var c = _combo_partner(o)
                    if c == "":
                        c = _pick_card(o)
                    if c != "":
                        target = o
                        cid = c
                        break
                if target != null:
                    break

            if cid == "":
                if g.rerolls > 0 and not g.hand.is_empty():
                    g.reroll(g.hand[0])
                    continue
                if g.clock + 1 <= g.max_clock:
                    g.wait()
                    continue
                break

            g.play_card(cid, target["uid"])
            trace.append("P|%d|%d|%d|%s|%s|%s" % [g.campaign["chapter"],
                g.campaign["shift"], g.clock, cid, target["uid"], _vitals_line()])
            st["plays"] += 1
            if g.combo_flash != null:
                st["combos"] += 1
            if g.cured_flash != null:
                st["cures"] += 1
            if g.emergency_flash != null:
                st["emergencies"] += 1
            g.combo_flash = null
            g.cured_flash = null
            g.emergency_flash = null

        if g.phase == "over":
            st["retries"] += 1
            trace.append("R|%d|%d" % [g.campaign["chapter"], g.campaign["shift"]])
            g.pending_feedback = null
            g.load_shift()
            g.start_shift()
            continue

        g.phase = "settle"
        if g.rating == null:
            g.rating = g.compute_rating()
        g.save_rating()
        trace.append("S|%d|%d|%d|%s" % [g.campaign["chapter"], g.campaign["shift"],
            g.rating["score"], str(g.rating["grade"])])
        var res = g.advance()
        if res[0]:
            break

    var c = g.campaign
    var ratings = []
    for r in c["ratings"]:
        if r != null:
            ratings.append(str(r))

    print("TRACE_BEGIN")
    for line in trace:
        print(line)
    print("TRACE_END")
    print("SUMMARY|cleared=%s|incidents=%d|misleading=%d|true_ending=%s" % [
        str(c["cleared"]), c["total_incidents"], _sum(c["chapter_mis"]),
        str(g.true_ending())])
    print("STATS|plays=%d|dilemmas=%d|combos=%d|cures=%d|emergencies=%d|retries=%d" % [
        st["plays"], st["dilemmas"], st["combos"], st["cures"],
        st["emergencies"], st["retries"]])
    print("RATINGS|" + ",".join(ratings))
    print("TRACE_LINES|%d" % trace.size())

    if check_mode:
        _self_check()


func _sum(arr) -> int:
    var s = 0
    for x in arr:
        s += int(x)
    return s


func _self_check() -> void:
    assert(g.clock <= g.max_clock, "clock 超过 max_clock")
    for k in g.vitals:
        assert(g.vitals[k] >= 0 and g.vitals[k] <= 100, "vital 越界: " + str(k))
    assert(g.rating != null, "rating 未生成")
    assert(g.stats["bad"] >= 0 and g.stats["quack"] >= 0, "负统计")
    var total_shifts := 0
    for ch in E.D.CHAPTERS:
        total_shifts += ch["shifts"].size()
    assert(g.campaign["ratings"].size() == total_shifts,
        "评级槽位不是 %d" % total_shifts)
    print("SELF_CHECK_OK")


func _initialize():
    var args = OS.get_cmdline_user_args()
    var seed_value = 20261030
    var check_mode = false
    for a in args:
        if a == "--check":
            check_mode = true
        elif a.is_valid_int():
            seed_value = int(a)
    _run(seed_value, check_mode)
    quit()

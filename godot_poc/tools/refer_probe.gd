extends SceneTree
## 红旗可解性探针：确认三件事
## ① 开局手牌里有红旗时，保底会补上转诊牌；
## ② 班中「突发红旗」插入后，同样会补（这是第 3 班的老坑）；
## ③ 旧存档（红旗在手、但手里没有转诊牌）读回来时会被补上，不需要玩家重开。
## 输出一行 REFER_PROBE，供 tests/ 正则断言。

const E = preload("res://engine.gd")
const D = preload("res://data.gd")


func _refer_in(hand) -> int:
	var n := 0
	for c in hand:
		if D.CARD_MAP[c]["s"] == "refer":
			n += 1
	return n


func _red_in(orders) -> int:
	var n := 0
	for o in orders:
		if o["kind"] == "redflag" and not o["resolved"]:
			n += 1
	return n


func _init():
	var g = E.Game.new(20261030)
	g.campaign["chapter"] = 0
	g.campaign["shift"] = 2          # 第 1 章第 3 班：红旗是中途突发的
	g.load_shift()
	g.start_shift()

	# ① 开局（此时突发单还没插入）
	var open_refs := _refer_in(g.hand)

	# ② 解掉两张单触发突发红旗
	var marked := 0
	for o in g.orders:
		if marked >= 2:
			break
		if o["kind"] != "redflag":
			o["resolved"] = true
			marked += 1
	g.maybe_emergency()
	var reds := _red_in(g.orders)
	var refs_after := _refer_in(g.hand)

	# ③ 造一个「旧档」：手里转诊牌被清空，再 restore
	var snap: Dictionary = g.snapshot()
	var kept := []
	for c in snap["shift"]["hand"]:
		if D.CARD_MAP[c]["s"] != "refer":
			kept.append(c)
	snap["shift"]["hand"] = kept
	var g2 = E.Game.new(7)
	var ok_restore: bool = g2.restore(snap)
	var refs_restored := _refer_in(g2.hand)
	var reds_restored := _red_in(g2.orders)

	# ④ 补出来的牌必须真的能打（不是塞了张不能用的）
	var can := false
	if reds_restored > 0:
		for c in g2.hand:
			if D.CARD_MAP[c]["s"] == "refer" and g2.can_play(c):
				can = true
				break

	print("REFER_PROBE open_refs=%d emergency_reds=%d refs_after=%d restore_ok=%s restored_refs=%d restored_reds=%d playable=%s"
		% [open_refs, reds, refs_after, str(ok_restore).to_lower(), refs_restored, reds_restored, str(can).to_lower()])
	var good: bool = refs_after >= reds and ok_restore and refs_restored >= reds_restored and (reds_restored == 0 or can)
	print("REFER_PROBE_RESULT %s" % str(good).to_lower())
	quit(0 if good else 1)

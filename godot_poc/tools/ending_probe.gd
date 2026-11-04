extends SceneTree

## 验证结局界面：独立实例化 main_ui、把 game 推到通关，调用 _ov_ending，
## 确认不崩、5 封宿主回信都出现、真结局 / 4 种变体分支都能选中。

func _init():
	print("ENDING_PROBE_START")
	var MainUI = load("res://ui/main_ui.gd")
	var E = preload("res://engine.gd")
	var D = preload("res://data.gd")
	print("LOADED MainUI=", MainUI != null, " E=", E != null, " D=", D != null)

	# ---- 1) 普通通关（信任低 → 非真结局，走变体分支）----
	var g = E.Game.new(20261102)
	for i in range(64):  # 只为跑到底，实际 25 班；数字放宽不写死
		var res = g.advance()
		if res[0]:
			break
	var ui = MainUI.new()
	ui.game = g
	var ok1 = _exercise(ui, g, "普通通关")

	# ---- 2) 强制真结局门槛：事故0 / 误导0 / 每章信任70 ----
	g = E.Game.new(20261102)
	for i in range(64):  # 只为跑到底，实际 25 班；数字放宽不写死
		var res = g.advance()
		if res[0]:
			break
	g.campaign["total_incidents"] = 0
	g.campaign["chapter_mis"] = [0, 0, 0, 0, 0]
	g.campaign["chapter_trust"] = [70, 70, 70, 70, 70]
	var ui2 = MainUI.new()
	ui2.game = g
	var ok2 = _exercise(ui2, g, "真结局路径")

	# ---- 3) 直接验证 _ending_variant 四种分支 ----
	var pick = {}
	var base = {"total_incidents":0,"chapter_mis":[0,0,0,0,0],"chapter_trust":[65,65,65,65,65]}
	var g3 = E.Game.new(1)
	g3.campaign = base.duplicate(true)
	pick["reconcile(高信任)"] = _variant(ui2, g3)
	var g4 = E.Game.new(1); g4.campaign = base.duplicate(true); g4.campaign["total_incidents"]=4
	pick["collapse(事故多)"] = _variant(ui2, g4)
	var g5 = E.Game.new(1); g5.campaign = base.duplicate(true); g5.campaign["chapter_mis"]=[0,0,3,0,0]
	pick["false(误导多)"] = _variant(ui2, g5)
	var g6 = E.Game.new(1); g6.campaign = base.duplicate(true); g6.campaign["chapter_trust"]=[50,50,50,50,50]
	pick["begin(信任低)"] = _variant(ui2, g6)

	print("ENDING_VARIANTS " + str(pick))
	print("ENDING_PROBE %s %s %s" % [ok1, ok2, (ok1 and ok2)])
	quit()

func _variant(ui, g) -> String:
	ui.game = g
	var d = ui._ending_variant()
	return str(d.get("name", "?"))

func _exercise(ui, g, tag) -> bool:
	var ctrl = ui._ov_ending()
	var labels = []
	_collect(ctrl, labels)
	var letters = 0
	for l in labels:
		if "——" in str(l.text):
			letters += 1
	var true_end = g.true_ending()
	print("  [%s] cleared=%s true_end=%s labels=%d letter_blocks=%d" % [
		tag, g.campaign["cleared"], true_end, labels.size(), letters])
	return ctrl is Control and letters >= 5

func _collect(n, out):
	for c in n.get_children():
		if c is Label:
			out.append(c)
		_collect(c, out)

extends SceneTree
## 存档往返的「确定性探针」（引擎级，不涉及界面）
##
## 只证明一件事：读档之后，接下来的每一刻都与「没存过档」的世界线完全一致。
## 做法是同一份状态走两条路——
##   A: 快照 → 继续跑 40 步
##   B: 快照写盘字符串 → 读回另一个 Game → 继续跑 40 步
## 两条路的逐步指纹必须逐字相同。指纹里含 rng.state，所以这条同时也验证了
## 「读档后洗牌序列不变」——这是玩家最容易察觉、也最难自查的一类 bug。
##
## 用法：
##   godot --headless --path . --script tools/save_probe.gd
## 退出码 0 = 一致，1 = 不一致（打印前 40 步两条轨迹便于定位）。

const E = preload("res://engine.gd")

const PRE_STEPS := 90    # 先跑够远，确保已经跨过班次推进（会触发 load_shift 洗牌）
const POST_STEPS := 60


func _initialize() -> void:
	var g = E.Game.new(20261030)
	var pre := _run(g, PRE_STEPS)
	var snap := g.snapshot()
	var text := var_to_str(snap)
	var cont_a := _run(g, POST_STEPS)

	var back = str_to_var(text)
	var g2 = E.Game.new(1)          # 故意给另一个种子，读档后应被覆盖
	var restored: bool = g2.restore(back) if typeof(back) == TYPE_DICTIONARY else false
	var restable: bool = restored and var_to_str(g2.snapshot()) == text
	var cont_b := _run(g2, POST_STEPS) if restored else ""

	var ok: bool = restored and restable and pre.length() > 0 and cont_a == cont_b
	print("SAVE_PROBE %s bytes=%d pre_sig_len=%d post_steps=%d restored=%s reserialize=%s"
		% ["OK" if ok else "MISMATCH", text.length(), pre.length(), POST_STEPS,
			str(restored).to_lower(), str(restable).to_lower()])
	if not ok:
		print("CONT_A=%s" % cont_a)
		print("CONT_B=%s" % cont_b)
	quit(0 if ok else 1)


## 确定性推进：不追求「打得好」，只追求「同样状态必然走同样的路」。
func _run(g, steps: int) -> String:
	var out := ""
	var done := 0
	var guard := 0
	while done < steps and guard < steps * 40:
		guard += 1
		if not _step(g):
			break
		done += 1
		out += _sig(g) + ";"
	return out


func _step(g) -> bool:
	if g.campaign["cleared"]:
		return false
	if g.phase == "brief":
		g.start_shift()
		return true
	if g.phase == "settle":
		if g.rating == null:
			g.rating = g.compute_rating()
		g.save_rating()
		g.advance()
		return true
	if g.pending_dilemma != null:
		g.choose_dilemma(0)
		return true
	if g.phase != "shift":
		return false
	var orders = g.active_orders()
	if orders.is_empty():
		return false
	var cid := ""
	for c in g.hand:
		if g.can_play(c):
			cid = c
			break
	if cid != "":
		g.play_card(cid, str(orders[0]["uid"]))
		return true
	if g.clock + 1 <= g.max_clock:
		g.wait()
		return true
	return false


## 一步一指纹：刻数、六指标、手牌序、牌堆序、状态、事故、随机数位置。
func _sig(g) -> String:
	var v := ""
	for it in E.D.VITALS:
		v += "%d," % int(g.vitals[str(it[0])])
	var st := ""
	var keys: Array = g.statuses.keys()
	keys.sort()
	for k in keys:
		st += str(k) + "+"
	return "c%d/%d|%s|h%s|d%s|%s|i%d|r%d|ch%d.%d" % [
		g.clock, g.max_clock, v, str(g.hand), str(g.deck), st,
		g.incidents, int(g.rng.state),
		int(g.campaign["chapter"]), int(g.campaign["shift"])]

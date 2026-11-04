extends SceneTree
## 悬停检视卡：**四类源全量**摆一遍，量高度、是否出屏、是否溢出面板底边。
##
## 为什么必须全量而不是抽查：
##   - 42 张牌的 `d`/`k` 长度在 7–41 字之间浮动，最高那张才顶出窗口；
##   - 40 张工单的 whisper + 正文 + danger + 线索叠起来差得很远，
##     红旗单只占 6 张，偏偏是最长的那几张；
##   - 状态和指标只有 6 条，但它们的摆放方向不同（贴右而不是贴上），
##     最容易犯的是「钳进窗口时把自己悬停的那一条盖住」。
##
## 用法：
##   godot --headless --path . --script tools/inspect_probe.gd     # 只量，快
##   godot --path . --script tools/inspect_probe.gd -- --save      # 另存两张图
##
## 注意别用 `--shot`：那是 main_ui 自己的整套截图流程的参数，会先于本脚本把游戏跑一遍。
##
## 产物（--save）：user://inspect_sheet.png（卡牌）、user://inspect_order.png（红旗单）

const OUT_CARD := "user://inspect_sheet.png"
const OUT_ORDER := "user://inspect_order.png"
const OUT_STATUS := "user://inspect_status.png"
const OUT_VITAL := "user://inspect_vital.png"
const E = preload("res://engine.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var want_shot := "--save" in args

	# 有存档时 `_ready` 会自动恢复进度（可能是已通关的一局），
	# 于是量到的根本不是一张干净的班次界面。先抹掉，保证 headless 和窗口下一致。
	preload("res://ui/save_sys.gd").erase()

	var ui := preload("res://ui/main_ui.gd").new()
	root.add_child(ui)
	# 直接 new 出来的界面绕过了 main.tscn 的 full-rect 锚点，size 会是 0×0，
	# 于是所有位置计算都退化成 0。headless 下 root 视口更是只有 64×64。
	# 这里显式给一个和真窗口一致的尺寸，测量才有意义。
	ui.size = Vector2(1280, 820)
	await process_frame
	await process_frame

	ui.game.start_shift()
	# 手牌固定成"3 张有图 + 3 张无图"，让截图里能同时看到两种插画来源
	ui.game.hand = ["c_sleep", "c_er", "c_juice", "c_water", "c_rest", "c_observe"]
	ui._refresh()
	await process_frame
	await process_frame

	# 检视卡放在手牌上方，上方留 10px 边距；再往上就是顶栏，所以天花板是 10
	var hand_top: int = int(ui._hand_box.get_global_rect().position.y)
	var limit: int = hand_top - 20

	# `INSPECT_W` 是内容宽；PanelContainer 的 1px 边框会把总宽顶到 +2。
	# 总宽错了就说明内容没按 296 铺开——卡牌那条会被插画的 264 宽度校验住。
	var want_w: int = ui.INSPECT_W + 2
	var bad := 0

	var cards: Array = E.D.CARD_MAP.keys()
	var card_worst := await _sweep(ui, "card", cards, want_w, bad)
	bad = card_worst[3]

	var orders: Array = E.D.ORDER_MAP.keys()
	var order_worst := await _sweep_orders(ui, orders, want_w, bad)
	bad = order_worst[3]

	var st: Array = E.D.STATUS.keys()
	for k in st:
		ui.game.statuses[k] = 1
	ui._refresh()
	await process_frame
	await process_frame
	var st_worst := await _sweep(ui, "status", st, want_w, bad)
	bad = st_worst[3]

	var vt := []
	for v in E.D.VITALS:
		vt.append(str(v[0]))
	var vt_worst := await _sweep(ui, "vital", vt, want_w, bad)
	bad = vt_worst[3]

	ui._hide_inspect()

	var max_h: int = maxi(int(card_worst[1]), int(order_worst[1]))
	max_h = maxi(max_h, int(st_worst[1]))
	max_h = maxi(max_h, int(vt_worst[1]))
	print("INSPECT cards=%d card_max=%d(%s) orders=%d order_max=%d(%s) status=%d(%s) vital=%d(%s) limit=%d bad=%d"
		% [cards.size(), card_worst[1], card_worst[2], orders.size(), order_worst[1],
			order_worst[2], st.size(), st_worst[2], vt.size(), vt_worst[2], limit, bad])
	print("INSPECT_PROBE %s cards=%d orders=%d status=%d vital=%d max_h=%d limit=%d bad=%d"
		% ["OK" if bad == 0 else "FAIL", cards.size(), orders.size(), st.size(),
			vt.size(), max_h, limit, bad])

	if want_shot:
		# 悬停一张「有图 + 长文案」的牌，这张最能暴露排版问题
		ui._show_inspect("card", "c_sleep", ui._inspect_gen)
		await process_frame
		await process_frame
		await _save(OUT_CARD)
		# 红旗单：唯一同时有 whisper + danger + 线索三种脚注的那种
		var red := _pick_redflag(ui)
		ui._refresh()
		await process_frame
		await process_frame
		ui._show_inspect("order", red, ui._inspect_gen)
		await process_frame
		await process_frame
		await _save(OUT_ORDER)
		# 状态：证明确实是贴右侧展开，而不是把 236px 的左栏自己盖住
		ui._show_inspect("status", "palpitation", ui._inspect_gen)
		await process_frame
		await process_frame
		await _save(OUT_STATUS)
		# 指标：目标是「一眼看出这是好是坏、离危险还有多远」
		ui.game.statuses.clear()
		ui._refresh()
		await process_frame
		await process_frame
		ui._show_inspect("vital", "sleep", ui._inspect_gen)
		await process_frame
		await process_frame
		await _save(OUT_VITAL)

	await ui._quit_clean(0 if bad == 0 else 1)


## 逐个摆一遍，返回 [n, max_h, worst_id, bad]。
func _sweep(ui, kind: String, ids: Array, want_w: int, bad: int) -> Array:
	var worst := 0
	var worst_id := ""
	for id in ids:
		# 直接调 `_show_inspect` 并传当前代数：走 `_hover` 那条路要等 0.16s
		# 的防抖，全量跑下来要几十秒，没必要。
		# `_show_inspect` 内部会再等一帧让 minimum 重算，所以这里多等一帧。
		ui._show_inspect(kind, id, ui._inspect_gen)
		await process_frame
		await process_frame
		var r := Rect2(ui._inspect.position, ui._inspect.size)
		var h := int(r.size.y)
		if h > worst:
			worst = h
			worst_id = id
		bad += _judge(ui, kind, id, r, want_w)
	return [ids.size(), worst, worst_id, bad]


## 工单要在真行里量：`_fill_order` 要按 uid 回查 game.orders，
## 而它的高度又取决于标题/正文长度，所以逐张塞进去、重画、再悬停。
func _sweep_orders(ui, ids: Array, want_w: int, bad: int) -> Array:
	var worst := 0
	var worst_id := ""
	for oid in ids:
		var src = E.D.ORDER_MAP[oid]
		var o = src.duplicate()
		o["title"] = src["t"]
		o["body"] = src["b"]
		o["uid"] = str(oid) + "_probe"
		o["arrival"] = 0
		o["resolved"] = false
		ui.game.orders = [o]
		ui._refresh()
		await process_frame
		await process_frame
		ui._show_inspect("order", o["uid"], ui._inspect_gen)
		await process_frame
		await process_frame
		var r := Rect2(ui._inspect.position, ui._inspect.size)
		var h := int(r.size.y)
		if h > worst:
			worst = h
			worst_id = oid
		bad += _judge(ui, "order", oid, r, want_w)
	return [ids.size(), worst, worst_id, bad]


func _judge(ui, kind: String, id: String, r: Rect2, want_w: int) -> int:
	var n := 0
	var w := int(r.size.x)
	var off: bool = r.position.y < 0.0 or r.position.x < 0.0 \
		or r.end.x > ui.size.x - 10.0 or r.end.y > ui.size.y - 10.0
	# 内容溢出面板 = 最后一行/最后一列被切掉。截图上看只是「本来就这么短」，
	# 所以必须靠量：纵向漏出去是知识点被裁，横向漏出去是被撑宽。
	var ov := _overflow(ui._inspect, r)
	if w != want_w or off or ov.x > 1.0 or ov.y > 1.0:
		n += 1
		print("INSPECT BAD kind=%s id=%s w=%d h=%d pos=%d,%d off=%s ov=%.1f,%.1f"
			% [kind, id, w, int(r.size.y), int(r.position.x), int(r.position.y),
				str(off), ov.x, ov.y])
	return n


## 挑一张会被发现的红旗单当截图样本（有 danger 才有第三种脚注）
func _pick_redflag(ui) -> String:
	for oid in E.D.ORDER_MAP:
		var src = E.D.ORDER_MAP[oid]
		if str(src.get("kind", "")) == "redflag" and str(src.get("danger", "")) != "":
			var o = src.duplicate()
			o["title"] = src["t"]
			o["body"] = src["b"]
			o["uid"] = str(oid) + "_probe"
			o["arrival"] = 0
			o["resolved"] = false
			ui.game.orders = [o]
			return o["uid"]
	return ""


func _save(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img != null and not img.is_empty():
		img.save_png(path)
		print("INSPECT_SHEET saved=%s %dx%d" % [path, img.get_width(), img.get_height()])
	else:
		print("INSPECT_SHEET FAIL 拿不到视口图像 path=%s" % path)


## 最深的子节点越出面板边多少像素（x 右、y 下）。0 表示装得下。
## 允许 1px：面板自己有一圈描边，子节点的 rect 是相对内边距算的，
## 亚像素累积偶尔会多出零点几。
func _overflow(n: Node, panel: Rect2) -> Vector2:
	var worst := Vector2.ZERO
	for ch in n.get_children():
		if ch is Control and (ch as Control).is_visible_in_tree():
			var r := (ch as Control).get_global_rect()
			worst.x = maxf(worst.x, r.end.x - panel.end.x)
			worst.y = maxf(worst.y, r.end.y - panel.end.y)
		worst = worst.max(_overflow(ch, panel))
	return worst

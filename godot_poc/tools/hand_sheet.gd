extends SceneTree
## 指定手牌的卡面样张：把若干张卡凑成一手，用**真实卡面**渲染出来存图。
##
## 为什么不另写一套卡牌绘制：复制一份布局代码，就注定会和真界面走样。
## 这里直接实例化 `ui/main_ui.gd`，只把 `game.hand` 换掉再调 `_refresh()`，
## 画出来的一定是玩家看到的那张卡。
##
## 用法（需要窗口，headless 是 dummy 渲染器出不了图）：
##   godot --path . --script tools/hand_sheet.gd -- c_sleep c_er c_juice c_talk
##
## 产物：user://hand_sheet.png，同时拷一份到 _shots/。

const OUT := "user://hand_sheet.png"

## 不够 6 张时用这些补位，顺便能看出"有图"和"占位"混排时的观感差异
const FILLER := ["c_water", "c_rest", "c_observe", "c_walk", "c_temp", "c_patch"]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var layout_only := "--layout-only" in args
	var ids: Array = []
	for a in args:
		if not str(a).begins_with("--"):
			ids.append(str(a))
	while ids.size() < 6:
		ids.append(FILLER[ids.size() % FILLER.size()])

	var ui := preload("res://ui/main_ui.gd").new()
	root.add_child(ui)
	await process_frame
	await process_frame

	# 走到「正在值班」的状态，卡面才会显示为可用（亮色）
	ui.game.start_shift()
	ui.game.hand = ids.slice(0, 6)
	ui.sel_uid = ""
	ui._refresh()

	await process_frame
	await process_frame

	# 卡高必须一致。`custom_minimum_size` 只是下限——内容更高时 PanelContainer
	# 会自己长高，于是"四条效果的牌"比"两条效果的牌"高出一截，一排里高低不齐。
	# 这个检查必须在不依赖渲染的前提下能跑，所以放在存图之前。
	var heights := {}
	var widths := {}
	var lines := ""
	for c in ui._hand_box.get_children():
		if c is Control:
			var h := int((c as Control).size.y)
			var mm: Vector2 = (c as Control).get_combined_minimum_size()
			var cid := str((c as Control).get_meta("cid", "?"))
			heights[h] = true
			widths[int((c as Control).size.x)] = true
			lines += "CARD_MIN h=%d w=%d need=%d cid=%s\n" \
				% [h, int((c as Control).size.x), int(mm.y), cid]
	print(lines.strip_edges())

	# 工单行是横向排的（类型 chip + 突发 chip + 标题 + 剩余刻数），而它所在的
	# ScrollContainer 关掉了横向滚动 —— 内容一旦比列宽还宽，就会把「剩 X 刻」裁掉，
	# 且不报任何错。类型 chip 加了图标之后宽度变大，这里必须量一遍。
	var over := 0
	var limit: int = int(ui._orders_box.size.x)
	for o in ui._orders_box.get_children():
		if o is Control:
			var need := int((o as Control).get_combined_minimum_size().x)
			if need > limit:
				over += 1
			print("ORDER_MIN need=%d limit=%d %s"
				% [need, limit, "OVERFLOW" if need > limit else "ok"])
	print("ORDER_FIT %s over=%d limit=%d"
		% ["OK" if over == 0 else "FAIL", over, limit])

	if layout_only:
		var uniform := heights.size() == 1
		var tall := 0
		for h in heights:
			tall = maxi(tall, int(h))
		# 宽度也要一致：chip 里塞图标会让最小值变宽，一旦某类卡撑破 150，
		# 整排就会变成"这张牌胖一点"，同样是不报错的走样。
		var ok := uniform and over == 0 and widths.size() == 1
		print("LAYOUT %s cards=6 heights=%s widths=%s max=%d"
			% ["OK" if ok else "FAIL", str(heights.keys()), str(widths.keys()), tall])
		# 走界面自己的收尾逻辑：音频线程要一轮混音才释放 playback，
		# 直接 quit 会留下 "ObjectDB instances were leaked" 的噪声
		await ui._quit_clean(0 if ok else 1)
		return

	await RenderingServer.frame_post_draw

	var img := root.get_texture().get_image()
	if img == null or img.is_empty():
		print("HAND_SHEET FAIL 拿不到视口图像（是否用了 --headless？加 --layout-only 可只查布局）")
		await ui._quit_clean(1)
		return
	var err := img.save_png(OUT)
	if err != OK:
		print("HAND_SHEET FAIL 存盘失败 err=%d" % err)
		await ui._quit_clean(1)
		return
	print("HAND_SHEET OK %s %dx%d hand=%s" % [OUT, img.get_width(), img.get_height(), ",".join(ids)])
	await ui._quit_clean(0)

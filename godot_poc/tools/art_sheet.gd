extends SceneTree
## 42 张卡牌插画的对照表。**按卡面真实尺寸 132×60 排**，不是按原图尺寸。
##
## 为什么必须按 132 宽看：手册 §二 Step 3 的筛选标准只有一条——缩到卡面尺寸
## 还能不能看出是什么。单张大图每一张都好看，缩略图才是玩家实际看到的样子。
## `c_talk` 第一版就是这么被判死的：两把椅子的大图很好，132 宽下是一坨黑。
##
## 用法（需要窗口，headless 是 dummy 渲染器出不了图）：
##   godot --path . --script tools/art_sheet.gd -- --scale 1 --page 0
##   godot --path . --script tools/art_sheet.gd -- --scale 2 --page 1
##
## 产物：user://art_sheet_<scale>x_p<page>.png
##
## **必须分页**：42 张 6 列、2 倍图时要 1001px 高，而窗口高度受屏幕可用高度限制，
## 超出部分会被直接截掉（第一版就少了一整行，且 save_png 不报错，只是图变矮）。
## 一页 5 行 20 张。**列数也受宽度限制**：4 列 × (132×2+8) = 1096px，
## 在 1280 宽的主窗口内；6 列会到 1632px，右边两列直接被裁掉。

const SRC := "res://assets/cards/"
const BG := Color("#0E242B")   # 卡面底色，插画是贴在它上面的，对照表也用同一色

const COLS := 4
const PER_PAGE := 20
const W := 132
const H := 60
const GAP := 8
const LABEL_H := 15


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var scale := 1
	var page := 0
	var idx := args.find("--scale")
	if idx >= 0 and idx + 1 < args.size():
		scale = int(args[idx + 1])
	idx = args.find("--page")
	if idx >= 0 and idx + 1 < args.size():
		page = int(args[idx + 1])

	var dir := DirAccess.open(SRC)
	if dir == null:
		print("ART_SHEET FAIL 找不到 %s" % SRC)
		quit(1)
		return
	var ids: Array = []
	for f in dir.get_files():
		if f.to_lower().ends_with(".png"):
			ids.append(str(f).get_basename())
	ids.sort()

	var all: Array = ids
	ids = all.slice(page * PER_PAGE, (page + 1) * PER_PAGE)
	if ids.is_empty():
		print("ART_SHEET SKIP page=%d 没有内容（共 %d 张）" % [page, all.size()])
		quit(0)
		return
	var pages := int(ceil(float(all.size()) / float(PER_PAGE)))

	var rows := int(ceil(float(ids.size()) / float(COLS)))
	var cell_w := W * scale + GAP
	var cell_h := H * scale + LABEL_H + GAP
	root.size = Vector2i(COLS * cell_w + GAP, rows * cell_h + GAP)

	var bgc := ColorRect.new()
	bgc.color = BG
	bgc.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bgc)

	var grid := GridContainer.new()
	grid.columns = COLS
	grid.add_theme_constant_override("h_separation", GAP)
	grid.add_theme_constant_override("v_separation", GAP)
	grid.position = Vector2(GAP, GAP)
	root.add_child(grid)

	var missing := 0
	for id in ids:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 2)
		var tr := TextureRect.new()
		tr.custom_minimum_size = Vector2(W * scale, H * scale)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_SCALE   # 264×120 → 132×60 是整 2:1，等比
		var img := Image.load_from_file(SRC + id + ".png")
		if img == null or img.is_empty():
			missing += 1
			continue
		tr.texture = ImageTexture.create_from_image(img)
		cell.add_child(tr)
		var l := Label.new()
		l.text = id
		l.add_theme_font_size_override("font_size", 10)
		l.add_theme_color_override("font_color", Color("#8FA3A8"))
		cell.add_child(l)
		grid.add_child(cell)

	# 一张图里 42 个名字，人眼对不上号；把行列顺序打出来备查
	print("ART_SHEET order page=%d/%d cols=%d rows=%d scale=%dx"
		% [page, pages, COLS, rows, scale])
	for i in ids.size():
		if i % COLS == 0:
			print("  row %d:" % int(i / COLS))
		print("    [%d,%d] %s" % [int(i / COLS), i % COLS, ids[i]])

	await process_frame
	await process_frame
	await process_frame

	var out := "user://art_sheet_%dx_p%d.png" % [scale, page]
	var err := root.get_texture().get_image().save_png(out)
	print("ART_SHEET OK page=%d n=%d missing=%d out=%s err=%d"
		% [page, ids.size(), missing, out, err])
	quit(0 if err == OK and missing == 0 else 1)

extends SceneTree
## 角色立绘对照表。**按简报里的真实显示尺寸 168×224 排**，不是按 336×448 的原尺寸。
##
## 判据和卡牌插画那张表（`art_sheet.gd`）不同，这里要判的不是「认不认得出是什么」，
## 而是**同一张脸在两个表情之间有没有差别**。这是立绘最容易糊弄过去的地方：
## 大图一比一眼就能看出「疲惫」和「平静」不一样，可是缩到 168 宽之后，
## 差别常常只剩眼睑阴影的几个像素——那样四张差分只值一张的钱。
##
## 用法（需要窗口，headless 是 dummy 渲染器出不了图）：
##   godot --path . --script tools/char_sheet.gd -- --scale 1 --page 0
##   godot --path . --script tools/char_sheet.gd -- --scale 2 --page 0
##
## 产物：user://char_sheet_<scale>x_p<page>.png
##
## 分页是硬约束：主窗口 1280×820 由 project.godot 决定，`root.size` 改不动，
## 超出部分会被静默裁掉（卡牌对照表踩过这个坑，save_png 照样返回 OK）。

const SRC := "res://assets/chars/"
const BG := Color("#101F26")   # 面板底色，立绘贴在它上面

## 与 UI 里的显示尺寸一致（2 倍图 432×576 缩一半）。这个数一变，那张表的结论就作废。
const W := 216
const H := 288

## 按「宿主 + 表情序」排，不按文件名排。
## 字母序是 alert/calm/relief/tired，四个表情被这个顺序打散，比对时要在脑子里重排；
## 而且判「四张差分够不够」必须让它们紧挨着。表情序 = 情绪从收起到外放。
const EXPR_ORDER := ["calm", "tired", "alert", "relief"]
const GAP := 10
const LABEL_H := 14


## 宿主序号小者在前，同一宿主内按 EXPR_ORDER。未知后缀排到该宿主末尾。
func _cmp(a: String, b: String) -> bool:
	var pa := _key(a)
	var pb := _key(b)
	if pa[0] != pb[0]:
		return pa[0] < pb[0]
	return pa[1] < pb[1]


func _key(id: String) -> Array:
	var cut := id.rfind("_")
	var host := id.substr(0, cut)
	var expr := id.substr(cut + 1)
	var i := EXPR_ORDER.find(expr)
	return [host, 99 if i < 0 else i]


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

	# 列数固定 = 每个宿主的表情数：**一行就是一个宿主的四张差分**。
	# 这样"是不是同一个人"和"四张够不够分辨"两个问题都能横向扫一眼答完，
	# 按窗口能塞几列去排的话，同一个宿主会被折到两行，比对就断了。
	var cols := EXPR_ORDER.size()
	var cell_h := H * scale + LABEL_H + GAP
	var rows := maxi(1, int((820 - GAP) / float(cell_h)))
	var per_page := cols * rows

	var dir := DirAccess.open(SRC)
	if dir == null:
		print("CHAR_SHEET FAIL 找不到 %s" % SRC)
		quit(1)
		return
	var all: Array = []
	for f in dir.get_files():
		if f.to_lower().ends_with(".png"):
			all.append(str(f).get_basename())
	all.sort_custom(_cmp)

	var ids: Array = all.slice(page * per_page, (page + 1) * per_page)
	if ids.is_empty():
		print("CHAR_SHEET SKIP page=%d 没有内容（共 %d 张）" % [page, all.size()])
		quit(0)
		return
	var pages := int(ceil(float(all.size()) / float(per_page)))

	var used_rows := int(ceil(float(ids.size()) / float(cols)))
	var want := Vector2i(cols * (W * scale + GAP) + GAP, used_rows * cell_h + GAP)
	if want.x > 1280 or want.y > 820:
		print("CHAR_SHEET FAIL 页尺寸 %dx%d 超出窗口 1280x820，会被静默裁掉" % [want.x, want.y])
		quit(1)
		return

	var bgc := ColorRect.new()
	bgc.color = BG
	bgc.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bgc)

	var grid := GridContainer.new()
	grid.columns = cols
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
		tr.stretch_mode = TextureRect.STRETCH_SCALE   # 336×448 → 168×224 正好 2:1，等比
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

	print("CHAR_SHEET order page=%d/%d cols=%d rows=%d scale=%dx"
		% [page, pages, cols, rows, scale])
	for i in ids.size():
		print("  [%d,%d] %s" % [int(i / cols), i % cols, ids[i]])

	await process_frame
	await process_frame
	await process_frame

	var out := "user://char_sheet_%dx_p%d.png" % [scale, page]
	var err := root.get_texture().get_image().save_png(out)
	print("CHAR_SHEET OK page=%d n=%d missing=%d out=%s err=%d"
		% [page, ids.size(), missing, out, err])
	quit(0 if err == OK and missing == 0 else 1)

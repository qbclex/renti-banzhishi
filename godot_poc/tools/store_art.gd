extends Control
## 商店素材渲染器：拿游戏自己的立绘、背景、字体拼 Steam 各类胶囊图。
##
## 为什么用 Godot 而不是 PS/PIL：
##   1) 字体就是游戏里那套（Kit.serif / Kit.sans），商店页和本体不会两种味道；
##   2) 立绘是现成资源，改一版美术重跑一遍就跟着更新；
##   3) 这台机器上没有 PIL，装了也未必有中文字体。
##
## 用法：
##   godot --path . res://tools/store_art.tscn
## 产物在 res://_store/（已在 export_presets.cfg 的 exclude_filter 里排除）
##
## 尺寸按 Steam 官方要求取：
##   主图 616×353 / 头图 460×215 / 小图 231×87 / 竖图 374×448
##   库图 600×900 / 库头图 3840×1240 / 库 Logo 1280×720（透明）
##   社群图标 184×184 / 页面背景 1438×810
##
## 构图原则（第一版踩过的坑）：
##   立绘是**带自身背景的摄影图**，直接摆一块矩形上去，边缘是一道硬线，
##   一眼就是"贴上去的"。所以这里让照片**铺满整张图**，再用一侧的渐变把
##   文字区压暗——照片自己的暗背景正好和 `BG0` 接上，看不出边界。
##   标题字号按可用宽度自动缩，绝不压到脸上。

const Kit = preload("res://ui/ui_kit.gd")

const OUT_DIR := "res://_store"

## 用 chars_src（1024×1536）而不是 assets/chars（432×576）：
## 库头图要做到 3840 宽，小图的细节在大尺寸下会糊成一片。
## 这个目录不进发行包（exclude_filter），只是给本工具读。
const SRC := "res://assets/chars_src/"

const TITLE := "人体值班室"
const SUB := "THE BODY NIGHT SHIFT"
const TAG := "把自己，也排进今天的值班表"

## lay: 版式 | fx: 脸在画面里的横向位置 | vtop: 可见窗口从原图多高处开始
##
## 用 vtop 而不是"脸的位置"来定纵向：原图是 2:3 的竖构图，胶囊图宽度差十几倍，
## 同一个"脸在 44% 处"在 3:1 的库头图上会变成只露一截下巴。直接指定
## "从 15% 开始往下取"才是随比例稳定的量。
const SPECS := [
	{"n": "main_capsule", "w": 616, "h": 353, "lay": "wide", "char": "host3_calm.png", "fx": 0.74, "vtop": 0.15},
	{"n": "header_capsule", "w": 460, "h": 215, "lay": "wide", "char": "host3_calm.png", "fx": 0.76, "vtop": 0.16},
	{"n": "small_capsule", "w": 231, "h": 87, "lay": "tiny", "char": "host1_calm.png", "fx": 0.5, "vtop": 0.20},
	{"n": "vertical_capsule", "w": 374, "h": 448, "lay": "tall", "char": "host5_calm.png", "fx": 0.5, "vtop": 0.02},
	{"n": "library_capsule", "w": 600, "h": 900, "lay": "tall", "char": "host2_calm.png", "fx": 0.5, "vtop": 0.01},
	{"n": "library_hero", "w": 3840, "h": 1240, "lay": "hero", "char": "host4_calm.png", "fx": 0.78, "vtop": 0.14},
	{"n": "page_bg", "w": 1438, "h": 810, "lay": "wide", "char": "host1_calm.png", "fx": 0.72, "vtop": 0.14},
	{"n": "community_icon", "w": 184, "h": 184, "lay": "icon", "char": "host3_calm.png", "fx": 0.5, "vtop": 0.18},
	{"n": "library_logo", "w": 1280, "h": 720, "lay": "logo", "char": "", "fx": 0.5, "vtop": 0.0},
]

## .ico 需要多档尺寸，Windows 才会在各个场合都清晰
const ICO_SIZES := [256, 128, 64, 48, 32, 16]


## 本项目不走 Godot 的导入管线（没有 .import 文件），美术一律
## Image.load_from_file 现读；这里也一样——用 load() 会直接报
## "No loader found for resource"，画面全黑。
func _tex(path: String) -> Texture2D:
	var img := Image.load_from_file(path)
	if img == null:
		push_error("读不到图：%s" % path)
		return null
	return ImageTexture.create_from_image(img)


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for s in SPECS:
		await _render(s["n"], s["w"], s["h"], s)
	for sz in ICO_SIZES:
		await _render("icon_%d" % sz, sz, sz,
			{"n": "icon", "w": sz, "h": sz, "lay": "icon",
			 "char": "host3_calm.png", "fx": 0.5, "vtop": 0.16})
	print("STORE_ART_OK %d" % (SPECS.size() + ICO_SIZES.size()))
	get_tree().quit(0)


func _render(name: String, w: int, h: int, spec: Dictionary) -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(w, h)
	vp.disable_3d = true
	vp.transparent_bg = spec.get("lay", "") == "logo"
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)

	var root := Control.new()
	root.size = Vector2(w, h)
	vp.add_child(root)
	_build(root, w, h, spec)

	# 贴图/字体在这一帧才真正生成，等两帧再取
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var err := img.save_png(ProjectSettings.globalize_path(OUT_DIR.path_join(name + ".png")))
	# 图标另存一份裸 RGBA：Windows 的 .ico 要 BMP 条目，Python 那边没法解 PNG
	# （这台机器没装 PIL），所以让引擎直接吐像素，tools/make_ico.py 只负责拼文件头。
	if name.begins_with("icon_"):
		img.convert(Image.FORMAT_RGBA8)
		var f := FileAccess.open(ProjectSettings.globalize_path(OUT_DIR.path_join(name + ".rgba")), FileAccess.WRITE)
		if f != null:
			f.store_buffer(img.get_data())
			f.close()
	print("  %-18s %4d×%-4d err=%d" % [name, w, h, err])
	vp.queue_free()
	await get_tree().process_frame


# ---------------------------------------------------------------- 版式

func _build(root: Control, w: int, h: int, spec: Dictionary) -> void:
	var lay: String = spec["lay"]
	if lay != "logo":
		_photo(root, w, h, spec["char"], spec["fx"], spec["vtop"])

	match lay:
		"wide":
			_shade_side(root, w, h, 0.74)
			_title_left(root, w, h, 0.20, 0.046, 0.46)
		"hero":
			_shade_side(root, w, h, 0.66)
			_title_left(root, w, h, 0.19, 0.042, 0.42)
		"tall":
			_shade_bottom(root, w, h, 0.56)
			_title_bottom(root, w, h, 0.115, 0.032, 0.86)
		"tiny":
			_shade_all(root, w, h, 0.58)
			_title_center(root, w, h, 0.34, 0.0)
		"icon":
			_shade_all(root, w, h, 0.48)
			_icon(root, w, h)
		"logo":
			_title_center(root, w, h, 0.145, 0.0, true)

	if lay != "logo":
		_frame(root, w, h)


## 照片铺满整张图，并按 fx/fy 把脸放到指定位置。
##
## 两个硬约束：
##   · 必须**盖住**整张画布（否则露出底色，边界立刻显形）；
##   · 画布底边不能越过原图 90% —— chars_src 是 AI 生成的，右下角带工具水印，
##     裁到 90% 就把水印裁在画面外了。
func _photo(root: Control, w: int, h: int, file: String, fx: float, vtop: float) -> void:
	if file == "":
		return
	var t := _tex(SRC + file)
	if t == null:
		return
	var iw: float = t.get_width()
	var ih: float = t.get_height()
	var dh: float = max(h * 1.10, w * ih / iw)
	var dw: float = dh * iw / ih

	var x: float = w * fx - dw * 0.5
	var y: float = -vtop * dh
	x = clamp(x, w - dw, 0.0)
	# 底边最多取到原图 92%：再往下就是 AI 生成工具的水印区
	y = clamp(y, h - 0.92 * dh, 0.0)

	var tex := TextureRect.new()
	tex.texture = t
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.size = Vector2(dw, dh)
	tex.position = Vector2(x, y)
	root.add_child(tex)
	_clip(root, w, h)


## SubViewport 本身没有裁剪，超出画布的部分照样画出来；
## 套一层 Control 只是为了让 _frame 有干净的坐标系，这里显式裁一次。
func _clip(root: Control, w: int, h: int) -> void:
	root.clip_contents = true
	root.size = Vector2(w, h)


func _grad(dir: int) -> TextureRect:
	# dir: 0 = 左→右, 1 = 下→上, 2 = 全向压暗
	var g := Gradient.new()
	if dir == 0:
		g.offsets = PackedFloat32Array([0.0, 0.30, 0.56, 0.80, 1.0])
		g.colors = PackedColorArray([
			Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 0.96),
			Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 0.82),
			Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 0.34),
			Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 0.05),
			Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 0.30),
		])
	elif dir == 1:
		g.offsets = PackedFloat32Array([0.0, 0.42, 0.72, 1.0])
		g.colors = PackedColorArray([
			Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 0.0),
			Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 0.28),
			Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 0.80),
			Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 0.97),
		])
	else:
		g.offsets = PackedFloat32Array([0.0, 1.0])
		g.colors = PackedColorArray([
			Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 0.0),
			Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 1.0),
		])

	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 8
	gt.height = 256
	if dir == 0:
		gt.fill_from = Vector2(0, 0)
		gt.fill_to = Vector2(1, 0)
	elif dir == 1:
		gt.fill_from = Vector2(0, 1)     # 底 → 顶
		gt.fill_to = Vector2(0, 0)
	else:
		gt.fill_from = Vector2(0, 0)
		gt.fill_to = Vector2(1, 1)

	var r := TextureRect.new()
	r.texture = gt
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	return r


func _shade_side(root: Control, w: int, h: int, _x: float) -> void:
	root.add_child(_grad(0))


func _shade_bottom(root: Control, w: int, h: int, _y: float) -> void:
	root.add_child(_grad(1))


func _shade_all(root: Control, w: int, h: int, a: float) -> void:
	var c := ColorRect.new()
	c.color = Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, a)
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(c)


## 左侧文字：宽度上限是画布的 wfrac，字号自动缩到能放下为止。
func _title_left(root: Control, w: int, h: int, hfrac: float, margin: float, wfrac: float) -> void:
	var pad := int(w * margin)
	var maxw := int(w * wfrac)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", max(2, int(h * 0.024)))
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = pad
	box.offset_right = -int(w - pad - maxw)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(box)

	var f := Kit.serif()
	var tsize := _fit(f, TITLE, int(h * hfrac), maxw)
	var t := Kit.serif_lbl(TITLE, tsize, Kit.PAPER)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_stroke(t, tsize)
	box.add_child(t)

	var s := Kit.lbl(SUB, max(8, int(tsize * 0.24)), Color(Kit.TEAL.lightened(0.40), 0.95))
	box.add_child(s)

	var line := ColorRect.new()
	line.color = Color(Kit.TEAL.r, Kit.TEAL.g, Kit.TEAL.b, 0.5)
	line.custom_minimum_size = Vector2(int(maxw * 0.42), max(1, int(h * 0.0035)))
	line.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.add_child(line)

	var tag := Kit.lbl(TAG, max(9, int(tsize * 0.22)),
		Color(Kit.PAPER2.r, Kit.PAPER2.g, Kit.PAPER2.b, 0.85))
	box.add_child(tag)


## 竖版文字压在底边：脸在上，字在下，互不打架。
func _title_bottom(root: Control, w: int, h: int, hfrac: float, margin: float, yfrac: float) -> void:
	var pad := int(w * 0.08)
	var maxw := w - pad * 2
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", max(2, int(h * 0.014)))
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = pad
	box.offset_right = -pad
	box.offset_bottom = -int(h * (1.0 - yfrac))
	box.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(box)

	var f := Kit.serif()
	var tsize := _fit(f, TITLE, int(h * hfrac), maxw)
	var t := Kit.serif_lbl(TITLE, tsize, Kit.PAPER)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stroke(t, tsize)
	box.add_child(t)

	var s := Kit.lbl(SUB, max(8, int(tsize * 0.20)), Color(Kit.TEAL.lightened(0.40), 0.95))
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(s)


## 小图与 Logo：只有字，居中。
func _title_center(root: Control, w: int, h: int, hfrac: float, _unused: float,
		logo: bool = false) -> void:
	var pad := int(w * 0.06)
	var maxw := w - pad * 2
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", max(2, int(h * 0.10)))
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = pad
	box.offset_right = -pad
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(box)

	var f := Kit.serif()
	var tsize := _fit(f, TITLE, int(h * hfrac), maxw)
	var t := Kit.serif_lbl(TITLE, tsize, Kit.PAPER)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stroke(t, tsize)
	box.add_child(t)

	if logo:
		var s := Kit.lbl(SUB, max(10, int(tsize * 0.22)),
			Color(Kit.PAPER2.r, Kit.PAPER2.g, Kit.PAPER2.b, 0.72))
		s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(s)


func _icon(root: Control, w: int, h: int) -> void:
	# 小尺寸放不下标题，只放一个字：值
	var size := int(h * 0.56)
	var lbl := Kit.serif_lbl("值", size, Kit.PAPER)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_stroke(lbl, size)
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(lbl)


func _frame(root: Control, w: int, h: int) -> void:
	# 内描边，商店缩略图排在一起时边缘更"实"
	var f := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Color(Kit.PAPER.r, Kit.PAPER.g, Kit.PAPER.b, 0.09)
	var bw: int = max(1, int(round(min(w, h) * 0.004)))
	sb.set_border_width_all(bw)
	f.add_theme_stylebox_override("panel", sb)
	f.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(f)


## 字号往上试到放得下为止：商店图的宽度差着十几倍（231 → 3840），
## 固定字号必然要么撑破要么小到看不见。
func _fit(font: Font, text: String, want: int, max_w: int) -> int:
	var s: int = max(8, want)
	while s > 8 and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, s).x > max_w:
		s -= 1
	return s


func _stroke(l: Label, px: int) -> void:
	l.add_theme_constant_override("outline_size", max(2, int(px * 0.09)))
	l.add_theme_color_override("font_outline_color", Color(Kit.BG0.r, Kit.BG0.g, Kit.BG0.b, 0.55))

extends SceneTree
## 图标对照图：一次性把全部图标按 32/16/12px 三档渲染出来，拼成一张图。
##
## 为什么要「最近邻放大」：小尺寸图标糊不糊、笔画粘连没粘连，只有把像素方块
## 放大看才判断得准。直接按原尺寸贴图，人眼几乎看不出 12px 的问题。
##
## 输出 _shots/icons_sheet.png，同时打印每个图标的非空像素数（防空图）。

const Icons = preload("res://ui/icons.gd")

## 三组图标按「指标 / 卡牌类型 / 工单类型」排，同组的观感才可比。
## 分组之间的空档由 GAP_AFTER 指定（列号），避免六项指标和图标的类型图标混看。
const NAMES := [
	"energy", "sleep", "stress", "metabolic", "inflammation", "trust",
	"life", "home", "observe", "refer", "talk", "quack",
	"order_common", "order_emotion", "order_redflag",
	"save", "load", "sound_on", "sound_off",
	"st_palpitation", "st_reflux", "st_insomnia",
	"inflammation", "st_dehydration", "st_misled",
]
const LABELS := [
	"精力", "睡眠债", "压力", "代谢负荷", "炎症水平", "身体信任",
	"生活", "家庭", "观察", "转诊", "沟通", "偏方",
	"报修", "情绪", "红旗",
	"存档", "读档", "音效开", "音效关",
	"心悸", "反流", "失眠",
	"炎症", "脱水", "被误导",
]
## 在这些列**之前**插一段空白（列号 → 额外像素）
const GAP_AFTER := {6: 18, 12: 18, 15: 18, 19: 18}

const BG := Color("#071318")
const FG := Color("#F1E9D8")

## 每一档：[渲染尺寸, 放大倍数, 行高]
const ROWS := [[32, 3, 118], [16, 4, 88], [12, 4, 76]]
const COL_W := 116
const PAD := 14


func _col_x(i: int) -> int:
	var x: int = PAD + i * COL_W
	for g in GAP_AFTER:
		if i > int(g):
			x += int(GAP_AFTER[g])
	return x


func _initialize() -> void:
	var w: int = PAD * 2 + COL_W * NAMES.size()
	for g in GAP_AFTER:
		w += int(GAP_AFTER[g])
	var h: int = PAD * 2 + 20
	for r in ROWS:
		h += int(r[2])

	var canvas := Image.create(w, h, false, Image.FORMAT_RGBA8)
	canvas.fill(BG)

	var fails: Array = []

	# 先做一遍 24px 安全区检查：墨迹不能贴边，否则 12px 下会被裁。
	# 用真实渲染的外接框判断，比解析 path 靠谱——path 里混着相对坐标（l/h/v），
	# 正则根本分不清哪些数字是绝对位置。
	for name in NAMES:
		var probe := _render(name, 24)
		if probe == null:
			fails.append("%s 渲染失败" % name)
			continue
		var b := _bbox(probe)
		print("bbox %-14s %-22s span=%dx%d 光学尺寸=%.0f%%"
			% [name, str(b), b.size.x, b.size.y,
			100.0 * maxf(b.size.x, b.size.y) / 24.0])
		if b.size == Vector2i.ZERO:
			fails.append("%s 空图" % name)
		elif b.position.x < 1 or b.position.y < 1 \
				or b.position.x + b.size.x > 23 or b.position.y + b.size.y > 23:
			fails.append("%s 墨迹贴边 %s（小尺寸会被裁）" % [name, str(b)])

	var y := PAD + 18
	var row_i := 0

	for row in ROWS:
		var px: int = row[0]
		var zoom: int = row[1]
		var rh: int = row[2]

		# 行标题线：一条浅色分隔，方便对齐
		_draw_hline(canvas, PAD, y - 10, w - PAD, Color(1, 1, 1, 0.10))

		for i in NAMES.size():
			var name: String = NAMES[i]
			var img := _render(name, px)
			if img == null:
				fails.append("缺图标 %s" % name)
				continue

			var opaque := 0
			for yy in img.get_height():
				for xx in img.get_width():
					if img.get_pixel(xx, yy).a > 0.1:
						opaque += 1
			if opaque == 0:
				fails.append("%s 渲染为空（%dpx）" % [name, px])
			if row_i == 0:
				print("icon %-14s %2dpx opaque=%d" % [name, px, opaque])

			# 最近邻放大：保留硬边，才能看清像素级清晰度
			var big := img.duplicate()
			big.resize(px * zoom, px * zoom, Image.INTERPOLATE_NEAREST)
			var x: int = _col_x(i) + (COL_W - big.get_width()) / 2
			var yy2: int = y + (rh - 30 - big.get_height()) / 2
			canvas.blend_rect(big, Rect2i(Vector2i.ZERO, big.get_size()), Vector2i(x, yy2))

		y += rh
		row_i += 1

	var out := "user://icons_sheet.png"
	var abs_out := ProjectSettings.globalize_path(out)
	if canvas.save_png(out) != OK:
		print("ICONS_SHEET FAIL 无法写入 %s" % out)
		quit(1)
		return
	print("ICONS_SHEET saved=%s size=%dx%d rows=32/16/12 cols=%d"
		% [abs_out, w, h, NAMES.size()])
	if fails.is_empty():
		# n= 报的是**去重后**的文件数（炎症故意在状态组再出现一列，方便整组并排看），
		# cols= 报的是列数。两者不等是正常的，用去重数才能和目录里的文件数对账。
		var uniq := {}
		for n in NAMES:
			uniq[n] = true
		print("ICONS_SHEET OK n=%d cols=%d" % [uniq.size(), NAMES.size()])
		quit(0)
	else:
		print("ICONS_SHEET FAIL %s" % " / ".join(fails))
		quit(1)


func _draw_hline(img: Image, x0: int, y: int, x1: int, c: Color) -> void:
	if y < 0 or y >= img.get_height():
		return
	for x in range(maxi(0, x0), mini(x1, img.get_width())):
		img.set_pixel(x, y, c)


## 按指定显示尺寸渲染一个图标（走和运行时同一套着色与线宽逻辑）。
func _render(name: String, px: int) -> Image:
	var svg := Icons._load(name)
	if svg == "":
		return null
	svg = svg.replace("currentColor", "#" + FG.to_html(false))
	svg = svg.replace('stroke-width="%.1f"' % Icons.BASE_STROKE,
		'stroke-width="%.2f"' % Icons._stroke_for(px))
	var img := Image.new()
	if img.load_svg_from_string(svg, float(px) / Icons.BOX) != OK:
		return null
	return img


## 非透明像素的外接框。空图返回 size 为 0 的矩形。
func _bbox(img: Image) -> Rect2i:
	var minx := 99999
	var miny := 99999
	var maxx := -1
	var maxy := -1
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.1:
				minx = mini(minx, x)
				maxx = maxi(maxx, x)
				miny = mini(miny, y)
				maxy = maxi(maxy, y)
	if maxx < 0:
		return Rect2i()
	return Rect2i(minx, miny, maxx - minx + 1, maxy - miny + 1)

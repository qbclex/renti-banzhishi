extends RefCounted
## 极简 UI 工具箱：统一配色、字体与常用控件。
##
## 字体：正文用**随包内置**的 Noto Sans SC（OFL 1.1，可再分发）。
## 之所以不用 SystemFont 了：SystemFont 找不到候选时会静默回退到任意字族，
## 于是「你截图看到的排版」和「玩家看到的排版」不是同一套字形——
## 行距、字宽、标点位置全都会漂。发行版必须自带字体，这是硬要求。
##
## 加载方式用 FontFile.load_dynamic_font() 而不是 load("res://…ttf")：
## 后者要求编辑器先导入出 .import 与缓存，导出包和 CI 里容易踩空。
##
## 配色对齐网页版 src/css/01_base.css 的设计令牌，保证两端观感一致。

## 内置字体（缺失时回退 SystemFont 并告警，绝不静默）
##
## 优先用**子集化**版本（约 0.8 MB / 1505 字，见 tools/make_font_subset.py）：
## 发行包里不能塞 17 MB 全量字库。开发机上如果还没跑过子集化脚本，
## 就回退到全量字体，保证「拉下代码直接能跑」。
const EMBEDDED_SANS := "res://fonts/NotoSansSC-subset.ttf"
const EMBEDDED_SANS_FULL := "res://fonts/NotoSansSC-VF.ttf"
const EMBEDDED_SERIF := "res://fonts/NotoSerifSC-subset.ttf"
const EMBEDDED_SERIF_FULL := "res://fonts/NotoSerifSC-VF.ttf"

const Icons = preload("res://ui/icons.gd")

const BG0 := Color("#03080A")
const BG1 := Color("#071318")
const BG2 := Color("#0B1E24")
const LINE := Color("#123039")
const PAPER := Color("#FBF7EC")
const PAPER2 := Color("#F1E9D8")
const INK := Color("#182628")
const INK2 := Color("#42565A")
const TEAL := Color("#38A0A8")
const TEAL_D := Color("#1F6F78")
const CORAL := Color("#D95E42")
const GOLD := Color("#C9A227")
const VIOLET := Color("#8E74AC")
const GREEN := Color("#54A374")
const GREY := Color("#8CA0A4")
const MUTED := Color("#4C666C")
const WHITE := Color("#FFFFFF")

## ---------------------------------------------------------------- 指标条配色
##
## 一条规矩：**颜色只表达「危险程度」，不表达「这是哪个指标」**。
## 指标身份靠名字区分，不靠色相——否则「压力」和「炎症水平」这类后果完全
## 不同的指标一旦撞色，玩家就得先去读字才知道哪条在恶化。
##
## 下面的三档阈值与色值逐项抄自网页端 src/js/render.js 的 renderVitals()，
## 由 tests/test_godot_save.py::TestArtTokens 解析 JS 源码做逐字比对，
## 改这里不改那边会直接测试失败。

## health > 0.62 → 绿；> 0.38 → 黄；否则红。[明亮色, 深色]（深色留给渐变端）
const HEALTH_STOPS := [
	[0.62, "#7BE0A8", "#2E8C5E"],
	[0.38, "#F5D26B", "#B0821A"],
]
const HEALTH_LOW := ["#FF9A7E", "#B03A20"]

## 警戒态（指标已经糟到会影响结局）的文字色，网页端 .vital.bad 用同一个值
const WARN_FG := Color("#FFB29B")
## 警戒态进度条描边（rgba(217,94,66,.55)）
const WARN_LINE := Color("#D95E42", 0.55)
## 指标名的常态颜色 rgba(206,220,222,.72)
const VITAL_NAME := Color("#CEDCDE", 0.72)
## 图标专用中性色：比正文亮、且不透明。
## 12–14px 的细线图标若沿用正文那个 0.72 透明度，在深底上会糊成污点——
## 图标靠形状识别，必须先把轮廓给足对比度。
const ICON_INK := Color("#A9C2C6")

const BAD_BETTER := 35  # better 类指标低于此值 → 警戒
const BAD_WORSE := 68  # worse 类指标高于此值 → 警戒


## 健康度（0–100）→ [明亮色, 深色]。阈值判断用严格大于，与 JS 一致。
static func health_colors(health: float) -> Array:
	var h := health / 100.0
	for stop in HEALTH_STOPS:
		if h > float(stop[0]):
			return [Color(stop[1]), Color(stop[2])]
	return [Color(HEALTH_LOW[0]), Color(HEALTH_LOW[1])]


## 该指标是否已进入警戒态。dir 为 "better" 表示越高越好。
static func is_bad(val: int, dir: String) -> bool:
	if dir == "better":
		return val < BAD_BETTER
	return val > BAD_WORSE

## 卡牌类型 → [中文名, 颜色, 图标]
## 第三个元素是 assets/icons/ 下的文件名。图标不是装饰：颜色被「危险程度」占用之后，
## 类型之间的区分只剩名字和形状，图标是唯一能在扫一眼时生效的那一层。
const KINDS := {
	"life": ["生活", TEAL, "life"],
	"observe": ["观察", Color("#6FA8B8"), "observe"],
	"refer": ["转诊", CORAL, "refer"],
	"talk": ["沟通", VIOLET, "talk"],
	"home": ["家庭", GREEN, "home"],
	"quack": ["偏方", GOLD, "quack"],
}

## 工单类型 → [中文名, 颜色, 图标]
## 必须与 content_full.py 的注释（common / emotion / redflag）和网页端
## render.js 的标签（报修 / 情绪 / 红旗）三者对齐；此前这里写的是
## chronic/myth，导致 9 张「情绪」单在 Godot 端退化成灰色「·」标签。
const ORDER_KINDS := {
	"common": ["报修", TEAL, "order_common"],
	"emotion": ["情绪", VIOLET, "order_emotion"],
	"redflag": ["红旗", CORAL, "order_redflag"],
}

## 状态 → 图标名。数据里的 `icon` 字段是字符（♥ ▲ ◐ ✚ ◒ ?），
## 五个不同来源的字形混在一起，线宽和视觉重心全不一致，和这套手绘线稿
## 并排放会很明显。所以 UI 只认这张表，不读数据里的字符。
##
## `inflammation` 故意复用指标的温度计：它们指的是同一件事
## （炎症水平高 → 炎症状态），共用是语义正确，不是命名冲突。
const STATUS_ICONS := {
	"palpitation": "st_palpitation",
	"reflux": "st_reflux",
	"insomnia": "st_insomnia",
	"inflammation": "inflammation",
	"dehydration": "st_dehydration",
	"misled": "st_misled",
}

const GRADES := {
	"best": ["正解", GREEN],
	"good": ["可行", TEAL],
	"off": ["没对上", GREY],
	"bad": ["欠妥", GOLD],
	"incident": ["事故", CORAL],
	"status": ["状态", GREY],
}

static var _theme: Theme = null
static var _sans: Font = null
static var _serif: Font = null


## 从工程内加载字体；失败返回 null（由调用方回退）。
static func _embedded(path: String) -> FontFile:
	# 两条路都得留着：
	#   · 开发机没跑过导出时没有 .import/.godot，只能现读原文件；
	#   · 导出包里恰恰相反 —— 原始 ttf 不进包，只有导入出的二进制。
	# 之前只写了现读那条，结果 exe 里"字体缺失、回退系统字体"，
	# 换台机器字形就漂了。
	if ResourceLoader.exists(path):
		var r = load(path)
		if r is FontFile:
			var rf := r as FontFile
			rf.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
			rf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
			return rf
	if not FileAccess.file_exists(path):
		return null
	var f := FontFile.new()
	if f.load_dynamic_font(path) != OK:
		return null
	# 灰度抗锯齿 + 自动次像素定位：与网页端 -webkit-font-smoothing 观感最接近，
	# 也让同一字号在 100%/125%/150% 缩放下不至于突然变糊或变硬。
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	return f


## 这张图在不在（开发机看文件，导出包看资源）。
static func asset_exists(path: String) -> bool:
	return ResourceLoader.exists(path) or FileAccess.file_exists(path)


## 统一取图入口：导出包里只有导入过的贴图，开发机上只有原文件，
## 两边的正确写法不一样，所以这里一次判掉，各美术模块不必各写一遍。
static func texture_at(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		var r = load(path)
		if r is Texture2D:
			return r
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


static func sans() -> Font:
	if _sans == null:
		_sans = _embedded(EMBEDDED_SANS)
		if _sans == null:
			# 子集还没生成（新克隆的仓库）：退回全量字体，别让游戏直接看不见字
			_sans = _embedded(EMBEDDED_SANS_FULL)
		if _sans == null:
			push_warning("内置字体缺失（%s），已回退系统字体；排版会随机器漂移"
				% EMBEDDED_SANS)
			var f := SystemFont.new()
			f.font_names = PackedStringArray([
				"Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC",
				"Source Han Sans SC", "PingFang SC", "Heiti SC", "SimHei",
				"WenQuanYi Micro Hei", "sans-serif",
			])
			f.allow_system_fallback = true
			_sans = f
	return _sans


static func serif() -> Font:
	if _serif == null:
		_serif = _embedded(EMBEDDED_SERIF)
		if _serif == null:
			# 子集还没生成（新克隆的仓库）：退回全量，别让标题掉成系统字体
			_serif = _embedded(EMBEDDED_SERIF_FULL)
		if _serif == null:
			# 走到这里说明工程里两份 serif 都不在。这是**真 bug**，不是可选降级：
			# 曾有一版就是这样——常量指着一个从没拷进仓库的文件，
			# 于是主标题/章节名/结局标题在每台机器上都长不一样，
			# 非中文系统还可能整块豆腐。发行自检已经把这种情况判失败。
			push_warning("内置衬线字体缺失（%s），已回退系统字体；标题字形会随机器漂移"
				% EMBEDDED_SERIF)
			var f := SystemFont.new()
			f.font_names = PackedStringArray([
				"Noto Serif CJK SC", "Source Han Serif SC", "Songti SC",
				"SimSun", "STSong", "serif",
			])
			f.allow_system_fallback = true
			_serif = f
	return _serif


static func theme() -> Theme:
	if _theme == null:
		var t := Theme.new()
		t.default_font = sans()
		t.default_font_size = 14
		t.set_color("font_color", "Label", WHITE)
		t.set_constant("separation", "VBoxContainer", 8)
		t.set_constant("separation", "HBoxContainer", 8)
		_theme = t
	return _theme


## 静态缓存持有 FontFile/Theme，退出时不清会让 Godot 报 ObjectDB 泄漏。
static func release() -> void:
	_theme = null
	_sans = null
	_serif = null


static func sb(bg: Color, border: Color = Color(0, 0, 0, 0), radius: int = 8,
		bw: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	if bw > 0:
		s.set_border_width_all(bw)
		s.border_color = border
	return s


static func panel(bg: Color, border: Color = Color(0, 0, 0, 0), radius: int = 10,
		bw: int = 0) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", sb(bg, border, radius, bw))
	return p


static func margins(l: int, t: int, r: int, b: int) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	return m


static func lbl(text: String, size: int = 14, color: Color = WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func serif_lbl(text: String, size: int = 15, color: Color = PAPER) -> Label:
	var l := lbl(text, size, color)
	l.add_theme_font_override("font", serif())
	return l


static func wrap(l: Label, min_w: int = 0) -> Label:
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if min_w > 0:
		l.custom_minimum_size = Vector2(min_w, 0)
	return l


static func spacer(w: bool = true) -> Control:
	var c := Control.new()
	if w:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


static func button(text: String, accent: Color = TEAL, min_w: int = 0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 40)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", sans())
	b.add_theme_font_size_override("font_size", 15)
	var fg := Color("#04181B")
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg)
	b.add_theme_color_override("font_pressed_color", fg)
	b.add_theme_color_override("font_disabled_color", MUTED)
	b.add_theme_stylebox_override("normal", sb(accent, accent, 8))
	b.add_theme_stylebox_override("hover", sb(accent.lightened(0.14), accent, 8))
	b.add_theme_stylebox_override("pressed", sb(accent.darkened(0.16), accent, 8))
	b.add_theme_stylebox_override("focus", sb(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 8))
	b.add_theme_stylebox_override("disabled", sb(Color("#16262B"), LINE, 8, 1))
	return b


static func ghost_button(text: String, accent: Color = TEAL, min_w: int = 0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 38)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", sans())
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", accent)
	b.add_theme_color_override("font_hover_color", accent.lightened(0.25))
	b.add_theme_color_override("font_pressed_color", accent.darkened(0.2))
	b.add_theme_color_override("font_disabled_color", MUTED)
	b.add_theme_stylebox_override("normal", sb(Color("#0D2229"), LINE, 8, 1))
	b.add_theme_stylebox_override("hover", sb(Color("#123039"), accent.darkened(0.2), 8, 1))
	b.add_theme_stylebox_override("pressed", sb(Color("#0A1B21"), accent, 8, 1))
	b.add_theme_stylebox_override("focus", sb(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 8))
	b.add_theme_stylebox_override("disabled", sb(Color("#0A171B"), Color("#1B2A2E"), 8, 1))
	return b


## 小标签。`icon` 非空时在字前插一个同高的图标（不放大标签高度）。
static func chip(text: String, fg: Color, bg: Color, size: int = 11,
		icon: String = "") -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", sb(bg, Color(0, 0, 0, 0), 4))
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# 横向也必须「只占内容宽度」：放进 VBox 时默认 FILL 会把 chip 拉成整行。
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var m := margins(6, 2, 6, 2)
	if icon != "" and Icons.has(icon):
		# 图标边长 = 字号 + 1：落在汉字的视觉行高上，过大就会把 chip 顶高。
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		row.add_child(Icons.rect(icon, size + 1, fg))
		row.add_child(lbl(text, size, fg))
		m.add_child(row)
	else:
		m.add_child(lbl(text, size, fg))
	p.add_child(m)
	return p


## 递归关掉鼠标事件，让外层 Panel/卡片能接到点击
static func ignore_mouse(n: Node) -> void:
	if n is Control:
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in n.get_children():
		ignore_mouse(c)


static func clear(n: Node) -> void:
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()


## 与 engine.gd 的 D.VITALS 同序同名的镜像表（key → 中文名）
const VITAL_NAMES := {
	"energy": "精力", "sleep": "睡眠债", "stress": "压力",
	"metabolic": "代谢负荷", "inflammation": "炎症水平", "trust": "身体信任",
}


static func vital_name(key: String) -> String:
	return VITAL_NAMES.get(key, key)

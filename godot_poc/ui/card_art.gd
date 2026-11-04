extends RefCounted
## 卡牌插画条：`assets/cards/<id>.png`（244×120，由 `tools/bake_card_art.gd` 烘焙）。
##
## 两个关键决定：
##
## 1. **用 `Image.load_from_file()` 而不是 `load()`**。`load()` 依赖编辑器导入出的
##    `.import` 与 `.godot/imported/` 缓存，在导出包、CI、"只拷源码"三种场景都会踩空
##    （字体那一轮已经踩过一次，同一个坑不重复踩）。
##
## 2. **缺图时给占位，不留空**。42 张里现在只有 4 张有图；如果只有有图的卡片变高，
##    同一排卡片就会高低不齐，看起来像加载失败。占位条画**该类的大号类型图标**做水印：
##    读起来是"这一类牌的位置"，而不是"这里少了一张图"。
##    刻意不写类型名——类型名就在下面一行的 chip 里，重复两遍只会显得吵。

const Icons = preload("res://ui/icons.gd")
const Kit = preload("res://ui/ui_kit.gd")

const DIR := "res://assets/cards/"

## 插画条尺寸。卡牌 150 宽、内容边距 9 → 内容宽 132。
## 132×60 正好是烘焙产物的 2:1，无需二次裁切。
const ART_W := 132
const ART_H := 60

## 占位水印：图标边长 / 透明度。26px 是这个框里"看得出形状但不抢戏"的上限，
## 再大就会被人当成真插画，再小 12px 才有的加粗规则又会被触发（26>18，走基准线宽）。
const PH_ICON := 26
const PH_ALPHA := 0.3

static var _cache := {}


static func path_of(id: String) -> String:
	return DIR + id + ".png"


static func exists(id: String) -> bool:
	return Kit.asset_exists(path_of(id))


## 读图并缓存。失败返回 null（调用方自行降级到占位）。
static func tex(id: String) -> Texture2D:
	if _cache.has(id):
		return _cache[id]
	var t: Texture2D = Kit.texture_at(path_of(id))
	_cache[id] = t
	return t


## 构建插画条。`icon_name` 是缺图时画在占位条上的类型图标（assets/icons/ 的文件名），
## `accent` 是类型色。
##
## `w`/`h` 可以放大到检视卡用的 **264×120**——那是烘焙产物的原始尺寸，1:1 显示无损。
## 再往上就会糊：原图 1536×1024 经裁切缩到 264×120 时已经丢了细节，放大只是插值。
static func make(id: String, icon_name: String, accent: Color,
		w: int = ART_W, h: int = ART_H, icon_px: int = PH_ICON) -> Control:
	var t := tex(id)
	if t != null:
		var tr := TextureRect.new()
		tr.texture = t
		tr.custom_minimum_size = Vector2(w, h)
		# 原图 264×120 与本条 132×60 比例一致，COVERED 只是保底：
		# 将来换成别的比例的图也不会被拉变形。
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return tr

	# ---------- 占位 ----------
	var p := Panel.new()
	p.custom_minimum_size = Vector2(w, h)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color("#081419")
	bg.set_corner_radius_all(4)
	# 描边只留一丝，作用是"这是一个框"而不是"这张图坏了"。
	bg.set_border_width_all(1)
	bg.border_color = Color(accent.r, accent.g, accent.b, 0.12)
	p.add_theme_stylebox_override("panel", bg)

	if icon_name != "" and Icons.has(icon_name):
		var cc := CenterContainer.new()
		cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(cc)
		cc.add_child(Icons.rect(icon_name, icon_px,
			Color(accent.r, accent.g, accent.b, PH_ALPHA)))
	return p


static func release() -> void:
	_cache.clear()

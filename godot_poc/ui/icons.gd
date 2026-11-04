extends RefCounted
## 运行时 SVG 图标：零导入依赖、跟随语义色、按尺寸重新光栅化。
##
## 为什么不用 `load("res://x.svg")`：那要求编辑器先导入、生成 `.import` 与
## `.godot/` 缓存，在导出包、CI、「只拷源码」三种场景都会踩空（字体那轮已吃过亏）。
## 这里走 `Image.load_svg_from_string()`，纯运行时。
##
## 为什么不用位图 PNG：图标要在 11–24px 之间多档使用，位图非拉伸即糊。
## SVG 每个尺寸都重新光栅化，等效于「真矢量」。
##
## 规范（新增图标请照抄 assets/icons/README.md）：
##   viewBox 0 0 24 24 · fill none · stroke currentColor · 圆头端点
##   stroke-width 由本文件按尺寸自适应，**SVG 里统一写 1.8 作为基准值**

const DIR := "res://assets/icons/"
const BOX := 24.0  # 所有图标的 viewBox 边长
const BASE_STROKE := 1.8  # SVG 文件里写的基准线宽

## name -> 原始 SVG 文本
static var _src := {}
## "name|px|hex" -> ImageTexture
static var _tex := {}


## 小尺寸必须加粗：24 单位里 1.8 的线，画到 12px 上只有 0.9 像素，会发虚。
## 这是图标设计的基本功，不是可选项。
static func _stroke_for(px: int) -> float:
	if px <= 14:
		return 2.4
	if px <= 18:
		return 2.0
	return BASE_STROKE


static func _load(name: String) -> String:
	if _src.has(name):
		return _src[name]
	# 先找 .raw 副本：svgs 会被 Godot 当资源导入，导出包里只剩导入产物，
	# 原始 SVG 源码不在包内。build_win.bat 导出前用
	# tools/prepare_export_assets.py 生成 .raw 副本，而 .raw 不是资源，
	# 能被 include_filter 原样打进包。开发机上没有副本时就退回 .svg。
	var path := DIR + name + ".svg.raw"
	if not FileAccess.file_exists(path):
		path = DIR + name + ".svg"
	if not FileAccess.file_exists(path):
		push_warning("图标缺失：%s" % path)
		_src[name] = ""
		return ""
	var t := FileAccess.get_file_as_string(path)
	_src[name] = t
	return t


static func has(name: String) -> bool:
	return _load(name) != ""


## 取一张图标贴图。px 是**显示边长**；内部按 2x 超采样后由 UI 缩小，边缘更顺。
static func icon(name: String, px: int, color: Color) -> Texture2D:
	var hex := color.to_html(false)
	var key := "%s|%d|%s" % [name, px, hex]
	if _tex.has(key):
		return _tex[key]

	var svg := _load(name)
	if svg == "":
		return null
	svg = svg.replace("currentColor", "#" + hex)
	svg = svg.replace('stroke-width="%.1f"' % BASE_STROKE,
		'stroke-width="%.2f"' % _stroke_for(px))

	var img := Image.new()
	var scale := float(px) * 2.0 / BOX
	if img.load_svg_from_string(svg, scale) != OK:
		push_warning("图标光栅化失败：%s" % name)
		return null
	var tex := ImageTexture.create_from_image(img)
	_tex[key] = tex
	return tex


## 直接可用的图标控件（UI 层拿这个，不要自己拼 TextureRect）。
static func rect(name: String, px: int, color: Color) -> TextureRect:
	var r := TextureRect.new()
	r.texture = icon(name, px, color)
	r.custom_minimum_size = Vector2(px, px)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# alpha 走 modulate 而不是写进 SVG 的 hex，避免不同渲染后端对 #RRGGBBAA 的支持差异
	r.modulate = Color(1, 1, 1, color.a)
	return r


## 静态缓存持有 ImageTexture，退出时不清会被 Godot 报 ObjectDB 泄漏。
static func release() -> void:
	_src.clear()
	_tex.clear()

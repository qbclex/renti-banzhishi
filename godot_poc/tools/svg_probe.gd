extends SceneTree
## SVG 能力探针：确认 Godot 能在运行时把 SVG 字符串光栅化成贴图。
##
## 为什么先探这个：图标方案取决于它。
## 若走 `load("res://x.svg")`，就要求编辑器先导入、生成 .import 与 .godot 缓存，
## 导出包和 CI 里都会踩空（字体那次已经吃过这个亏）。
## `Image.load_svg_from_string()` 走运行时，零导入依赖，所以先证明它可用。

const SVG := """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M12 3v18M3 12h18"/></svg>"""


func _initialize() -> void:
	var fails: Array = []

	# 1) 原始渲染
	var img := Image.new()
	var err := img.load_svg_from_string(SVG, 1.0)
	print("load_svg err=%d (OK=%d) size=%s" % [err, OK, str(img.get_size())])
	if err != OK:
		fails.append("load_svg_from_string 返回 %d" % err)
	elif img.get_size() != Vector2i(24, 24):
		fails.append("viewBox 24 未映射为 24px，实际 %s" % str(img.get_size()))

	# 2) 放大渲染（图标要在 2x 下清晰，靠的是重新光栅化而不是拉伸）
	var big := Image.new()
	if big.load_svg_from_string(SVG, 3.0) == OK:
		print("scale3 size=%s" % str(big.get_size()))
		if big.get_size() != Vector2i(72, 72):
			fails.append("3x 渲染尺寸不对：%s" % str(big.get_size()))
	else:
		fails.append("3x 渲染失败")

	# 3) currentColor 替换是否真的改变像素（决定能不能按语义色着色）
	var red_svg := SVG.replace("currentColor", "#FF0000")
	var red := Image.new()
	if red.load_svg_from_string(red_svg, 2.0) == OK:
		var found := false
		for y in red.get_height():
			for x in red.get_width():
				var c := red.get_pixel(x, y)
				if c.a > 0.5 and c.r > 0.8 and c.g < 0.2:
					found = true
					break
			if found:
				break
		print("currentColor_replaced red_found=%s" % str(found).to_lower())
		if not found:
			fails.append("替换 currentColor 后没渲染出红色")
	else:
		fails.append("替换色后渲染失败")

	# 4) 转成贴图（UI 里实际用的形态）
	var tex := ImageTexture.create_from_image(big)
	print("texture size=%s" % str(tex.get_size()))
	if tex.get_width() != 72:
		fails.append("贴图宽度不对")

	if fails.is_empty():
		print("SVG_PROBE OK runtime=true")
		quit(0)
	else:
		print("SVG_PROBE FAIL %s" % " / ".join(fails))
		quit(1)

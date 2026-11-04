extends SceneTree
## chip 图标的接线探针：证明"标签里的图标真的占了位置"。
##
## 为什么需要它：这些 chip 图标要么画出来、要么不画，两种情况的界面都"看起来正常"——
## 不画只是少了一个小图形，不会报错、不会错位。所以不能靠肉眼看截图，得量数字：
##   同一段文字，带图标的 chip 必须比不带图标宽出一个图标 + 间距。
##
## 用法：godot --headless --path . --script tools/chip_probe.gd

const Kit = preload("res://ui/ui_kit.gd")
const Icons = preload("res://ui/icons.gd")

const TEXT := "生活"
const ICON := "life"
## 图标边长 = 字号 + 1 = 12，间距 4，所以最少要宽出 14
const MIN_DELTA := 14


func _initialize() -> void:
	var plain := Kit.chip(TEXT, Kit.TEAL, Color("#0B1E24"))
	var with_ic := Kit.chip(TEXT, Kit.TEAL, Color("#0B1E24"), 11, ICON)
	root.add_child(plain)
	root.add_child(with_ic)

	var w0 := int(plain.get_combined_minimum_size().x)
	var w1 := int(with_ic.get_combined_minimum_size().x)
	var delta := w1 - w0

	var tex := Icons.icon(ICON, 12, Kit.TEAL)
	var tex_ok := tex != null and tex.get_width() > 0

	# 高度不许变：chip 被图标顶高，整排卡片就会跟着动
	var h0 := int(plain.get_combined_minimum_size().y)
	var h1 := int(with_ic.get_combined_minimum_size().y)

	print("CHIP_PROBE text=%d icon=%d delta=%d tex=%s h=%d/%d"
		% [w0, w1, delta, str(tex_ok), h0, h1])

	var fails: Array = []
	if not tex_ok:
		fails.append("图标纹理没生成")
	if delta < MIN_DELTA:
		fails.append("带图标的 chip 只宽了 %d（至少 %d），说明图标没进布局" % [delta, MIN_DELTA])
	if h0 != h1:
		fails.append("图标把 chip 顶高了：%d → %d" % [h0, h1])

	Icons.release()
	if fails.is_empty():
		print("CHIP_PROBE OK delta=%d" % delta)
		quit(0)
	else:
		print("CHIP_PROBE FAIL %s" % " / ".join(fails))
		quit(1)

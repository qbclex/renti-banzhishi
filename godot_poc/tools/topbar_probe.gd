extends SceneTree
## 顶栏按钮探针：icon 进按钮之后，最容易出的事是「布局按原始纹理宽算、
## 绘制时再缩小」，于是图标和文字之间空出一大块。这种空隙截图看着像
## 「设计师留白」，量出来才发现是 13px 的浪费。

const Icons = preload("res://ui/icons.gd")


func _mk(icon: Texture2D, maxw: int) -> Button:
	var b := Button.new()
	b.text = "存档"
	b.icon = icon
	if maxw > 0:
		b.add_theme_constant_override("icon_max_width", maxw)
	b.add_theme_constant_override("h_separation", 5)
	root.add_child(b)
	return b


func _measure(b: Button) -> Vector2:
	await process_frame
	await process_frame
	var m := b.get_combined_minimum_size()
	b.queue_free()
	return m


func _initialize() -> void:
	var tex := Icons.icon("save", 13, Color.WHITE)
	if tex == null:
		print("TOPBAR_PROBE FAIL 图标生成失败")
		quit(1)
		return
	print("tex=%s" % str(tex.get_size()))

	var bare := _mk(null, 0)
	var m0: Vector2 = await _measure(bare)

	var capped := _mk(tex, 13)
	var m1: Vector2 = await _measure(capped)

	var uncapped := _mk(tex, 0)
	var m2: Vector2 = await _measure(uncapped)

	print("noicon   min=%s" % str(m0))
	print("maxw=13  min=%s" % str(m1))
	print("无maxw   min=%s" % str(m2))
	print("delta capped=%d  delta uncapped=%d  (期望 13+5=18)"
		% [int(m1.x - m0.x), int(m2.x - m0.x)])
	print("height  noicon=%d capped=%d" % [int(m0.y), int(m1.y)])

	var ok: bool = absf(m1.x - m0.x - 18.0) < 1.0 and absf(m1.y - m0.y) < 1.0
	print("TOPBAR_PROBE %s" % ("OK" if ok else "FAIL"))
	Icons.release()
	quit(0 if ok else 1)

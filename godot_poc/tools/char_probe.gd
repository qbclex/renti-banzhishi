extends SceneTree
## 立绘接线探针：**量**，不是看。
##
## 要验的四件事，每一件只看截图都会漏：
##   1. 照片在界面里的实际尺寸是不是正好 216×288 —— TextureRect 用 STRETCH_SCALE，
##      一旦父容器多给几个像素，脸就被纵向拉伸，而 3% 的拉伸人眼在静态图上分辨不出来。
##   2. 整块模态有没有超出窗口（1280×820）。
##   3. 加了照片之后，右侧文字列还剩多宽 —— 窄到 400 以下就开始折行折断。
##   4. 评级 → 表情 的映射真的接上了（不是"代码里有这个函数"）。
##
## 用法：
##   godot --headless --path . --script tools/char_probe.gd
##
## headless 下 root 视口是 64×64，布局无效，所以显式设 ui.size。

const UI = preload("res://ui/main_ui.gd")
const CharArt = preload("res://ui/char_art.gd")
const Save = preload("res://ui/save_sys.gd")

var bad := 0
var _shot := false


func _initialize() -> void:
	Save.erase()
	var ui = UI.new()
	root.add_child(ui)
	ui.size = Vector2(1280, 820)
	await process_frame
	await process_frame
	await process_frame

	var want_shot := OS.get_cmdline_user_args().has("--save")
	_shot = want_shot
	_report_missing()
	for n in range(1, 6):
		await _chapter_brief(n, want_shot)
	await _check("settle", "S", "释然")
	await _check("settle", "A", "释然")
	await _check("settle", "B", "平静")
	await _check("settle", "C", "疲惫")
	await _check("over", null, "警觉")
	# 结局的表情取决于真结局判定，这里只验证"有立绘且状态标注非空"，不锁具体值
	await _check("ending", null, "")

	print("CHAR_PROBE %s bad=%d" % ["OK" if bad == 0 else "BAD", bad])
	quit(0 if bad == 0 else 1)


## 逐章翻开简报：换章时立绘必须跟着换人。
## 只验第 1 章是不够的——路径是 `host%d` 拼出来的，一个下标写错（从 0 还是从 1）
## 会让第五章显示第一章的人，而第 1 章永远是对的。
func _chapter_brief(no: int, save: bool) -> void:
	var ui = _ui()
	ui.game.campaign["chapter"] = no - 1
	ui.game.campaign["shift"] = 0
	ui.game.campaign["cleared"] = false
	ui.game.phase = "brief"
	ui._overlay_sig = ""
	ui._refresh()
	await process_frame
	await process_frame
	await process_frame

	var tr := _find_tex(ui._overlay)
	if tr == null:
		bad += 1
		print("CHAR BAD chapter=%d 简报没有立绘" % no)
		return
	var want := CharArt.tex(no, "calm")
	if want == null or tr.texture != want:
		bad += 1
		print("CHAR BAD chapter=%d 简报立绘不是第 %d 位宿主" % [no, no])
	print("CHAR OK chapter=%d host=%s photo=%.0fx%.0f"
		% [no, str(ui.game.get_chapter()["host"]), tr.size.x, tr.size.y])
	if save:
		await process_frame
		var out := "user://char_brief_host%d.png" % no
		var err := root.get_texture().get_image().save_png(out)
		print("  saved %s err=%d" % [out, err])


func _report_missing() -> void:
	var miss: Array = []
	for n in range(1, 6):
		for e in CharArt.EXPRS:
			if not CharArt.has(n, e):
				miss.append("host%d_%s" % [n, e])
	print("CHAR_PROBE assets have=%d missing=%d %s"
		% [20 - miss.size(), miss.size(), "" if miss.is_empty() else "-> " + " ".join(miss)])


## `grade` 非空时把它塞进 rating，用来验评级→表情的映射
func _check(kind: String, grade, want_expr: String) -> void:
	var ui = _ui()
	ui._hide_inspect()
	if kind == "brief":
		ui.game.phase = "brief"
	elif kind == "settle":
		ui.game.rating = {"score": 70, "grade": grade, "comment": ""}
		ui.game.phase = "settle"
	elif kind == "over":
		ui.game.phase = "over"
	else:
		# _refresh_overlay 只在 campaign.cleared 时才给 "ending"；
		# 只改 phase 的话它算出 want=""，浮层不重建，量到的还是上一屏。
		ui.game.campaign["cleared"] = true
		ui.game.phase = "settle"
	ui._overlay_sig = ""
	ui._refresh()
	await process_frame
	await process_frame
	await process_frame

	var tr := _find_tex(ui._overlay)
	if tr == null:
		bad += 1
		print("CHAR BAD kind=%s grade=%s 没有找到立绘 TextureRect" % [kind, str(grade)])
		return
	var sz := tr.size
	var want := Vector2(CharArt.W, CharArt.H)
	if absf(sz.x - want.x) > 0.5 or absf(sz.y - want.y) > 0.5:
		bad += 1
		print("CHAR BAD kind=%s grade=%s 照片尺寸 %.1fx%.1f 应为 %.1fx%.1f（脸被拉伸）"
			% [kind, str(grade), sz.x, sz.y, want.x, want.y])

	# 整块模态是否出窗
	var panel := _panel_root(ui._overlay)
	if panel != null:
		var r: Rect2 = panel.get_global_rect()
		if r.position.x < 0 or r.position.y < 0 \
				or r.end.x > 1280.5 or r.end.y > 820.5:
			bad += 1
			print("CHAR BAD kind=%s 模态超出窗口 rect=%s" % [kind, str(r)])

	# 文字列剩余宽度
	var col_w := _text_col_width(ui._overlay)
	var label := _caption(tr)
	if want_expr != "" and label != want_expr:
		bad += 1
		print("CHAR BAD kind=%s grade=%s 状态标注是「%s」，应为「%s」（映射没接上）"
			% [kind, str(grade), label, want_expr])
	if label == "":
		bad += 1
		print("CHAR BAD kind=%s 立绘下方没有状态标注" % kind)
	if col_w < 400.0:
		bad += 1
		print("CHAR BAD kind=%s 文字列只有 %.0fpx（<400，会折行折断）" % [kind, col_w])
	print("CHAR OK kind=%-6s grade=%-4s expr=%-6s photo=%.0fx%.0f text_col=%.0f"
		% [kind, str(grade), label, sz.x, sz.y, col_w])
	if _shot:
		var out := "user://char_%s%s.png" % [kind, "" if grade == null else "_" + str(grade)]
		print("  saved %s err=%d" % [out, root.get_texture().get_image().save_png(out)])


func _ui():
	for ch in root.get_children():
		if ch.get_script() == UI:
			return ch
	return null


func _find_tex(n: Node) -> TextureRect:
	for ch in n.get_children():
		if ch is TextureRect and (ch as TextureRect).texture != null:
			return ch as TextureRect
		var r := _find_tex(ch)
		if r != null:
			return r
	return null


func _panel_root(n: Node) -> Control:
	for ch in n.get_children():
		if ch is CenterContainer:
			for c in ch.get_children():
				if c is PanelContainer:
					return c as Control
	return null


## 内容列（立绘右侧那个 VBox）的宽度：找和照片同级的那个 VBoxContainer
func _text_col_width(n: Node) -> float:
	var tr := _find_tex(n)
	if tr == null:
		return 0.0
	var row := tr.get_parent()
	while row != null and not (row is HBoxContainer):
		row = row.get_parent()
	if row == null:
		return 0.0
	var best := 0.0
	for ch in row.get_children():
		if ch is VBoxContainer:
			best = maxf(best, (ch as Control).size.x)
	return best


## 立绘下方那行「◆ 状态 · X」里的 X。
## 从场景里读而不是从代码里读：要验的正是"界面上写出来的字"，
## 断言一个变量等于自己猜的值没有意义。
func _caption(tr: TextureRect) -> String:
	var col := tr.get_parent()
	while col != null and not (col is VBoxContainer):
		col = col.get_parent()
	if col == null:
		return ""
	var last := ""
	for ch in col.get_children():
		for l in _labels(ch):
			last = (l as Label).text
	return last


func _labels(n: Node) -> Array:
	var out: Array = []
	if n is Label:
		out.append(n)
	for ch in n.get_children():
		out.append_array(_labels(ch))
	return out

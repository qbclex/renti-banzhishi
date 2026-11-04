extends SceneTree
## 角色立绘烘焙入口：assets/chars_src/*.png → assets/chars/*.png（336×448 双色调）。
##
## 用法：
##   godot --headless --path . --script tools/bake_char_art.gd
##
## 文件名就是立绘 id（`host1_calm` 这样），与 `data.gd` 的 CHARTS 表对齐。

const CharArt = preload("res://tools/char_art.gd")

const SRC := "res://assets/chars_src/"
const OUT := "res://assets/chars/"


func _initialize() -> void:
	var dir := DirAccess.open(SRC)
	if dir == null:
		print("BAKE FAIL 找不到原图目录 %s" % SRC)
		quit(1)
		return

	var names: Array = []
	for f in dir.get_files():
		if f.to_lower().ends_with(".png"):
			names.append(f)
	names.sort()
	if names.is_empty():
		print("BAKE SKIP %s 里没有 png" % SRC)
		quit(0)
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))

	var fails: Array = []
	var done := 0
	for f in names:
		var id: String = str(f).get_basename()
		var img := _load_png(SRC + f)
		if img == null:
			fails.append("%s 读不出来" % f)
			continue
		var out_img := CharArt.bake(img, id)
		if out_img.get_width() != CharArt.OUT_W or out_img.get_height() != CharArt.OUT_H:
			fails.append("%s 尺寸 %dx%d" % [id, out_img.get_width(), out_img.get_height()])
			continue
		if out_img.save_png(ProjectSettings.globalize_path(OUT + id + ".png")) != OK:
			fails.append("%s 写不出去" % id)
			continue
		done += 1
		print("baked %-18s %dx%d" % [id, out_img.get_width(), out_img.get_height()])

	if fails.is_empty():
		print("CHAR_BAKE OK n=%d size=%dx%d" % [done, CharArt.OUT_W, CharArt.OUT_H])
		quit(0)
	else:
		print("CHAR_BAKE FAIL %s" % " / ".join(fails))
		quit(1)


func _load_png(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(ProjectSettings.globalize_path(path)) != OK:
		return null
	if img.is_compressed():
		img.decompress()
	return img

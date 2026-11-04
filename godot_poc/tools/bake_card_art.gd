extends SceneTree
## 卡牌插画烘焙入口：遍历 assets/art_src/ 里的 AI 原图，产出 assets/cards/。
##
## 用法：
##   1. AI 原图丢进 assets/art_src/，文件名 = 卡牌 id（如 c_sleep.png）
##   2. godot --headless --path . --script tools/bake_card_art.gd
##   3. 产物在 assets/cards/（244×120，双色调，可直接进包）
##
## 原图目录不进安装包（打包脚本排除 art_src），只有烘焙产物进包。

const CardArt = preload("res://tools/card_art.gd")

const SRC := "res://assets/art_src/"
const OUT := "res://assets/cards/"


func _initialize() -> void:
	var dir := DirAccess.open(SRC)
	if dir == null:
		print("BAKE FAIL 找不到原图目录 %s（先建好并放入 AI 原图）" % SRC)
		quit(1)
		return

	var names: Array = []
	for f in dir.get_files():
		if f.to_lower().ends_with(".png"):
			names.append(f)
	names.sort()
	if names.is_empty():
		print("BAKE SKIP %s 里没有 png，无事可做" % SRC)
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
		var out_img := CardArt.bake(img, id)
		var abs_out := ProjectSettings.globalize_path(OUT + id + ".png")
		if out_img.save_png(abs_out) != OK:
			fails.append("%s 写不出去" % id)
			continue
		done += 1
		print("baked %-16s %dx%d" % [id, out_img.get_width(), out_img.get_height()])

	if fails.is_empty():
		print("BAKE OK n=%d size=%dx%d contrast=%.2f grain=%.3f"
			% [done, CardArt.OUT_W, CardArt.OUT_H, CardArt.CONTRAST, CardArt.GRAIN])
		quit(0)
	else:
		print("BAKE FAIL %s" % " / ".join(fails))
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

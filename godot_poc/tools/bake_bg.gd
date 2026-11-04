extends SceneTree
## 背景烘焙：assets/bg_src/<id>.png → assets/bg/<id>.png
##
## 文件名必须等于资产 id（清单见 11_美术风格指南 §D）。
## 缺哪张就跳过哪张，不报错——背景是可选资产，界面在没图时应该退回纯色底。
##
## 用法：
##   godot --headless --path . --script tools/bake_bg.gd
##   godot --headless --path . --script tools/bake_bg.gd -- --only bg_nurse_station

const BgArt = preload("res://tools/bg_art.gd")

const SRC_DIR := "res://assets/bg_src"
const OUT_DIR := "res://assets/bg"

## 产物是 **WebP 有损**，不是 PNG。这一条和项目里其它资产（图标/卡牌/立绘全是 png）
## 不一致，是有理由的：
##
## 背景是唯一「大面积缓变的暗部 + 全图颗粒」的资产，PNG 对这种内容几乎无法压缩——
## 1920×1230 实测 2528 KB。有损 WebP q=0.92 是 156 KB，**16 倍**差距；
## 而 q=0.92 在 2 倍放大下与 PNG 看不出区别（颗粒略柔一点，而这张图最终只从
## 面板缝隙里露出 12%，那点柔化早被挡掉了）。三张背景因此从 7.5 MB 降到 0.5 MB。
##
## 反过来，图标/卡牌不能这么做：它们是 24–264px 的小图，色带和块效应在
## 1px 描边上会非常明显，而且没有"大面积暗部"可利用。
const OUT_EXT := ".webp"
const WEBP_QUALITY := 0.92

## 清单：id → 用途（写在这里当文档，也当作"哪些是规定要有的"的对照）
const IDS := {
	"bg_nurse_station": "主界面全屏背景（P0）",
	"bg_corridor_night": "转场（P2）",
	"bg_ward": "终章（P2）",
}


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var only := ""
	var i := args.find("--only")
	if i >= 0 and args.size() > i + 1:
		only = args[i + 1]

	if not DirAccess.dir_exists_absolute(OUT_DIR):
		DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var done := 0
	var skipped := 0
	var fail := 0
	var total_bytes := 0
	for id in IDS:
		if only != "" and id != only:
			continue
		var src_path := "%s/%s.png" % [SRC_DIR, id]
		if not FileAccess.file_exists(src_path):
			print("BG_BAKE skip %s（无原图）" % id)
			skipped += 1
			continue
		var img := Image.load_from_file(src_path)
		if img == null:
			print("BG_BAKE FAIL 解码失败 %s" % src_path)
			fail += 1
			continue
		var src_size := "%dx%d" % [img.get_width(), img.get_height()]
		var t0 := Time.get_ticks_msec()
		var ml := BgArt.mark_area_luma(img)
		if ml > BgArt.MARK_MAX_LUMA:
			push_warning("BG_BAKE %s 右下角亮度 %.3f 超过 %.2f：水印克隆会抹掉内容，应重出构图"
				% [id, ml, BgArt.MARK_MAX_LUMA])
			print("BG_BAKE WARN %s 水印区亮度 %.3f（>%.2f，克隆会抹掉内容）"
				% [id, ml, BgArt.MARK_MAX_LUMA])
		var out := BgArt.bake(img, id, id)
		print("BG_BAKE timing %s baked in %.1fs" % [id, (Time.get_ticks_msec() - t0) / 1000.0])
		var out_path := "%s/%s%s" % [OUT_DIR, id, OUT_EXT]
		var err := out.save_webp(out_path, true, WEBP_QUALITY)
		if err != OK:
			print("BG_BAKE FAIL 写入失败 %s err=%d" % [out_path, err])
			fail += 1
			continue
		var bytes := FileAccess.get_file_as_bytes(out_path).size()
		total_bytes += bytes
		# 顺带报一次烘焙后的亮度：中心区必须比面板暗，四边必须归零。
		# 这两个数不对，接进界面就是"亮网格"或"一圈亮边"，不用等截图就能知道。
		print("BG_BAKE ok %s %s -> %dx%d  %.1f KB  %s" % [
			id, src_size, out.get_width(), out.get_height(),
			bytes / 1024.0, _stats(out)])
		done += 1

	print("BG_BAKE DONE ok=%d skip=%d fail=%d total=%.1f MB" % [
		done, skipped, fail, total_bytes / 1048576.0])
	quit(0 if fail == 0 else 1)


static func _stats(img: Image) -> String:
	var w := img.get_width()
	var h := img.get_height()
	var c := 0.0
	var e := 0.0
	var hi := 0.0
	var n := 0
	for y in range(0, h, 7):
		for x in range(0, w, 7):
			var l := _luma(img.get_pixel(x, y))
			# 中心 1/3
			if x > w / 3 and x < w * 2 / 3 and y > h / 3 and y < h * 2 / 3:
				c += l
			# 边缘 2%
			if x < w * 0.02 or x > w * 0.98 or y < h * 0.02 or y > h * 0.98:
				e += l
			hi = maxf(hi, l)
			n += 1
	var center := c / float(maxi(n / 9, 1))
	var edge := e / float(maxi(int(n * 0.07), 1))
	return "center=%.4f edge=%.4f max=%.3f" % [center, edge, hi]


static func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

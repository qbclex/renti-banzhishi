extends SceneTree
## 背景原图的亮度普查：分位数 + 中心/边缘对比 + 水印残留检测。
##
## 为什么需要这个：背景和卡牌/立绘的验收标准**不是一回事**。
## 卡牌看"132×60 还认不认得出来"，立绘看"216 宽还分不分得清四态"，
## 而背景在界面上只从 16px 外边距和 12px 面板缝隙里透出来（可见面积约 12%），
## 所以它唯一要满足的是**亮度曲线**：中间要压得住，四边要能接 #03080A。
## 这个脚本就是把这条曲线量出来的地方。
##
## 用法：
##   godot --headless --path . --script tools/bg_probe.gd -- <png 相对路径>

const BG0 := Color("#03080A")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("BG_PROBE FAIL 需要图片路径")
		quit(1)
		return
	var path: String = args[0]
	if not FileAccess.file_exists(path):
		print("BG_PROBE FAIL 文件不存在 %s" % path)
		quit(1)
		return
	var img := Image.load_from_file(path)
	if img == null:
		print("BG_PROBE FAIL 解码失败 %s" % path)
		quit(1)
		return
	img.convert(Image.FORMAT_RGBA8)

	var w := img.get_width()
	var h := img.get_height()
	print("size %d x %d  ratio %.3f" % [w, h, float(w) / float(h)])

	# ---------------------------------------------------------- 全局分位数
	var hist := []
	hist.resize(256)
	hist.fill(0)
	var lumas := []
	var step := 3
	for y in range(0, h, step):
		for x in range(0, w, step):
			var l := _luma(img.get_pixel(x, y))
			lumas.append(l)
			hist[clampi(int(l * 255.0), 0, 255)] += 1
	var n := lumas.size()
	lumas.sort()
	print("luma  p01=%.3f p10=%.3f p50=%.3f p90=%.3f p99=%.3f max=%.3f" % [
		lumas[int(n * 0.01)], lumas[int(n * 0.10)], lumas[int(n * 0.50)],
		lumas[int(n * 0.90)], lumas[int(n * 0.99)], lumas[n - 1]])
	var mean := 0.0
	for l in lumas:
		mean += l
	mean /= float(n)
	print("luma  mean=%.3f" % mean)
	# 亮部占比：界面上超过 0.30 的像素会把缝隙点亮成发光网格
	var hot := 0
	var warm := 0
	for l in lumas:
		if l > 0.30:
			hot += 1
		if l > 0.18:
			warm += 1
	print("bright  >0.18=%.1f%%  >0.30=%.1f%%" % [
		warm * 100.0 / n, hot * 100.0 / n])

	# ---------------------------------------------------------- 区域对比
	# 九宫格平均亮度：判"光是不是集中在中间"（集中才不会被缝隙切成碎条）
	print("region (3x3 平均亮度):")
	for ry in 3:
		var row := ""
		for rx in 3:
			row += "%6.3f" % _region_mean(img, rx, ry)
		print("  " + row)

	# 四边各 2% 的一圈：这一圈会被界面 16px 外边距直接贴到，必须是纯 #03080A 附近
	print("edge  top=%.3f bottom=%.3f left=%.3f right=%.3f" % [
		_edge_mean(img, 0), _edge_mean(img, 1), _edge_mean(img, 2), _edge_mean(img, 3)])

	# ---------------------------------------------------------- 水印
	# 出图端在右下角烤死「AI生成 WORKBUDDY」。背景不会被裁切（满屏铺），
	# 所以必须真的查一遍：右下 18% x 8% 区域的平均亮度如果明显高于同高度的左侧，就是水印。
	var wr := _region_mean(img, 2, 2)
	var wl := _region_mean(img, 0, 2)
	print("watermark? 右下=%.3f 左下=%.3f delta=%.3f" % [wr, wl, wr - wl])

	# ---------------------------------------------------------- 机器可读行
	# 测试（`tests/test_godot_bg.py`）解析这一行。背景的验收全在亮度曲线上，
	# 上面那些人读的段落在测试里没法稳定断言，所以单独压成一行 key=value。
	var center := _region_mean(img, 1, 1)
	var edge_v := (_edge_mean(img, 0) + _edge_mean(img, 1) + _edge_mean(img, 2) + _edge_mean(img, 3)) / 4.0
	# 右下角 6%×10% 的最大亮度：水印是浅灰字，抹干净后这块应该和周围一样暗
	var corner_max := _corner_max(img, 0.94, 0.94)
	print("BG_PROBE STATS w=%d h=%d mean=%.4f p50=%.4f p90=%.4f p99=%.4f max=%.4f center=%.4f edge=%.4f corner_max=%.4f hot=%.4f" % [
		w, h, mean, lumas[int(n * 0.50)], lumas[int(n * 0.90)], lumas[int(n * 0.99)],
		lumas[n - 1], center, edge_v, corner_max, hot * 100.0 / n])

	print("BG_PROBE OK")
	quit(0)


## 右上角 (fx, fy) 起的 6%×6% 区域内的最大亮度
func _corner_max(img: Image, fx: float, fy: float) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := int(w * fx)
	var y0 := int(h * fy)
	var mx := 0.0
	for y in range(y0, h):
		for x in range(x0, w):
			mx = maxf(mx, _luma(img.get_pixel(x, y)))
	return mx


static func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _region_mean(img: Image, rx: int, ry: int) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := int(w * rx / 3.0)
	var x1 := int(w * (rx + 1) / 3.0)
	var y0 := int(h * ry / 3.0)
	var y1 := int(h * (ry + 1) / 3.0)
	var acc := 0.0
	var cnt := 0
	for y in range(y0, y1, 5):
		for x in range(x0, x1, 5):
			acc += _luma(img.get_pixel(x, y))
			cnt += 1
	return acc / float(maxi(cnt, 1))


## side: 0=top 1=bottom 2=left 3=right，各取 2% 厚的一圈
func _edge_mean(img: Image, side: int) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var acc := 0.0
	var cnt := 0
	match side:
		0:
			for y in range(0, maxi(1, int(h * 0.02)), 3):
				for x in range(0, w, 3):
					acc += _luma(img.get_pixel(x, y))
					cnt += 1
		1:
			for y in range(int(h * 0.98), h, 3):
				for x in range(0, w, 3):
					acc += _luma(img.get_pixel(x, y))
					cnt += 1
		2:
			for y in range(0, h, 3):
				for x in range(0, maxi(1, int(w * 0.02)), 3):
					acc += _luma(img.get_pixel(x, y))
					cnt += 1
		3:
			for y in range(0, h, 3):
				for x in range(int(w * 0.98), w, 3):
					acc += _luma(img.get_pixel(x, y))
					cnt += 1
	return acc / float(maxi(cnt, 1))

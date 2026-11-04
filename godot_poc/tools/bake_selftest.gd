extends SceneTree
## 烘焙管线自测：没有真实 AI 原图时，也要能证明「裁切 / 双色调 / 可复现」是对的。
##
## 造三种极端比例的假原图（横幅、方形、超宽），走完整管线，然后检查：
##   1. 输出尺寸恒定 244×120
##   2. 输出只有两个端点色之间的过渡，没有彩色残留
##   3. 同样的输入跑两次，逐像素完全一致（可复现，才能 diff 与回滚）
##   4. 全黑输入不被压成死黑、全白不被烧成纯白（保留层次）

const CardArt = preload("res://tools/card_art.gd")


func _initialize() -> void:
	var fails: Array = []

	# 三种比例：覆盖「裁左右」和「裁上下」两条分支
	var cases := [
		["wide_3x2", 1536, 1024],
		["square", 800, 800],
		["ultrawide", 2000, 600],
	]
	for c in cases:
		var name: String = c[0]
		var src := _make_test_image(int(c[1]), int(c[2]))
		var out := CardArt.bake(src, name)
		print("case %-10s in=%dx%d out=%dx%d"
			% [name, src.get_width(), src.get_height(), out.get_width(), out.get_height()])
		if out.get_width() != CardArt.OUT_W or out.get_height() != CardArt.OUT_H:
			fails.append("%s 输出尺寸错" % name)

		var res := _check_duotone(out)
		print("  duotone residual=%.3f dark=%.3f light=%.3f"
			% [res[0], res[1], res[2]])
		if res[0] > 0.10:
			fails.append("%s 有彩色残留（残差 %.3f）" % [name, res[0]])
		# 亮度要铺开，否则整张卡面糊成一坨
		if res[2] - res[1] < 0.35:
			fails.append("%s 动态范围过窄（%.2f..%.2f）" % [name, res[1], res[2]])

		# 可复现：同输入同盐，必须逐像素相同
		var again := CardArt.bake(_make_test_image(int(c[1]), int(c[2])), name)
		if not _same(out, again):
			fails.append("%s 两次烘焙结果不一致" % name)

	# 全黑 / 全白：不能压成死黑或烧成纯白
	var black := Image.create(400, 300, false, Image.FORMAT_RGBA8)
	black.fill(Color(0, 0, 0))
	var bl := CardArt.bake(black, "black")
	var b1 := _luma_range(bl)
	print("black lo=%.3f hi=%.3f" % [b1[0], b1[1]])
	if b1[0] < 0.02:
		fails.append("全黑输入被压成死黑")
	if b1[1] > 0.30:
		fails.append("全黑输入不该这么亮")

	var white := Image.create(400, 300, false, Image.FORMAT_RGBA8)
	white.fill(Color(1, 1, 1))
	var wt := CardArt.bake(white, "white")
	var w1 := _luma_range(wt)
	print("white lo=%.3f hi=%.3f" % [w1[0], w1[1]])
	if w1[1] < 0.70:
		fails.append("全白输入被压暗过头（应接近亮端点）")

	# 不同盐必须给出不同的颗粒（否则 42 张会出现同一张颗粒纹理）
	var a := CardArt.bake(_make_test_image(600, 400), "a")
	var b := CardArt.bake(_make_test_image(600, 400), "b")
	if _same(a, b):
		fails.append("不同卡牌用了完全相同的颗粒图案")

	# 曝光一致性：同一张图整体变亮 / 变暗后，烘焙结果必须落在同一亮度带附近。
	# 这一条守的是"42 张并排不像一套"的主要成因——AI 每张曝光都在飘。
	#
	# 用乘性增益模拟真实的光照差异（加法会把两端直接推爆到 0 和 1，
	# 那是信息丢失，任何自动色阶都补不回来——这一点写在断言阈值里）：
	# 只要求差距被压到原来的 1/3 以内，不要求归零。
	var base := _make_test_image(600, 400)
	var dark_img := _scale_exposure(base, 0.62)
	var bright_img := _scale_exposure(base, 1.45)
	var bd := CardArt.bake(dark_img, "exp")
	var bb := CardArt.bake(bright_img, "exp")
	var md := _median_luma(bd)
	var mb := _median_luma(bb)
	var src_gap := absf(_median_luma(dark_img) - _median_luma(bright_img))
	print("exposure before=%.3f after=%.3f (dark=%.3f bright=%.3f)"
		% [src_gap, absf(md - mb), md, mb])
	# 两个阈值管两件事：
	#   绝对阈值 0.08 —— 最终观感要接近（0.08 的亮度差在 106px 的小条上已经看不出来）；
	#   相对阈值 1/3  —— 机制要真的起作用，防止改坏了却因为图本身差距小仍然蒙混过关。
	# 1.45 倍增益下做不到归零：亮端像素已经贴到 1.0，那部分信息已经没了。
	if absf(md - mb) > 0.08:
		fails.append("曝光差 %.2f 的两张图烘焙后仍未对齐（中位亮度 %.3f vs %.3f）"
			% [src_gap, md, mb])
	if src_gap > 0.10 and absf(md - mb) > src_gap / 3.0:
		fails.append("自动色阶没起到作用：源差距 %.2f 只压到 %.2f"
			% [src_gap, absf(md - mb)])

	if fails.is_empty():
		print("BAKE_SELFTEST OK cases=%d" % cases.size())
		quit(0)
	else:
		print("BAKE_SELFTEST FAIL %s" % " / ".join(fails))
		quit(1)


## 造一张有明暗层次的彩色测试图（暖色渐变 + 几个亮块），模拟 AI 原图
func _make_test_image(w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var u := float(x) / float(w)
			var v := float(y) / float(h)
			img.set_pixel(x, y, Color(
				clampf(0.15 + u * 0.75, 0, 1),
				clampf(0.10 + v * 0.55, 0, 1),
				clampf(0.30 + (1.0 - u) * 0.40, 0, 1),
				1.0))
	# 一个亮方块 + 一个暗方块，保证有明确的高光与阴影
	for y in range(int(h * 0.25), int(h * 0.45)):
		for x in range(int(w * 0.55), int(w * 0.75)):
			img.set_pixel(x, y, Color(0.95, 0.93, 0.88))
	for y in range(int(h * 0.6), int(h * 0.8)):
		for x in range(int(w * 0.15), int(w * 0.35)):
			img.set_pixel(x, y, Color(0.04, 0.05, 0.06))
	return img


## 检查所有像素是否都落在 DARK→LIGHT 这条线上。
## 做法：分别用 R/G/B 反解 t，若三者一致，说明这个像素确实是端点色的插值。
## 返回 [最大残差, 最小亮度, 最大亮度]
func _check_duotone(img: Image) -> Array:
	var d := CardArt.DARK
	var l := CardArt.LIGHT
	var max_res := 0.0
	var lo := 1.0
	var hi := 0.0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var tr := (c.r - d.r) / (l.r - d.r)
			var tg := (c.g - d.g) / (l.g - d.g)
			var tb := (c.b - d.b) / (l.b - d.b)
			var res := maxf(maxf(absf(tr - tg), absf(tg - tb)), absf(tr - tb))
			max_res = maxf(max_res, res)
			var luma := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			lo = minf(lo, luma)
			hi = maxf(hi, luma)
	return [max_res, lo, hi]


func _luma_range(img: Image) -> Array:
	var lo := 1.0
	var hi := 0.0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var luma := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			lo = minf(lo, luma)
			hi = maxf(hi, luma)
	return [lo, hi]


func _same(a: Image, b: Image) -> bool:
	if a.get_size() != b.get_size():
		return false
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				return false
	return true


## 整张图乘一个增益，模拟"AI 这次的光比上次亮/暗"
func _scale_exposure(src: Image, k: float) -> Image:
	var out: Image = src.duplicate()
	for y in out.get_height():
		for x in out.get_width():
			var c := out.get_pixel(x, y)
			out.set_pixel(x, y, Color(
				clampf(c.r * k, 0.0, 1.0),
				clampf(c.g * k, 0.0, 1.0),
				clampf(c.b * k, 0.0, 1.0),
				c.a))
	return out


## 中位亮度：比均值稳，少量高光不会把它带跑
func _median_luma(img: Image) -> float:
	var vals: Array = []
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			vals.append(0.299 * c.r + 0.587 * c.g + 0.114 * c.b)
	vals.sort()
	return vals[vals.size() / 2]

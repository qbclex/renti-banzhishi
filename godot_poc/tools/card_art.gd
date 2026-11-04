extends RefCounted
## 卡牌插画的烘焙逻辑（纯函数，不碰文件系统，方便自测）。
##
## 为什么必须有这一步：AI 生图最大的问题不是单张难看，而是**42 张放一起不像一套**。
## 每张的光线、色温、对比度都在飘，逐张手调不现实。这里用固定参数把三件事
## 一次性对齐——裁切比例、双色调映射、颗粒。统一感来自「同一套数值」，
## 而不是来自「同一个画家」。

## 卡面插画区的 2 倍图。卡牌 150 宽、内容边距 9 → 插画条 132×60。
## 输出必须与显示尺寸同比（264×120 = 132×60 的 2 倍），否则运行时还要再横向裁一次，
## 白丢两侧的内容，而且多一道裁切就多一个"构图为啥变了"的疑问。
const OUT_W := 264
const OUT_H := 120

## 双色调端点：暗部直接取背景色（插画才能和卡面无缝衔接），
## 亮部取比图标中性色再亮一档的同族色——若用图标那档亮度，卡面会灰成一片没有层次。
const DARK := Color("#0B1E24")
const LIGHT := Color("#B6CACC")

const CONTRAST := 1.18
const GRAIN := 0.022
const SEED := 20261101

## 自动色阶：把每张图自身的 5% / 95% 亮度拉齐到固定目标。
##
## 这是"42 张像一套"的第二个机制。双色调统一了**色相**，但没统一**曝光**——
## 实测四张 AI 图：电话那张整体偏亮（中位亮度 ~0.55），椅子那张几乎全黑（~0.12），
## 并排摆在同一排里，一个像开了灯一个像关了灯。光靠调一个全局参数压不平，
## 因为偏差的方向不一样。必须先按各自的直方图归一到同一条基线。
const LEVEL_LO := 0.08
const LEVEL_HI := 0.92
const CLIP_PCT := 0.05

## 边缘压暗强度。这是"插画是卡面的一部分"和"插画是贴在卡上的一张相纸"的分界：
## 不压边时，4 张有图的卡在 6 张牌里亮得像开了灯，和占位条一比是两种东西。
## 左右压得多（贴卡侧边），上下压得少（中间要留住主体的层次）。
const VIG_X := 0.55
const VIG_Y := 0.40


## 原图 → 卡面插画条。返回新 Image，不改入参。
static func bake(src: Image, salt: String) -> Image:
	var img := cover_crop(src, OUT_W, OUT_H)
	img.resize(OUT_W, OUT_H, Image.INTERPOLATE_LANCZOS)
	img = auto_level(img)
	return duotone(img, salt)


static func luma_of(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


## 按直方图把亮度归一到 [LEVEL_LO, LEVEL_HI]。
## 用分位数而不是 min/max：AI 图常有一小块高光或死黑，min/max 会被它们带跑。
static func auto_level(img: Image) -> Image:
	var hist := []
	hist.resize(256)
	hist.fill(0)
	var w := img.get_width()
	var h := img.get_height()
	var total := w * h
	for y in h:
		for x in w:
			var b := int(clampf(luma_of(img.get_pixel(x, y)) * 255.0, 0.0, 255.0))
			hist[b] += 1

	var clip := int(total * CLIP_PCT)
	var lo_bin := 0
	var acc := 0
	for i in 256:
		acc += hist[i]
		if acc > clip:
			lo_bin = i
			break
	var hi_bin := 255
	acc = 0
	for i in range(255, -1, -1):
		acc += hist[i]
		if acc > clip:
			hi_bin = i
			break
	var lo := float(lo_bin) / 255.0
	var hi := float(hi_bin) / 255.0
	# 纯色图（lo == hi）时不能除零：原样返回，交给后面双色调处理
	var span := hi - lo
	if span < 0.02:
		return img

	# 系数预算好，避免每个像素重复算
	var gain := (LEVEL_HI - LEVEL_LO) / span
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var t := clampf((luma_of(c) - lo) * gain + LEVEL_LO, 0.0, 1.0)
			# 保持原图的相对明暗关系：按亮度差值整体平移，而不是把每个通道单独拉
			# （单独拉会让原本偏色的区域出现色偏，双色调前置灰时更明显）
			var k := t - luma_of(c)
			img.set_pixel(x, y, Color(
				clampf(c.r + k, 0.0, 1.0),
				clampf(c.g + k, 0.0, 1.0),
				clampf(c.b + k, 0.0, 1.0),
				c.a))
	return img


## 按目标比例居中裁切（cover）：不拉伸、不补边。
## 拉伸会把圆形压成椭圆，补边会露出黑框——这两种错误在卡面上都特别扎眼。
static func cover_crop(src: Image, tw: int, th: int) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	var want := float(tw) / float(th)
	var cw := w
	var ch := int(round(w / want))
	if ch > h:
		ch = h
		cw = int(round(h * want))
	var x0 := int((w - cw) / 2.0)
	var y0 := int((h - ch) / 2.0)
	return src.get_region(Rect2i(x0, y0, cw, ch))


## 去色 → 提对比 → 映射到两个端点色 → 加颗粒。
##
## 关键决定：**丢掉原图的颜色，只保留明暗**。
## 这是"42 张像一套"的真正原因——色相不再由 AI 的心情决定，
## 而且插画与 UI 用同一组端点色，视觉上天然同族。
static func duotone(img: Image, salt: String) -> Image:
	var rng := RandomNumberGenerator.new()
	# 用 id 做盐：每张颗粒图案不同（否则会有明显重复纹理），但每张自身可复现
	rng.seed = hash(salt) ^ SEED

	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var luma := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			luma = clampf((luma - 0.5) * CONTRAST + 0.5, 0.0, 1.0)
			# 轻微提亮暗部，避免大面积死黑把卡面压塌
			luma = pow(luma, 0.92)
			luma *= vignette(x, y, img.get_width(), img.get_height())
			var out := DARK.lerp(LIGHT, luma)
			var n := rng.randf_range(-GRAIN, GRAIN)
			img.set_pixel(x, y, Color(
				clampf(out.r + n, 0.0, 1.0),
				clampf(out.g + n, 0.0, 1.0),
				clampf(out.b + n, 0.0, 1.0),
				1.0))
	return img


## 边缘亮度系数：中心 1.0，四角最暗。
## 用三次方而不是线性，是为了让主体的 60% 中心区几乎不受影响，
## 只把外围压下去——线性压边会把整张图都变灰。
static func vignette(x: int, y: int, w: int, h: int) -> float:
	var nx := (float(x) + 0.5) / float(w)
	var ny := (float(y) + 0.5) / float(h)
	var fx := 1.0 - VIG_X * pow(absf(nx * 2.0 - 1.0), 3.0)
	var fy := 1.0 - VIG_Y * pow(absf(ny * 2.0 - 1.0), 3.0)
	return fx * fy

extends RefCounted
## 角色立绘的烘焙逻辑（纯函数，不碰文件系统，方便自测）。
##
## 和卡牌插画（`card_art.gd`）共用「自动色阶 + 双色调」这两个机制——
## 那是「42 张像一套」的真正原因，立绘必须沿用它，否则一张人脸就成了整个界面里
## 唯一有肤色的一块，看着像贴错图。但**参数不能照抄**，理由见下面每个常量。

## 显示尺寸 216×288（3:4）的 2 倍图。
## 比例必须和显示一致：立绘是**脸部**，纵向拉伸 5% 就会被人眼立刻发现
## （卡牌的静物没这个约束，所以那边可以用 cover_crop 随便裁）。
##
## 为什么是 216 而不是 168：168 宽时脸只有约 50px，四个表情在真实尺寸下
## **肉眼完全分不出**（对照表实测：只有歪头的"释然"能认出来）。脸宽要到
## 90px 以上，眼睑、嘴角、下巴角度这些差别才稳定可辨。
const OUT_W := 432
const OUT_H := 576

## 裁切窗口，按原图比例给。原图是 2:3（1024×1536），头肩只占中间一小块，
## 直接用 cover_crop 居中裁出来的脸只有画面的 1/6，缩到 168 宽后五官就糊了。
## 所以按「头肩像」重新取景：窗口高度取原图的 55%，位置由 `face_anchor` 自动定。
const CROP_H := 0.60

## 脸部重心落在窗口的这个高度上。0.42 是头肩像的常规构图：
## 上方留出额头和头发，下方留到胸线——正好也是简报里"档案照"该有的样子。
const FACE_AT := 0.44

## 重心只在上半幅里找。找全身会把深色衣服的零星亮部算进去，
## 而衣服在下方，一算就把窗口往下拽，头顶就切了。
const FACE_SCAN_H := 0.62

## 亮度权重下限：背景（约 0.1）和深色衣服都在它下面，不参与。
## 超过的部分按平方加权——平方让"脸"这种成片的亮区压过零星的亮边。
const FACE_LO := 0.30

## 双色调端点比卡牌**亮一档**（卡牌 LIGHT 是 #B6CACC）。
## 原因：卡牌是物件，亮部只是反光；人脸的高光是额头、鼻梁、颧骨——
## 用物件那档亮度，整张脸会压成一块灰，表情全没了。
const DARK := Color("#0B1E24")
const LIGHT := Color("#CBD8D6")

## 对比度和卡牌一样是 1.18，但**不做**卡牌那步 `pow(luma, 0.92)` 提亮暗部。
## 那步是为「避免大面积死黑把卡面压塌」；人脸上暗部就是眼窝、鼻影、下颌线，
## 提亮等于把五官抹平。
const CONTRAST := 1.12

## 颗粒更细：卡牌是 0.022，人脸上会读成噪点/皮肤粗糙。
const GRAIN := 0.014
const SEED := 20261102

## 边缘压暗只压纵向，横向几乎不压。
## 卡牌左右压得多是因为它两侧贴着卡边、要和卡面融合；立绘左右要接的是面板背景，
## 压暗会在脸旁边压出一圈可见的方框。
const VIG_X := 0.10
const VIG_Y := 0.34

## 色阶端点：上端收到 0.86 而不是 0.92。
## 人脸的高光（额头/鼻尖）比物件更容易过曝，收一点才留得住皮肤层次。
const LEVEL_LO := 0.10
const LEVEL_HI := 0.86
const CLIP_PCT := 0.02

const CardArt = preload("res://tools/card_art.gd")


## 原图 → 立绘。返回新 Image，不改入参。
static func bake(src: Image, salt: String) -> Image:
	var img := head_crop(src)
	img.resize(OUT_W, OUT_H, Image.INTERPOLATE_LANCZOS)
	img = auto_level(img)
	return duotone(img, salt)


## 按 CROP_* 取「头肩像」窗口，比例锁 3:4。
## 手写而不是复用 `CardArt.cover_crop`：那个是居中 cover，取景完全由原图比例决定，
## 而这里要的是「框住头」，是一个**构图决定**，不能交给数学。
## 按「脸部亮度重心」取头肩像，比例锁 3:4。
##
## 为什么不写死裁切坐标：五张原图分别生成，人物在画框里的位置各不相同
## （实测：一个偏左上、一个偏右、一个偏下），固定窗口会分别切掉头顶、右肩、下巴。
## 而手工给每张调一组坐标，下次重出又全部作废。
##
## 为什么不上人脸识别：项目里没有这种依赖，而且这里要的精度只是
## "把脸放到窗口的某个高度上"，不是"框出五官"——亮度重心够用，也不怕换画质。
static func head_crop(src: Image) -> Image:
	var w := float(src.get_width())
	var h := float(src.get_height())
	var ch := h * CROP_H
	var cw := ch * float(OUT_W) / float(OUT_H)
	if cw > w:
		cw = w
		ch = cw * float(OUT_H) / float(OUT_W)

	var a := face_anchor(src)
	var x0 := int(round(a.x - cw * 0.5))
	var y0 := int(round(a.y - ch * FACE_AT))
	# 头发不能被切。重心定位只管"脸在窗口里的高度"，管不了"这张脸本身有多大"——
	# 头像大的那几张，按 0.44 摆放会把额头顶出框（host2 实测切掉约 25px）。
	# 所以再量一次"亮区从哪一行开始"，窗口上沿不许高过它。
	var head_top := mass_top(src)
	if head_top >= 0.0:
		y0 = mini(y0, int(round(head_top - ch * 0.04)))
	x0 = clampi(x0, 0, int(w - cw))
	y0 = clampi(y0, 0, int(h - ch))
	return src.get_region(Rect2i(x0, y0, int(cw), int(ch)))


## 亮区最高的一行（占该图最大行权重的 6% 以上即算"开始了"）。
## 用行权重而不是逐个像素：头发边缘有零星亮点，逐像素会被噪点骗。
static func mass_top(src: Image) -> float:
	var w := src.get_width()
	var h := src.get_height()
	var y_max := int(h * FACE_SCAN_H)
	var step := 4
	var rows: Array = []
	rows.resize(y_max)
	var peak := 0.0
	for y in range(0, y_max, step):
		var acc := 0.0
		for x in range(0, w, step):
			var l := CardArt.luma_of(src.get_pixel(x, y))
			if l > FACE_LO:
				acc += (l - FACE_LO)
		rows[y] = acc
		peak = maxf(peak, acc)
	if peak <= 0.0:
		return -1.0
	var need := peak * 0.06
	for y in range(0, y_max, step):
		if float(rows[y]) >= need:
			return float(y)
	return -1.0


## 上半幅里"亮且成片"区域的加权重心，返回原图像素坐标。
static func face_anchor(src: Image) -> Vector2:
	var w := src.get_width()
	var h := src.get_height()
	var y_max := int(h * FACE_SCAN_H)
	var step := 4
	var sx := 0.0
	var sy := 0.0
	var sw := 0.0
	for y in range(0, y_max, step):
		for x in range(0, w, step):
			var l := CardArt.luma_of(src.get_pixel(x, y))
			if l <= FACE_LO:
				continue
			var k := (l - FACE_LO) * (l - FACE_LO)
			sx += x * k
			sy += y * k
			sw += k
	if sw <= 0.0:
		return Vector2(w * 0.5, h * FACE_SCAN_H * 0.5)
	return Vector2(sx / sw, sy / sw)


static func auto_level(img: Image) -> Image:
	var hist := []
	hist.resize(256)
	hist.fill(0)
	var w := img.get_width()
	var h := img.get_height()
	var total := w * h
	for y in h:
		for x in w:
			var b := int(clampf(CardArt.luma_of(img.get_pixel(x, y)) * 255.0, 0.0, 255.0))
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
	var span := hi - lo
	if span < 0.02:
		return img

	var gain := (LEVEL_HI - LEVEL_LO) / span
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var luma := CardArt.luma_of(c)
			var t := clampf((luma - lo) * gain + LEVEL_LO, 0.0, 1.0)
			var k := t - luma
			img.set_pixel(x, y, Color(
				clampf(c.r + k, 0.0, 1.0),
				clampf(c.g + k, 0.0, 1.0),
				clampf(c.b + k, 0.0, 1.0),
				c.a))
	return img


static func duotone(img: Image, salt: String) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(salt) ^ SEED
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var luma := CardArt.luma_of(c)
			luma = clampf((luma - 0.5) * CONTRAST + 0.5, 0.0, 1.0)
			luma *= vignette(x, y, w, h)
			var out := DARK.lerp(LIGHT, luma)
			var n := rng.randf_range(-GRAIN, GRAIN)
			img.set_pixel(x, y, Color(
				clampf(out.r + n, 0.0, 1.0),
				clampf(out.g + n, 0.0, 1.0),
				clampf(out.b + n, 0.0, 1.0),
				1.0))
	return img


static func vignette(x: int, y: int, w: int, h: int) -> float:
	var nx := (float(x) + 0.5) / float(w)
	var ny := (float(y) + 0.5) / float(h)
	var fx := 1.0 - VIG_X * pow(absf(nx * 2.0 - 1.0), 3.0)
	var fy := 1.0 - VIG_Y * pow(absf(ny * 2.0 - 1.0), 3.0)
	return fx * fy

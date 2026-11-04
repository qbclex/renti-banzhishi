extends RefCounted
## 背景烘焙逻辑（纯函数，不碰文件系统，方便自测）。
##
## 背景和卡牌/立绘的验收标准完全不同，所以这套参数**一条都不能照抄**：
##
## - 卡牌看「132×60 还认不认得出主体」，所以做双色调 + 局部裁切，把主体塞满；
## - 立绘看「216 宽还分不分得清四态」，所以要保住脸的层次，端点抬高、不提亮暗部；
## - 背景**不会被"看"，只会被"透"**：界面上 16px 外边距 + 12px 面板缝隙，
##   可见面积实测约 12%，而且是被切成一格一格的细条。
##
## 于是背景唯一要满足的是一条亮度曲线：
##   1. 中心区必须**比面板更暗**（面板 BG1=#071318 的 luma≈0.06），否则缝隙会亮成
##      一张发光的网格，比纯黑底更脏；
##   2. 四边必须收敛到 #03080A，因为 16px 外边距直接贴着屏幕边缘，接不上就是一圈明显的框；
##   3. 亮部要留极少数（荧光灯管那一小块），那是"这里有光"的唯一线索，但不能成片。
##
## 原图实测（`tools/bg_probe.gd`）：mean=0.109 p50=0.073 p90=0.224 p99=0.533，
## 中心格平均 0.207——正好是面板的 3 倍亮。不压这一刀，接上去就是亮网格。

## 输出尺寸。界面是 1280×820，出 1.5 倍（1920×1230）而不是 2 倍，两个理由：
## 1. 背景是**铺满 + 压到近黑**的图，没有任何需要数像素的细节，1.5 倍放大后
##    在 125%/150% DPI 下也看不出软；
## 2. 烘焙是逐像素 GDScript，2 倍图（420 万像素）实测要跑 2 分半，改一次参数等太久，
##    不利于迭代——这张图的全部价值都在参数曲线上。
## 比例锁 1280:820：背景是**铺满**的，比例不对就得裁掉画面内容，
## 而原图构图（台面在下、灯管在上）两头都是有用的。
const OUT_W := 1920
const OUT_H := 1230

## 压暗曲线：out = GAIN * pow(luma, GAMMA)。
##
## **第一版这里定反了**，值得记下来：当时想的是"背景必须比面板暗，否则缝隙亮成网格"，
## gamma 1.35 / gain 0.42 把中位数压到 0.012，烘出来是一片纯黑——接上去和原来的
## ColorRect 没有任何区别，等于白做。因为**面板本身已经很暗了**（BG1=#071318，luma 0.060），
## 比它更暗只剩黑。背景要提供的是"面板浮在暗处"的空间感，所以它必须比面板
## **稍亮一点**，让缝隙里透出来的是光，不是更深的黑。
##
## 现在的定标是照着原图的实测分位数反解的（原图 p50=0.073 p90=0.224 p99=0.533 max=0.959）：
##
## | 原图 | 烘焙后 | 界面上的角色 |
## |---|---|---|
## | p01 0.026 | 0.020 | 四边（暗角后）< BG0，从边缘消失 |
## | p50 0.073 | **0.045** | 大面积暗部，比 BG0 亮一档 |
## | p90 0.224 | **0.110** | 缝隙里能看出结构，与 BG2 相当 |
## | p99 0.533 | 0.218 | 灯管周围的光晕 |
## | max 0.959 | 0.348 | 灯管本体，留一点高光但不白 |
##
## GAMMA < 1 是**提亮暗部**，和名字相反但它是对的：原图本身 50% 的像素就接近黑，
## 不再抬一把，中间调全部塌进 0.01 以下。
const GAMMA := 0.795
const GAIN := 0.42

## 双色调端点。低端 #02070A 比 Kit.BG0(#03080A) 还暗一档：
## 边缘经过暗角后必须**低于**界面底色，否则四边会浮出一条亮边（实测第一版就是这样）。
## 高端是冷青白，取荧光灯的颜色，不用纯白——纯白在暗环境里会读成"过曝"。
const DARK := Color("#02070A")
const LIGHT := Color("#8AA8A2")

## 暗角。指数 2.6 让过渡压在外圈 15% 内：中心的明暗结构不能被暗角吃掉。
## VIG 0.55（第一版是 0.92，四边直接归零）——归零之后四角是"比屏幕底色更黑的一块"，
## 在 16px 外边距那一圈反而读成一条脏边。现在只压到 BG0 附近就停手。
const VIG := 0.55
const VIG_POW := 2.6

## 颗粒 0.010：背景面积大，颗粒稍重就会读成"脏"。卡牌 0.022、立绘 0.014。
const GRAIN := 0.010
const SEED := 20261102

## ---------------------------------------------------------------- 水印
##
## 本地出图端会在右下角烤死两行「AI生成 / WORKBUDDY」。卡牌那批是靠**居中裁切顺手削掉**的
## （3:2 → 2:1 裁掉上下各 12.5%，水印正好在最下沿），那是运气。背景是满屏铺、几乎不裁，
## 水印一定会留下来——实测在成品图底部 4.5%，而界面右下角 216px 宽那一块正是**没有面板**
## 的可见背景区，两行字会原样露出来。
##
## 处理方式是**在原图上克隆覆盖**：把水印框正上方同样高的一条贴下来。选竖向而不是横向，
## 是因为竖向两侧的暗角、地面渐变都是连续的，贴上去接缝看不出来；横向会跨过柜脚。
##
## 这条只对「水印落在无内容的暗角」成立。如果某张背景的右下角正好有主体，
## 不能靠这个函数救——应该换构图重出。`bake` 里会先检查这块区域的亮度，
## 太亮就报警（见 `MARK_MAX_LUMA`）。
const MARK_X := 0.900
const MARK_Y := 0.912
## 水印框的右/下边界用 1.0（贴边），但要留 4px 余量防止抗锯齿残留
const MARK_PAD := 0.004
## 克隆源相对水印框的竖直偏移（按图高比例）。0.085 刚好跨过两行字的高度。
const MARK_SHIFT := 0.085
## 遮盖前这块区域的平均亮度上限。超过说明右下角有内容，克隆会抹掉东西。
const MARK_MAX_LUMA := 0.16

## 取景：不做全幅 cover，而是**放大再取**，并把取景窗的中心按图调到合适高度。
##
## 为什么每个 id 要单独定：界面能看见背景的地方只有「四周一圈」——顶栏上方一条窄带、
## 左右各 16px、底部一条窄带。居中的大块被模态弹窗/面板盖死。所以背景里**最亮的那点**
## 必须落到这条「顶栏上方的窄带」里（画面顶部约 8–12% 处），否则光就被弹窗吃掉了，
## 背景退化成一片均匀黑，等于没做。
##
## - 护理站：灯在天花板，原图顶部就是亮处，1.15× + 中心 0.44 正好把灯留在顶部窄带。
## - 走廊：灯在画面正中（一点透视的灭点），必须放大到 1.6× 并把取景窗下移到 0.64，
##   才能把灭点灯挤进顶部窄带；代价是放弃了下半截地板，但地板在窄带里本来也看不见。
## - 病房：窗在偏上（约 0.33），1.6× + 中心 0.57 把窗抬进顶部窄带。
const ZOOM := 1.15
## 取景窗中心落在原图的这个高度。0.44 让台面下移约 9% 画面高。
const ANCHOR_Y := 0.44

## 逐图取景覆盖。键是资产 id，缺省回退到上面的全局常量。
## 数值是按「把该图最亮的灭点/窗挤进顶部窄带」反算的（见各条注释）。
const CROP := {
	"bg_nurse_station": {"zoom": 1.15, "anchor_y": 0.44},
	"bg_corridor_night": {"zoom": 1.60, "anchor_y": 0.64},
	"bg_ward": {"zoom": 1.60, "anchor_y": 0.57},
}

const CardArt = preload("res://tools/card_art.gd")


## 原图 → 背景。返回新 Image，不改入参。
static func bake(src: Image, salt: String, id: String = "") -> Image:
	var img: Image = src.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	img = strip_mark(img)
	img = cover(img, id)
	img.resize(OUT_W, OUT_H, Image.INTERPOLATE_LANCZOS)
	return duotone(img, salt)


## 抹掉右下角的出图水印。返回新 Image；没有水印时行为等价于克隆一块暗部。
static func strip_mark(src: Image) -> Image:
	var img: Image = src.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var pad := int(h * MARK_PAD)
	var x0 := int(w * MARK_X)
	var y0 := int(h * MARK_Y)
	var x1 := w - pad
	var y1 := h - pad
	var bh := y1 - y0
	var ys := y0 - int(h * MARK_SHIFT)
	if ys < 0:
		return img
	# 羽化带：接缝上下各 FEATHER 行做线性混合，硬贴会留一条水平硬边
	var feather := maxi(2, int(h * 0.006))
	# 亮度守门在烘焙日志里由 `bake_bg.gd` 报出来，这里只做覆盖
	for y in range(y0, y1):
		var sy := ys + (y - y0)
		if sy < 0 or sy >= h:
			sy = clampi(sy, 0, h - 1)
		# 顶部 feather 行与源区的对应行做渐变，避免"贴块"的硬边
		var k := 1.0
		if y - y0 < feather:
			k = float(y - y0) / float(feather)
		for x in range(x0, x1):
			var dst := img.get_pixel(x, y)
			var srcp := img.get_pixel(x, sy)
			img.set_pixel(x, y, dst.lerp(srcp, k))
	# 水平方向也羽化左边界：克隆块与左侧原图之间不能有一条竖缝
	var fade := maxi(2, int(w * 0.004))
	for y in range(y0, y1):
		var sy := clampi(ys + (y - y0), 0, h - 1)
		for x in range(x0, mini(x0 + fade, x1)):
			var k := float(x - x0) / float(fade)
			var dst := img.get_pixel(x, y)
			var srcp := img.get_pixel(x, sy)
			img.set_pixel(x, y, dst.lerp(srcp, k))
	return img


## 水印区域的原始平均亮度，用来判断"这块到底是暗角还是有内容"。
## `bake_bg.gd` 拿它和 MARK_MAX_LUMA 比，超了就打警告。
static func mark_area_luma(src: Image) -> float:
	var w := src.get_width()
	var h := src.get_height()
	var x0 := int(w * MARK_X)
	var y0 := int(h * MARK_Y)
	var acc := 0.0
	var n := 0
	for y in range(y0, h - int(h * MARK_PAD), 3):
		for x in range(x0, w - int(h * MARK_PAD), 3):
			acc += CardArt.luma_of(src.get_pixel(x, y))
			n += 1
	return acc / float(maxi(n, 1))


## 取景窗：按 ZOOM 放大后居中偏上取，比例锁 OUT_W:OUT_H。
## `id` 用于查 CROP 覆盖；查不到就用全局 ZOOM/ANCHOR_Y。
static func cover(src: Image, id: String = "") -> Image:
	var z := ZOOM
	var ay := ANCHOR_Y
	if CROP.has(id):
		z = float(CROP[id]["zoom"])
		ay = float(CROP[id]["anchor_y"])
	var w := float(src.get_width())
	var h := float(src.get_height())
	var want := float(OUT_W) / float(OUT_H)
	var cw := w / z
	var ch := cw / want
	if ch > h:
		ch = h
		cw = ch * want
	var x0 := int(round((w - cw) * 0.5))
	var y0 := int(round(h * ay - ch * 0.5))
	x0 = clampi(x0, 0, int(w - cw))
	y0 = clampi(y0, 0, int(h - ch))
	return src.get_region(Rect2i(x0, y0, int(cw), int(ch)))


static func duotone(img: Image, salt: String) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(salt) ^ SEED
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var l := CardArt.luma_of(img.get_pixel(x, y))
			var t := GAIN * pow(clampf(l, 0.0, 1.0), GAMMA)
			t *= vignette(x, y, w, h)
			var out := DARK.lerp(LIGHT, clampf(t, 0.0, 1.0))
			var n := rng.randf_range(-GRAIN, GRAIN)
			img.set_pixel(x, y, Color(
				clampf(out.r + n, 0.0, 1.0),
				clampf(out.g + n, 0.0, 1.0),
				clampf(out.b + n, 0.0, 1.0),
				1.0))
	return img


## 四边归零的暗角。用「到最近边的归一化距离」而不是椭圆距离：
## 屏幕是长方形，椭圆暗角在长边会收得不够，四角反而比上下边亮。
static func vignette(x: int, y: int, w: int, h: int) -> float:
	var nx := (float(x) + 0.5) / float(w)
	var ny := (float(y) + 0.5) / float(h)
	var dx := minf(nx, 1.0 - nx) * 2.0
	var dy := minf(ny, 1.0 - ny) * 2.0
	var d := minf(dx, dy)
	return clampf(1.0 - VIG * pow(1.0 - d, VIG_POW), 0.0, 1.0)

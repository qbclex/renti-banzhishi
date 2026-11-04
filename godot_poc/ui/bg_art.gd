extends RefCounted
## 背景的运行时读取层（对应 `assets/bg/`）。
##
## 和 `Icons`/`CardArt`/`CharArt` 同一套路：运行时 `Image.load_from_file`，不走 `load()`。
##
## 但这里**不做缓存**，只缓存一张。理由：背景是全屏底图，同一时刻只会显示一张，
## 而一张 1920×1230 的 RGBA 纹理是 9.4 MB 显存——三张全缓存就是 28 MB，
## 为了一个"切换场景时不卡 30ms"的收益不值。切走时旧的会被释放。

const DIR := "res://assets/bg/"
const Kit = preload("res://ui/ui_kit.gd")

## 优先 webp（烘焙默认输出），png 作为兼容保留。
## 背景是唯一用有损格式的资产，理由写在 `tools/bake_bg.gd` 的 `OUT_EXT` 上方：
## 大面积暗部 + 全图颗粒，PNG 压不动，而这张图只从面板缝隙里露出 12%。
## 加载器两种都认，是为了"烘焙脚本换了格式但旧图还没重烘"时不会突然整屏变黑。
const EXTS := [".webp", ".png"]

## 清单与 `tools/bake_bg.gd` 的 IDS 一致。
const IDS := ["bg_nurse_station", "bg_corridor_night", "bg_ward"]

## 界面基准尺寸。背景按 cover 铺（等比放大到盖满），而不是拉伸——
## 拉伸会把 1920×1230 拉成 1280×820 时纵向压 0.4%，看不出；
## 但一旦玩家把窗口拖成别的比例（`window/size/resizable=true`），拉伸就会把房间拉变形。
const BASE_W := 1280.0
const BASE_H := 820.0

static var _key := ""
static var _tex: Texture2D = null


## 返回磁盘上真实存在的那个路径，找不到返回 ""。
##
## 注意 `String(e)` 不能省：`EXTS` 是无类型 `Array`，`for` 出来的 `e` 是 Variant，
## 直接 `var p := DIR + id + e` 会因为"推断不出类型"整文件编译失败——
## 而失败的方式很不直观：Godot 只是把 `BgArt` 变成一个空脚本，于是主界面里
## 每一处 `BgArt.xxx()` 都报 "Nonexistent function"，看起来像函数没写，
## 实际是上面这一行类型没标。
static func find(id: String) -> String:
	for e in EXTS:
		var p: String = DIR + id + String(e)
		if Kit.asset_exists(p):
			return p
	return ""


static func has(id: String) -> bool:
	return find(id) != ""


## 缺失时返回 null。调用方**必须**准备好 null 的情况：背景是可选的，
## 没有背景就该退回 `Kit.BG0` 纯色底，而不是显示一块黑框或者报错。
static func tex(id: String) -> Texture2D:
	if id == _key:
		return _tex
	var p := find(id)
	_tex = null if p == "" else Kit.texture_at(p)
	_key = id
	return _tex


static func release() -> void:
	_tex = null
	_key = ""


## 主界面用哪张。写成函数而不是常量，方便以后按章节/场景切换。
##
## 现在：终章/结局用病房，章节过场用走廊夜景，其余用护理站。
## `intro` 优先级高于 `ending` 没有意义（过场不会和结局同时出现），
## 但这里仍按「ending 先判」的顺序写，和 `_refresh_overlay` 的 want 优先级一致。
static func scene_for(_chapter: int, ending: bool = false, intro: bool = false) -> String:
	if ending:
		return "bg_ward"
	if intro:
		return "bg_corridor_night"
	return "bg_nurse_station"

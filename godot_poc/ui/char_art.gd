extends RefCounted
## 角色立绘的运行时读取层（对应 `assets/chars/`）。
##
## 和 `Icons`（`ui/icon.gd`）同一个套路：**运行时用 `Image.load_from_file` 读 png，
## 不用 `load()`**。`load()` 要求资源已被编辑器导入（`.godot/imported/`），
## 而这个项目是新图直接丢进目录、跑一次烘焙脚本就要能显示，中间没有"打开编辑器"这一步。
##
## 图片进内存后按 (宿主, 表情) 缓存成 ImageTexture——一张 432×576 的图解码要几十毫秒，
## 而简报/结算/结局会在同一次会话里反复弹，不缓存就会每次卡一下。

const DIR := "res://assets/chars/"
const Kit = preload("res://ui/ui_kit.gd")

## 四个状态，顺序即「情绪从收起到外放」。
## 顺序有实际用途：`char_sheet.gd` 按它排对照表，四张差分必须紧挨着才能判够不够。
const EXPRS := ["calm", "tired", "alert", "relief"]

## 有立绘的宿主编号。发行自检按它逐个验，别在自检里另写一份 range(1,6)——
## 加一位宿主时改这里就够了，漏改的后果是"新宿主没图也能过闸门"。
const HOSTS := [1, 2, 3, 4, 5]

## 与 `tools/char_art.gd` 的 OUT_W/OUT_H 是 2:1 关系，改一处必须改另一处。
const W := 216
const H := 288

const LABELS := {
	"calm": "平静",
	"tired": "疲惫",
	"alert": "警觉",
	"relief": "释然",
}

static var _cache := {}


static func path(host_no: int, expr: String) -> String:
	return DIR + "host%d_%s.png" % [host_no, expr]


static func has(host_no: int, expr: String) -> bool:
	return Kit.asset_exists(path(host_no, expr))


## 缺失时返回 null，由调用方决定「不显示立绘」而不是显示一个空框。
## 21 张图里少一张就整块塌掉，比"这一章没有立绘"糟糕得多。
static func tex(host_no: int, expr: String) -> Texture2D:
	var key := "%d_%s" % [host_no, expr]
	if _cache.has(key):
		return _cache[key]
	var t := Kit.texture_at(path(host_no, expr))
	if t == null:
		return null
	_cache[key] = t
	return t


static func label_of(expr: String) -> String:
	return str(LABELS.get(expr, ""))

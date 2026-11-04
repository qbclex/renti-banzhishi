extends RefCounted
## 玩家设置：音量、窗口、分辨率。
##
## 存在 user://settings.cfg，和存档 user://save.json 分开 —— 换存档不该把
## 音量重置，反过来重装也不该丢进度。
##
## 这里只管「读写 + 应用」，界面在 ui/main_ui.gd 的 _ov_settings()。

const PATH := "user://settings.cfg"

## 音量都是 0..1 的线性值，落盘也存线性：玩家看到的滑块位置就是存的值，
## 中间不引入 dB，避免「拖到一半、重开变成另一个位置」。
const DEFAULTS := {
	"master": 0.85,
	"sfx": 0.72,
	"music": 0.42,
	"fullscreen": false,
	"res_index": 0,
}

## 可选分辨率。第一项必须等于 project.godot 的设计分辨率：
## 整套 UI 是按 1280×820 手排的，其它尺寸只是等比缩放（stretch=canvas_items）。
## 1280×800 单独留着，因为 Steam Deck 就是它。
const RESOLUTIONS := [
	Vector2i(1280, 820),
	Vector2i(1280, 800),
	Vector2i(1440, 900),
	Vector2i(1600, 1000),
	Vector2i(1920, 1080),
]


static func defaults() -> Dictionary:
	return DEFAULTS.duplicate()


static func load_settings() -> Dictionary:
	var d := defaults()
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return d
	for k in d.keys():
		var v = cf.get_value("main", k, null)
		# 类型也要对：手改过 cfg 的人可能把 "0.8" 写成字符串
		if v != null and typeof(v) == typeof(d[k]):
			d[k] = v
	return d


static func save_settings(s: Dictionary) -> void:
	var cf := ConfigFile.new()
	for k in s.keys():
		cf.set_value("main", k, s[k])
	cf.save(PATH)


## 窗口模式 + 分辨率。无头（CI/巡演）时直接跳过：
## 那几个 DisplayServer 调用在 headless 驱动下要么无效要么报错。
static func apply_display(s: Dictionary) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if bool(s.get("fullscreen", false)):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	var idx: int = clampi(int(s.get("res_index", 0)), 0, RESOLUTIONS.size() - 1)
	var size: Vector2i = RESOLUTIONS[idx]
	# 用「可用区域」而不是整屏：整屏会把窗口压到任务栏底下，
	# 底部的「完成」按钮永远点不到。
	# 而且必须夹到屏幕内——列表里有 1920×1080，1366×768 的笔记本选了它，
	# 窗口会比屏幕大，设置面板直接卡在屏幕外面出不来。
	var usable: Rect2i = DisplayServer.screen_get_usable_rect()
	if usable.size.x > 0 and usable.size.y > 0:
		size.x = mini(size.x, usable.size.x)
		size.y = mini(size.y, usable.size.y)
	DisplayServer.window_set_size(size)
	# 居中：换分辨率后窗口会留在原地，玩家会以为「变小了、卡在角落」
	var origin: Vector2i = usable.position if usable.size.x > 0 else Vector2i.ZERO
	DisplayServer.window_set_position(origin + (usable.size - size) / 2)


static func resolution_label(idx: int) -> String:
	var r: Vector2i = RESOLUTIONS[clampi(idx, 0, RESOLUTIONS.size() - 1)]
	return "%d × %d" % [r.x, r.y]

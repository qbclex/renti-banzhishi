extends RefCounted
## 存档槽（单槽位 POC）
##
## 只做三件事：把引擎快照写成文件、读回来、报时间戳。
## 序列化用 var_to_str / str_to_var 而不是 JSON —— JSON 往返会把 int 读成 float，
## 而引擎里 clock、刻数、血量全是整数运算，一旦变浮点就会在 range()/%d 上崩。
##
## 路径固定在 user://（Windows 下是 %APPDATA%\Godot\app_userdata\人体值班室），
## 不写到 res:// 里，避免打包后（只读目录）存档失败。

const DIR := "user://save"
const SLOT_MAIN := "user://save/slot1.sav"
## 自动化巡演专用的假槽位。
##
## `--autoplay` / `--shot` 每跑一班都会自动存档，如果直接写 slot1，
## 那「跑一次巡演」等于「把玩家的存档冲掉」——开发期最典型的事故是：
## 想验证「读回真实存档继续玩」，结果每次准备数据都被自己上一次的巡演盖掉。
## 所以自动化模式一律写这个文件，玩家的 slot1 完全不碰。
const SLOT_PROBE := "user://save/_probe.sav"
const VERSION := 1

static var SLOT := SLOT_MAIN


## 切到假槽位（只有自动化模式会调）。
static func use_probe_slot() -> void:
	SLOT = SLOT_PROBE


static func path() -> String:
	return SLOT


static func exists() -> bool:
	return FileAccess.file_exists(SLOT)


static func _ensure_dir() -> int:
	if DirAccess.dir_exists_absolute(DIR):
		return OK
	return DirAccess.make_dir_recursive_absolute(DIR)


## 写入快照；ui 是界面层的附加状态（选中工单、换签模式），引擎不认识它。
static func write_slot(state: Dictionary, ui: Dictionary = {}) -> bool:
	var err := _ensure_dir()
	if err != OK:
		push_error("存档目录建不出来：%s（err=%d，实际路径 %s）"
			% [DIR, err, ProjectSettings.globalize_path(DIR)])
		return false
	var payload := {
		"v": VERSION,
		"at": Time.get_datetime_string_from_system(false, false),
		"state": state,
		"ui": ui,
	}
	var f := FileAccess.open(SLOT, FileAccess.WRITE)
	if f == null:
		# 这里失败通常只有两种：目录不可写（比如装在 Program Files 下被
		# UAC 拦），或者 user:// 根本没有落到用户 AppData。报出真实路径，
		# 免得用户看到"存不上档"却没线索。
		push_error("存档写不进去：%s（err=%d，实际路径 %s）"
			% [SLOT, FileAccess.get_open_error(), ProjectSettings.globalize_path(SLOT)])
		return false
	f.store_string(var_to_str(payload))
	f.close()
	return true


## 读回存档；不存在/版本不符/结构损坏都返回空字典（调用方按「无档」处理）。
static func read_slot() -> Dictionary:
	if not exists():
		return {}
	var f := FileAccess.open(SLOT, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var v = str_to_var(text)
	if typeof(v) != TYPE_DICTIONARY:
		return {}
	if int(v.get("v", 0)) != VERSION:
		return {}
	if typeof(v.get("state")) != TYPE_DICTIONARY:
		return {}
	if typeof(v.get("ui", {})) != TYPE_DICTIONARY:
		v["ui"] = {}
	return v


## 存档时间戳（给界面显示「上次：2026-11-01 13:20:00」）
static func stamp() -> String:
	var v := read_slot()
	return str(v.get("at", ""))


static func erase() -> void:
	if exists():
		DirAccess.remove_absolute(SLOT)

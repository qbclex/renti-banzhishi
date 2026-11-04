extends RefCounted
## 音频总线：Master / Music / SFX。
##
## 为什么要在运行时建、而不是放一个 default_bus_layout.tres：
## 总线只有三条、关系固定，代码里建更不容易被「编辑器里手滑改坏」；
## 而且巡演/测试进程也能确定性地拿到同样的总线。
##
## 分工：
##   Master —— 总音量，玩家最终听到的上限
##   Music  —— 背景音乐（audio/bgm.gd）
##   SFX    —— 程序化音效（audio/sfx.gd）
## 三条各自独立，玩家才能「关掉音乐但留着判定音」。

const MASTER := "Master"
const MUSIC := "Music"
const SFX := "SFX"

static var _ready := false


static func ensure_buses() -> void:
	if _ready:
		return
	# Master 是 0 号总线，永远存在，只需要保证不静音
	for name in [MUSIC, SFX]:
		if AudioServer.get_bus_index(name) < 0:
			var i := AudioServer.bus_count
			AudioServer.add_bus(i)
			AudioServer.set_bus_name(i, name)
			AudioServer.set_bus_send(i, MASTER)
	_ready = true


## 线性 0..1 → dB。0 直接给 -60 dB（而不是 -inf）：
## -inf 在 Godot 里会被当成「保持原值」，静音反而失效。
static func to_db(v: float) -> float:
	var x := clampf(v, 0.0, 1.0)
	if x <= 0.005:
		return -60.0
	return linear_to_db(x)


static func apply(s: Dictionary) -> void:
	ensure_buses()
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(MASTER), to_db(float(s.get("master", 0.85))))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(MUSIC), to_db(float(s.get("music", 0.42))))
	# SFX 的音量在 Sfx 里按 player 应用（见 audio/sfx.gd），这里只保证总线不额外衰减
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(SFX), 0.0)

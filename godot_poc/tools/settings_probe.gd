extends SceneTree

## 设置系统的回归探针：只测「存档 → 读回 → 应用」这条链，不截图。
##
## 为什么要独立探针而不是塞进 test_godot_bg：
## 设置全部是 static 函数 + user:// 文件，用 SceneTree 脚本跑最快（毫秒级），
## 而 UI 集成测试要起整个窗口、跑完整巡演，几十秒起步。
##
## 输出一行 SETTINGS_OK，测试脚本按行断言。

const AppSettings = preload("res://ui/app_settings.gd")
const AudioMix = preload("res://ui/audio_mix.gd")


func _init():
	var ok := true

	# 1) 默认值自洽：三项音量都在 0..1，分辨率下标合法
	var d: Dictionary = AppSettings.defaults()
	for k in ["master", "sfx", "music"]:
		var v: float = float(d.get(k, -1.0))
		if v < 0.0 or v > 1.0:
			print("BAD volume ", k, "=", v)
			ok = false
	if int(d.get("res_index", -1)) < 0 or int(d["res_index"]) >= AppSettings.RESOLUTIONS.size():
		print("BAD res_index")
		ok = false

	# 2) 写进去、读回来要一模一样（浮点数按 0.01 步长存，不该有精度漂移）
	var probe := {
		"master": 0.31, "sfx": 0.47, "music": 0.08,
		"fullscreen": true, "res_index": 3,
	}
	AppSettings.save_settings(probe)
	var back: Dictionary = AppSettings.load_settings()
	for k in probe.keys():
		if typeof(probe[k]) == TYPE_FLOAT:
			if absf(float(back[k]) - float(probe[k])) > 0.001:
				print("BAD roundtrip ", k, " ", probe[k], " -> ", back[k])
				ok = false
		elif back[k] != probe[k]:
			print("BAD roundtrip ", k, " ", probe[k], " -> ", back[k])
			ok = false

	# 3) 总线：建完之后 Music / SFX 都在，且能按设置改音量
	AudioMix.ensure_buses()
	var mi := AudioServer.get_bus_index("Music")
	var si := AudioServer.get_bus_index("SFX")
	if mi < 0 or si < 0:
		print("BAD bus missing music=", mi, " sfx=", si)
		ok = false
	else:
		AudioMix.apply({"master": 0.5, "music": 0.25, "sfx": 0.5})
		var db := AudioServer.get_bus_volume_db(mi)
		if absf(db - linear_to_db(0.25)) > 0.2:
			print("BAD music bus db=", db)
			ok = false
		# 0 必须是 -60dB 而不是 -inf：-inf 会被当成「不改」而静音失败
		if absf(AudioMix.to_db(0.0) + 60.0) > 0.001:
			print("BAD zero db=", AudioMix.to_db(0.0))
			ok = false

	# 4) 收尾：别把测试值留在玩家机器上
	DirAccess.remove_absolute(ProjectSettings.globalize_path(AppSettings.PATH))
	print("SETTINGS_OK ", ok)
	quit(0 if ok else 1)

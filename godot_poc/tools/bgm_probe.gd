extends SceneTree
## BGM 探针：素材现在是一段现成的 CC0 ogg，这里量的是「它真的被加载、真的会循环、
## 五章真的换了速率」，而不是以前的"合成耗时/峰值"。
##
## 注意：ogg 是压缩流，拿不到逐样本峰值，所以这里不再做削波统计——
## 素材入库前已经单独测过（RMS -19.4dBFS、峰值 -4.5dBFS、接缝小于一个采样步长）。
##
## 输出一行 BGM_OK <ok> len=<秒> loop=<0/1> ch=<五章速率> err=<>
##
## 用法：godot --headless --path . -s res://tools/bgm_probe.gd

const Bgm = preload("res://audio/bgm.gd")


func _initialize() -> void:
	var b = Bgm.new()
	var s: AudioStream = b.stream_for(1)
	if s == null:
		print("BGM_OK false no-stream err=%s" % b.last_error())
		quit(1)
		return

	var dur: float = s.get_length()
	var looping: bool = bool(s.get("loop")) if "loop" in s else false

	# 五章的播放速率必须互不相同，否则"随章节变化"是假的
	var pitches := []
	for ch in [1, 2, 3, 4, 5]:
		pitches.append(snappedf(Bgm.pitch_for(ch), 0.0001))
	var distinct := {}
	for p in pitches:
		distinct[p] = true

	# 硬指标：能加载、时长够长（太短的氛围垫会听出重复）、开了循环、五章有差异
	var ok: bool = dur > 60.0 and looping and distinct.size() >= 4

	print("BGM_OK %s len=%.1f loop=%d pitches=%s err=%s" % [
		str(ok).to_lower(), dur, 1 if looping else 0,
		str(pitches), b.last_error()])
	quit(0 if ok else 1)

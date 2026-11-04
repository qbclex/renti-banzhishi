extends SceneTree
## 音效探针：证明「配方 → PCM」这条路真的产出了有声音的波形。
##
## 听不到声音也要能验证：每条配方渲染出来的采样数必须等于 dur × 22050，
## 且峰值不能接近 0（否则就是一条静音，运行时会「播放成功但没声」）。
## 顺带打印峰值排序，方便日后调平衡时一眼看出谁太响。
##
## 用法：godot --headless --path . --script tools/audio_probe.gd

const D = preload("res://data.gd")
const Sfx = preload("res://audio/sfx.gd")

const MIN_PEAK := 800        # 16bit 满量程 32767，低于 800 基本听不见


func _initialize() -> void:
	var s := Sfx.new()
	var names: Array = D.SOUNDS.keys()
	names.sort()
	var fails := []
	var rows := []
	var total_ms := 0.0
	for name in names:
		var spec = D.SOUNDS[name]
		var w: AudioStreamWAV = s.render(spec)
		var data: PackedByteArray = w.data
		var n: int = data.size() / 2
		var peak := 0
		for i in range(n):
			var v := absi(data.decode_s16(i * 2))
			if v > peak:
				peak = v
		var want := int(float(spec.get("dur", 0.2)) * 22050.0)
		var ok_len: bool = absi(n - want) <= 1
		var ok_peak: bool = peak >= MIN_PEAK
		var ok_rate: bool = w.mix_rate == 22050 and w.format == AudioStreamWAV.FORMAT_16_BITS
		if not (ok_len and ok_peak and ok_rate):
			fails.append("%s(len=%d/%d peak=%d rate=%d)" % [name, n, want, peak, w.mix_rate])
		rows.append("%s pk=%d %.0fms" % [name, peak, float(n) / 22.05 * 0.001 * 1000.0])
		total_ms += float(n) / 22050.0 * 1000.0

	var ok: bool = fails.is_empty() and names.size() >= 12
	print("AUDIO_PROBE %s n=%d total_ms=%.0f fails=%d"
		% ["OK" if ok else "FAIL", names.size(), total_ms, fails.size()])
	if ok:
		print("AUDIO_PEAKS %s" % " | ".join(rows))
	else:
		print("AUDIO_FAILS %s" % " ; ".join(fails))
	quit(0 if ok else 1)

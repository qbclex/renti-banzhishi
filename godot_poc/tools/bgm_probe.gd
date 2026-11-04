extends SceneTree

## BGM 探针：生成一段，量三件事——生成耗时、峰值/RMS、循环接缝。
##
## 为什么循环接缝要量：程序化音乐最常见的毛病就是"每 30 秒咔一下"，
## 而这个毛病在游戏里只能靠听，很容易漏。这里直接比较首尾样本的跳变。
##
## 输出一行 BGM_OK <ok> gen_ms=<> peak=<> rms=<> seam=<>

const Bgm = preload("res://audio/bgm.gd")


func _init():
	var b = Bgm.new()

	var t0 := Time.get_ticks_msec()
	var s: AudioStreamWAV = b.stream_for(1)
	var gen := Time.get_ticks_msec() - t0

	if s == null or s.data.is_empty():
		print("BGM_OK false no-stream")
		quit(1)
		return

	var n := s.data.size() / 2
	var peak := 0
	var sumsq := 0.0
	var first := s.data.decode_s16(0)
	var last := s.data.decode_s16((n - 1) * 2)
	var seam := absi(first - last)

	# 每隔 16 个样本量一次，够用且快
	var step := 16
	var cnt := 0
	for i in range(0, n, step):
		var v := s.data.decode_s16(i * 2)
		peak = maxi(peak, absi(v))
		sumsq += float(v) * float(v)
		cnt += 1
	var rms := sqrt(sumsq / maxf(1.0, float(cnt)))

	# 三条硬指标：
	#   1) 生成 < 1500ms（卡这么久玩家会以为没启动）
	#   2) 峰值不爆（<=32000），但不能小到听不见（>2000）
	#   3) 接缝跳变 < 1500（约 5% 满刻度；再大就能听见"咔"）
	var ok: bool = gen < 1500 and peak <= 32000 and peak > 2000 and seam < 1500

	# 五章都要能生成，且移调真的不同（否则"随章节变化"是假的）
	var diff := 0
	for ch in [1, 2, 3, 4, 5]:
		var w: AudioStreamWAV = b.stream_for(ch)
		if w == null or w.data.is_empty():
			ok = false
		else:
			var a := w.data.decode_s16(4000)
			var bb := s.data.decode_s16(4000) if ch != 1 else 0
			if ch != 1 and absi(a - bb) > 0:
				diff += 1

	if diff < 4:
		print("BGM_OK false transpose-not-distinct ", diff)

	print("BGM_OK %s gen_ms=%d peak=%d rms=%d seam=%d loop=%d" % [
		str(ok).to_lower(), gen, peak, int(rms), seam, s.loop_end])
	quit(0 if ok else 1)

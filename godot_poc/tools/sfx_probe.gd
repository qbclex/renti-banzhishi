extends SceneTree
## 验证「清脆化」是否真的进了渲染产物。
## 用 Godot 端真实的 Sfx.render 渲染每个音，量化两个清脆度指标：
##   attack_idx : 第一个 |样本| 达到峰值 15% 的样本下标（越小=起音越利落）
##   zc_4ms     : 前 4ms 内的过零次数（越高=起音高频瞬态越强=越清脆）
const D = preload("res://data.gd")
const SfxScript = preload("res://audio/sfx.gd")

const RATE := 22050

func _init():
	var sfx = SfxScript.new()
	var names = ["ui", "select", "card", "best", "good", "toast", "status", "emergency"]
	print("SFX_PROBE_START rate=%d" % RATE)
	for nm in names:
		var st = sfx.render(D.SOUNDS[nm])
		var buf: PackedByteArray = st.data
		var n := buf.size() / 2
		# 第一遍：峰值
		var peak := 0.0
		for i in range(n):
			var s := absf(buf.decode_s16(i * 2) / 32767.0)
			if s > peak:
				peak = s
		# 第二遍：过零与起音
		var prev := 0.0
		var zc_total := 0
		var zc_first := 0
		var atk_idx := -1
		var n_first := int(RATE * 0.004)
		for i in range(n):
			var s := buf.decode_s16(i * 2) / 32767.0
			if i > 0 and ((prev < 0.0) != (s < 0.0)):
				zc_total += 1
				if i < n_first:
					zc_first += 1
			if atk_idx < 0 and i > 0 and absf(s) >= 0.15 * peak:
				atk_idx = i
			prev = s
		var dur_ms := float(n) / float(RATE) * 1000.0
		print("SFX_STATS name=%s dur_ms=%.1f peak=%.3f attack_idx=%d zc_4ms=%d zc_total=%d"
			% [nm, dur_ms, peak, atk_idx, zc_first, zc_total])
	print("SFX_PROBE_END")
	quit()

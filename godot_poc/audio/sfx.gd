extends RefCounted
## 程序化音效（Godot 版）
##
## 三个客户端共用同一份配方：content_full.SOUNDS
##   网页  → src/js/audio.js 用 WebAudio 实时合成
##   桌面  → audio.py 用 wave 离线合成为 WAV，交给 winsound 播
##   Godot → 本文件用同一条公式算 PCM，塞进 AudioStreamWAV 交给 AudioStreamPlayer
##
## 为什么不用 .wav/.ogg 素材：POC 阶段不想引入二进制资产，配方改一个数字
## 就能听出差别；而且三端「同一个音」这件事本身是可验证的（见音频回归测试）。
##
## 用法（在 Control 的 _ready 里）：
##   var sfx = Sfx.new()
##   sfx.attach(self)      # 建播放器池，挂在当前节点下
##   sfx.play("best")
##   sfx.enabled = false   # 静音

const D = preload("res://data.gd")
const AudioMix = preload("res://ui/audio_mix.gd")

const RATE := 22050          # 与 audio.py 的 RATE 一致
const POOL := 6              # 同时最多叠 6 个音（判定音 + 组合 + 状态…）
const NOISE_SEED := 12345    # 与 audio.py 的固定种子一致，保证听感可复现

var enabled := true
var volume := 0.72           # 线性，0..1；play 时换算成 dB

var _cache := {}             # name -> AudioStreamWAV（懒加载，只合成一次）
var _players: Array = []
var _next := 0


# ---------------------------------------------------------------- 挂载
func attach(parent: Node) -> void:
	AudioMix.ensure_buses()
	for _i in range(POOL):
		var p := AudioStreamPlayer.new()
		# 走 SFX 总线而不是 Master：玩家需要「音乐关掉、判定音留着」
		p.bus = AudioMix.SFX
		p.process_mode = Node.PROCESS_MODE_ALWAYS
		parent.add_child(p)
		_players.append(p)


func is_ready() -> bool:
	return not _players.is_empty()


# ---------------------------------------------------------------- 合成
## phase 为任意实数，内部取小数部分，返回 -1..1
func _sample(wave_name: String, phase: float) -> float:
	var p := phase - floorf(phase)
	match wave_name:
		"triangle":
			return 4.0 * absf(p - 0.5) - 1.0
		"square":
			return 1.0 if p < 0.5 else -1.0
		"sawtooth":
			return 2.0 * p - 1.0
	return sin(TAU * p)


## 把一条配方渲染成 16bit 单声道 PCM，包成 AudioStreamWAV。
func render(spec: Dictionary) -> AudioStreamWAV:
	var dur := float(spec.get("dur", 0.2))
	var f0 := float(spec.get("f0", 440))
	var f1 := float(spec.get("f1", f0))
	var wn := str(spec.get("wave", "sine"))
	var atk := maxf(0.001, float(spec.get("atk", 0.01)))
	var vol := clampf(float(spec.get("vol", 0.2)), 0.0, 1.0)
	var chord = spec.get("chord", [1.0])
	if chord == null or (chord is Array and chord.is_empty()):
		chord = [1.0]
	var noise := float(spec.get("noise", 0.0))
	var pulse := float(spec.get("pulse", 0.0))
	var tick := float(spec.get("tick", 0.0))
	var tick_len := maxf(0.001, float(spec.get("tick_len", 0.004)))

	var n := maxi(1, int(RATE * dur))
	var buf := PackedByteArray()
	buf.resize(n * 2)
	var seed_val := NOISE_SEED
	var tail := maxf(0.001, dur - atk)
	var inv_rate := 1.0 / float(RATE)
	var inv_chord := 1.0 / float((chord as Array).size())

	for i in range(n):
		var t := float(i) * inv_rate
		var g := t / dur
		# 扫频：从 f0 线性到 f1
		var f := f0 + (f1 - f0) * g
		# 包络：起音线性，之后指数衰减（与 audio.py 同一条曲线）
		var env: float
		if t < atk:
			env = t / atk
		else:
			env = exp(-4.2 * (t - atk) / tail)
		var amp := 0.0
		for ratio in chord:
			amp += _sample(wn, f * float(ratio) * t)
		amp *= inv_chord

		if noise > 0.0:
			seed_val = (1103515245 * seed_val + 12345) & 0x7FFFFFFF
			var r := float(seed_val) / float(0x7FFFFFFF) * 2.0 - 1.0
			amp = amp * (1.0 - noise) + r * noise

		if pulse != 0.0:
			amp *= 0.6 + 0.4 * sin(TAU * pulse * t)

		# 起音高频瞬态：极短(默认 4ms)的 5.5kHz 脉冲，平方窗快起快落，制造"清脆/敲击感"。
		# tick=0 时退回原音色；桌面端 audio.py 用同一条公式，保证两端同一个音。
		if tick > 0.0 and t < tick_len:
			var tg := t / tick_len
			var click := sin(TAU * 5500.0 * t)
			var cenv := (1.0 - tg) * (1.0 - tg)
			amp = amp * (1.0 - tick) + click * cenv * tick

		var v := clampf(amp * env * vol, -1.0, 1.0)
		buf.encode_s16(i * 2, int(v * 32767.0))

	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = buf
	return s


func stream(name: String) -> AudioStreamWAV:
	if _cache.has(name):
		return _cache[name]
	if not D.SOUNDS.has(name):
		return null
	var s := render(D.SOUNDS[name])
	_cache[name] = s
	return s


## 预热：开局把常用音效一次合成好，避免第一次点牌时卡一下。
func warm(names: Array = []) -> void:
	var list: Array = names
	if list.is_empty():
		list = ["ui", "select", "card", "toast"]
	for n in list:
		stream(str(n))


# ---------------------------------------------------------------- 播放
func play(name: String) -> void:
	if not enabled or _players.is_empty():
		return
	var s := stream(name)
	if s == null:
		return
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = s
	p.volume_db = linear_to_db(maxf(0.0001, volume))
	p.play()


func toggle() -> bool:
	enabled = not enabled
	if not enabled:
		for p in _players:
			(p as AudioStreamPlayer).stop()
	return enabled


func stop_all() -> void:
	for p in _players:
		(p as AudioStreamPlayer).stop()


## 退出前收尾：停播、断开对音频流的引用、清缓存。
## 不做这一步，无头退出时 AudioServer 还挂着播放实例，Godot 会报
## "ObjectDB instances were leaked at exit"——测试里看见这条会误以为有内存问题。
func dispose() -> void:
	stop_all()
	for p in _players:
		if is_instance_valid(p):
			(p as AudioStreamPlayer).stream = null
	_players.clear()
	_cache.clear()

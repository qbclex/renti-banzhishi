extends RefCounted
## 程序化环境音乐（BGM）。
##
## 和音效一样，这里**不放二进制音频**：整段「氛围垫」在启动时用几条正弦波算出来，
## 塞进 AudioStreamWAV 循环播放。理由和 sfx.gd 相同——
## 一份公式，改一个数字就能换调性/密度，不用管理 wav 素材。
##
## 音乐设计（不是随便糊一层 pad）：
##   · 四个和弦循环（Am – F – C – G），每个 8 秒，全部落在低频区，音量很小；
##   · 每章升/降一点调（chapter_transpose），同一段音乐会随章节推进变"亮"，
##     到第五章（一个人的夜班）降回去，听感上收在安静里；
##   · 叠一层极轻的房间底噪（一阶低通白噪），模拟"值班室空调在响"；
##   · 循环无缝：和弦包络在段首段尾都收在 0，末尾再做一次等功率交叉淡化。
##
## 采样率只有 16 kHz：这是低频垫音，没有需要高频的东西；
## 用 44.1k 会让生成时间翻三倍，而听感没有区别。

const AudioMix = preload("res://ui/audio_mix.gd")

const RATE := 12000
const LOOP_SEC := 32.0
const CHORD_SEC := 8.0          # 4 个和弦 × 8 秒 = 32 秒
const PEAK := 0.11              # 垫音很轻：它要在 25 个班次里一直存在，不能抢戏

## 四个和弦的音级（半音，相对 A2=110Hz）
const CHORDS := [
	[0, 3, 7, 12],      # Am
	[-4, 0, 3, 8],      # F
	[3, 7, 10, 15],     # C
	[-2, 2, 5, 10],     # G
]
const ROOT_HZ := 110.0

var enabled := true
var _player: AudioStreamPlayer
var _cache := {}
var _cur := -1
var _want := -1          # 最后一次请求的章节（音源可能还没算好）
var _timer: Timer
var _mutex := Mutex.new()
var _task := -1


func attach(parent: Node) -> void:
	AudioMix.ensure_buses()
	_player = AudioStreamPlayer.new()
	_player.bus = AudioMix.MUSIC
	_player.process_mode = Node.PROCESS_MODE_ALWAYS
	parent.add_child(_player)
	warm_async()

	# 算好之后要有人来"再试一次"：主界面的刷新是玩家驱动的，开局那几十秒
	# 玩家可能一直停在简报上不动，没有 _refresh 就永远不会开播。
	# 之前没有这个定时器，实测结果是"点一下才有音乐"。
	_timer = Timer.new()
	_timer.wait_time = 0.4
	_timer.autostart = true
	_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	parent.add_child(_timer)
	_timer.timeout.connect(_retry)


## 在后台线程把五章都算好。
##
## 一段 32 秒的垫音要跑 1.5M 次迭代、约 0.9 秒；同步算的话，
## 玩家换章那一瞬间会卡住近一秒，比没有音乐更糟。
## 所以启动时丢给 WorkerThreadPool，`play_chapter` 拿不到就先不响，
## 下一次界面刷新再试（通常 0.3–4 秒后就绪，玩家正在看过场）。
func warm_async() -> void:
	if _task >= 0:
		return
	# 无头（巡演/测试）不算：省得白烧 CPU，也不影响任何断言
	if DisplayServer.get_name() == "headless":
		return
	_task = WorkerThreadPool.add_task(_warm_all, false, "bgm-warm")


func _warm_all() -> void:
	for ch in [1, 2, 3, 4, 5]:
		var w := _render(ch)
		_mutex.lock()
		_cache[ch] = w
		_mutex.unlock()


## 换章时调用。同一章重复调用不会重新起播（否则每次 _refresh 都会断续）。
## 音源还没算好就直接返回，交给下一次刷新重试。
func play_chapter(no: int) -> void:
	if _player == null or not enabled:
		return
	_want = no
	if no == _cur and _player.playing:
		return
	var s := _cached(no)
	if s == null:
		return
	_cur = no
	_player.stream = s
	_player.play()


func _cached(no: int) -> AudioStreamWAV:
	_mutex.lock()
	var w = _cache.get(clampi(no, 1, 5), null)
	_mutex.unlock()
	return w


func _retry() -> void:
	if _player == null or not enabled:
		return
	if _player.playing and _cur == _want:
		if _timer != null:
			_timer.stop()      # 已经在播了，定时器可以退休
		return
	if _want > 0:
		play_chapter(_want)


func stop() -> void:
	_cur = -1
	if _player != null:
		_player.stop()


func dispose() -> void:
	stop()
	# 后台线程还在算就先收掉：进程退出时留着一个活线程会报 leak
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _player != null:
		# 和 sfx 的收尾同理：主动断掉对流的引用，退出时才不会报资源泄漏
		_player.stream = null


func set_enabled(on: bool) -> void:
	enabled = on
	if not on:
		stop()


## 同步取（探针/即时可用时走这条）。正常游玩走 play_chapter 的异步路径。
func stream_for(no: int) -> AudioStreamWAV:
	var key := clampi(no, 1, 5)
	var hit = _cached(key)
	if hit != null:
		return hit
	var w := _render(key)
	_mutex.lock()
	_cache[key] = w
	_mutex.unlock()
	return w


## 每章移调：一章 0、二章 +2、三章 -2、四章 +1、五章 -5（低下去，收在安静里）
static func chapter_transpose(no: int) -> int:
	match no:
		1: return 0
		2: return 2
		3: return -2
		4: return 1
		_: return -5


func _render(no: int) -> AudioStreamWAV:
	var n := int(LOOP_SEC * RATE)
	var data := PackedByteArray()
	data.resize(n * 2)

	var semi: int = chapter_transpose(no)
	var chord_len := CHORD_SEC
	var overlap := 1.2
	var win := chord_len + overlap   # 每个和弦实际占用（含提前进来的 1.2 秒）

	# 每个和弦的频率表
	var voicings := []
	for c in range(CHORDS.size()):
		var freqs := []
		for st in CHORDS[c]:
			freqs.append(ROOT_HZ * pow(2.0, float(st + semi) / 12.0))
		voicings.append(freqs)

	for i in range(n):
		var t := float(i) / RATE
		var v := 0.0
		for c in range(CHORDS.size()):
			# 和弦 c 从「拍点前 overlap 秒」开始响，循环内用取模回绕，
			# 这样跨过循环点的那半个和弦是连续的（不是靠淡入淡出糊过去）。
			var local: float = fposmod(t - (float(c) * chord_len - overlap), LOOP_SEC)
			if local >= win:
				continue
			var env := _env(local, win, overlap, 2.6)
			if env <= 0.0:
				continue
			v += _pad(voicings[c], local, env)
		# 房间底噪：极轻，只为让静音处"不是死的"
		v += _noise(i) * 0.012

		var s := clampf(v, -1.0, 1.0) * PEAK
		data.encode_s16(i * 2, int(s * 32767.0))

	# 不需要交叉淡化：整段音乐的所有成分（和弦包络、相位）都只取决于
	# 「在本轮循环里的位置」，所以 x[n+i] 本来就等于 x[i]，天然无缝；
	# 唯一不周期的是底噪，而它只有 ±40/32767，接缝跳变在 100 以内。
	# 之前那版在这里做首尾淡化，反而把正确的头部覆盖坏了（接缝跳到 2359）。

	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w


## 慢起慢收包络。段首段尾都收在 0，所以循环点本身就是连续的 —— 这一步是
## 「无缝循环」的主保障，末尾的交叉淡化只是兜住噪声那一层。
static func _env(t: float, total: float, attack: float, release: float) -> float:
	if t <= 0.0 or t >= total:
		return 0.0
	var a: float = minf(1.0, t / attack)
	var r: float = minf(1.0, (total - t) / release)
	# 平方根曲线：起音比线性更"软"，收尾也更自然
	return sqrt(a) * sqrt(r)


## 一个和弦：基音 + 八度 + 五度，各自带极慢的相位漂移，避免"电子风琴"的死板。
static func _pad(freqs: Array, t: float, env: float) -> float:
	var v := 0.0
	for k in range(freqs.size()):
		var f: float = freqs[k]
		var amp := 1.0 / (1.6 + float(k) * 0.75)
		# 每层用略微不同的频率比做出自然的拍频（chorus 效果）
		var detune := 1.0 + 0.0012 * float(k + 1)
		v += sin(TAU * f * detune * t) * amp
		# 高八度的"空气感"，非常轻
		if k == 0:
			v += sin(TAU * f * 2.0 * t + 0.6) * 0.10
	return v * env


## 固定种子的伪随机噪声（不能用 randf：每次启动要不一致就不叫"同一段音乐"了）
static func _noise(i: int) -> float:
	var x := (i * 1103515245 + 12345) & 0x7FFFFFFF
	var y := (x >> 7) & 0xFFFF
	# 相邻样本取平均 = 粗糙的一阶低通，听起来像远处的空调而不是"沙沙"
	var x2 := ((i + 1) * 1103515245 + 12345) & 0x7FFFFFFF
	var y2 := (x2 >> 7) & 0xFFFF
	return (float(y) + float(y2)) / 65535.0 - 1.0

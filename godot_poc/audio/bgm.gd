extends RefCounted
## 环境音乐（BGM）——现在播的是一段现成的 CC0 素材，不再现场合成。
##
## 素材：`audio/bgm_forest.ogg`
##   曲名 Cathedral in the forest (ambient loop)
##   作者 congusbongus（OpenGameArt）
##   授权 CC0 1.0（公有领域，无署名义务；本文件与 NOTICE 仍保留出处）
##   137 秒，44100Hz 立体声，首尾对齐的无缝循环
##
## 为什么把原来的程序化合成换掉（是实测，不是口味问题）：
##   旧实现用 A2=110Hz 起的四个正弦叠成垫音，整段 97% 的能量落在 40–120Hz。
##   笔记本扬声器基本不发声，玩家实际听到的只剩削波产生的互调失真，
##   听感就是"噪音"；去掉削波后连失真也没了，变成"没声音"。
##   换成这段素材后，能量分布 120–250Hz 27%、250–500Hz 41%、500–2kHz 29%，
##   在任何扬声器上都有内容，且它本身就是按循环做的，不需要再拼包络。
##
## 章节差异靠播放速率（pitch_scale）实现：升/降一个半音就会换调性和气息，
## 而对 137 秒的氛围垫来说，这点速度变化听不出来。原设计"随章节变亮、
## 第五章沉下去"因此保留。

const AudioMix = preload("res://ui/audio_mix.gd")

const TRACK := "res://audio/bgm_forest.ogg"

## 下标 = 章节号。0 不用；一章 0、二章 +1、三章 -1、四章 +1、五章 -2（沉下去）
const CHAPTER_SEMITONES := [0, 0, 1, -1, 1, -2]

var enabled := true
var _player: AudioStreamPlayer
var _stream: AudioStream
var _load_error := ""
var _cur := -1
var _want := -1          # 最后一次请求的章节


func attach(parent: Node) -> void:
	AudioMix.ensure_buses()
	# 无头（巡演 / 自检 / 截图）没有声卡：dummy 驱动下混音轮次不保证在退出前跑完，
	# 播放实例会挂在退出检查里（每开一局漏 1 个 stream + 1 个 playback）。
	# 所以这里连素材都不加载；探针需要流时走 stream_for()，那是显式请求。
	if DisplayServer.get_name() == "headless":
		return
	_player = AudioStreamPlayer.new()
	_player.bus = AudioMix.MUSIC
	_player.process_mode = Node.PROCESS_MODE_ALWAYS
	parent.add_child(_player)
	# 只有 2.9MB 的 ogg，加载是毫秒级，不再需要后台线程。
	_ensure_stream()


## 换章时调用。同一章重复调用不会重新起播（否则每次 _refresh 都会断续）。
func play_chapter(no: int) -> void:
	if _player == null or not enabled:
		return
	_want = no
	if no == _cur and _player.playing:
		return
	var s := _ensure_stream()
	if s == null:
		return
	_cur = no
	if _player.stream != s:
		_player.stream = s
	_player.pitch_scale = pitch_for(no)
	_player.play()


## 章节 → 播放速率。半音换算，超出表范围就当第一章。
static func pitch_for(no: int) -> float:
	var idx := no if no >= 1 and no < CHAPTER_SEMITONES.size() else 1
	return pow(2.0, float(CHAPTER_SEMITONES[idx]) / 12.0)


func _ensure_stream() -> AudioStream:
	if _stream != null:
		return _stream
	if not ResourceLoader.exists(TRACK):
		_load_error = "缺少 %s" % TRACK
		push_warning("BGM: " + _load_error)
		return null
	_stream = load(TRACK)
	if _stream == null:
		_load_error = "无法加载 %s" % TRACK
		push_warning("BGM: " + _load_error)
		return null
	# ogg 的循环点在文件末尾，素材本身是首尾对齐的，整段循环即可
	if "loop" in _stream:
		_stream.set("loop", true)
	return _stream


func stop() -> void:
	_cur = -1
	if _player != null:
		_player.stop()


func dispose() -> void:
	stop()
	if _player != null:
		# 主动断掉对流的所有引用，退出时才不会报 "resources still in use"
		_player.stream = null
	_stream = null


func set_enabled(on: bool) -> void:
	enabled = on
	if not on:
		stop()


## 给探针用：拿第 no 章该播的那条流（同一份素材，只是播放速率不同）。
func stream_for(no: int) -> AudioStream:
	return _ensure_stream()


func last_error() -> String:
	return _load_error

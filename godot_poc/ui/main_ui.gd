extends Control
## 班次界面骨架（POC）
##
## 职责边界：这里只负责「画」和「收输入」，规则全部在 engine.gd 的 Game 类里。
## 任何操作都只有两步——调用 Game 的公开方法，然后 _refresh() 重画整屏。
## 所以把这个文件换成正式 UI / 换美术时，引擎层一行都不用改。
##
## 结构（全部在 _build() 里用代码搭，方便 POC 阶段快速改布局）：
##   顶栏（章/班/环境/刻数/目标）
##   ├ 左：身体指标 + 状态
##   ├ 中：待处理工单（可点选）
##   └ 右：值班记录
##   底部：手牌 + 动作按钮
##   最上层：模态层（开场简报/抉择/结算/事故/通关）+ 结果提示条
##
## 跑法：
##   godot --path .                       正常玩
##   godot --path . -- --shot             自动跑一遍并截图到 _shots/

const E = preload("res://engine.gd")
const Kit = preload("res://ui/ui_kit.gd")
const Sfx = preload("res://audio/sfx.gd")
const Bgm = preload("res://audio/bgm.gd")
const Save = preload("res://ui/save_sys.gd")
const CardArt = preload("res://ui/card_art.gd")
const Icons = preload("res://ui/icons.gd")
const CharArt = preload("res://ui/char_art.gd")
const BgArt = preload("res://ui/bg_art.gd")
const AppSettings = preload("res://ui/app_settings.gd")
const AudioMix = preload("res://ui/audio_mix.gd")

const SEED := 20261030

## 本局种子：默认 SEED，可被启动参数 `--seed=N` 覆盖（批量试玩用）。
var run_seed: int = SEED

## 模态面板宽度。没有立绘时 640（原来就是它）；有立绘时正文列要保住 560，
## 否则结算/事故这两屏的正文会比简报窄三分之一。
const MODAL_W_NOPORTRAIT := 640
const MODAL_W := 850

## 卡牌尺寸。高度必须容纳最坏情况：插画条 + 两行卡名 + 三条效果 + 页脚。
## 卡牌和手牌面板都从这里推导，避免两个地方各写一个数字、日后改一处忘了另一处。
##
## 为什么是 150 宽而不是更省地方的 122：手牌面板横跨整行（1248px），
## 6 张 122 的卡排完按钮右侧还剩约 300px 空着。加宽到 150 之后，
## 最长的卡名（9 个字）也能一行放下，卡高因此可以从 242 降到 216，
## ——用横向的空余去换纵向的空间，比去压榨工单区合理。
const CARD_W := 150
const CARD_H := 216
## 手牌面板 = 卡高 + 上下内边距 10×2 + 一点余量
const HAND_H := CARD_H + 24

## 检视卡（悬停放大）：宽度必须 ≥ 插画原始宽 264 + 左右内边距 14×2。
## 插画只能在 264×120 这一档 1:1 显示，再放大就是插值糊图——
## 原图 1536×1024 缩到 264×120 时细节已经丢过了，这里没有第二份高清可拿。
const INSPECT_W := 292
## 悬停多久才弹。0.16s 是「扫过不弹、停住就弹」的分界；
## 再短会把整排牌扫一遍时弹出一连串，再长会让人以为没这个功能。
const INSPECT_DELAY := 0.16

var game = null
var sel_uid := ""
var reroll_mode := false
var sfx = null

# 常驻节点
var _top_left: Label
var _top_mid: Label
var _top_right: Label
var _vitals_box: VBoxContainer
var _status_box: VBoxContainer
var _orders_box: VBoxContainer
var _orders_foot: Label
var _log_box: VBoxContainer
var _hand_box: HBoxContainer
var _flash_active := false
var _rr_btn: Button
var _overlay: Control
var _overlay_sig := ""
var _toast: PanelContainer
var _toast_l: Label
var _toast_gen := 0
var _prev_statuses := {}
var bgm
## 动效总开关：截图/无头模式必须关掉，否则 tween 还没跑完就截图，
## 会截到半透明的面板（之前排查过一次"截图发灰"就是这个原因）。
var _no_fx := false
## 上一次手牌张数：只给"新发到的牌"做淡入，出牌时不重放整排
var _prev_hand := 0
var _audio_btn: Button
var _set_btn: Button
var _save_btn: Button
var _load_btn: Button

## 玩家设置（音量 / 窗口）。读到 _ready 里，改一处就落盘一次。
var _settings: Dictionary = {}
## 设置面板是不是开着。它压在一切模态之上（见 _refresh_overlay），
## 所以可以在简报、抉择、结算任何一屏按 Esc 打开，关掉后回到原来那屏。
var _settings_open := false

## 悬停检视。`_inspect_gen` 是代数：每次悬停/离开都 +1，
## `await` 回来的那次如果代数对不上就放弃——否则快速扫过整排牌会在
## 每次停留 0.16s 后弹出一张已经不需要的卡。
##
## `_inspect_kind` / `_inspect_id` 是「现在这张卡讲的是谁」的键。同一张卡要给
## 四种源用：手牌（card）、工单（order）、状态（status）、指标（vital），
## 靠这一对键判断要不要重填内容。
var _inspect: PanelContainer
var _inspect_kind := ""
var _inspect_id := ""
var _inspect_gen := 0

## 全屏背景层。和底下的纯色 ColorRect 是两层，不是一层：
## 背景图是**可选资产**（`assets/bg/` 缺哪张都不该报错），纯色底保证缺图时
## 界面退回原来的观感，而不是变成一块白。
var _bg_rect: TextureRect


func _ready() -> void:
	theme = Kit.theme()
	var args := OS.get_cmdline_user_args()
	var headless_mode := "--autoplay" in args or "--shot" in args \
		or "--selfcheck" in args or "--packlist" in args
	# 允许 `-- --seed=123` 指定种子：批量试玩要用真实入口跑很多局，
	# 固定 SEED 只能验一条路径，很多分支（双红旗/低信任/透支结局）永远碰不到。
	for a in args:
		if str(a).begins_with("--seed="):
			run_seed = int(str(a).substr(7))

	_no_fx = headless_mode or DisplayServer.get_name() == "headless"

	game = E.Game.new(run_seed)
	_build()

	# 设置必须在建播放器之前读：否则第一声音效放的是默认音量，
	# 玩家会听到「音量滑块明明调小了，开头还是那么响」。
	_settings = AppSettings.load_settings()
	AudioMix.apply(_settings)
	# 巡演/截图要求可复现：别让玩家上次选的分辨率改变截图尺寸
	if not headless_mode:
		AppSettings.apply_display(_settings)

	sfx = Sfx.new()
	sfx.attach(self)
	sfx.volume = float(_settings.get("sfx", 0.72))

	# BGM 是一条 2.9MB 的 CC0 ogg，attach 时同步加载（毫秒级），不再走后台线程
	bgm = Bgm.new()
	bgm.attach(self)
	bgm.set_enabled(float(_settings.get("music", 0.42)) > 0.005)
	# 无头模式（--headless）不建播放实例：dummy 驱动下 AudioServer 的混音轮次
	# 不保证在退出前跑完，播放实例就会挂在退出检查里漏掉——每开一局漏 1 个
	# AudioStreamWAV + 1 个 AudioStreamPlaybackWAV。反正无头也没有声卡。
	sfx.enabled = not ("--mute" in args) and DisplayServer.get_name() != "headless"
	sfx.warm(["ui", "select", "card", "toast", "best", "good", "bad"])

	# 巡演/截图必须从零开始，否则会读到上一次跑留下的档，结果不可复现。
	if headless_mode or "--fresh" in args:
		Save.erase()
	elif Save.exists():
		var sv := Save.read_slot()
		if not sv.is_empty() and game.restore(sv.get("state", {})):
			_restore_ui(sv.get("ui", {}))
			_flash("已接上次进度（%s）" % str(sv.get("at", "")), Kit.TEAL)
	_refresh()

	if "--selfcheck" in args:
		await _selfcheck()
		return
	if "--packlist" in args:
		await _packlist()
		return
	if "--audiocheck" in args:
		await _audiocheck()
		return
	# 自动化模式一律写假槽位：这些模式每班都会自动存档，
	# 直接写 slot1 就等于「跑一次巡演冲掉一次玩家存档」。
	if "--autoplay" in args or "--shot" in args:
		Save.use_probe_slot()
	if "--autoplay" in args:
		_autoplay("--chaos" in args)
		return
	if "--shot" in args:
		await _run_shots()

func _exit_tree() -> void:
	if sfx != null:
		sfx.dispose()
	if bgm != null:
		bgm.dispose()
	Kit.release()
	Icons.release()
	CardArt.release()
	BgArt.release()


# =====================================================================
#                              搭界面
# =====================================================================
func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Kit.BG0
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 背景图铺在纯色底之上。`EXPAND_IGNORE_SIZE` + `KEEP_ASPECT_COVERED`：
	# 按等比放大到盖满全屏、多出来的部分裁掉，而不是拉伸。
	# 这条不是洁癖——`window/size/resizable=true`，玩家可以把窗口拖成 4:3，
	# 拉伸会把整个房间压变形，cover 只是多裁一点边缘（都是暗角）。
	_bg_rect = TextureRect.new()
	_bg_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_rect.visible = false
	add_child(_bg_rect)

	var page := Kit.margins(16, 14, 16, 14)
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(page)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	page.add_child(col)

	col.add_child(_build_topbar())

	var mid := HBoxContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 12)
	col.add_child(mid)
	mid.add_child(_build_vitals())
	mid.add_child(_build_orders())
	mid.add_child(_build_log())

	col.add_child(_build_toast_slot())
	col.add_child(_build_hand())

	# 检视卡是绝对定位的浮层，不参与任何容器布局——它要跨过手牌面板的边界
	# 浮在工单区上面，塞进容器就会被裁掉。加在 _overlay 之前，模态层永远盖住它。
	_inspect = Kit.panel(Color("#0E242B"), Kit.LINE, 12, 1)
	# 宽度钉死 = 内容宽 + 左右各 1px 描边。**必须钉死**：检视卡的宽度要是跟着
	# 内容走，那么鼠标在工单之间移动时卡会一张一个宽度，位置也跟着横跳。
	# 代价是所有内容都得容得下 292，塞不下就该换行（见 `_fill_order` 的标签流式布局）。
	_inspect.custom_minimum_size = Vector2(INSPECT_W + 2, 0)
	_inspect.visible = false
	# 纯展示，不接收鼠标：鼠标一离开卡牌就该收起，让它可交互只会制造竞态
	# （卡牌 exit 请求隐藏、检视 enter 请求显示，两者在同一帧里打架）。
	_inspect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inspect.add_theme_stylebox_override("panel", _inspect_style())
	add_child(_inspect)

	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	add_child(_overlay)


func _build_topbar() -> Control:
	var p := Kit.panel(Kit.BG1, Kit.LINE, 10, 1)
	p.custom_minimum_size = Vector2(0, 54)
	var m := Kit.margins(16, 10, 16, 10)
	p.add_child(m)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	m.add_child(h)

	_top_left = Kit.lbl("", 17, Kit.PAPER)
	h.add_child(_top_left)
	h.add_child(Kit.spacer())
	_top_mid = Kit.lbl("", 13, Kit.GREY)
	h.add_child(_top_mid)
	h.add_child(Kit.spacer())
	_top_right = Kit.lbl("", 13, Kit.GREY)
	h.add_child(_top_right)

	# 存档 / 读档 / 音效：POC 阶段先给按钮，正式版会收进设置页。
	h.add_child(Kit.spacer())
	var sep := ColorRect.new()
	sep.color = Kit.LINE
	sep.custom_minimum_size = Vector2(1, 22)
	sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(sep)

	_save_btn = _top_btn("存档", func(): _save_game(true), "save")
	h.add_child(_save_btn)
	_load_btn = _top_btn("读档", func(): _load_game(), "load")
	h.add_child(_load_btn)
	_audio_btn = _top_btn("音效 开", func(): _toggle_audio(), "sound_on")
	h.add_child(_audio_btn)
	_set_btn = _top_btn("设置", func(): _toggle_settings(), "gear")
	h.add_child(_set_btn)
	return p


## 顶栏上的小按钮（38px 高会撑高顶栏，这里压到 28px）
## `icon` 走 Button 自带的 icon 通道：贴图用白色生成，颜色交给 icon_*_color，
## 这样常态/悬停/按下三态由按钮自己管，不用手写三张图。
func _top_btn(text: String, cb: Callable, icon: String = "") -> Button:
	var b := Kit.ghost_button(text, Kit.GREY, 0)
	b.custom_minimum_size = Vector2(72, 28)
	b.add_theme_font_size_override("font_size", 12)
	if icon != "" and Icons.has(icon):
		b.icon = Icons.icon(icon, 13, Color.WHITE)
		# 贴图本身是 2x 超采样的，不掐住宽度会被按原始像素画成 26px，把顶栏顶高。
		b.add_theme_constant_override("icon_max_width", 13)
		b.add_theme_constant_override("h_separation", 5)
		b.add_theme_color_override("icon_normal_color", Kit.GREY)
		b.add_theme_color_override("icon_hover_color", Kit.GREY.lightened(0.3))
		b.add_theme_color_override("icon_pressed_color", Kit.TEAL)
	b.pressed.connect(cb)
	return b


func _build_vitals() -> Control:
	var p := Kit.panel(Kit.BG1, Kit.LINE, 10, 1)
	p.custom_minimum_size = Vector2(236, 0)
	var m := Kit.margins(14, 12, 14, 12)
	p.add_child(m)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	m.add_child(v)

	v.add_child(Kit.lbl("身体指标", 12, Kit.MUTED))
	_vitals_box = VBoxContainer.new()
	_vitals_box.add_theme_constant_override("separation", 9)
	v.add_child(_vitals_box)

	v.add_child(Kit.spacer(false))
	v.add_child(_hline())
	v.add_child(Kit.lbl("状态", 12, Kit.MUTED))
	_status_box = VBoxContainer.new()
	_status_box.add_theme_constant_override("separation", 5)
	v.add_child(_status_box)
	return p


func _build_orders() -> Control:
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 8)

	var head := HBoxContainer.new()
	head.add_child(Kit.lbl("待处理工单", 13, Kit.GREY))
	head.add_child(Kit.spacer())
	head.add_child(Kit.lbl("点工单选中 → 点牌处置", 11, Kit.MUTED))
	v.add_child(head)

	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)

	_orders_box = VBoxContainer.new()
	_orders_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_orders_box.add_theme_constant_override("separation", 8)
	sc.add_child(_orders_box)

	_orders_foot = Kit.lbl("", 11, Kit.MUTED)
	v.add_child(_orders_foot)
	return v


func _build_log() -> Control:
	var p := Kit.panel(Kit.BG1, Kit.LINE, 10, 1)
	p.custom_minimum_size = Vector2(288, 0)
	var m := Kit.margins(14, 12, 14, 12)
	p.add_child(m)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.alignment = BoxContainer.ALIGNMENT_BEGIN
	m.add_child(v)
	v.add_child(Kit.lbl("值班记录", 12, Kit.MUTED))
	_log_box = VBoxContainer.new()
	_log_box.add_theme_constant_override("separation", 6)
	_log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_log_box)
	return p


func _build_hand() -> Control:
	var p := Kit.panel(Kit.BG1, Kit.LINE, 10, 1)
	p.custom_minimum_size = Vector2(0, HAND_H)
	var m := Kit.margins(12, 10, 12, 10)
	p.add_child(m)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	m.add_child(h)

	_hand_box = HBoxContainer.new()
	_hand_box.add_theme_constant_override("separation", 8)
	_hand_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(_hand_box)

	var act := VBoxContainer.new()
	act.custom_minimum_size = Vector2(152, 0)
	act.add_theme_constant_override("separation", 8)
	act.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_child(act)

	var b_wait := Kit.button("等一刻　␣", Kit.GOLD, 152)
	b_wait.pressed.connect(_on_wait)
	act.add_child(b_wait)

	_rr_btn = Kit.ghost_button("换签　R", Kit.TEAL, 152)
	_rr_btn.pressed.connect(_on_reroll_toggle)
	act.add_child(_rr_btn)

	var tip := Kit.lbl("换签模式：点牌即换", 10, Kit.MUTED)
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	act.add_child(tip)
	return p


## 结果提示条：占固定高度的一行，避免「浮层压住工单/手牌」的排版问题。
## 用 CenterContainer 常驻，提示条本身隐藏时不塌陷（不然整屏会跳一下）。
func _build_toast_slot() -> Control:
	var slot := CenterContainer.new()
	slot.custom_minimum_size = Vector2(0, 38)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_toast = Kit.panel(Color("#0A1A20"), Kit.LINE, 10, 1)
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(_toast)

	var m := Kit.margins(16, 7, 16, 7)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.add_child(m)

	_toast_l = Kit.lbl("", 12, Kit.MUTED)
	_toast_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(_toast_l)
	return slot


# =====================================================================
#                              刷新
# =====================================================================
func _refresh() -> void:
	if game == null:
		return
	# 重画会销毁所有被悬停的节点，而它们的 `mouse_exited` 未必还发得出来
	# （节点没了 = 没有"离开"这个事件），检视卡于是会停在屏上，
	# 讲一条已经不在列表里的工单。所以每次整屏重画都先收掉。
	_hide_inspect()
	_refresh_bg()
	_refresh_top()
	_refresh_vitals()
	_refresh_statuses()
	_refresh_orders()
	_refresh_log()
	_refresh_hand()
	_refresh_hint()
	_refresh_overlay()
	_sync_status_sfx()
	_sync_bgm()
	_refresh_audio_btn()


## 背景跟着状态走：终章/结局用病房（bg_ward），章节过场用走廊夜景
## （bg_corridor_night），其余值班界面用护理站（bg_nurse_station）。
##
## 每次刷新重设一次 texture 看着浪费，但 `BgArt.tex` 内部只缓存一张，
## 同一个 id 连续调用是纯比较字符串，开销可以忽略；换来的是**读档跳到别的章**
## 时不用另写一条更新路径。
func _refresh_bg() -> void:
	if _bg_rect == null:
		return
	var ending: bool = game.campaign["cleared"]
	var intro: bool = game.pending_chapter_intro != null and not game.pending_chapter_intro.is_empty()
	var t := BgArt.tex(BgArt.scene_for(int(game.campaign.get("chapter", 0)), ending, intro))
	_bg_rect.texture = t
	_bg_rect.visible = t != null


## 新增状态 → 一个短促的提示音。放在刷新里而不是每个动作里，
## 这样「超时恶化」「抉择附带」「纠纷升级」三条路径都不会漏。
func _sync_status_sfx() -> void:
	if sfx == null:
		return
	for k in game.statuses:
		if not _prev_statuses.has(k):
			sfx.play("status")
			break
	_prev_statuses = game.statuses.duplicate()


func _refresh_audio_btn() -> void:
	if _audio_btn == null:
		return
	var on: bool = sfx != null and sfx.enabled
	_audio_btn.text = "音效 开" if on else "音效 关"
	# 图标跟着一起换：只在文字上说「关」，扫视时是看不出来的
	var icon := "sound_on" if on else "sound_off"
	if Icons.has(icon):
		_audio_btn.icon = Icons.icon(icon, 13, Color.WHITE)
	_audio_btn.add_theme_color_override("font_color", Kit.TEAL if on else Kit.MUTED)
	_audio_btn.add_theme_color_override("icon_normal_color", Kit.TEAL if on else Kit.MUTED)


func _refresh_top() -> void:
	var ch = game.get_chapter()
	var sd = game.get_shift_def()
	_top_left.text = "%s · %s　／　第 %d 班 · %s" % [ch["code"], ch["title"], sd["n"], sd["name"]]
	var env = game.env
	_top_mid.text = "%s　已用 %d / %d 刻　换签 %d" % [env["name"], game.clock, game.max_clock, game.rerolls]
	var gp = game.goal_progress()
	_top_right.text = "%s（%d / %d）%s" % [sd["goal"]["text"], gp[0], gp[1], "　✓" if gp[2] else ""]
	_top_right.add_theme_color_override("font_color", Kit.GREEN if gp[2] else Kit.GREY)


## 指标条：颜色只讲「危险程度」，指标身份靠名字。
## 三档色与警戒阈值全部走 Kit（与网页端 render.js 同一套，测试会比对）。
func _refresh_vitals() -> void:
	Kit.clear(_vitals_box)
	for v in E.D.VITALS:
		var key: String = v[0]
		var disp: String = v[1]
		var dir: String = v[2]
		var val: int = int(game.vitals[key])
		var health := val if dir == "better" else 100 - val
		var c2: Array = Kit.health_colors(float(health))
		var bad := Kit.is_bad(val, dir)

		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 3)
		# 指标条只回答了「现在多少」，没回答「涨是好事还是坏事」「到多少才算坏」。
		# 那两个答案数据里都有（方向 / 警戒阈值），但左栏放不下，只能挂悬停。
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.set_meta("vkey", key)
		row.mouse_entered.connect(_hover.bind("vital", key, true))
		row.mouse_exited.connect(_hover.bind("vital", key, false))

		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 5)
		var nm_col: Color = Kit.WARN_FG if bad else Kit.VITAL_NAME
		# 取消了指标身份色之后，识别度靠图标补回来：
		# 颜色只说危险程度，图标说这是哪个指标。图标用不透明中性色才看得清。
		var ico_col: Color = Kit.WARN_FG if bad else Kit.ICON_INK
		head.add_child(Icons.rect(key, 14, ico_col))
		head.add_child(Kit.lbl(disp, 12, nm_col))
		head.add_child(Kit.spacer())
		head.add_child(Kit.lbl(str(val), 13, Kit.WARN_FG if bad else c2[0]))
		row.add_child(head)

		var bar := ProgressBar.new()
		bar.min_value = 0
		bar.max_value = 100
		bar.value = val
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 5)
		bar.add_theme_stylebox_override("background",
			Kit.sb(Color("#0E2228"), Kit.WARN_LINE, 3, 1 if bad else 0))
		# 填充色带一圈同色微光，对应网页端的 box-shadow: 0 0 .6rem currentColor
		var fill := Kit.sb(c2[0], Color(0, 0, 0, 0), 3)
		fill.shadow_color = Color(c2[0], 0.40)
		fill.shadow_size = 3
		bar.add_theme_stylebox_override("fill", fill)
		row.add_child(bar)

		for ch in row.get_children():
			Kit.ignore_mouse(ch)
		_vitals_box.add_child(row)


func _refresh_statuses() -> void:
	Kit.clear(_status_box)
	if game.statuses.is_empty():
		var l := Kit.lbl("无", 12, Kit.MUTED)
		_status_box.add_child(l)
		return
	for k in game.statuses:
		var s = E.D.STATUS[k]
		# 名称行和描述合成一块再挂悬停：只挂名称行的话，鼠标往下一挪到描述上，
		# 检视卡就闪没了——玩家眼里那是同一个状态。
		var blk := VBoxContainer.new()
		blk.add_theme_constant_override("separation", 2)
		blk.mouse_filter = Control.MOUSE_FILTER_STOP
		blk.set_meta("skey", k)
		blk.mouse_entered.connect(_hover.bind("status", k, true))
		blk.mouse_exited.connect(_hover.bind("status", k, false))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		# 数据里的 icon 是字形（♥ ▲ ☾ ✳ ◈ ?），五套字形混排线宽和重心都不齐；
		# 这里走统一的手绘线稿，缺图才退回字形（宁可退，也不要空一格）。
		var iname: String = Kit.STATUS_ICONS.get(k, "")
		if iname != "" and Icons.has(iname):
			row.add_child(Icons.rect(iname, 13, Color(s["color"])))
		else:
			row.add_child(Kit.lbl(s["icon"], 13, Color(s["color"])))
		row.add_child(Kit.lbl(s["name"], 12, Kit.PAPER2))
		blk.add_child(row)
		var desc := Kit.lbl(s["desc"], 10, Kit.GREY)
		Kit.wrap(desc)
		blk.add_child(desc)

		for ch in blk.get_children():
			Kit.ignore_mouse(ch)
		_status_box.add_child(blk)


func _refresh_orders() -> void:
	Kit.clear(_orders_box)
	var act: Array = game.active_orders()
	if act.is_empty():
		_orders_box.add_child(Kit.lbl("工单已全部处理完毕。", 13, Kit.MUTED))
	# 先列未处理的（要点就点它），已处理的收成一行留在下面——
	# 既填住了空白，也让玩家随时看得见「这一班我做了什么」。
	for o in game.orders:
		if not o["resolved"]:
			_orders_box.add_child(_mk_order(o))
	for o in game.orders:
		if o["resolved"]:
			_orders_box.add_child(_mk_done_row(o))
	var done: int = game.orders.size() - act.size()
	_orders_foot.text = "已处理 %d / %d　·　本班共 %d 刻" % [done, game.orders.size(), game.max_clock]


func _refresh_log() -> void:
	Kit.clear(_log_box)
	var n := 0
	for e in game.log:
		if n >= 9:
			break
		n += 1
		var grade: String = e[0]
		var g: Array = Kit.GRADES.get(grade, ["·", Kit.GREY])
		var text := ""
		if e[1] != null:
			text = "%s　%s" % [e[1]["title"], e[2]["n"]]
		elif e[2] is Dictionary:
			text = str(e[2].get("n", ""))
		if text == "":
			continue

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var dot := ColorRect.new()
		dot.color = g[1]
		dot.custom_minimum_size = Vector2(3, 13)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(dot)
		var l := Kit.lbl(text, 12, Kit.GREY if grade == "status" else Kit.PAPER2)
		Kit.wrap(l)
		row.add_child(l)
		_log_box.add_child(row)


func _refresh_hand() -> void:
	Kit.clear(_hand_box)
	if game.hand.is_empty():
		_hand_box.add_child(Kit.lbl("手牌为空", 13, Kit.MUTED))
		_prev_hand = 0
		return
	# 只有"比上一帧多出来的那几张"做淡入：出牌后整排重放会闪一下，
	# 玩家会以为"我出的牌又回来了"。
	var n: int = game.hand.size()
	var fresh: int = maxi(0, n - _prev_hand)
	_prev_hand = n
	var i := 0
	for cid in game.hand:
		var card := _mk_play_card(cid)
		_hand_box.add_child(card)
		if not _no_fx and i >= n - fresh:
			card.modulate.a = 0.0
			var tw := create_tween()
			tw.tween_interval(0.035 * float(i - (n - fresh)))
			tw.tween_property(card, "modulate:a", 1.0, 0.14)
		i += 1
	_rr_btn.text = "换签　R（%d）" % game.rerolls


func _refresh_hint() -> void:
	var msg := ""
	if reroll_mode:
		msg = "换签模式：点一张牌换掉它（剩 %d 次）" % game.rerolls
	elif game.phase == "shift":
		var n := 0
		for cid in game.hand:
			if game.can_play(cid):
				n += 1
		msg = "可出 %d / %d 张　1–6 出牌　空格 等一刻　Esc 设置" % [n, game.hand.size()]
	else:
		msg = "本班已结束"
	if _flash_active:
		return
	_toast_l.text = msg
	_toast_l.add_theme_color_override("font_color", Kit.MUTED)
	_toast.add_theme_stylebox_override("panel", Kit.sb(Color("#0A1A20"), Kit.LINE, 10, 1))


# =====================================================================
#                            卡片 / 工单
# =====================================================================
func _mk_play_card(cid: String) -> Control:
	var c = E.D.CARD_MAP[cid]
	var playable: bool = game.can_play(cid) and game.phase == "shift"
	var kind: Array = Kit.KINDS.get(c["s"], ["·", Kit.GREY, ""])
	var accent: Color = kind[1]

	var p := Kit.panel(Kit.BG2 if playable else Color("#081419"),
		accent if playable else Kit.LINE, 10, 1)
	p.custom_minimum_size = Vector2(CARD_W, CARD_H)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	if playable:
		p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 不用 tooltip_text：原生 tooltip 是系统黑框 + 0.5s 延迟，和这套设计不搭，
	# 而且它装不下「描述 + 知识点」两段。悬停走自绘检视（见「悬停检视」一节）。
	p.mouse_entered.connect(_hover_card.bind(cid, true))
	p.mouse_exited.connect(_hover_card.bind(cid, false))
	p.gui_input.connect(_on_card_input.bind(cid))
	p.set_meta("cid", cid)

	var m := Kit.margins(9, 8, 9, 8)
	p.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	m.add_child(v)

	v.add_child(CardArt.make(cid, kind[2], accent))

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 4)
	top.add_child(Kit.chip(kind[0], accent, accent.darkened(0.55), 11, kind[2]))
	top.add_child(Kit.spacer())
	top.add_child(Kit.chip("%d刻" % game.cost_of(cid), Kit.PAPER, Color("#1D3239")))
	v.add_child(top)

	var name_l := Kit.lbl(c["n"], 13, Kit.PAPER if playable else Kit.MUTED)
	Kit.wrap(name_l)
	name_l.custom_minimum_size = Vector2(0, 36)
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	v.add_child(name_l)

	v.add_child(_hline())

	# 效果写成流式紧凑组（「精力 +8」），而不是一条一行。
	# 一条一行时，4 条效果的牌要比 2 条的高 34px，同一排里必然高低不齐；
	# 流式排布下最坏情况也只有 2 行，所有牌高度一致（实测 4 条 / 2 条都能落在 216）。
	var eff := HFlowContainer.new()
	eff.add_theme_constant_override("h_separation", 9)
	eff.add_theme_constant_override("v_separation", 2)
	eff.custom_minimum_size = Vector2(0, 34)
	for k in c["eff"]:
		var d: int = int(c["eff"][k])
		var item := HBoxContainer.new()
		item.add_theme_constant_override("separation", 2)
		item.add_child(Kit.lbl(Kit.vital_name(k), 11, Kit.GREY))
		item.add_child(Kit.lbl("%+d" % d, 12, Kit.GREEN if d > 0 else Kit.CORAL))
		eff.add_child(item)
	v.add_child(eff)

	v.add_child(Kit.spacer(false))

	var foot := Kit.lbl("", 10, Kit.GOLD)
	if game.last_card != null:
		var cb = E.D.COMBO_BY_PAIR.get(str(game.last_card) + "|" + cid, null)
		if cb != null and not game.combos_done.has(cb["id"]):
			foot.text = "◆ 可接「连」"
	if not playable:
		foot.text = "刻数不够"
		foot.add_theme_color_override("font_color", Kit.MUTED)
	v.add_child(foot)

	for ch in p.get_children():
		Kit.ignore_mouse(ch)
	return p


# =====================================================================
#                            悬停检视
# =====================================================================
## 一张浮层，四种源。起因是卡面 150×216 塞不下 `d`（描述）和 `k`（知识点），
## 那两个字段此前只活在 Godot **原生 tooltip** 里：系统黑框、0.5s 延迟、跟着鼠标跑。
## 但顺着这条线查下去，被埋掉的远不止卡牌：
##
##   工单   `whisper`（器官的第一人称心声，全项目 40 条）和 `danger`
##          （红旗单为什么不能等）在 Godot 端**一行都没显示过**；
##   状态   `hint`（「为什么会有这个状态」）同样只活在数据里；
##   指标   没有方向说明，玩家看不出「睡眠债 40」是在涨还是该跌、到多少才算坏。
##
## 所以做成通用浮层：card / order / status / vital 共用同一张卡，
## 只换「填哪个函数」和「锚在哪个节点」。同一个交互学会一次，到处都能用。
##
## 位置是**绝对定位**，不参与容器布局：它要跨过手牌面板边界浮到工单区上面，
## 塞进任何容器都会被裁掉。

## 检视卡的浮层样式。只有描边不加投影时，它和底下的工单面板贴在一起分不出层次；
## 而这套背景本身已经很深，纯黑投影几乎看不见，所以描边要比正文面板亮一档。
func _inspect_style() -> StyleBoxFlat:
	var s := Kit.sb(Color("#0E242B"), Color("#33525B"), 12, 1)
	s.shadow_size = 14
	s.shadow_color = Color(0, 0, 0, 0.55)
	s.shadow_offset = Vector2(0, 6)
	return s


## 悬停进出。`on=false` 立刻收，`on=true` 要等一小段——扫过整排时不该一路弹。
## `kind` 见本节开头：card / order / status / vital。
func _hover(kind: String, id: String, on: bool) -> void:
	# 代数：每次进出都 +1，await 回来的那次对不上就放弃
	_inspect_gen += 1
	var gen := _inspect_gen
	if not on:
		_hide_inspect()
		return
	await get_tree().create_timer(INSPECT_DELAY).timeout
	if gen != _inspect_gen or not is_inside_tree():
		return
	# 简报/抉择/结算/通关是全屏模态，检视卡会压在它们下面露一角，不体面
	if game == null or game.phase != "shift" or _overlay.visible:
		return
	_show_inspect(kind, id, gen)


## 手牌那条悬停路径的老入口，保留一层壳：`_mk_play_card` 里绑的还是它，
## 而 card 是唯一「锚点要从牌堆里现找」的源。
func _hover_card(cid: String, on: bool) -> void:
	_hover("card", cid, on)


## 锚点每次现找（`_anchor_for`），不缓存节点——节点每次重画都会换，
## 缓存下来的那个指针在重画后就是悬空的。
func _show_inspect(kind: String, id: String, gen: int) -> void:
	var anchor := _anchor_for(kind, id)
	if anchor == null:
		return
	if _inspect_kind != kind or _inspect_id != id:
		_fill_inspect(kind, id)
	_inspect.visible = true

	# 浮层不在任何容器里，size 不会跟着内容走，只能自己收。
	#
	# 但**不能在 `_fill_inspect` 之后立刻量**：内容刚换过时
	# `get_combined_minimum_size()` 还是脏的（实测读到 1610，一帧后才是 376）。
	# 而 `Control.size` 只会被 minimum 往上顶、不会自己缩回去——用脏值设一次，
	# 之后每一张都保持那个高度。所以必须等一帧让 minimum 重算，再 `reset_size()`
	# 把浮层缩到真正的内容大小。多这一帧（16ms）在 0.16s 的悬停延迟里无感。
	await get_tree().process_frame
	if gen != _inspect_gen or not _inspect.visible or not is_inside_tree():
		return
	_inspect.reset_size()
	_place_inspect(anchor)


func _hide_inspect() -> void:
	# 顺手把代数推一格：正在 await 的那次悬停回来时会发现世界变了，直接放弃。
	_inspect_gen += 1
	_inspect_kind = ""
	_inspect_id = ""
	if _inspect != null:
		_inspect.visible = false


## 按 kind 到对应的列表里找被悬停的节点。四类源的 meta 键各自不同：
## 手牌是 cid、工单是 uid、状态是 skey、指标是 vkey。
func _anchor_for(kind: String, id: String) -> Control:
	var box: Node = null
	var meta := ""
	match kind:
		"card":
			box = _hand_box
			meta = "cid"
		"order":
			box = _orders_box
			meta = "uid"
		"status":
			box = _status_box
			meta = "skey"
		"vital":
			box = _vitals_box
			meta = "vkey"
		_:
			return null
	if box == null:
		return null
	for ch in box.get_children():
		if ch is Control and str((ch as Control).get_meta(meta, "")) == id:
			return ch as Control
	return null


## 摆放分两种：
##   手牌 / 工单——贴在锚点上方（手牌在最底下，上方全是空地）；
##   指标 / 状态——贴在锚点**右侧**：它们在最左栏，往上放的话左右一钳
##                 就正好把这个 236px 的栏目自己盖住。
## 上下左右四个方向都钳进窗口内，宁可盖住别的东西也不出屏。
func _place_inspect(anchor: Control) -> void:
	var r := anchor.get_global_rect()
	var w := _inspect.size.x
	var h := _inspect.size.y
	var side: bool = _inspect_kind == "vital" or _inspect_kind == "status"
	var x: float
	var y: float
	if side:
		x = r.end.x + 12.0
		y = r.position.y
	else:
		x = clampf(r.get_center().x - w * 0.5, 10.0, maxf(10.0, size.x - w - 10.0))
		y = r.position.y - h - 10.0
		# 上方放不下就翻到下方。顶到 10px 不动的话，卡会盖住自己悬停的那一条，
		# 玩家就没法确认「我指的是这条吗」。
		if y < 10.0:
			y = r.end.y + 10.0
	x = clampf(x, 10.0, maxf(10.0, size.x - w - 10.0))
	y = clampf(y, 10.0, maxf(10.0, size.y - h - 10.0))
	_inspect.position = Vector2(x, y)


func _fill_inspect(kind: String, id: String) -> void:
	_inspect_kind = kind
	_inspect_id = id
	Kit.clear(_inspect)

	var m := Kit.margins(14, 13, 14, 13)
	_inspect.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	m.add_child(v)

	match kind:
		"order":
			_fill_order(v, id)
		"status":
			_fill_status(v, id)
		"vital":
			_fill_vital(v, id)
		_:
			_fill_card(v, id)

	Kit.ignore_mouse(_inspect)


# ---------------------------------------------------------------- 卡牌
func _fill_card(v: VBoxContainer, cid: String) -> void:
	var c = E.D.CARD_MAP[cid]
	var kind: Array = Kit.KINDS.get(c["s"], ["·", Kit.GREY, ""])
	var accent: Color = kind[1]
	var playable: bool = game.can_play(cid) and game.phase == "shift"

	# 插画按烘焙原尺寸 264×120 显示。这是唯一无损的一档：
	# 再放大只是在 264 宽的图里插值，不会多出任何细节。
	v.add_child(CardArt.make(cid, kind[2], accent, INSPECT_W - 28, 120, 64))

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	top.add_child(Kit.chip(kind[0], accent, accent.darkened(0.55), 11, kind[2]))
	top.add_child(Kit.spacer())
	if not playable:
		top.add_child(Kit.chip("此刻不可出", Kit.MUTED, Color("#14262C"), 11))
	top.add_child(Kit.chip("%d 刻" % game.cost_of(cid), Kit.PAPER, Color("#1D3239")))
	v.add_child(top)

	v.add_child(Kit.wrap(Kit.lbl(c["n"], 17, Kit.PAPER)))

	var d := str(c.get("d", ""))
	if d != "":
		v.add_child(Kit.wrap(Kit.lbl(d, 12, Kit.PAPER2)))

	v.add_child(_hline())

	# 效果在检视卡里一行一条。卡面里用流式紧凑组是为了压高度，
	# 这里高度够，一行一条更好读——同一个信息不必两处都用最省的排法。
	var eff := VBoxContainer.new()
	eff.add_theme_constant_override("separation", 3)
	for k in c["eff"]:
		var n: int = int(c["eff"][k])
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		# 名称列给固定宽，数值才会对齐成一列。名称是 2–3 个汉字（精力/睡眠债），
		# 让它自然宽的话每行数值起点都不一样，一眼看去像三行随手写的东西。
		var nm := Kit.lbl(Kit.vital_name(k), 12, Kit.GREY)
		nm.custom_minimum_size = Vector2(62, 0)
		row.add_child(nm)
		row.add_child(Kit.lbl("%+d" % n, 13, Kit.GREEN if n > 0 else Kit.CORAL))
		eff.add_child(row)
	v.add_child(eff)

	var kb := str(c.get("k", ""))
	if kb != "":
		v.add_child(_note_box("◆ 知识点", kb, Kit.GOLD))


# ---------------------------------------------------------------- 工单
## 工单行能放下的只有：类型、标题、器官、标签、两行正文。
## 这里补上那两行之后的正文，以及三样从未露过面的东西：
##   whisper —— 器官在说话（衬线体 + 引号，全项目 40 条，此前一条都没显示）；
##   danger  —— 红旗单「为什么不能等」（6 条，此前只存在于数据里）；
##   hint    —— 「线索」（此前只活在原生 tooltip）。
func _fill_order(v: VBoxContainer, uid: String) -> void:
	var o = _order_by_uid(uid)
	if o == null:
		return
	var kind: Array = Kit.ORDER_KINDS.get(o["kind"], ["·", Kit.GREY, ""])
	var accent: Color = kind[1]

	var left: int = _order_left(o)
	var left_col: Color = Kit.CORAL if left <= 1 else (Kit.GOLD if left == 2 else Kit.GREY)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	top.add_child(Kit.chip(kind[0], accent, accent.darkened(0.55), 11, kind[2]))
	if o.get("is_emergency", false):
		top.add_child(Kit.chip("突发", Kit.PAPER, Kit.CORAL.darkened(0.2)))
	top.add_child(Kit.spacer())
	top.add_child(Kit.chip("剩 %d 刻" % left, left_col, Color("#132A31")))
	v.add_child(top)

	v.add_child(Kit.wrap(Kit.lbl(o["title"], 17, Kit.PAPER)))

	# 器官名 + 标签走**流式**容器而不是 HBox：工单行里 4 个标签加器官名在
	# 宽列里放得下，但检视卡只有 292 宽，HBox 的最小宽会被子节点撑爆——
	# 实测最宽的一张被撑到 356，于是同一个浮层在工单之间一张一个宽度。
	# 流式布局到边就换行，宽度恒等于面板宽。
	var sub := HFlowContainer.new()
	sub.add_theme_constant_override("h_separation", 5)
	sub.add_theme_constant_override("v_separation", 3)
	# 器官名在行上是 MUTED（次要信息，不抢标题），但在检视卡里它是「谁在说话」的
	# 主语，紧挨着下面的心声——太暗就不是次要，而是看不见了，所以提一档。
	sub.add_child(Kit.lbl(str(o.get("organ", "")), 11, Kit.GREY))
	for t in o.get("tags", []).slice(0, 4):
		sub.add_child(Kit.chip(str(t), Kit.GREY, Color("#102329")))
	v.add_child(sub)

	var wh := str(o.get("whisper", ""))
	if wh != "":
		v.add_child(_voice(wh))

	var body := str(o.get("body", ""))
	if body != "":
		v.add_child(Kit.wrap(Kit.lbl(body, 12, Kit.PAPER2)))

	var dg := str(o.get("danger", ""))
	if dg != "":
		v.add_child(_note_box("◆ 不能等", dg, Kit.CORAL,
			Color("#170D0A"), Color("#D95E42", 0.45)))

	var hint := str(o.get("hint", ""))
	if hint != "":
		v.add_child(_note_box("◆ 线索", hint, Kit.TEAL))


# ---------------------------------------------------------------- 状态
func _fill_status(v: VBoxContainer, key: String) -> void:
	if not E.D.STATUS.has(key):
		return
	var s = E.D.STATUS[key]
	var col := Color(s.get("color", "#8CA0A4"))

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var iname: String = Kit.STATUS_ICONS.get(key, "")
	if iname != "" and Icons.has(iname):
		head.add_child(Icons.rect(iname, 20, col))
	else:
		head.add_child(Kit.lbl(str(s.get("icon", "")), 20, col))
	head.add_child(Kit.lbl(str(s["name"]), 17, Kit.PAPER))
	v.add_child(head)

	v.add_child(Kit.wrap(Kit.lbl(str(s["desc"]), 12, Kit.PAPER2)))

	# hint 是「为什么会有这个状态」，之前哪儿都没显示。
	var hint := str(s.get("hint", ""))
	if hint != "":
		v.add_child(_hline())
		v.add_child(_note_box("◆ 说明", hint, col))


# ---------------------------------------------------------------- 指标
## 左栏那条彩色进度条回答不了两个问题：涨是好事还是坏事？到多少才算坏？
## 两个答案都在数据里（方向 `dir`、警戒阈值 Kit.BAD_BETTER / BAD_WORSE），
## 只是没地方放。这里补上，并把「离警戒还有多远」直接算给玩家看。
func _fill_vital(v: VBoxContainer, key: String) -> void:
	var meta := _vital_row(key)
	if meta.is_empty():
		return
	var dir: String = meta[2]
	var val: int = int(game.vitals[key])
	var better := dir == "better"
	var bad := Kit.is_bad(val, dir)
	# 与左栏同一套档位颜色：检视卡和指标条不能出现两种「红」
	var c2: Array = Kit.health_colors(float(val if better else 100 - val))
	var col: Color = Kit.WARN_FG if bad else c2[0]
	var line: int = Kit.BAD_BETTER if better else Kit.BAD_WORSE

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.add_child(Icons.rect(key, 20, col))
	head.add_child(Kit.lbl(Kit.vital_name(key), 17, Kit.PAPER))
	head.add_child(Kit.spacer())
	head.add_child(Kit.lbl(str(val), 22, col))
	v.add_child(head)

	var tags := HBoxContainer.new()
	tags.add_theme_constant_override("separation", 6)
	tags.add_child(Kit.chip("越高越好" if better else "越低越好", Kit.GREY, Color("#102329")))
	tags.add_child(Kit.chip("警戒线 %d" % line,
		Kit.WARN_FG if bad else Kit.MUTED, Color("#14262C")))
	v.add_child(tags)

	v.add_child(_hline())
	if bad:
		v.add_child(Kit.lbl("已越过警戒线 %d" % absi(val - line), 12, Kit.WARN_FG))
	else:
		v.add_child(Kit.lbl("距警戒线还有 %d" % absi(val - line), 12, Kit.GREY))


# ---------------------------------------------------------------- 小零件
## 器官的「心声」。用衬线体：它和上下那些数据行的区别不是内容多少，
## 而是「有人在说话」。同一套无衬线读下来会像又一条描述。
func _voice(text: String) -> Control:
	var p := Kit.panel(Color("#0A1A20"), Color(0, 0, 0, 0), 8)
	var m := Kit.margins(10, 8, 10, 8)
	m.add_child(Kit.wrap(Kit.serif_lbl(text, 13, Color("#DCE7E2"))))
	p.add_child(m)
	return p


## 一个小标题 + 一段灰字的脚注块。知识点 / 线索 / 说明 / 不能等共用，
## 区别只在标题文字、标题色和底色——四种语气各一个色，形状完全一致。
func _note_box(title: String, text: String, accent: Color,
		bg: Color = Color("#0A1A20"), border: Color = Color(0, 0, 0, 0)) -> Control:
	var p := Kit.panel(bg, border, 6, 1 if border.a > 0.0 else 0)
	var m := Kit.margins(8, 7, 8, 6)
	var kv := VBoxContainer.new()
	kv.add_theme_constant_override("separation", 3)
	kv.add_child(Kit.lbl(title, 10, accent))
	kv.add_child(Kit.wrap(Kit.lbl(text, 11, Kit.GREY)))
	m.add_child(kv)
	p.add_child(m)
	return p


func _vital_row(key: String) -> Array:
	for item in E.D.VITALS:
		if str(item[0]) == key:
			return item
	return []


func _order_by_uid(uid: String):
	for o in game.orders:
		if str(o["uid"]) == uid:
			return o
	return null


## 剩余刻数。工单行的徽标和检视卡必须用同一个算式，
## 否则同一张单在行上写着「剩 2 刻」、悬停进去写「剩 3 刻」。
func _order_left(o) -> int:
	var lim: int = game.eff_limit(o)
	return clampi(lim - (game.clock - int(o["arrival"])), 0, lim)


func _mk_order(o) -> Control:
	var kind: Array = Kit.ORDER_KINDS.get(o["kind"], ["·", Kit.GREY, ""])
	var accent: Color = kind[1]
	var sel: bool = o["uid"] == sel_uid

	var p := Kit.panel(Kit.BG2, accent if sel else Kit.LINE, 10, 2 if sel else 1)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 不再用原生 tooltip：它只装得下 `hint` 一行，而这张单子里还有器官的心声、
	# 完整正文、红旗单的「不能等」。悬停走自绘检视（见「悬停检视」一节）。
	p.set_meta("uid", o["uid"])
	p.mouse_entered.connect(_hover.bind("order", o["uid"], true))
	p.mouse_exited.connect(_hover.bind("order", o["uid"], false))
	p.gui_input.connect(_on_order_input.bind(o["uid"]))

	var m := Kit.margins(14, 8, 14, 8)
	p.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	m.add_child(v)

	var left: int = _order_left(o)
	var left_col: Color = Kit.CORAL if left <= 1 else (Kit.GOLD if left == 2 else Kit.GREY)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	top.add_child(Kit.chip(kind[0], accent, accent.darkened(0.55), 11, kind[2]))
	if o.get("is_emergency", false):
		top.add_child(Kit.chip("突发", Kit.PAPER, Kit.CORAL.darkened(0.2)))
	var title_l := Kit.lbl(o["title"], 15, Kit.PAPER)
	Kit.wrap(title_l)
	top.add_child(title_l)
	top.add_child(Kit.chip("剩 %d 刻" % left, left_col, Color("#132A31")))
	v.add_child(top)

	var sub := HBoxContainer.new()
	sub.add_theme_constant_override("separation", 5)
	sub.add_child(Kit.lbl(str(o.get("organ", "")), 11, Kit.MUTED))
	sub.add_child(Kit.spacer())
	for t in o.get("tags", []).slice(0, 3):
		sub.add_child(Kit.chip(str(t), Kit.GREY, Color("#102329")))
	v.add_child(sub)

	var body := Kit.lbl(o["body"], 12, Kit.GREY)
	Kit.wrap(body)
	body.custom_minimum_size = Vector2(0, 28)
	body.clip_text = true
	v.add_child(body)

	for ch in p.get_children():
		Kit.ignore_mouse(ch)
	return p


## 已处理工单的收束行：✓ 标题 —— 用了哪张牌 · 评级
func _mk_done_row(o) -> Control:
	var grade := ""
	var card_name := ""
	for e in game.log:
		if e[1] != null and e[1]["uid"] == o["uid"]:
			grade = str(e[0])
			card_name = str(e[2]["n"])
			break
	var g: Array = Kit.GRADES.get(grade, ["已处理", Kit.GREY])

	var p := Kit.panel(Color("#060F13"), Color(0, 0, 0, 0), 8)
	var m := Kit.margins(14, 5, 14, 5)
	p.add_child(m)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	m.add_child(h)

	h.add_child(Kit.lbl("✓", 12, g[1]))
	var t := Kit.lbl(o["title"], 12, Kit.MUTED)
	t.clip_text = true
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(t)
	if card_name != "":
		h.add_child(Kit.lbl(card_name, 11, Color("#3E5A60")))
	h.add_child(Kit.chip(g[0], g[1].darkened(0.15), Color("#0B1C21"), 10))
	return p


func _hline() -> Control:
	var r := ColorRect.new()
	r.color = Color("#16333B")
	r.custom_minimum_size = Vector2(0, 1)
	return r


# =====================================================================
#                              交互
# =====================================================================
func _on_card_input(event: InputEvent, cid: String) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not (mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT):
		return
	accept_event()
	if reroll_mode:
		_do_reroll(cid)
	else:
		_try_play(cid)


func _on_order_input(event: InputEvent, uid: String) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not (mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT):
		return
	accept_event()
	sel_uid = uid
	sfx.play("ui")
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not (k.pressed and not k.echo):
		return

	# 全局键：任何模态下都能用（弹着结算窗也该能存档）
	if k.ctrl_pressed and k.keycode == KEY_S:
		get_viewport().set_input_as_handled()
		_save_game(true)
		return
	if k.ctrl_pressed and k.keycode == KEY_L:
		get_viewport().set_input_as_handled()
		_load_game()
		return
	if not k.ctrl_pressed and k.keycode == KEY_M:
		get_viewport().set_input_as_handled()
		_toggle_audio()
		return
	# Esc / O：设置面板。压在一切模态之上，所以不放在下面的 phase 闸门之后。
	if not k.ctrl_pressed and (k.keycode == KEY_ESCAPE or k.keycode == KEY_O):
		get_viewport().set_input_as_handled()
		_toggle_settings()
		return

	if game.phase != "shift" or game.pending_dilemma != null:
		return
	match k.keycode:
		KEY_SPACE:
			get_viewport().set_input_as_handled()
			_on_wait()
		KEY_R:
			get_viewport().set_input_as_handled()
			_on_reroll_toggle()
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
			var i: int = k.keycode - KEY_1
			if i < game.hand.size():
				get_viewport().set_input_as_handled()
				_try_play(game.hand[i])


func _current_uid() -> String:
	var act: Array = game.active_orders()
	if act.is_empty():
		return ""
	if sel_uid != "":
		for o in act:
			if o["uid"] == sel_uid:
				return sel_uid
	sel_uid = act[0]["uid"]
	return sel_uid


func _try_play(cid: String) -> void:
	if game.phase != "shift" or not game.hand.has(cid):
		return
	if not game.can_play(cid):
		sfx.play("status")
		_flash("刻数不够，试试「等一刻」或换签", Kit.GOLD)
		return
	var uid := _current_uid()
	if uid == "":
		sfx.play("status")
		_flash("没有待处理工单", Kit.GOLD)
		return
	# 转诊牌对「既不是红旗、也不是本单正解」的单无效（引擎会拒），先说清楚，
	# 别让玩家点了没反应。预约门诊这类同时是普通单正解的牌不受影响。
	if E.D.CARD_MAP[cid]["s"] == "refer":
		for o in game.orders:
			if o["uid"] == uid:
				var valid: bool = cid in o["best"] or cid in o["good"]
				if o["kind"] != "redflag" and not valid:
					sfx.play("status")
					_flash("这张转诊牌对这张单没用", Kit.GOLD)
					return
				break
	game.play_card(cid, uid)
	_after_action()


func _do_reroll(cid: String) -> void:
	var ok: bool = game.reroll(cid)
	reroll_mode = false
	if ok:
		sfx.play("select")
	else:
		sfx.play("status")
		_flash("换签次数用完了", Kit.GOLD)
	_refresh()


func _on_wait() -> void:
	if game.phase != "shift":
		return
	if game.clock + 1 > game.max_clock:
		sfx.play("status")
		_flash("已经到最后一刻了", Kit.GOLD)
		return
	game.wait()
	_after_action()


func _on_reroll_toggle() -> void:
	if game.phase != "shift":
		return
	if game.rerolls <= 0:
		sfx.play("status")
		_flash("本班换签次数用完了", Kit.GOLD)
		return
	reroll_mode = not reroll_mode
	sfx.play("ui")
	_refresh()


func _after_action() -> void:
	var fb = game.pending_feedback
	if fb != null and game.phase != "over":
		_show_result(fb)
		game.pending_feedback = null
	_consume_flashes()
	_refresh()


## 引擎只负责「置标志」，表现层负责「取走并播放」——所以这里读完就清空。
## 与判定音（best/good/bad）叠放：判定音是主音，这几个只是点缀。
## 连击不单独出声（它必然伴随一次 best），否则两个同音叠在一起只显得糊。
func _consume_flashes() -> void:
	if sfx == null:
		return
	var pick := ""
	if game.emergency_flash != null:
		pick = "emergency"
	elif game.combo_flash != null:
		pick = "combo"
	elif game.cured_flash != null:
		pick = "cure"
	game.emergency_flash = null
	game.combo_flash = null
	game.cured_flash = null
	game.streak_flash = null
	if pick != "":
		sfx.play(pick)


func _show_result(fb) -> void:
	var grade := "incident"
	if fb.size() > 3:
		grade = fb[3]
	var g: Array = Kit.GRADES.get(grade, ["结果", Kit.GREY])
	var order = fb[1]
	var card = fb[2]
	var text := ""
	if grade == "best" or grade == "good":
		text = str(order.get("good_text", ""))
	elif grade == "bad" or grade == "incident":
		text = str(order.get("bad_text", ""))
	else:  # off：牌与本病单没对上，不编造「有效」的叙事
		text = "这张好像没对症——它不是这号子该用的处置。"
	# 判定音：正解上扬、可行平稳、欠妥下沉（配方见 data.gd 的 SOUNDS）
	var grade_sound: String = {"best": "best", "good": "good", "bad": "bad", "off": "toast"}.get(grade, "good")
	sfx.play(grade_sound)
	_flash("%s　%s｜%s" % [g[0], card["n"], text], g[1])


func _flash(msg: String, color: Color) -> void:
	_flash_active = true
	_toast_l.text = msg
	_toast_l.add_theme_color_override("font_color", color)
	_toast.add_theme_stylebox_override("panel", Kit.sb(Color("#0E262D"), color, 10, 1))
	# 提示条淡入：它是"刚刚发生了什么"的反馈，突然出现会显得像界面闪了一下
	if not _no_fx:
		_toast.modulate.a = 0.0
		create_tween().tween_property(_toast, "modulate:a", 1.0, 0.12)
	_toast_gen += 1
	var gen := _toast_gen
	await get_tree().create_timer(3.0).timeout
	if gen == _toast_gen and is_instance_valid(_toast):
		_flash_active = false
		_refresh_hint()


# =====================================================================
#                              模态层
# =====================================================================
func _refresh_overlay() -> void:
	var want := ""
	if _settings_open:
		# 设置压在一切之上：简报/抉择/结算哪一屏都能叫出来，关掉就回到原屏。
		# 不这么做的话，玩家想调音量就得先「打完这一班」。
		want = "settings"
	elif game.campaign["cleared"]:
		want = "ending"
	elif game.pending_chapter_intro != null and not game.pending_chapter_intro.is_empty():
		want = "chapter_intro"
	elif game.phase == "over":
		want = "over"
	elif game.pending_dilemma != null:
		want = "dilemma"
	elif game.phase == "brief":
		want = "brief"
	elif game.phase == "settle":
		want = "settle"

	var sig := want
	match want:
		"dilemma":
			sig += "|" + str(game.pending_dilemma.get("id", ""))
		"chapter_intro":
			sig += "|" + str(game.pending_chapter_intro.get("no", ""))
		"brief", "settle":
			sig += "|%d|%d" % [game.campaign["chapter"], game.campaign["shift"]]
			sig += "|" + str(game.clock)

	if sig == _overlay_sig:
		return
	_overlay_sig = sig

	Kit.clear(_overlay)
	if want == "":
		_overlay.visible = false
		_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return

	_overlay.visible = true
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_toast_gen += 1
	_flash_active = false

	# 模态切换的音：简报「落座」、抉择「抽气」、结算「翻页」、事故「警报」、通关「长音」
	match want:
		"settings":
			sfx.play("ui")
		"brief":
			sfx.play("ui")
		"dilemma":
			sfx.play("select")
		"settle":
			sfx.play("settle")
		"over":
			sfx.play("incident")
		_:
			sfx.play("ending")

	var dim := ColorRect.new()
	# 遮罩浓度：0.74 → 0.66，是在背景接进来之后调的。
	#
	# 在这之前底下是纯黑，0.74 和 0.85 看起来一样——遮罩只是"把主界面压下去"。
	# 有了背景之后它变成了一个**背景可见度旋钮**：0.74 时面板外那圈房间几乎看不见
	# （背景 luma 0.08 × 0.26 剩 0.02，和纯黑没差），模态屏就还是"一块板浮在黑上"。
	# 0.66 让房间隐约透出来，但主界面文字仍读不出（不是靠 alpha 拦住阅读，
	# 是 12px 的正文本来就在这个亮度下不可读，见下）。
	dim.color = Color(0.01, 0.03, 0.035, 0.66)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(center)

	var body: Control
	match want:
		"settings": body = _ov_settings()
		"brief": body = _ov_brief()
		"dilemma": body = _ov_dilemma()
		"settle": body = _ov_settle()
		"over": body = _ov_over()
		"chapter_intro": body = _ov_chapter_intro()
		_: body = _ov_ending()
	body.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(body)

	# 入场动效：整屏重画 → 面板淡入，遮罩也一起压上来。
	# 只做透明度、不做位移/缩放：CenterContainer 会覆盖 position，
	# 而 scale 会让中文小字在动画中糊掉一帧（比"没有动效"更廉价）。
	if not _no_fx:
		body.modulate.a = 0.0
		dim.modulate.a = 0.0
		create_tween().tween_property(body, "modulate:a", 1.0, 0.16).set_ease(Tween.EASE_OUT)
		create_tween().tween_property(dim, "modulate:a", 1.0, 0.12)


## 模态的统一外壳：一块面板 + 一个纵向内容列。
##
## `expr` 非空且该宿主的图读得出来时，左侧会多出一张 216×288 的**档案照**，
## 内容列整体右移。为什么是"档案照"而不是站着的立绘：这段剧情里宿主并不在场——
## 你在值班室看的是他的记录，所以这里该出现的是**一张照片**，不是一个人站在暗处。
## 这个判断同时解决了两件事：不用处理"人物站在渐隐背景上"的合成感，
## 也让 216 宽的照片在 856 宽的面板里显得合理。
##
## 图缺失时静默退回原来的一栏布局（少一张图不该让整块面板塌掉）。
func _ov_frame(expr: String = "") -> Array:
	var p := Kit.panel(Kit.BG1, Kit.TEAL_D, 14, 1)
	# 最小宽度必须把立绘和它两侧的间距算进去。
	# 只写无立绘时的 640，结算/事故/结局（正文短、撑不开）的文字列就只剩 346px，
	# 同一个句子在简报里一行、在结算里折三行——同一个面板换一屏就变窄，很显廉价。
	# 22(左) + 216(照片) + 22(间距) + 560(文字列) + 30(右) = 850
	p.custom_minimum_size = Vector2(MODAL_W, 0)
	var host_no: int = int(game.get_chapter()["no"])
	var tex := CharArt.tex(host_no, expr) if expr != "" else null
	if tex == null:
		p.custom_minimum_size = Vector2(MODAL_W_NOPORTRAIT, 0)
		var m := Kit.margins(30, 24, 30, 24)
		p.add_child(m)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 12)
		m.add_child(v)
		return [p, v]

	var outer := Kit.margins(22, 22, 30, 22)
	p.add_child(outer)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 22)
	outer.add_child(row)
	row.add_child(_portrait(tex, expr))
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 12)
	row.add_child(col)
	# 照片（288）通常比正文高，面板会被照片撑起来，正文下面留出一块悬空的空白。
	# 在这里预埋一个纵向弹簧：后面加进 col 的动作按钮就被顶到底边，
	# 那块空白变成"正文与操作之间"的间距，而不是"右下角没人用的地方"。
	col.add_child(Kit.spacer(false))
	return [p, col]


## 一张贴顶的档案照 + 一行状态标注，下方留白（内容列更高时也不跟着拉长）。
func _portrait(tex: Texture2D, expr: String) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	var fr := Kit.panel(Color("#08171C"), Kit.LINE, 5, 1)
	var tr := TextureRect.new()
	tr.texture = tex
	tr.custom_minimum_size = Vector2(CharArt.W, CharArt.H)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# 432×576 → 216×288 正好 2:1，等比；写 SCALE 而不是 KEEP_ASPECT，
	# 是为了万一有人塞了别的比例的图，宁可变形也要让测试发现，
	# 而不是悄悄留出一条黑边（黑边会被误读成"照片没拍满"）。
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	fr.add_child(tr)
	col.add_child(fr)

	var cap := HBoxContainer.new()
	cap.add_theme_constant_override("separation", 5)
	cap.add_child(Kit.lbl("◆ 状态", 10, Kit.GOLD))
	cap.add_child(Kit.lbl(CharArt.label_of(expr), 10, Kit.GREY))
	col.add_child(cap)

	col.add_child(Kit.spacer(false))
	return col


func _ov_brief() -> Control:
	# 简报只有一个表情：平静。这不是偷懒——简报发生在**交手之前**，
	# 当时还没有"疲惫"或"释然"可言，那时候给人一个疲惫的脸是倒因为果。
	# 四张差分的分工在下面三个模态里（结算看评级、事故看警觉、结局看释然）。
	var fr := _ov_frame("calm")
	var p: PanelContainer = fr[0]
	var v: VBoxContainer = fr[1]
	var ch = game.get_chapter()
	var sd = game.get_shift_def()
	var env = game.env

	var kicker := HBoxContainer.new()
	kicker.add_theme_constant_override("separation", 6)
	kicker.add_child(Kit.chip("%s · %s" % [ch["code"], ch["title"]], Kit.TEAL, Color("#0E2A2E")))
	kicker.add_child(Kit.chip("第 %d 班" % sd["n"], Kit.GOLD, Color("#2A2410")))
	kicker.add_child(Kit.spacer())
	kicker.add_child(Kit.lbl("%s，%d 岁 · %s" % [ch["host"], int(ch["age"]), ch["job"]], 12, Kit.GREY))
	v.add_child(kicker)

	v.add_child(Kit.serif_lbl(str(sd["name"]), 26, Kit.PAPER))
	v.add_child(Kit.wrap(Kit.serif_lbl(str(sd["intro"]), 15, Kit.PAPER2), 560))
	v.add_child(_hline2())

	v.add_child(_kv("环境", "%s — %s" % [env["name"], env["desc"]], Color(env["color"])))
	v.add_child(_kv("目标", str(sd["goal"]["text"]), Kit.PAPER2))
	v.add_child(_kv("时限", "%d 刻　·　开局抽 %d 张　·　换签 %d 次" % [
		game.max_clock, _expected_hand(), game.rerolls], Kit.PAPER2))
	var gifts: Array = sd.get("gift", [])
	if not gifts.is_empty():
		v.add_child(_gift_row(gifts, str(sd.get("gift_note", ""))))

	var brow := HBoxContainer.new()
	brow.add_child(Kit.spacer())
	var b := Kit.button("开始值班", Kit.TEAL, 180)
	b.pressed.connect(_start_shift)
	brow.add_child(b)
	v.add_child(brow)
	return p


## 设置面板。
##
## 为什么是「压在一切之上的独立模态」而不是页面里的一个 tab：
## 玩家第一次想调音量时，往往正卡在简报或结算里——如果设置只能在主界面进，
## 他就得先打完这一班。所以它优先级最高，关掉就回到原来那屏。
func _ov_settings() -> Control:
	var p := Kit.panel(Kit.BG1, Kit.TEAL_D, 14, 1)
	p.custom_minimum_size = Vector2(600, 0)
	var m := Kit.margins(30, 26, 30, 22)
	p.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	m.add_child(v)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	top.add_child(Kit.chip("设置", Kit.TEAL, Color("#0E2A2E")))
	top.add_child(Kit.spacer())
	top.add_child(Kit.lbl("Esc 关闭　·　M 静音", 11, Kit.MUTED))
	v.add_child(top)
	v.add_child(_hline2())

	v.add_child(_slider_row("总音量", "master"))
	v.add_child(_slider_row("音效", "sfx"))
	v.add_child(_slider_row("音乐", "music"))
	v.add_child(_hline2())

	# —— 窗口模式：两个按钮，当前那个是实心的 ——
	var full: bool = bool(_settings.get("fullscreen", false))
	var wrow := HBoxContainer.new()
	wrow.add_theme_constant_override("separation", 10)
	var wl := Kit.lbl("窗口", 13, Kit.PAPER2)
	wl.custom_minimum_size = Vector2(58, 0)
	wrow.add_child(wl)
	var b_win: Button = Kit.ghost_button("窗口", Kit.TEAL, 96) if full else Kit.button("窗口", Kit.TEAL, 96)
	b_win.pressed.connect(func(): _set_fullscreen(false))
	wrow.add_child(b_win)
	var b_full: Button = Kit.button("全屏", Kit.TEAL, 96) if full else Kit.ghost_button("全屏", Kit.TEAL, 96)
	b_full.pressed.connect(func(): _set_fullscreen(true))
	wrow.add_child(b_full)
	wrow.add_child(Kit.spacer())
	v.add_child(wrow)

	# —— 分辨率：只有窗口模式才有意义，全屏时置灰 ——
	var rrow := HBoxContainer.new()
	rrow.add_theme_constant_override("separation", 10)
	var rl := Kit.lbl("分辨率", 13, Kit.PAPER2)
	rl.custom_minimum_size = Vector2(58, 0)
	rrow.add_child(rl)
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.custom_minimum_size = Vector2(168, 34)
	opt.add_theme_font_override("font", Kit.sans())
	opt.add_theme_font_size_override("font_size", 13)
	for i in range(AppSettings.RESOLUTIONS.size()):
		opt.add_item(AppSettings.resolution_label(i), i)
	opt.selected = clampi(int(_settings.get("res_index", 0)), 0, AppSettings.RESOLUTIONS.size() - 1)
	opt.disabled = full
	opt.item_selected.connect(func(idx: int): _set_resolution(idx))
	rrow.add_child(opt)
	rrow.add_child(Kit.lbl("全屏时按显示器自适应" if full else "窗口模式下生效", 11, Kit.MUTED))
	rrow.add_child(Kit.spacer())
	v.add_child(rrow)

	v.add_child(_hline2())
	v.add_child(Kit.wrap(Kit.lbl(
		"本作是健康科普作品，不构成医疗建议。身体不适请及时就医。", 11, Kit.MUTED), 540))

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 10)
	var reset := Kit.ghost_button("恢复默认", Kit.GREY, 116)
	reset.pressed.connect(func(): _reset_settings())
	brow.add_child(reset)
	brow.add_child(Kit.spacer())
	var done := Kit.button("完成", Kit.TEAL, 150)
	done.pressed.connect(func(): _toggle_settings())
	brow.add_child(done)
	v.add_child(brow)
	return p


## 一行音量：标签 + 滑块 + 百分比。
##
## 落盘放在 `drag_ended`：拖动时每帧写 cfg 既没必要，也会让配置文件反复重写。
## 但音量本身要实时生效，所以 `value_changed` 里就改音频总线。
func _slider_row(label: String, key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := Kit.lbl(label, 13, Kit.PAPER2)
	l.custom_minimum_size = Vector2(58, 0)
	row.add_child(l)

	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.01
	s.value = float(_settings.get(key, 0.5))
	s.custom_minimum_size = Vector2(320, 20)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	s.add_theme_stylebox_override("slider", Kit.sb(Color("#123039"), Color("#1B3D46"), 3, 1))
	s.add_theme_stylebox_override("grabber_area", Kit.sb(Kit.TEAL_D, Kit.TEAL_D, 3))
	s.add_theme_stylebox_override("grabber_area_highlight", Kit.sb(Kit.TEAL, Kit.TEAL, 3))
	row.add_child(s)

	var pct := Kit.lbl("%d%%" % int(round(s.value * 100.0)), 12, Kit.MUTED)
	pct.custom_minimum_size = Vector2(44, 0)
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(pct)

	s.value_changed.connect(func(val: float):
		pct.text = "%d%%" % int(round(val * 100.0))
		_settings[key] = val
		_apply_audio_settings()
	)
	s.drag_ended.connect(func(_changed: bool): AppSettings.save_settings(_settings))
	return row


func _apply_audio_settings() -> void:
	AudioMix.apply(_settings)
	if sfx != null:
		sfx.volume = float(_settings.get("sfx", 0.72))
	if bgm != null:
		# 音乐音量拖到 0 就真的停掉播放实例：只把总线调到 -60dB 还在后台解码
		bgm.set_enabled(float(_settings.get("music", 0.42)) > 0.005)


## 章节变了就换一段移调，同一章重复调用是幂等的（不会把音乐打断重放）。
func _sync_bgm() -> void:
	if bgm == null or game == null:
		return
	bgm.play_chapter(int(game.get_chapter()["no"]))


func _toggle_settings() -> void:
	_settings_open = not _settings_open
	sfx.play("ui")
	_overlay_sig = ""
	_refresh_overlay()


## 改完窗口/分辨率要重建面板：按钮的实心/描边状态是在构建时定的。
func _persist_display_settings() -> void:
	AppSettings.save_settings(_settings)
	AppSettings.apply_display(_settings)
	_overlay_sig = ""
	_refresh_overlay()


func _set_fullscreen(on: bool) -> void:
	if bool(_settings.get("fullscreen", false)) == on:
		return
	_settings["fullscreen"] = on
	sfx.play("select")
	_persist_display_settings()


func _set_resolution(idx: int) -> void:
	_settings["res_index"] = idx
	sfx.play("select")
	_persist_display_settings()


func _reset_settings() -> void:
	_settings = AppSettings.defaults()
	AppSettings.save_settings(_settings)
	_apply_audio_settings()
	sfx.play("select")
	_persist_display_settings()


func _ov_dilemma() -> Control:
	var fr := _ov_frame()
	var p: PanelContainer = fr[0]
	var v: VBoxContainer = fr[1]
	var d = game.pending_dilemma

	v.add_child(Kit.chip("值班中 · 抉择", Kit.GOLD, Color("#2A2410")))
	v.add_child(Kit.serif_lbl(str(d["title"]), 22, Kit.PAPER))
	v.add_child(Kit.wrap(Kit.serif_lbl(str(d["text"]), 15, Kit.PAPER2), 560))
	v.add_child(_hline2())

	for i in range(d["options"].size()):
		v.add_child(_mk_option(d["options"][i], i))
	return p


func _mk_option(opt, idx: int) -> Control:
	var p := Kit.panel(Color("#0D2229"), Kit.LINE, 10, 1)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	p.gui_input.connect(_on_option_input.bind(idx))

	var m := Kit.margins(14, 11, 14, 11)
	p.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	m.add_child(v)

	var head := HBoxContainer.new()
	head.add_child(Kit.lbl(str(opt["label"]), 16, Kit.PAPER))
	head.add_child(Kit.spacer())
	head.add_child(Kit.lbl("选择 →", 11, Kit.TEAL))
	v.add_child(head)

	v.add_child(Kit.lbl(str(opt.get("desc", "")), 12, Kit.GREY))

	for ch in p.get_children():
		Kit.ignore_mouse(ch)
	return p


func _on_option_input(event: InputEvent, idx: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not (mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT):
		return
	accept_event()
	_choose_option(idx)


func _choose_option(idx: int) -> void:
	game.choose_dilemma(idx)
	_refresh()


func _ov_settle() -> Control:
	# 评级要先算出来：它决定这张脸是"释然"还是"疲惫"。
	# 这是四张差分里唯一真正有信息的一张——分数已经在下面写着，
	# 照片负责让人**先看见**这一班把那具身体弄成了什么样，再去看数字。
	if game.rating == null:
		game.rating = game.compute_rating()
	var r = game.rating
	var fr := _ov_frame(_settle_expr(str(r["grade"])))
	var p: PanelContainer = fr[0]
	var v: VBoxContainer = fr[1]
	var col := _grade_color(str(r["grade"]))
	var sd = game.get_shift_def()
	var gp = game.goal_progress()

	v.add_child(Kit.chip("本班结束", Kit.TEAL, Color("#0E2A2E")))

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 18)
	var big := Kit.serif_lbl(str(r["grade"]), 60, col)
	head.add_child(big)
	var colv := VBoxContainer.new()
	colv.add_theme_constant_override("separation", 4)
	colv.add_child(Kit.lbl("%d 分　·　%s" % [int(r["score"]), str(r.get("comment", ""))], 15, Kit.PAPER))
	colv.add_child(Kit.lbl("目标 %s　%s" % [str(sd["goal"]["text"]), "达成 ✓" if gp[2] else "未达成"], 12,
		Kit.GREEN if gp[2] else Kit.CORAL))
	head.add_child(colv)
	v.add_child(head)

	v.add_child(_hline2())

	var s = game.stats
	v.add_child(Kit.lbl("正解 %d　可行 %d　欠妥 %d　误信 %d　事故 %d　余 %d 刻" % [
		int(s["best"]), int(s["good"]), int(s["bad"]), int(s["quack"]),
		game.incidents, maxi(0, game.max_clock - game.clock)], 13, Kit.PAPER2))
	if game.best_streak >= 2:
		v.add_child(Kit.lbl("最长连击 %d 次" % game.best_streak, 12, Kit.GOLD))

	var brow := HBoxContainer.new()
	brow.add_child(Kit.spacer())
	var last: bool = game.campaign["chapter"] >= E.D.CHAPTERS.size() - 1 and game.campaign["shift"] >= 2
	var b := Kit.button("完成战役" if last else "进入下一班", Kit.TEAL, 190)
	b.pressed.connect(_next_shift)
	brow.add_child(b)
	v.add_child(brow)
	return p


## 评级 → 表情。S/A 是释然，B 是平静，C 是疲惫。
## 阈值故意宽（只有 C 才给疲惫）：四张差分里"疲惫"最容易被误读成"生病"，
## 一局里出现太频繁就不稀奇了；只留给出问题的班次，它才是信息。
func _settle_expr(grade: String) -> String:
	if grade == "S" or grade == "A":
		return "relief"
	if grade == "C":
		return "tired"
	return "calm"


func _ov_over() -> Control:
	# 事故是唯一"警觉"有意义的时刻：这张脸不是评价，是反应。
	var fr := _ov_frame("alert")
	var p: PanelContainer = fr[0]
	var v: VBoxContainer = fr[1]
	var fb = game.pending_feedback
	var order = fb[1] if fb != null and fb.size() > 1 else null
	var card = fb[2] if fb != null and fb.size() > 2 else null

	v.add_child(Kit.chip("事故 · 本班作废", Kit.CORAL, Color("#3A1410")))
	v.add_child(Kit.serif_lbl("身体被推进了危险区", 24, Kit.PAPER))
	if order != null and card != null:
		v.add_child(Kit.wrap(Kit.serif_lbl(
			"「%s」你用了「%s」。这一步没有第二次机会。" % [str(order["title"]), str(card["n"])],
			15, Kit.PAPER2), 560))
	v.add_child(_hline2())
	v.add_child(Kit.lbl("红旗工单只能用「转诊」类处置。本班需要重打。", 12, Kit.GREY))

	var brow := HBoxContainer.new()
	brow.add_child(Kit.spacer())
	var b := Kit.button("重打本班", Kit.CORAL, 170)
	b.pressed.connect(_retry_shift)
	brow.add_child(b)
	v.add_child(brow)
	return p


func _ov_ending() -> Control:
	var true_end: bool = game.true_ending()
	var p := Kit.panel(Kit.BG1, Kit.TEAL_D, 14, 1)
	p.custom_minimum_size = Vector2(720, 0)
	var m := Kit.margins(30, 26, 30, 26)
	p.add_child(m)

	# 结局内容较长（5 封回信），用滚动容器兜住，避免在小窗里被截断。
	var sc := ScrollContainer.new()
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.custom_minimum_size = Vector2(660, 600)
	m.add_child(sc)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)

	# —— 结局类型 + 标题 ——
	var ev: Dictionary = _ending_variant()
	if true_end:
		v.add_child(Kit.chip("真结局 · 交班", Kit.GOLD, Color("#2A2410")))
	else:
		v.add_child(Kit.chip("结局 · " + ev["name"], Kit.TEAL, Color("#0D2229")))
	v.add_child(Kit.serif_lbl("%s个班次之后" % _cn_num(_total_shifts()), 26, Kit.PAPER))

	# —— 结局正文 ——
	var end_text: String = E.D.TRUE_ENDING["text"] if true_end else ev["text"]
	v.add_child(Kit.wrap(Kit.serif_lbl(end_text, 15, Kit.PAPER2), 600))

	# —— 评级汇总 ——
	v.add_child(_hline2())
	v.add_child(_rating_strip())
	var counts := {"S": 0, "A": 0, "B": 0, "C": 0}
	for r in game.campaign["ratings"]:
		if r != null and counts.has(r):
			counts[r] += 1
	v.add_child(Kit.lbl("S %d　A %d　B %d　C %d　·　累计事故 %d" % [
		counts["S"], counts["A"], counts["B"], counts["C"],
		int(game.campaign["total_incidents"])], 12, Kit.GREY))

	# —— 五个宿主的后来 ——
	v.add_child(_hline2())
	v.add_child(Kit.serif_lbl("他们后来……", 17, Kit.GOLD))
	for ch in E.D.CHAPTERS:
		var no: int = int(ch["no"])
		var host: String = str(ch["host"])
		var letter: String = E.D.LETTERS.get(no, "")
		if letter == "":
			continue
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 8)
		hb.add_child(Kit.chip(host, Kit.GOLD, Color("#2A2410"), 11))
		hb.add_child(Kit.lbl("%d岁 · %s" % [int(ch["age"]), str(ch["job"])], 11, Kit.GREY))
		v.add_child(hb)
		v.add_child(Kit.wrap(Kit.serif_lbl(letter, 13.5, Kit.PAPER2), 600))

	# —— 再来一次 ——
	v.add_child(Kit.spacer(false))
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 10)
	brow.add_child(Kit.spacer(true))
	var b := Kit.button("再来一次", Kit.TEAL, 170)
	b.pressed.connect(_restart)
	brow.add_child(b)
	v.add_child(brow)
	return p


## 根据整场表现，从 ENDINGS 里挑一个结局变体。
## 事故多 → 透支；误导多 → 被误导；信任高 → 和解；否则 → 开始。
func _ending_variant() -> Dictionary:
	var c: Dictionary = game.campaign
	var mis: int = 0
	for mm in c["chapter_mis"]:
		mis += int(mm)
	var inc: int = int(c["total_incidents"])
	var avg_t: float = 0.0
	for t in c["chapter_trust"]:
		avg_t += float(t)
	avg_t = avg_t / max(1, c["chapter_trust"].size())
	if inc >= 4:
		return E.D.ENDINGS["collapse"]
	if mis >= 3:
		return E.D.ENDINGS["false"]
	if avg_t >= 62.0:
		return E.D.ENDINGS["reconcile"]
	return E.D.ENDINGS["begin"]


## 章节过场：跨章时从结算页「下一班」按钮之后弹出，背景用 bg_corridor_night（走廊夜景）。
##
## 故意**不放宿主档案照**——档案照是「你在值班室看他的记录」的语义，属于简报；
## 过场是「你走在去医院另一头的走廊上、夜很深」的语义，该是空旷的、没有人物的。
## 把照片挪到过场会模糊这两屏的分工，也让 corridor 这张图没了用武之地。
func _ov_chapter_intro() -> Control:
	var ch: Dictionary = game.pending_chapter_intro
	if ch.is_empty():
		ch = game.get_chapter()

	var p := Kit.panel(Kit.BG1, Kit.TEAL_D, 14, 1)
	p.custom_minimum_size = Vector2(MODAL_W_NOPORTRAIT, 0)
	var m := Kit.margins(30, 26, 30, 26)
	p.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	m.add_child(v)

	var kicker := HBoxContainer.new()
	kicker.add_theme_constant_override("separation", 8)
	kicker.add_child(Kit.chip("%s" % str(ch.get("code", "")), Kit.GOLD, Color("#2A2410")))
	kicker.add_child(Kit.chip("值班交接", Kit.TEAL, Color("#0E2A2E")))
	kicker.add_child(Kit.spacer())
	kicker.add_child(Kit.lbl("夜已深，你走向另一间值班室", 11, Kit.MUTED))
	v.add_child(kicker)

	v.add_child(Kit.serif_lbl(str(ch.get("title", "")), 28, Kit.PAPER))
	v.add_child(Kit.wrap(Kit.serif_lbl(str(ch.get("logline", "")), 15, Kit.PAPER2), 560))
	v.add_child(_hline2())

	v.add_child(_kv("宿主", "%s，%d 岁 · %s" % [
		str(ch.get("host", "")), int(ch.get("age", 0)), str(ch.get("job", ""))]))
	v.add_child(_kv("本章主题", str(ch.get("theme", "")), Kit.PAPER2))
	v.add_child(_kv("关注", str(ch.get("focus", "")), Kit.PAPER2))
	if ch.has("unlock"):
		v.add_child(_kv("解锁", str(ch["unlock"]), Kit.GREEN))

	v.add_child(Kit.spacer(false))
	var brow := HBoxContainer.new()
	brow.add_child(Kit.spacer())
	var b := Kit.button("进入 %s" % str(ch.get("code", "")), Kit.TEAL, 190)
	b.pressed.connect(_dismiss_chapter_intro)
	brow.add_child(b)
	v.add_child(brow)
	return p


## 开局会抽几张：与 engine.start_shift 的规则一致（失眠 -1、平静 +1、独自 -1，下限 2）
func _expected_hand() -> int:
	var n := 5
	if game.statuses.has("insomnia"):
		n -= 1
	if game.env_key == "calm":
		n += 1
	elif game.env_key == "alone":
		n -= 1
	return maxi(2, n)


func _kv(key: String, val: String, col: Color = Kit.PAPER2) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var k := Kit.lbl(key, 12, Kit.MUTED)
	k.custom_minimum_size = Vector2(58, 0)
	h.add_child(k)
	h.add_child(Kit.lbl(val, 13, col))
	return h


## 宿主自己带回来的干扰牌。必须在简报里露出来。
##
## 这些牌是强制塞进牌组的——不打招呼就多一张废牌，玩家只会当成 bug；
## 说清楚「他自己买回来的，甩不掉」，它才成为难度的一部分。
func _gift_row(ids: Array, note: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var names := PackedStringArray()
	for cid in ids:
		var c: Dictionary = E.D.CARD_MAP.get(cid, {})
		names.append("◈ " + str(c.get("n", cid)))
	box.add_child(_kv("带回", "　".join(names), Kit.GOLD))
	if note.strip_edges() != "":
		var m := MarginContainer.new()
		m.add_theme_constant_override("margin_left", 68)
		m.add_child(Kit.wrap(Kit.serif_lbl(note, 12, Kit.GREY), 480))
		box.add_child(m)
	return box


func _hline2() -> Control:
	var r := ColorRect.new()
	r.color = Color("#1B3D46")
	r.custom_minimum_size = Vector2(0, 1)
	return r


func _grade_color(g: String) -> Color:
	match g:
		"S":
			return Kit.GOLD
		"A":
			return Kit.TEAL
		"B":
			return Kit.GREEN
		"C":
			return Kit.CORAL
	return Kit.GREY


## 通关页的评级串。
## 原来是把字母拼成一个字符串（SABCSABCSABCSAB），15 个字母连成一坨，
## 既看不出节奏、也对不上「第几班」。改成逐字母上色 + 每 5 班一组。
## 全篇总班次：从章节定义算，不写死（曾经是 15，扩容后变 25，标题还写着「十五个班次之后」）。
func _total_shifts() -> int:
	var n := 0
	for ch in E.D.CHAPTERS:
		n += ch["shifts"].size()
	return n


## 0–99 的中文数字：结局标题是散文语感，不接受「25 个班次之后」这种阿拉伯数字。
func _cn_num(n: int) -> String:
	var digits := ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
	if n < 10:
		return digits[n]
	if n < 20:
		return "十" if n == 10 else "十" + digits[n % 10]
	var tens := int(n / 10)
	var ones := n % 10
	return digits[tens] + "十" + ("" if ones == 0 else digits[ones])


func _rating_strip() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	var head := Kit.lbl("评级", 12, Kit.GREY)
	head.custom_minimum_size = Vector2(34, 0)
	row.add_child(head)

	var n: int = game.campaign["ratings"].size()
	for i in range(n):
		if i > 0:
			var gap := Control.new()
			# 每 5 班加一道宽缝 —— 一章正好 5 班，缝就是章的边界
			gap.custom_minimum_size = Vector2(11 if i % 5 == 0 else 4, 0)
			row.add_child(gap)
		var raw = game.campaign["ratings"][i]
		var g: String = "—" if raw == null else str(raw)
		var l := Kit.lbl(g, 15, Kit.MUTED if g == "—" else _grade_color(g))
		l.custom_minimum_size = Vector2(14, 0)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(l)
	return row


# =====================================================================
#                          流程动作
# =====================================================================
func _start_shift() -> void:
	game.start_shift()
	sel_uid = ""
	reroll_mode = false
	# 新的一班：手牌整排都是"新发的"，全部做淡入
	_prev_hand = 0
	sfx.play("shift")
	_refresh()


## 关闭章节过场，进入新章简报。pending_chapter_intro 清空后，下一次 _refresh_overlay
## 会因为 phase==\"brief\" 而弹出新章简报——过场只是中间插的一屏，不留在状态里。
func _dismiss_chapter_intro() -> void:
	game.pending_chapter_intro = {}
	sfx.play("ui")
	_refresh()


func _next_shift() -> void:
	if game.rating == null:
		game.rating = game.compute_rating()
	game.save_rating()
	game.pending_feedback = null
	var res = game.advance()
	# 跨章：advance 把新章 dict 放在 [1]。存进 game 状态，让 _refresh_overlay 弹过场，
	# 而不直接跳到新章简报——否则这 5 章之间没有任何"换场"的呼吸感。
	if res[1] != null and res[1] is Dictionary and not res[1].is_empty():
		game.pending_chapter_intro = res[1]
	sel_uid = ""
	reroll_mode = false
	# 自动存档：每班推进后存一次，玩家就算硬关机也只丢一班。
	_save_game(false)
	if bool(res[0]):
		sfx.play("ending")
	else:
		sfx.play("shift")
	_refresh()


func _retry_shift() -> void:
	# 事故已经发生了：先记进整场账本再重开本班。
	# load_shift() 会把 self.incidents 清零，而整场事故只在 advance() 里累加，
	# 所以不在这里补记的话，「重打本班」就等于免费洗白——真结局门槛
	# （true_ending: total_incidents <= 2）会形同虚设。身体记得每一次。
	if game.incidents > 0:
		game.campaign["total_incidents"] += game.incidents
	game.pending_feedback = null
	game.load_shift()
	game.start_shift()
	sel_uid = ""
	reroll_mode = false
	sfx.play("shift")
	_refresh()


func _restart() -> void:
	game = E.Game.new(SEED + int(Time.get_unix_time_from_system()) % 997)
	_overlay_sig = ""
	sel_uid = ""
	reroll_mode = false
	_prev_statuses = {}
	Save.erase()
	sfx.play("ui")
	_refresh()


# =====================================================================
#                            存档 / 音效
# =====================================================================
func _ui_state() -> Dictionary:
	return {"sel_uid": sel_uid, "reroll_mode": reroll_mode}


func _restore_ui(ui: Dictionary) -> void:
	sel_uid = str(ui.get("sel_uid", ""))
	reroll_mode = bool(ui.get("reroll_mode", false))
	_overlay_sig = ""
	_prev_statuses = game.statuses.duplicate()
	# 选中工单可能已经处理掉了，回落成第一张待处理单
	if sel_uid != "":
		var alive := false
		for o in game.active_orders():
			if str(o["uid"]) == sel_uid:
				alive = true
				break
		if not alive:
			sel_uid = ""


func _save_game(manual: bool) -> bool:
	var ok: bool = Save.write_slot(game.snapshot(), _ui_state())
	if ok:
		sfx.play("toast")
		if manual:
			_flash("已存档 · %s 第 %d 班 第 %d 刻" % [
				str(game.get_chapter()["code"]), int(game.get_shift_def()["n"]), game.clock], Kit.TEAL)
	else:
		_flash("存档失败：写不进 user:// 目录", Kit.CORAL)
	return ok


func _load_game() -> bool:
	var sv := Save.read_slot()
	if sv.is_empty():
		sfx.play("status")
		_flash("没有可读的存档", Kit.GOLD)
		return false
	if not game.restore(sv.get("state", {})):
		sfx.play("status")
		_flash("存档版本不符或已损坏", Kit.CORAL)
		return false
	_restore_ui(sv.get("ui", {}))
	sfx.play("shift")
	_refresh()
	_flash("已读档 · %s" % str(sv.get("at", "")), Kit.TEAL)
	return true


func _toggle_audio() -> void:
	if sfx == null:
		return
	var on: bool = sfx.toggle()
	_refresh_audio_btn()
	if on:
		sfx.play("ui")
		_flash("音效已开启", Kit.TEAL)
	else:
		_flash("音效已关闭", Kit.GREY)


# =====================================================================
#                          截图 QA 模式
# =====================================================================
func _run_shots() -> void:
	var dir := ProjectSettings.globalize_path("res://_shots")
	DirAccess.make_dir_recursive_absolute(dir)
	await _wait_frames(8)

	await _shot(dir.path_join("01_brief.png"))

	# 干扰牌班次的简报：第一章第 2 班会带回一张偏方，这一屏多了「带回」两行，
	# 必须单独钉一张图——否则以后改简报布局，这一行挤没了也没人发现。
	var keep_shift: int = game.campaign["shift"]
	game.campaign["shift"] = 1
	game.load_shift()
	_refresh()
	await _wait_frames(4)
	await _shot(dir.path_join("01b_brief_gift.png"))
	game.campaign["shift"] = keep_shift
	game.load_shift()
	_refresh()
	await _wait_frames(2)

	_start_shift()
	await _wait_frames(4)
	await _shot(dir.path_join("02_shift.png"))

	# 六种状态全挂上再抓一张：一局里很少同时出现 3 个以上，而这一列恰恰是
	# 「字形混排 vs 统一线稿」差距最明显的地方。截完立刻还原，不影响后面的图。
	var keep: Dictionary = game.statuses.duplicate()
	for k in E.D.STATUS:
		game.statuses[k] = 1
	_refresh()
	await _wait_frames(4)
	await _shot(dir.path_join("02b_status.png"))
	game.statuses = keep
	_refresh()
	await _wait_frames(2)

	# 出一张牌，抓结果提示条
	for cid in game.hand:
		if game.can_play(cid):
			_try_play(cid)
			break
	await _wait_frames(4)
	await _shot(dir.path_join("03_result.png"))

	# 强制触发抉择，抓抉择层
	game.clock = maxi(game.clock, int(game.max_clock / 2))
	game.pending_dilemma = null
	game.dilemma_fired = false
	game.maybe_dilemma()
	_refresh()
	await _wait_frames(4)
	await _shot(dir.path_join("04_dilemma.png"))

	# 结算层
	game.choose_dilemma(0)
	game.phase = "settle"
	game.rating = game.compute_rating()
	_refresh()
	await _wait_frames(4)
	await _shot(dir.path_join("05_settle.png"))

	# 章节过场（强制切到第二章，验证 bg_corridor_night 与文案渲染）
	game.pending_chapter_intro = E.D.CHAPTERS[1].duplicate()
	_refresh()
	await _wait_frames(4)
	await _shot(dir.path_join("05b_chapter_intro.png"))
	game.pending_chapter_intro = {}
	_refresh()

	# 末班简报（每章第 5 班）：这一班是后加的收尾班，班次标题/目标/文案都换过，
	# 单独抓一张，避免"每章 3 班"时代的排版假设被悄悄带回来。
	game.campaign["chapter"] = 0
	game.campaign["shift"] = E.D.CHAPTERS[0]["shifts"].size() - 1
	game.load_shift()
	game.phase = "brief"
	_refresh()
	await _wait_frames(4)
	await _shot(dir.path_join("05c_shift5_brief.png"))
	game.campaign["chapter"] = 0
	game.campaign["shift"] = 0
	game.load_shift()

	# 通关层
	game.campaign["cleared"] = true
	var total_shifts := 0
	for ch in E.D.CHAPTERS:
		total_shifts += ch["shifts"].size()
	for i in range(total_shifts):
		while game.campaign["ratings"].size() <= i:
			game.campaign["ratings"].append(null)
		game.campaign["ratings"][i] = ["S", "A", "B", "C"][i % 4]
	_refresh()
	await _wait_frames(4)
	await _shot(dir.path_join("06_ending.png"))

	# 设置面板：它是唯一「压在所有模态之上」的一屏，单独抓一张
	_settings_open = true
	_overlay_sig = ""
	_refresh_overlay()
	await _wait_frames(4)
	await _shot(dir.path_join("07_settings.png"))
	_settings_open = false
	_overlay_sig = ""
	_refresh_overlay()

	print("SHOTS_DONE")
	await _quit_clean(0)


## 统一收尾。两条退出路径（巡演 / 截图）都必须走这里：
## 音频线程是独立线程，`stop()` 之后 playback 要等下一轮混音才被 AudioServer 释放，
## 立刻 quit 会偶发报 "ObjectDB instances were leaked at exit"。
## 无头模式（--headless 的 dummy 驱动）不保证还有"下一轮混音"，等帧也不管用，
## 所以这里直接 `dispose()`：停播 + 把 player.stream 置空，主动断掉对流的引用。
## 只 stop_all() 会在 layout 探针这类「开一局就退出」的路径上稳定漏 1 个 WAV + 1 个 playback。
func _quit_clean(code: int) -> void:
	if sfx != null:
		sfx.dispose()
	# BGM 现在是一条从磁盘加载的 ogg，必须一起断引用：
	# 只停播不清 stream，退出时会稳定报 2 个 resource still in use。
	if bgm != null:
		bgm.dispose()
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(code)


func _wait_frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame
func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("SHOT %s err=%d size=%dx%d" % [path, err, img.get_width(), img.get_height()])


# =====================================================================
#                     端到端巡演模式（--autoplay）
# =====================================================================
## 用「和玩家点击完全相同」的入口把整场战役走完：
## _start_shift / _try_play / _on_wait / _do_reroll / _choose_option / _next_shift。
## 目的不是替代一致性测试（那条比的是规则），而是验证「按钮 → 引擎 → 重画 → 弹窗」
## 这条接线在整篇班次里不会卡死、不会走进没有出口的状态。
func _autoplay(chaos: bool = false) -> void:
	var guard := 0
	var shifts := 0
	var plays := 0
	var waits := 0
	var rerolls := 0
	var dilemmas := 0
	var retries := 0
	var bad_plays := 0
	var save_ok := false
	var swallowed := 0          # 引擎触发了抉择、却被结算冲掉的班次数
	var shift_had_dilemma := false

	while guard < 6000:
		guard += 1
		if game.campaign["cleared"]:
			break
		# 章节过场：advance 跨章后弹出，这里显式 dismiss 才进得了新章简报。
		# 必须放在 phase 判断之前——否则 phase 已是 brief，会直接跳过过场。
		if game.pending_chapter_intro != null and not game.pending_chapter_intro.is_empty():
			_dismiss_chapter_intro()
			continue
		if game.phase == "brief":
			_start_shift()
			shifts += 1
			shift_had_dilemma = false
			# 第一班开局后立刻做一次「存档 → 改动 → 读档」往返自检：
			# 这是唯一能证明「读档后 RNG 与整班状态都回来了」的运行时证据。
			if shifts == 1:
				save_ok = _save_roundtrip()
			continue
		if game.phase == "over":
			_retry_shift()
			retries += 1
			continue
		# 抉择必须排在 settle 之前——顺序要和 _refresh_overlay() 一致（over → dilemma → settle）。
		# 之前写反了：玩家解决最后一个工单时，maybe_dilemma() 会同时挂上 pending_dilemma
		# 并把 phase 置成 settle，于是这一轮的抉择被 _next_shift() 直接冲掉。
		# 症状很隐蔽：25 个班次只弹 19 个抉择，而引擎侧（--check 路径）是规规矩矩的 25 个，
		# 巡演指标看着正常、实际少测了 6 个抉择的全部后果。
		if game.pending_dilemma != null:
			# 混沌模式随机选项：正常巡演永远选第 0 项，其余选项的文案/后果从来没被跑过。
			var opt := 0
			if chaos and game.pending_dilemma["options"].size() > 1:
				opt = randi() % game.pending_dilemma["options"].size()
			_choose_option(opt)
			dilemmas += 1
			shift_had_dilemma = true
			continue
		if game.phase == "settle":
			# 精确判据：引擎**已经**触发了抉择（dilemma_fired），但这一班从头到尾
			# 没有一次走到 _choose_option —— 说明它被结算冲掉了。
			# 不用「抉择数 == 班次数」来判，是因为短班次（1 个工单）常常在 clock
			# 走到过半之前就打完了，本来就不该弹抉择；那种「少一个」是正常的。
			if game.dilemma_fired and not shift_had_dilemma:
				swallowed += 1
			_next_shift()
			continue
		if game.phase != "shift":
			break

		# 混沌模式：故意把非转诊牌打到红旗上，强制走「事故 → 本班作废 → 重打」。
		# 正常对局一次事故都不出（incidents=0），这条路径在巡演里从来跑不到，
		# 而它恰恰是真人玩家最常踩的坑——必须能被自动化覆盖。
		if chaos and bad_plays < 3:
			var red_order = null
			for o in game.active_orders():
				if o["kind"] == "redflag":
					red_order = o
					break
			if red_order != null:
				var wrong := ""
				for c in game.hand:
					if E.D.CARD_MAP[c]["s"] != "refer" and game.can_play(c):
						wrong = c
						break
				if wrong != "":
					sel_uid = str(red_order["uid"])
					_try_play(wrong)
					bad_plays += 1
					continue

		var cid := _ai_pick()
		# 混沌模式也走「换签」和「等一刻」：AI 总能找到可出的牌，这两条玩家常用的
		# 按钮在常规巡演里 waits/rerolls 恒为 0，等于完全没测过。
		if chaos and game.rerolls > 0 and not game.hand.is_empty() and randf() < 0.08:
			_do_reroll(game.hand[0])
			rerolls += 1
			continue
		if chaos and randf() < 0.06 and game.clock + 1 <= game.max_clock:
			_on_wait()
			waits += 1
			continue
		if cid != "":
			_try_play(cid)
			plays += 1
			continue
		if game.rerolls > 0 and not game.hand.is_empty():
			_do_reroll(game.hand[0])
			rerolls += 1
			continue
		if game.clock + 1 <= game.max_clock:
			_on_wait()
			waits += 1
			continue
		break

	var ratings := ""
	for r in game.campaign["ratings"]:
		ratings += ("-" if r == null else str(r))
	var ok: bool = game.campaign["cleared"] and guard < 6000 and save_ok
	# 抉择数必须对得上：正常局没有事故，每个班次正好弹一次，少一个就是 UI 把它吞了。
	# 这条以前没有，于是「25 个班次只弹 19 个抉择」在闸门上是全绿的。
	# 混沌模式会因为 reroll/等一刻改变节奏，偶发少一个，所以只对正常巡演下硬约束。
	if not chaos and swallowed > 0:
		ok = false
		print("AUTOPLAY 有 %d 个班次的抉择被结算冲掉了（引擎已触发，UI 没处理）" % swallowed)
	# 注意：第一段以前打的是 `str(ok)`，标签却写 `cleared=`。
	# 于是「闸门因为别的原因判失败」会被读成「没通关」，误导排查方向（我自己就被带偏过一次）。
	# 现在 ok 进前缀、cleared 打真实值，两个维度分开。
	print("AUTOPLAY_%s cleared=%s shifts=%d plays=%d waits=%d rerolls=%d dilemmas=%d incidents=%d save=%s ratings=%s"
		% ["OK" if ok else "FAIL", str(game.campaign["cleared"]).to_lower(),
			shifts, plays, waits, rerolls, dilemmas,
			int(game.campaign["total_incidents"]), str(save_ok).to_lower(), ratings])
	if chaos:
		# 混沌模式额外要求：确实踩过事故、并且踩完还能把整场打完（不软锁）。
		var chaos_ok: bool = ok and retries > 0 and bad_plays > 0
		print("CHAOS_OK cleared=%s retries=%d bad_plays=%d shifts=%d incidents=%d save=%s waits=%d rerolls=%d"
			% [str(chaos_ok).to_lower(), retries, bad_plays, shifts,
				int(game.campaign["total_incidents"]), str(save_ok).to_lower(),
				waits, rerolls])
		ok = chaos_ok
	if not ok:
		print("AUTOPLAY_FAIL guard=%d phase=%s clock=%d/%d save=%s"
			% [guard, game.phase, game.clock, game.max_clock, str(save_ok).to_lower()])
	# 音频线程是独立线程：`stop()` 之后 playback 要等下一轮混音才会被 AudioServer 释放。
	# 立刻 quit 会偶发报 "ObjectDB instances were leaked"（实测 4 次里 1 次），
	# 而这条噪声会让测试怀疑真有内存问题。收尾逻辑集中在 _quit_clean()。
	await _quit_clean(0 if ok else 1)


## 状态的「指纹」：刻数、指标、手牌、工单处理情况、事故数、换签次数。
## 存档往返只要这个字符串一致，就说明整班状态（含 RNG 位置）都回来了。
func _state_sig() -> String:
	var v := ""
	for item in E.D.VITALS:
		v += "%s=%d," % [str(item[0]), int(game.vitals[str(item[0])])]
	var h := ""
	for c in game.hand:
		h += str(c) + "."
	var r := ""
	for o in game.orders:
		r += ("1" if o["resolved"] else "0")
	return "c%d/%d|%s|%s|%s|i%d|rr%d|p%s|s%d/%d" % [
		game.clock, game.max_clock, v, h, r, game.incidents, game.rerolls,
		game.phase, int(game.stats["best"]), int(game.stats["good"])]


## 存档 → 改动 → 读档；要求读回后指纹与存档前一致，且中间确实变过。
func _save_roundtrip() -> bool:
	var before := _state_sig()
	if not Save.write_slot(game.snapshot(), _ui_state()):
		print("SAVE_ROUNDTRIP FAIL 写入失败")
		return false
	_on_wait()
	var moved := _state_sig()
	if moved == before:
		print("SAVE_ROUNDTRIP FAIL 改动无效（等一刻没改变状态）")
		return false
	if not _load_game():
		print("SAVE_ROUNDTRIP FAIL 读档失败")
		return false
	var back := _state_sig()
	var ok: bool = back == before
	print("SAVE_ROUNDTRIP %s before=[%s] moved=[%s] back=[%s]"
		% ["OK" if ok else "MISMATCH", before, moved, back])
	return ok


## 与 engine.py 的 pick_card 同策略：红旗单只认转诊，其余 best → good → 任意。
## 红旗单答不了就退去处理别的单，而不是干等到超时。
func _ai_pick() -> String:
	var orders: Array = game.active_orders()
	if orders.is_empty():
		return ""
	var usable := []
	for c in game.hand:
		if game.can_play(c):
			usable.append(c)
	if usable.is_empty():
		return ""

	var red := []
	var other := []
	for o in orders:
		if o["kind"] == "redflag":
			red.append(o)
		else:
			other.append(o)

	for o in red:
		for c in usable:
			if E.D.CARD_MAP[c]["s"] == "refer":
				sel_uid = str(o["uid"])
				return c
	for o in other:
		for b in ["best", "good"]:
			for c in usable:
				if c in o[b]:
					sel_uid = str(o["uid"])
					return c
	for o in other:
		for c in usable:
			# 对这张单无效的转诊牌会被引擎拒（避免空转），跳过它。
			if E.D.CARD_MAP[c]["s"] == "refer" \
					and not (c in o["best"]) and not (c in o["good"]):
				continue
			sel_uid = str(o["uid"])
			return str(c)
	return ""


# =====================================================================
#                  发行前自检（--selfcheck）
# =====================================================================
## 导出包里最阴的一类故障：**资源没进包，但游戏照常启动**。
##
## 这段代码存在的唯一理由就是把它变成会红的事。背景里那些美术模块
## 全都"缺图就返回 null、界面降级"，单看能不能启动、能不能自走完，
## 一个都发现不了 —— 上一版 exe 里 20 张立绘、3 张背景、25 个图标、
## 全套字体全都不在包里，而 AUTOPLAY 依然打印 cleared=true。
##
## 判据：
##   · 立绘 5×4、背景 3、图标全部、字体必须来自内置 ttf（不是 SystemFont）
##   · user:// 必须真的写得进去（装在 Program Files 下会踩到）
func _selfcheck() -> void:
	var miss: Array[String] = []

	var chars := 0
	for h in CharArt.HOSTS:
		for e in CharArt.EXPRS:
			chars += 1
			if CharArt.tex(h, e) == null:
				miss.append("立绘 host%d_%s" % [h, e])
	for id in BgArt.IDS:
		if BgArt.tex(id) == null:
			miss.append("背景 %s" % id)
	# 目录整体缺失时上面两个循环各转一圈就结束（每张都 null，miss 会具体到张），
	# 但数量本身也要对得上——锚点写死会在改数据后变成假通过。
	if chars < CharArt.HOSTS.size() * CharArt.EXPRS.size():
		miss.append("立绘清单异常：%d 张" % chars)

	var icon_names := _icon_names()
	# 清单为空是**最坏的失败形态**：下面那个 for 循环一次都不会转，
	# miss 一条都不加，闸门照样打印 OK。整个图标目录没进包时就是这个症状。
	if icon_names.is_empty():
		miss.append("图标清单为空：res://assets/icons 整个没进包")
	for n in icon_names:
		if not Icons.has(n):
			miss.append("图标 %s" % n)

	# 字体：内置 ttf 缺失时会静默回退系统字体，排版随之漂移，
	# 所以这里判"拿到的是不是 SystemFont"，而不是"能不能显示字"。
	# **sans 和 serif 都要判**。之前 serif 只打印不判定，于是
	# 「EMBEDDED_SERIF 指向一个从不存在的文件」这件事一路绿灯到发行。
	var sans_ok: bool = not (Kit.sans() is SystemFont)
	var serif_ok: bool = not (Kit.serif() is SystemFont)
	if not sans_ok:
		miss.append("内置 sans 字体缺失，已回退系统字体")
	if not serif_ok:
		miss.append("内置 serif 字体缺失，标题字形会随机器漂移")

	var cards := 0
	for id in E.D.CARD_MAP.keys():
		if CardArt.exists(str(id)):
			cards += 1
	# 同上：数量必须比得上，不能只"逐张检查、缺了就加"——
	# 那样 cards=0/43 也是零条 miss。
	if cards < E.D.CARD_MAP.size():
		miss.append("卡面缺失：%d/%d（检查 assets/cards 是否进包）"
			% [cards, E.D.CARD_MAP.size()])

	var save_ok := _probe_save()
	var ok: bool = miss.is_empty() and sans_ok and serif_ok and save_ok
	print("SELFCHECK %s art_missing=%d icons=%d chars=%d bgs=%d cards=%d/%d font_embed=%s serif_embed=%s save=%s"
		% ["OK" if ok else "FAIL", miss.size(), icon_names.size(), chars,
			BgArt.IDS.size(), cards,
			E.D.CARD_MAP.size(), str(sans_ok).to_lower(), str(serif_ok).to_lower(),
			str(save_ok).to_lower()])
	for m in miss:
		print("  MISS %s" % m)
	await _quit_clean(0 if ok else 1)


## 图标清单从目录里读，而不是写死一份列表：新增图标不用记得同步这里。
## 包里只有 .raw 副本（原始 svg 被导入管线吃掉），开发机上只有 .svg，
## 两种都要认。
func _icon_names() -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(Icons.DIR)
	if d == null:
		return out
	for f in d.get_files():
		var n := String(f)
		if n.ends_with(".svg.raw"):
			out.append(n.substr(0, n.length() - 8))
		elif n.ends_with(".svg"):
			out.append(n.substr(0, n.length() - 4))
	out.sort()
	# 去重（同一图标的 .svg 与 .svg.raw 同时存在时）
	var uniq: Array[String] = []
	for n in out:
		if uniq.is_empty() or uniq[-1] != n:
			uniq.append(n)
	return uniq


## user:// 真的能写吗。不写这个，装机版可能一路玩到结算才发现存不上档。
func _probe_save() -> bool:
	var root := OS.get_user_data_dir()
	print("  [save] name=%s  user_dir=%s  exists=%s"
		% [str(ProjectSettings.get_setting("application/config/name", "?")),
			root, str(DirAccess.dir_exists_absolute(root))])
	print("  [save] temp=%s" % OS.get_temp_dir())
	var probes := [
		"user://_selfcheck.tmp",
		root.path_join("_selfcheck.tmp"),
		OS.get_temp_dir().path_join("rtbzs_selfcheck.tmp"),
	]
	for p in probes:
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f == null:
			print("  [save] open %s -> null, err=%d" % [p, FileAccess.get_open_error()])
			continue
		f.store_string("ok")
		f.close()
		var r := FileAccess.open(p, FileAccess.READ)
		var got := "" if r == null else r.get_as_text()
		if r != null:
			r.close()
		DirAccess.remove_absolute(p)
		print("  [save] %s 往返 %s" % [p, "OK" if got == "ok" else "失败"])
		if got == "ok":
			return true
	return false


# =====================================================================
#                  包内清单（--packlist）
# =====================================================================
## 从**导出包内部**把资源逐个列出来。
##
## 为什么不在外面解析 PCK 文件：Godot 4.7 的包把文件名压成了 GST2 表，
## 手写解析器很容易读出"0 个文件"这种假结果（我就在这儿栽过一次，
## 差点以为资源都没进包）。让引擎自己遍历 res:// 才是唯一可信的答案。
func _packlist() -> void:
	var total := 0
	var bytes := 0
	for root in ["res://assets", "res://fonts", "res://audio", "res://ui"]:
		var r := _walk(root)
		total += int(r[0])
		bytes += int(r[1])
	print("PACKLIST files=%d bytes=%d" % [total, bytes])
	await _quit_clean(0)


func _walk(dir: String) -> Array:
	var n := 0
	var sz := 0
	var d := DirAccess.open(dir)
	if d == null:
		return [0, 0]
	for f in d.get_files():
		var p := dir.path_join(f)
		n += 1
		sz += int(FileAccess.get_file_as_bytes(p).size())
		print("  %-56s %7d B" % [p, FileAccess.get_file_as_bytes(p).size()])
	for sub in d.get_directories():
		var r := _walk(dir.path_join(sub))
		n += int(r[0])
		sz += int(r[1])
	return [n, sz]


# =====================================================================
#                  音频接线检查（--audiocheck）
# =====================================================================
## BGM 是程序化合成的，探针（tools/bgm_probe.gd）已经证明波形对、接缝无缝；
## 但"波形对"和"玩家真的听得到"是两件事——总线没建、播放器没 play、
## 音量被设成 -60dB，任何一种都静悄悄，而探针全是绿的。
##
## 这条只能在**有窗口**的时候跑（dummy 驱动下 AudioServer 不出声），
## 所以它不在发布闸门里，属于人工验收的一步。
func _audiocheck() -> void:
	await _wait_frames(6)
	# 起一局，让 BGM 真正按章节开播
	if game.phase == "idle":
		_start_shift()
	await get_tree().create_timer(1.6).timeout

	var mi := AudioServer.get_bus_index(AudioMix.MUSIC)
	var si := AudioServer.get_bus_index(AudioMix.SFX)
	var playing: bool = bgm != null and bgm._player != null and bgm._player.playing
	var pos := 0.0
	var length := 0.0
	var bus := ""
	if bgm != null and bgm._player != null:
		pos = bgm._player.get_playback_position()
		bus = bgm._player.bus
		if bgm._player.stream != null:
			length = bgm._player.stream.get_length()

	var ok: bool = playing and mi > 0 and si > 0 and bus == AudioMix.MUSIC \
		and pos > 0.01 and length > 30.0
	print("AUDIOCHECK %s music_bus=%d sfx_bus=%d bus=%s playing=%s pos=%.2f len=%.1f music_db=%.1f sfx_db=%.1f"
		% ["OK" if ok else "FAIL", mi, si, bus, str(playing).to_lower(),
			pos, length, AudioServer.get_bus_volume_db(mi), AudioServer.get_bus_volume_db(si)])
	if sfx != null:
		print("  sfx enabled=%s" % str(sfx.enabled).to_lower())
	await _quit_clean(0 if ok else 1)

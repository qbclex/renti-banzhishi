extends SceneTree
## 字体探针：确认**实际要用的那两支字体**能被运行时加载，并量出几个关键字的字形尺寸。
##
## 为什么不用光看截图：SystemFont 找不到字体时会静默回退到别的字族，
## 截图「看起来有字」并不等于「用的是我们内置的那一支」。
## 这里直接问字体要字形：名字对了、width>0、而且不同字号的宽度单调递增，
## 才能说明真的加载成功。
##
## 为什么要测**子集版而不是全量版**：发行包里只带子集，全量被 exclude_filter
## 挡在门外。之前这里探的是 NotoSansSC-VF.ttf（全量），于是「子集漏字 / 子集没
## 生成 / serif 子集压根不存在」这三件事它一件都发现不了——探针绿着，包里却是空的。

## 与 ui_kit.gd 的 EMBEDDED_SANS / EMBEDDED_SERIF 必须一致。
const TARGETS := [
	{"label": "sans", "path": "res://fonts/NotoSansSC-subset.ttf"},
	{"label": "serif", "path": "res://fonts/NotoSerifSC-subset.ttf"},
]
const PROBE := "人体值班室认知负荷值班档"
## 覆盖各章会出现的字：标题、指标名、评级、结局关键词。
const SPOT := "值班室血压血糖体重情绪睡眠体检报告住院夜班"


func _initialize() -> void:
	var fails: Array = []

	for t in TARGETS:
		var label: String = t["label"]
		var path: String = t["path"]

		# 1) 文件在不在
		var exists := FileAccess.file_exists(path)
		print("[%s] exists=%s path=%s" % [label, str(exists).to_lower(), path])
		if not exists:
			fails.append("%s 字体不存在（跑 tools/make_font_subset.py）" % label)
			continue

		# 2) 运行时加载（绕开编辑器导入系统，导出包里同样有效）
		var f := FontFile.new()
		var err: int = f.load_dynamic_font(path)
		print("[%s] load_dynamic_font err=%d (OK=%d)" % [label, err, OK])
		if err != OK:
			fails.append("%s load_dynamic_font 返回 %d" % [label, err])
			continue

		# 3) 字形度量：必须是「有宽度、且字号变大宽度也变大」
		#    注意：可变字体上调用 get_font_name()/get_font_style_count() 会让
		#    Godot 4.7.2 卡死（headless 下实测无输出直到超时），别在这里调。
		#    字族身份由 Python 侧直接解析 TTF 的 name 表确认。
		for size in [12, 14, 24]:
			var w: float = f.get_string_size(PROBE, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
			print("[%s] measure size=%d width=%.1f" % [label, size, w])
			if w <= 0.0:
				fails.append("%s 在 %dpx 下测不出宽度" % [label, size])
		var w12: float = f.get_string_size(PROBE, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var w24: float = f.get_string_size(PROBE, HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x
		if not (w24 > w12 * 1.5):
			fails.append("%s 24px 宽度未明显大于 12px，可能回退到了别的字族" % label)

		# 4) 子集必须真的覆盖正文用字。
		#    子集漏字在游戏里表现为「某个字变豆腐块」，而且只在特定那句文案上出现，
		#    极其难在截图里发现。这里逐个字问一遍，缺一个就报。
		var zero := 0
		var missing := ""
		for i in range(SPOT.length()):
			var cp: int = SPOT.unicode_at(i)
			if f.get_char_size(cp, 16).x <= 0:
				zero += 1
				missing += SPOT[i]
		print("[%s] spot_chars=%d missing=%d %s"
			% [label, SPOT.length(), zero, ("缺：" + missing) if zero > 0 else ""])
		if zero > 0:
			fails.append("%s 子集缺 %d 字：%s" % [label, zero, missing])

	# 5) SystemFont 兜底链也得留着（换机器/换系统时不至于空屏）
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Noto Sans CJK SC", "Source Han Sans SC",
		"Microsoft YaHei", "sans-serif"])
	sf.allow_system_fallback = true
	var sw: float = sf.get_string_size(PROBE, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	print("system_fallback width=%.1f" % sw)
	if sw <= 0.0:
		fails.append("SystemFont 兜底也测不出宽度")

	if fails.is_empty():
		print("FONT_PROBE OK embedded=both")
		quit(0)
	else:
		print("FONT_PROBE FAIL %s" % " / ".join(fails))
		quit(1)

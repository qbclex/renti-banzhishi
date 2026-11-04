extends SceneTree
## 过场接线探针：确定性地验证
##  1. advance() 在跨章时把新章 dict 放进 [1]，清章时返回 [true, {}]；
##  2. BgArt.scene_for 的三个分支分别指向 bg_nurse_station / bg_ward / bg_corridor_night。
##
## 不靠 autoplay（autoplay 走过场靠 dismiss，不能直接断言"是否跨章"）。这里直接
## 构造一个「第一章最后一班」的局面，手工 advance 一次，看返回值。
const E = preload("res://engine.gd")
const BgArt = preload("res://ui/bg_art.gd")


func _init() -> void:
	var g := E.Game.new(12345)
	g.campaign["chapter"] = 0
	g.campaign["shift"] = E.D.CHAPTERS[0]["shifts"].size() - 1
	g.load_shift()
	var res = g.advance()
	var crossed: bool = res[1] != null and res[1] is Dictionary and not res[1].is_empty()
	print("INTRO_PROBE crossed=%s new_no=%s cleared=%s"
		% [crossed, (res[1].get("no", "") if crossed else ""), res[0]])

	# 终章：把局面推到最后一章最后一班再 advance，应直接通关、不过场。
	var g2 := E.Game.new(12345)
	g2.campaign["chapter"] = E.D.CHAPTERS.size() - 1
	g2.campaign["shift"] = E.D.CHAPTERS[E.D.CHAPTERS.size() - 1]["shifts"].size() - 1
	g2.load_shift()
	var res2 = g2.advance()
	var crossed2: bool = res2[1] != null and res2[1] is Dictionary and not res2[1].is_empty()
	print("INTRO_PROBE final crossed=%s cleared=%s" % [crossed2, res2[0]])

	print("INTRO_PROBE scene nurse=%s ward=%s corridor=%s" % [
		BgArt.scene_for(0, false, false),
		BgArt.scene_for(0, true, false),
		BgArt.scene_for(0, false, true)])
	quit(0)

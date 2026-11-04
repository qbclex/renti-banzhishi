# -*- coding: utf-8 -*-
"""把 Python 侧的内容数据序列化成 Godot 的 data.gd。

默认（全量）：从 content_full.py 生成 —— 43 张牌 / 65 个工单 / 5 章 25 班 /
22 条知识点 / 10 条抉择 / 5 封来信 / 15 条音效配方，Godot 端即为「真内容可跑版」。

可选 --mini：从 poc_data.py 生成迷你数据集到 data_mini.gd，
用于在排查问题时把「数据问题」与「移植问题」分开。

用法：
    python gen_data_gd.py           # 生成 godot_poc/data.gd（全量）
    python gen_data_gd.py --mini    # 生成 godot_poc/data_mini.gd（迷你）
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "godot_poc")

_ESC = {
    "\\": "\\\\",
    '"': '\\"',
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
}


def gd_str(s):
    return '"' + "".join(_ESC.get(ch, ch) for ch in s) + '"'


def to_gd(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v) if isinstance(v, float) else str(v)
    if isinstance(v, str):
        return gd_str(v)
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(to_gd(x) for x in v) + "]"
    if isinstance(v, dict):
        items = []
        for k, val in v.items():
            if isinstance(k, str):
                key = gd_str(k)
            elif isinstance(k, tuple):
                # GDScript 字典不支持元组键 -> "a|b"
                key = gd_str("|".join(str(x) for x in k))
            else:
                key = str(k)
            items.append(key + ": " + to_gd(val))
        return "{" + ", ".join(items) + "}"
    raise TypeError("cannot serialize %r" % (type(v),))


def combos_as_str_keys(pairs):
    """COMBO_BY_PAIR 的元组键 -> "a|b"（与 engine.gd 的查找方式一致）。"""
    out = {}
    for (a, b), spec in pairs.items():
        out["%s|%s" % (a, b)] = spec
    return out


# 引擎必需的 14 项（engine.py / engine.gd 都会读）
ENGINE_FIELDS = [
    "VITALS", "CARD_MAP", "STARTER_DECK", "ORDER_MAP", "STATUS",
    "COMBO_BY_PAIR", "CURE_TO_STATUS", "ORDER_STATUS", "RATING_TIERS",
    "EMERGENCY", "SHIFT_ENV", "ENV", "DILEMMAS", "CHAPTERS",
]

# 叙事/音频等扩展项（引擎不强制，供 Godot 的 UI 层使用）
EXTRA_FIELDS = [
    "GAME_TITLE", "GAME_SUBTITLE", "DOMAINS", "KNOWLEDGE",
    "LETTERS", "ENDINGS", "TRUE_ENDING", "SOUNDS",
]


def build(module, fields, out_name, banner):
    blocks = []
    for name in fields:
        val = getattr(module, name, None)
        if val is None:
            continue
        if name == "COMBO_BY_PAIR":
            val = combos_as_str_keys(val)
        blocks.append((name, val))

    lines = [
        "# 由 gen_data_gd.py 自动生成，请勿手工编辑。",
        "# 来源：%s" % banner,
        "# 纯数据脚本（无需 extends），engine.gd 通过 preload 后以 D.XXX 访问。",
        "",
    ]
    for name, val in blocks:
        lines.append("const %s = %s" % (name, to_gd(val)))
        lines.append("")

    path = os.path.join(OUT_DIR, out_name)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    size = os.path.getsize(path)
    print("wrote %-14s %6.1f KB  (%d consts)" % (out_name, size / 1024.0, len(blocks)))
    return path


def main():
    if "--mini" in sys.argv:
        import poc_data
        build(poc_data, ENGINE_FIELDS + ["VITALS"],  # 迷你集只有引擎字段
              "data_mini.gd", "poc_data.py（迷你回归数据集）")
        return

    import content_full as D
    missing = [f for f in ENGINE_FIELDS if not hasattr(D, f)]
    if missing:
        raise SystemExit("content_full 缺少引擎字段：%r" % (missing,))

    build(D, ENGINE_FIELDS + EXTRA_FIELDS, "data.gd",
          "content_full.py（全量：43 牌 / 65 工单 / 5 章 25 班 / 22 知识点）")

    # 交叉引用自检：数据里引用的 id 必须存在，否则 Godot 端会静默拿到 null
    problems = []
    for c in D.STARTER_DECK:
        if c not in D.CARD_MAP:
            problems.append("STARTER_DECK 引用了不存在的牌 %s" % c)
    for oid, o in D.ORDER_MAP.items():
        for c in list(o.get("best", [])) + list(o.get("good", [])) + list(o.get("bad", [])):
            if c not in D.CARD_MAP:
                problems.append("工单 %s 引用了不存在的牌 %s" % (oid, c))
    for ch in D.CHAPTERS:
        for sd in ch["shifts"]:
            for oid in sd["pool"]:
                if oid not in D.ORDER_MAP:
                    problems.append("第 %d 章第 %d 班 池中工单不存在 %s"
                                    % (ch["no"], sd["n"], oid))
            for c in sd.get("reward", []):
                if c not in D.CARD_MAP:
                    problems.append("第 %d 章第 %d 班 奖励牌不存在 %s"
                                    % (ch["no"], sd["n"], c))
            for c in sd.get("gift", []):
                if c not in D.CARD_MAP:
                    problems.append("第 %d 章第 %d 班 干扰牌不存在 %s"
                                    % (ch["no"], sd["n"], c))
                if c in sd.get("reward", []):
                    problems.append("第 %d 章第 %d 班 同一张牌既是奖励又是干扰 %s"
                                    % (ch["no"], sd["n"], c))
                if not str(sd.get("gift_note", "")).strip():
                    problems.append("第 %d 章第 %d 班 塞了干扰牌 %s 却没写 gift_note"
                                    % (ch["no"], sd["n"], c))

    # 可达性：每张牌都必须至少有一条获得途径，否则就是永远抽不到的死数据
    reachable = set(D.STARTER_DECK)
    for ch in D.CHAPTERS:
        for sd in ch["shifts"]:
            reachable |= set(sd.get("reward", [])) | set(sd.get("gift", []))
    for cid in D.CARD_MAP:
        if cid not in reachable:
            problems.append("牌 %s 不可获得（不在初始牌组、奖励或干扰牌里）" % cid)
    for (a, b) in D.COMBO_BY_PAIR:
        for c in (a, b):
            if c not in D.CARD_MAP:
                problems.append("组合技引用了不存在的牌 %s" % c)
    for oid, st in D.ORDER_STATUS.items():
        if oid not in D.ORDER_MAP:
            problems.append("ORDER_STATUS 引用了不存在的工单 %s" % oid)
        if st not in D.STATUS:
            problems.append("ORDER_STATUS 引用了不存在的状态 %s" % st)
    for cid, sts in D.CURE_TO_STATUS.items():
        if cid not in D.CARD_MAP:
            problems.append("CURE_TO_STATUS 引用了不存在的牌 %s" % cid)
        for st in sts:
            if st not in D.STATUS:
                problems.append("CURE_TO_STATUS 引用了不存在的状态 %s" % st)

    if problems:
        print("\n数据自检发现 %d 个问题：" % len(problems))
        for p in problems[:20]:
            print("  -", p)
        raise SystemExit(1)
    print("数据自检通过：卡牌/工单/组合/状态/奖励 交叉引用全部有效")
    print("统计：%d 牌 · %d 工单 · %d 组合 · %d 知识点 · %d 章 / %d 班 · %d 抉择 · %d 来信"
          % (len(D.CARD_MAP), len(D.ORDER_MAP), len(D.COMBO_BY_PAIR),
             len(D.KNOWLEDGE), len(D.CHAPTERS),
             sum(len(c["shifts"]) for c in D.CHAPTERS),
             sum(len(v) for v in D.DILEMMAS.values()), len(D.LETTERS)))


if __name__ == "__main__":
    main()

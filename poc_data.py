# -*- coding: utf-8 -*-
"""
Godot POC 用的迷你数据集（字段与 content_full.py 完全一致）。
- gen_data_gd.py 用它生成 godot_poc/data.gd
- 正式迁移时，应改成由 content_full.py 批量生成，而非手维护
"""

VITALS = [
    ("trust", "信任", "better", 50),
    ("energy", "精力", "better", 70),
    ("stress", "压力", "worse", 20),
]

CARD_MAP = {
    "c_water":  {"name": "喝水", "s": "life", "cost": 1, "eff": {"energy": 8, "stress": -3}},
    "c_rest":   {"name": "小憩", "s": "life", "cost": 1, "eff": {"energy": 12, "stress": -5}},
    "c_observe":{"name": "观察", "s": "observe", "cost": 1, "eff": {"trust": 2}},
    "c_refer":  {"name": "转诊", "s": "refer", "cost": 2, "eff": {"trust": 6}},
    "c_quack":  {"name": "偏方", "s": "quack", "cost": 1, "eff": {"trust": -10, "stress": 8}},
    "c_med":    {"name": "对症药", "s": "life", "cost": 2, "eff": {"trust": 5, "energy": -2, "stress": -4}},
}
STARTER_DECK = ["c_water", "c_water", "c_rest", "c_observe",
                "c_refer", "c_quack", "c_med", "c_med"]

ORDER_MAP = {
    "o_fever":  {"id": "o_fever", "t": "发热", "b": "患者体温升高", "gt": "",
                 "bt": "", "f": "", "kind": "normal", "limit": 6,
                 "best": ["c_med"], "good": ["c_refer"], "bad": ["c_quack"]},
    "o_chest":  {"id": "o_chest", "t": "胸痛", "b": "需警惕心源性", "gt": "",
                 "bt": "", "f": "", "kind": "redflag", "limit": 5,
                 "best": [], "good": [], "bad": []},
    "o_thirst": {"id": "o_thirst", "t": "口渴", "b": "身体缺水信号", "gt": "",
                 "bt": "", "f": "", "kind": "normal", "limit": 6,
                 "best": ["c_water"], "good": ["c_rest"], "bad": ["c_quack"]},
}

STATUS = {
    "dehydration": {"name": "脱水"},
    "inflammation": {"name": "炎症"},
    "palpitation":  {"name": "心悸"},
    "reflux":       {"name": "反流"},
    "insomnia":     {"name": "失眠"},
}

# Python 用元组键；生成 GDScript 时转成 "c_water|c_med" 字符串键
COMBO_BY_PAIR = {
    ("c_water", "c_med"): {"id": "combo_hydrate",
                           "effect": {"trust": 3, "energy": 3}, "trust": 0},
}
CURE_TO_STATUS = {
    "c_med": ["dehydration"],
}
ORDER_STATUS = {
    "o_thirst": "dehydration",
}
RATING_TIERS = [
    (90, "S", ""),
    (75, "A", ""),
    (60, "B", ""),
    (0, "C", ""),
]
EMERGENCY = {}
SHIFT_ENV = {0: ["calm"]}
ENV = {
    "calm":  {"name": "平静的夜"},
    "busy":  {"name": "繁忙"},
    "alone": {"name": "独自值班"},
    "rumor": {"name": "谣言四起"},
}
DILEMMAS = {0: [
    {"title": "夜班抉择", "options": [
        {"label": "坚持处置", "eff": {"trust": 5, "energy": -5}, "log": "你选择坚持处置"},
        {"label": "呼叫支援", "eff": {"stress": -5}, "draw": 1, "log": "你呼叫了支援"},
    ]},
]}
CHAPTERS = [
    {"no": 0, "shifts": [
        {"n": 1, "clock": 14, "order_count": 3,
         "pool": ["o_fever", "o_chest", "o_thirst"],
         "goal": {"kind": "trust", "value": 70}, "reward": ["c_refer"]}
    ]},
]

# -*- coding: utf-8 -*-
"""工单 × 处置签 的配对体检。

两件事，都必须在内容改动后跑：

1. **同一张牌不能自相矛盾**：best 与 good 不能有交集，best/good 与 bad 也不能。
2. **正解必须是玩家手里真有的牌**：按班次顺序累积牌组（开局 7 张 + 每班 reward），
   逐班检查该班 pool 里每个工单的 best 有几张是「此刻可出」的。
   少于 1 张 = 死局；只有 1 张 = 容错为零（玩家一错过就没有第二次机会）。

用法：
    python tools/pair_audit.py          # 打印全部工单的配对表与体检结果
    python tools/pair_audit.py --quiet  # 只打印问题
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

import content_full as C  # noqa: E402


def check_self_conflict():
    bad = []
    for o in C.ORDERS:
        b, g, x = set(o["best"]), set(o["good"]), set(o["bad"])
        if b & g:
            bad.append((o["id"], "best∩good", sorted(b & g)))
        if b & x:
            bad.append((o["id"], "best∩bad", sorted(b & x)))
        if g & x:
            bad.append((o["id"], "good∩bad", sorted(g & x)))
        for cid in b | g | x:
            if cid not in C.CARD_MAP:
                bad.append((o["id"], "未知牌", cid))
    return bad


def walk_shifts():
    """按真实游玩顺序产出 (章, 班, 班定义, 此刻手上的牌组)。

    注意：奖励牌是「接班前领签」，在本班开局即可用（引擎 load_shift 会先把
    当班 shift_def 的 reward 并入 deck），所以 deck 在进班前就包含本班奖励。

    红旗单的转诊(refer)牌由引擎 _ensure_redflag_refer 在开局补发，这里按同
    一规则把本班所有红旗单 best 里的 refer 牌视为「开局已可得」。
    """
    deck = list(C.STARTER_DECK)
    for ch in C.CHAPTERS:
        for s in ch["shifts"]:
            deck = deck + [c for c in s["reward"] if c not in deck]
            # 模拟红旗补发
            for oid in s["pool"]:
                o = C.ORDER_MAP[oid]
                if o["kind"] == "redflag":
                    for cid in o["best"]:
                        if C.CARD_MAP.get(cid, {}).get("s") == "refer" and cid not in deck:
                            deck.append(cid)
            yield ch, s, set(deck)


def check_obtainable():
    """每班每个工单，此刻可出的 best 有几张。"""
    rows = []
    for ch, s, deck in walk_shifts():
        for oid in s["pool"]:
            o = C.ORDER_MAP[oid]
            avail = [c for c in o["best"] if c in deck]
            rows.append((ch["no"], s["n"], s["name"], oid, len(avail), avail))
    return rows


def main():
    quiet = "--quiet" in sys.argv

    conflict = check_self_conflict()
    rows = check_obtainable()
    dead = [r for r in rows if r[4] == 0]
    thin = [r for r in rows if r[4] == 1]

    if not quiet:
        print("=" * 78)
        print("工单 × 处置签 配对表")
        print("=" * 78)
        for o in C.ORDERS:
            print("[%d章 %s] %s · %s" % (o["ch"], o["kind"], o["organ"], o["t"]))
            print("   正解：" + " / ".join(C.CARD_MAP[c]["n"] for c in o["best"]))
            print("   可行：" + (" / ".join(C.CARD_MAP[c]["n"] for c in o["good"]) or "—"))
            print("   欠妥：" + (" / ".join(C.CARD_MAP[c]["n"] for c in o["bad"]) or "—"))
            print("   判词：" + o["gt"])
            print()

    print("=" * 78)
    print("体检结果")
    print("=" * 78)
    print("牌 %d 张 / 工单 %d 个 / 班次 %d 个"
          % (len(C.CARDS), len(C.ORDERS), sum(len(c["shifts"]) for c in C.CHAPTERS)))
    print("映射自相矛盾：%d 处" % len(conflict))
    for x in conflict:
        print("   ✗", x)
    print("正解不可得（死局）：%d 处" % len(dead))
    for r in dead:
        print("   ✗ %d-%d %s / %s → best 全不在手上" % (r[0], r[1], r[2], r[3]))
    print("正解只剩 1 张（零容错）：%d 处" % len(thin))
    for r in thin:
        print("   · %d-%d %s / %s → %s"
              % (r[0], r[1], r[2], r[3],
                 " / ".join(C.CARD_MAP[c]["n"] for c in r[5])))
    ok = (not conflict) and (not dead)
    print()
    print("结论：" + ("通过" if ok else "不通过"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

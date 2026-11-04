# -*- coding: utf-8 -*-
"""程序化音效（桌面版）

与网页版共用 content_full.SOUNDS 里的同一份合成配方：
网页用 WebAudio 实时合成，桌面用 wave 模块离线合成成 WAV，
再用 winsound 以「文件名异步」方式播放。

注意：CPython 的 winsound **不允许** `SND_MEMORY | SND_ASYNC`（会抛
`RuntimeError: Cannot play asynchronously from memory`），所以这里先把
WAV 落盘到临时目录、再用 `SND_FILENAME | SND_ASYNC` 播放。落盘文件按
音名缓存，整个会话只生成一次，性能无压力。

用法：
    sfx = Sfx()
    sfx.play("best")
    sfx.toggle()
"""
import io
import math
import os
import struct
import tempfile
import wave

import content_full as D

try:
    import winsound
except Exception:          # 非 Windows 或组件缺失时静默降级
    winsound = None

RATE = 22050
_TWO_PI = math.pi * 2.0


# ---------------------------------------------------------------- 波形
def _sample(wave_name, phase):
    """phase 为 0-1 的相位，返回 -1..1。"""
    p = phase - math.floor(phase)
    if wave_name == "triangle":
        return 4.0 * abs(p - 0.5) - 1.0
    if wave_name == "square":
        return 1.0 if p < 0.5 else -1.0
    if wave_name == "sawtooth":
        return 2.0 * p - 1.0
    return math.sin(_TWO_PI * p)


def _render(spec):
    """把一条音效配方渲染成 16bit 单声道 WAV 字节。"""
    dur = float(spec.get("dur", 0.2))
    f0 = float(spec.get("f0", 440))
    f1 = float(spec.get("f1", f0))
    wave_name = spec.get("wave", "sine")
    atk = max(0.001, float(spec.get("atk", 0.01)))
    vol = max(0.0, min(1.0, float(spec.get("vol", 0.2))))
    chord = spec.get("chord") or [1.0]
    noise = float(spec.get("noise", 0.0))
    pulse = float(spec.get("pulse", 0.0))
    tick = float(spec.get("tick", 0.0))
    tick_len = max(0.001, float(spec.get("tick_len", 0.004)))

    n = max(1, int(RATE * dur))
    frames = bytearray()
    # 简易白噪声（固定种子，保证两端听感一致且可复现）
    seed = 12345

    for i in range(n):
        t = float(i) / RATE
        g = t / dur
        # 扫频
        f = f0 + (f1 - f0) * g
        # 包络：起音线性，之后指数衰减
        if t < atk:
            env = t / atk
        else:
            env = math.exp(-4.2 * (t - atk) / max(0.001, dur - atk))
        amp = 0.0
        for ratio in chord:
            amp += _sample(wave_name, f * ratio * t)
        amp /= len(chord)

        if noise > 0:
            seed = (1103515245 * seed + 12345) & 0x7FFFFFFF
            amp = amp * (1.0 - noise) + ((seed / 0x7FFFFFFF) * 2.0 - 1.0) * noise

        if pulse:
            amp *= 0.6 + 0.4 * math.sin(_TWO_PI * pulse * t)

        # 起音高频瞬态：极短(默认 4ms)的 5.5kHz 脉冲，平方窗快起快落，制造"清脆/敲击感"。
        # 与 Godot 端 sfx.gd 同一条公式，保证两端同一个音。
        if tick > 0.0 and t < tick_len:
            tg = t / tick_len
            click = math.sin(_TWO_PI * 5500.0 * t)
            cenv = (1.0 - tg) * (1.0 - tg)
            amp = amp * (1.0 - tick) + click * cenv * tick

        v = amp * env * vol
        v = max(-1.0, min(1.0, v))
        frames += struct.pack("<h", int(v * 32767))

    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(frames))
    return buf.getvalue()


# ---------------------------------------------------------------- 播放器
class Sfx:
    """音效播放器：懒加载合成 + 静音开关。

    播放走「落盘 WAV + SND_FILENAME 异步」，避开 winsound 对
    SND_MEMORY|SND_ASYNC 的限制（会抛 RuntimeError）。
    """

    def __init__(self, enabled=True, volume=0.72):
        self.enabled = bool(enabled)
        self.volume = max(0.0, min(1.0, volume))
        self._cache = {}          # name -> 渲染出的 WAV 字节（供自测）
        self._paths = {}          # name -> 已落盘的 .wav 路径（按会话缓存）
        self._last_err = None     # 最近一次播放错误，便于排查
        if winsound is None:
            self.enabled = False
        # 临时目录：整局只建一次，文件按音名复用
        try:
            self._dir = os.path.join(tempfile.gettempdir(), "hbn_sfx")
            os.makedirs(self._dir, exist_ok=True)
        except OSError:
            self._dir = None

    # ---------------- 内部 ----------------
    def _data(self, name):
        """渲染成 WAV 字节（带缓存）。供自测与落盘复用。"""
        if name in self._cache:
            return self._cache[name]
        spec = D.SOUNDS.get(name)
        if not spec:
            return None
        try:
            data = _render(spec)
        except Exception:
            data = None
        self._cache[name] = data
        return data

    def _path(self, name):
        """把音效落盘为 .wav 并返回路径（按会话缓存，只写一次）。"""
        if name in self._paths:
            return self._paths[name]
        if self._dir is None:
            return None
        spec = D.SOUNDS.get(name)
        if not spec:
            return None
        data = self._data(name)
        if not data:
            return None
        p = os.path.join(self._dir, name + ".wav")
        try:
            with open(p, "wb") as f:
                f.write(data)
            self._paths[name] = p
            return p
        except OSError as e:
            self._last_err = "write %s: %r" % (p, e)
            return None

    # ---------------- 对外 ----------------
    def play(self, name):
        if not self.enabled or winsound is None:
            return
        # 主路径：文件名异步播放（最稳，winsound 不支持内存异步）
        p = self._path(name)
        if p:
            try:
                winsound.PlaySound(p, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)
                return
            except Exception as e:   # 极端情况（如文件被占用）退回内存同步
                self._last_err = "file %s: %r" % (name, e)
        # 退回路径：内存同步播放（SND_MEMORY 不能异步，这里用同步）
        data = self._data(name)
        if not data:
            return
        try:
            winsound.PlaySound(data, winsound.SND_MEMORY | winsound.SND_NODEFAULT)
        except Exception as e:
            self._last_err = "mem %s: %r" % (name, e)

    def toggle(self):
        was = self.enabled
        self.enabled = (not self.enabled) if winsound is not None else False
        if was and not self.enabled and winsound is not None:
            try:
                winsound.PlaySound(None, winsound.SND_PURGE)
            except Exception:
                pass
        return self.enabled

    def stop(self):
        if winsound is None:
            return
        try:
            winsound.PlaySound(None, winsound.SND_PURGE)
        except Exception:
            pass


# 便于自测：直接合成并给出字节数
def render_all():
    out = {}
    for name in D.SOUNDS:
        out[name] = len(_render(D.SOUNDS[name]))
    return out


if __name__ == "__main__":
    for k, v in render_all().items():
        print(k, v)

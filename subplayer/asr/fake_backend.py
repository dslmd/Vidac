"""测试用后端：不识别语音，每 2 秒给一条日语占位字幕，末尾括号里是绝对时间。

用来验证分段、调度、缓存、翻译、播放器叠加这些流程，不代表识别质量。
SUBPLAYER_FAKE_DELAY=1.5 可以模拟每段耗时 1.5 秒。
"""

from __future__ import annotations

import os
import threading
import time
from typing import Optional

import numpy as np

from .base import Backend, Segment

SENTENCES = [
    "今日はいい天気ですね",
    "駅まで一緒に歩きましょう",
    "この映画はとても面白かったです",
    "明日は雨が降るかもしれません",
    "日本語の字幕を自動で作ります",
    "次のシーンに進みましょう",
    "ご飯を食べてから出かけます",
    "電車の時間に間に合うでしょうか",
    "もう一度ゆっくり話してください",
    "天気がよくなってきました",
]


class FakeBackend(Backend):
    name = "fake"
    calls = 0  # 类级计数，测试里用来确认缓存没有重跑
    _lock = threading.Lock()

    def __init__(self) -> None:
        self.delay = float(os.environ.get("SUBPLAYER_FAKE_DELAY", "0") or 0)

    def transcribe(self, audio: np.ndarray, language: Optional[str], task: str = "transcribe",
                   *, offset: float = 0.0) -> tuple[list[Segment], Optional[str]]:
        with FakeBackend._lock:
            FakeBackend.calls += 1
        if self.delay:
            time.sleep(self.delay)
        dur = len(audio) / 16000
        segs = []
        t = 0.0
        while t < dur - 0.05:
            e = min(t + 2.0, dur)
            when = offset + t
            sentence = SENTENCES[int(round(when / 2.0)) % len(SENTENCES)]
            segs.append(Segment(t, e, f"{sentence}({when:.1f}s)"))
            t += 2.0
        return segs, language or "ja"

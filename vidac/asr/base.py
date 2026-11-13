"""ASR 后端的公共定义。"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import numpy as np


@dataclass
class Segment:
    start: float            # 相对于传入音频开头的秒数
    end: float
    text: str
    no_speech_prob: float = 0.0
    avg_logprob: float = 0.0
    compression_ratio: float = 0.0


class Backend:
    """所有后端都实现 transcribe。

    audio: 16 kHz 单声道 float32。
    language: Whisper 语言代码（ja / en / zh / ko ...），None 表示让模型自己检测。
    task: "transcribe"（原文）或 "translate"（译成英文）。
    offset: 这段音频在视频里的起始秒数。真实后端不用它，测试后端用来生成时间标签。
    返回 (分段列表, 检测到的语言或 None)。
    """

    name = "backend"

    def transcribe(
        self,
        audio: np.ndarray,
        language: Optional[str],
        task: str = "transcribe",
        *,
        offset: float = 0.0,
    ) -> tuple[list[Segment], Optional[str]]:
        raise NotImplementedError

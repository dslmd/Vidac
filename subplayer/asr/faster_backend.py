"""faster-whisper 后端：CPU 上跑（int8），mlx 装不上时的回退方案。Mac 上没有 GPU 加速，会慢很多。"""

from __future__ import annotations

from typing import Optional

import numpy as np

from .base import Backend, Segment


class FasterWhisperBackend(Backend):
    name = "faster-whisper"

    def __init__(self, model: str) -> None:
        from faster_whisper import WhisperModel

        self.model = WhisperModel(model, device="cpu", compute_type="int8")

    def transcribe(self, audio: np.ndarray, language: Optional[str], task: str = "transcribe",
                   *, offset: float = 0.0) -> tuple[list[Segment], Optional[str]]:
        it, info = self.model.transcribe(
            audio,
            language=language,
            task=task,
            beam_size=5,
            condition_on_previous_text=False,
            vad_filter=False,
        )
        segs = [
            Segment(s.start, s.end, s.text, s.no_speech_prob, s.avg_logprob, s.compression_ratio)
            for s in it
        ]
        return segs, info.language

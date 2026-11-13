"""mlx-whisper 后端（Apple Silicon 首选）。"""

from __future__ import annotations

from typing import Optional

import numpy as np

from .base import Backend, Segment


class MlxBackend(Backend):
    name = "mlx-whisper"

    def __init__(self, repo: str) -> None:
        import mlx_whisper  # 导入失败就尽早报错

        self._mlx = mlx_whisper
        self.repo = repo

    def transcribe(self, audio: np.ndarray, language: Optional[str], task: str = "transcribe",
                   *, offset: float = 0.0) -> tuple[list[Segment], Optional[str]]:
        result = self._mlx.transcribe(
            audio,
            path_or_hf_repo=self.repo,
            language=language,               # None 时 mlx-whisper 自己检测
            task=task,
            condition_on_previous_text=False,  # 段与段之间不传上下文，避免幻觉串联
            word_timestamps=False,
            verbose=None,
        )
        segs = [
            Segment(
                start=float(s["start"]),
                end=float(s["end"]),
                text=s["text"],
                no_speech_prob=float(s.get("no_speech_prob", 0.0)),
                avg_logprob=float(s.get("avg_logprob", 0.0)),
                compression_ratio=float(s.get("compression_ratio", 0.0)),
            )
            for s in result.get("segments", [])
        ]
        return segs, result.get("language")

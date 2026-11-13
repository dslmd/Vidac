"""模型预设和后端选择。

换模型：--model small（或 SUBPLAYER_MODEL=small）。
想用别的 mlx 仓库：--model 直接写 HuggingFace 仓库名，例如 mlx-community/whisper-medium-mlx。
"""

from __future__ import annotations

import importlib.util
import platform

from .base import Backend, Segment

MODEL_PRESETS: dict[str, dict[str, str]] = {
    "tiny":           {"mlx": "mlx-community/whisper-tiny",           "faster": "tiny"},
    "base":           {"mlx": "mlx-community/whisper-base-mlx",       "faster": "base"},
    "small":          {"mlx": "mlx-community/whisper-small-mlx",      "faster": "small"},
    "medium":         {"mlx": "mlx-community/whisper-medium-mlx",     "faster": "medium"},
    "large-v3":       {"mlx": "mlx-community/whisper-large-v3-mlx",   "faster": "large-v3"},
    "large-v3-turbo": {"mlx": "mlx-community/whisper-large-v3-turbo", "faster": "large-v3-turbo"},
}

BACKENDS = ("auto", "mlx", "faster", "fake")


def resolve_model(model: str) -> dict[str, str]:
    if model in MODEL_PRESETS:
        return MODEL_PRESETS[model]
    return {"mlx": model, "faster": model}


def pick_backend(kind: str) -> str:
    if kind != "auto":
        return kind
    on_apple_silicon = platform.system() == "Darwin" and platform.machine() == "arm64"
    if on_apple_silicon and importlib.util.find_spec("mlx_whisper"):
        return "mlx"
    if importlib.util.find_spec("faster_whisper"):
        return "faster"
    raise RuntimeError("没有可用的识别后端，请运行 install.sh 安装 mlx-whisper")


def make_backend(kind: str, model: str) -> Backend:
    """在转写线程里调用，保证 mlx 的模型和 Stream 都在同一个线程里用。"""
    kind = pick_backend(kind)
    names = resolve_model(model)
    if kind == "mlx":
        from .mlx_backend import MlxBackend
        return MlxBackend(names["mlx"])
    if kind == "faster":
        from .faster_backend import FasterWhisperBackend
        return FasterWhisperBackend(names["faster"])
    if kind == "fake":
        from .fake_backend import FakeBackend
        return FakeBackend()
    raise ValueError(f"未知后端：{kind}")


__all__ = ["Backend", "Segment", "MODEL_PRESETS", "make_backend", "resolve_model", "pick_backend"]

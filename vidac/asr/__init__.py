"""模型预设和后端选择。

换模型：--model small（或 VIDAC_MODEL=small）。
想用别的 mlx 仓库：--model 直接写 HuggingFace 仓库名，例如 mlx-community/whisper-medium-mlx。
"""

from __future__ import annotations

import importlib.util
import os
import platform
from typing import Callable, Optional

from .base import Backend, Segment

# mlx 值是候选仓库名列表，按顺序解析（先找本地已有的，再联网依次尝试）。
# 只有 mlx-community/whisper-tiny 确认存在，其余名字没有验证过，所以每个预设都留了备用名。
MODEL_PRESETS: dict[str, dict] = {
    "tiny":           {"mlx": ["mlx-community/whisper-tiny", "mlx-community/whisper-tiny-mlx"],
                       "faster": "tiny"},
    "base":           {"mlx": ["mlx-community/whisper-base-mlx", "mlx-community/whisper-base"],
                       "faster": "base"},
    "small":          {"mlx": ["mlx-community/whisper-small-mlx", "mlx-community/whisper-small"],
                       "faster": "small"},
    "medium":         {"mlx": ["mlx-community/whisper-medium-mlx", "mlx-community/whisper-medium"],
                       "faster": "medium"},
    "large-v3":       {"mlx": ["mlx-community/whisper-large-v3-mlx", "mlx-community/whisper-large-v3"],
                       "faster": "large-v3"},
    "large-v3-turbo": {"mlx": ["mlx-community/whisper-large-v3-turbo", "mlx-community/whisper-turbo"],
                       "faster": "large-v3-turbo"},
}

BACKENDS = ("auto", "mlx", "faster", "fake")


def resolve_model(model: str) -> dict:
    """预设名返回候选列表；直接写仓库名（或本地目录）时候选就是那一个。"""
    if model in MODEL_PRESETS:
        return MODEL_PRESETS[model]
    return {"mlx": [model], "faster": model}


def _looks_complete(path: str) -> bool:
    """本地目录里要有配置和权重，中断的下载不算。不是真实目录（测试里的假路径）不检查。"""
    if not os.path.isdir(path):
        return True
    names = set(os.listdir(path))
    return "config.json" in names and bool(names & {"weights.safetensors", "weights.npz"})


def resolve_mlx_repo(candidates: list[str], download: Optional[Callable] = None) -> str:
    """把候选仓库名解析成本地模型目录，不依赖 mlx。

    先用 local_files_only 找本地已有的；都没有再联网依次尝试，用第一个成功的。
    download 默认是 huggingface_hub.snapshot_download，测试里可以换成假的。
    """
    if download is None:
        from huggingface_hub import snapshot_download as download
    for repo in candidates:
        if os.path.isdir(repo):
            return repo  # --model 直接给了本地目录
    for repo in candidates:
        try:
            path = download(repo, local_files_only=True)
        except Exception:
            continue
        if _looks_complete(str(path)):
            return str(path)
    errors = []
    for repo in candidates:
        try:
            return str(download(repo))
        except Exception as exc:
            errors.append(f"{repo}（{type(exc).__name__}: {exc}）")
    raise RuntimeError(
        "下载识别模型失败，试过：" + "；".join(errors)
        + "。第一次运行需要联网；也可以用 --model 指定仓库名，例如 --model mlx-community/whisper-tiny"
    )


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


__all__ = ["Backend", "Segment", "MODEL_PRESETS", "make_backend", "resolve_model",
           "resolve_mlx_repo", "pick_backend"]

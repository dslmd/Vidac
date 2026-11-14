"""把转写、翻译线程的情况整理成 docs/COMPANION_PROTOCOL.md 里的 vidac-state 对象。

这里只读取各对象的属性，不起线程、不碰 mpv，所以可以直接单元测试。
所有给用户看的 message / reason 都是英文句子：发生了什么，用户可以怎么办。
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Optional

from .translate import lang_name_en

STATE_VERSION = 1


def _fraction(done: int, total: int) -> Optional[float]:
    return round(min(1.0, done / total), 4) if total > 0 else None


def _phase(video, open_error, ts, generating: bool) -> str:
    if open_error:
        return "error"
    if video is None or ts is None:
        return "idle"
    if ts.error:
        return "error"
    if ts.complete:
        return "ready"
    if not generating:
        return "disabled"
    if ts.downloading:
        return "model-download"
    if ts.model_loading:
        return "model-load"
    return "transcribing"


def _same_lang_reason(language: Optional[str], target: Optional[str]) -> str:
    """说的语言和目标语言算同一种（主语言码相同）时给用户看的话。"""
    spoken = (language or "").lower()
    if spoken.split("-")[0] == "zh":
        if target and target.lower() != spoken:
            # 简体和繁体只差字形：Vidac 不做转换，也别说成“已经是简体中文”
            return ("The speech is in Chinese, and Vidac does not convert between Simplified and "
                    "Traditional characters, so the subtitles are shown as recognized.")
        name = "Chinese"
    else:
        name = lang_name_en(language) if language else "the target language"
    return (f"The speech is already in {name}, so there is nothing to translate. "
            "Choose a different language in “Translate to” to get a translation.")


def translation_state(settings: dict, ts, translator, generating: bool) -> dict:
    """translation 字段。ts 是转写线程（可为 None），translator 是翻译线程（可为 None）。"""
    out: dict[str, Any] = {
        "state": "off", "done": 0, "total": 0,
        "target": settings.get("target_lang"), "engine": settings.get("translate_engine"),
        "reason": None,
    }
    if not settings.get("translate") or translator is None:
        return out
    out["done"], out["total"] = int(translator.translated), int(translator.total)
    status = translator.status
    if status == "same_lang":
        out["reason"] = _same_lang_reason(ts.language if ts is not None else None, out["target"])
    elif status == "disabled":
        # 翻译线程只读了缓存里的译文（自动字幕关着或已停止），不会再翻译新的行
        if out["total"] and out["done"] >= out["total"]:
            out["state"] = "ready"
        elif settings.get("enabled"):
            # 自动字幕是开着的，所以是用户对这个视频点了“停止”：再说“打开它”没有用
            out["reason"] = ("Subtitle generation was stopped for this video, so no more lines will be "
                             "translated. Choose Retry to continue.")
        else:
            out["reason"] = ("Automatic subtitles are off, so no more lines will be translated. "
                             "Turn them on or choose Retry to continue.")
    elif status in ("offline", "no_model"):
        out["state"] = "unavailable"
        out["reason"] = translator.error_msg or ("The translation engine is not available. "
                                                 "Subtitles are shown in the original language.")
    elif status == "error":
        out["state"] = "error"
        out["reason"] = translator.error_msg or ("Translation stopped because of an unexpected "
                                                 "problem. Subtitles are shown in the original language.")
    elif status == "ok":
        failed = int(translator.failed)
        source_done = ts is None or ts.complete or ts.error is not None or not generating
        if out["done"] + failed >= out["total"] and source_done:
            out["state"] = "ready"
            if failed:
                out["reason"] = (f"{failed} line{'s' if failed != 1 else ''} could not be translated "
                                 "and stay in the original language.")
        else:
            out["state"] = "working"
            if getattr(translator, "slow", False):
                out["reason"] = ("The translation server is responding slowly, so translation may take "
                                 "a while. Vidac keeps trying with smaller batches.")
    else:  # checking：还没检测到语言，或在确认翻译服务
        out["state"] = "working"
    return out


def build_state(*, video: Optional[Path], open_error: Optional[tuple[str, str]], ts, translator,
                settings: dict, delay: float, resumed_from: Optional[float], generating: bool,
                ahead: bool) -> dict:
    """生成要发布的状态。open_error 是 (错误码, 英文句子)，打不开文件或没有音轨时用。"""
    phase = _phase(video, open_error, ts, generating)
    loaded = ts is not None and ts.loaded.is_set()
    progress = None
    if ts is not None and loaded:
        if ts.complete:
            progress = 1.0
        else:
            done, total = ts.progress()
            progress = _fraction(done, total)
    error = None
    if open_error:
        error = {"code": open_error[0], "message": open_error[1]}
    elif ts is not None and ts.error:
        error = {"code": ts.error_code or "internal", "message": ts.error}
    files: list[str] = []
    for owner in (ts, translator):
        if owner is not None:
            for path in owner.output_files():
                p = str(Path(path).absolute())
                if p not in files:
                    files.append(p)
    shown = dict(settings)
    shown["delay"] = delay
    return {
        "v": STATE_VERSION,
        "phase": phase,
        "progress": progress,
        "ahead": bool(ahead),
        "download": ts.model_progress.snapshot() if phase == "model-download" else None,
        "model": ts.used_model if ts is not None else settings.get("model"),
        "language": ts.language if ts is not None else None,
        "source": ts.source if loaded else None,
        "resumed_from": resumed_from,
        "delay": delay,
        "translation": translation_state(settings, ts, translator, generating),
        "error": error,
        "files": files,
        "settings": shown,
    }

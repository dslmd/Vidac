"""字幕文件（.srt）读写，缓存文件命名，进度文件。

缓存文件命名（base 是视频名，第 2 条及以后音轨为 movie.a2 这种形式）：
  <base>.subplayer.json   进度：模型、语言、已完成段号、当前原文字幕文件名
  <base>.<语言码>.srt     原文字幕，语言未知时用 und
  <base>.<目标语言>.srt   译文字幕
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

CACHE_DIR = Path.home() / "Library" / "Caches" / "subplayer"


@dataclass
class Cue:
    start: float
    end: float
    text: str                          # 原文，不会被改成译文
    translation: Optional[str] = None  # 译文，没译好时为 None


def fmt_time(sec: float) -> str:
    ms = max(0, int(round(sec * 1000)))
    h, ms = divmod(ms, 3_600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def render_srt(cues: list[Cue]) -> str:
    blocks = []
    for i, c in enumerate(cues, 1):
        blocks.append(f"{i}\n{fmt_time(c.start)} --> {fmt_time(c.end)}\n{c.text}\n")
    return "\n".join(blocks)


_TIME_RE = re.compile(r"(\d+):(\d+):(\d+)[,.](\d+)")


def _parse_time(s: str) -> float:
    m = _TIME_RE.match(s.strip())
    if not m:
        raise ValueError(f"坏的时间戳：{s!r}")
    h, mi, sec, ms = m.groups()
    return int(h) * 3600 + int(mi) * 60 + int(sec) + int(ms.ljust(3, "0")[:3]) / 1000


def parse_srt(text: str) -> list[Cue]:
    cues: list[Cue] = []
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n").strip()):
        lines = block.split("\n")
        for i, line in enumerate(lines):
            if "-->" not in line:
                continue
            try:
                a, b = line.split("-->")[:2]
                start, end = _parse_time(a), _parse_time(b)
            except ValueError:
                break
            body = "\n".join(lines[i + 1:]).strip()
            if body and end > start:
                cues.append(Cue(start, end, body))
            break
    return cues


def atomic_write(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def track_stem(video: Path, track: int) -> str:
    """第 1 条音轨用视频名；第 2 条及以后加 .aN（N 从 2 起）。"""
    return video.stem + (f".a{track + 1}" if track > 0 else "")


def cache_layout(video: Path, track: int, cache_dir: Optional[Path] = None) -> tuple[Path, str]:
    """返回 (存放字幕的目录, 文件名基础部分)。

    默认放在视频旁边。视频所在目录不可写时（比如只读的外接盘），退到 CACHE_DIR，
    文件名前面加视频绝对路径的哈希，避免不同目录的同名视频互相覆盖。
    """
    base = track_stem(video, track)
    folder = video.parent
    if cache_dir is None and not os.access(folder, os.W_OK):
        cache_dir = CACHE_DIR
    if cache_dir is not None:
        cache_dir.mkdir(parents=True, exist_ok=True)
        key = hashlib.sha1(str(video.resolve()).encode("utf-8")).hexdigest()[:12]
        folder = cache_dir
        base = f"{key}-{base}"
    return folder, base


def original_srt_path(folder: Path, base: str, language: Optional[str]) -> Path:
    """原文字幕文件。语言未知时用 und。"""
    return folder / f"{base}.{language or 'und'}.srt"


def translation_srt_path(folder: Path, base: str, target: str) -> Path:
    return folder / f"{base}.{target}.srt"


def progress_path(folder: Path, base: str) -> Path:
    return folder / f"{base}.subplayer.json"


def load_progress(path: Path) -> Optional[dict]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def save_progress(path: Path, data: dict) -> None:
    atomic_write(path, json.dumps(data, ensure_ascii=False, indent=1))


def clear_cache(folder: Path, base: str, *, language: Optional[str] = None,
                target: Optional[str] = None) -> None:
    """--rebuild 用：删除进度文件和原文字幕；传 target 时也删除译文。"""
    names: set[Path] = {progress_path(folder, base), original_srt_path(folder, base, None)}
    if language:
        names.add(original_srt_path(folder, base, language))
    prog = load_progress(progress_path(folder, base))
    if prog and prog.get("srt"):
        names.add(folder / prog["srt"])
    if target:
        names.add(translation_srt_path(folder, base, target))
    for p in names:
        p.unlink(missing_ok=True)

"""字幕文件（.srt）读写，缓存文件命名，进度文件。

缓存文件命名（base 是视频名，第 2 条及以后音轨为 movie.a2 这种形式）：
  <base>.vidac.json           进度：模型、语言、已完成段号、当前原文字幕文件名
  <base>.vidac.<语言码>.srt     原文字幕，语言未知时用 und
  <base>.vidac.tr.<目标语言>.srt 译文字幕（带 tr.，所以永远不会和原文字幕同名，即使说的就是目标语言）

所有 Vidac 自己写的文件名里都带 .vidac.，不会和用户自备的 movie.zh.srt / movie.srt 重名。
0.6 开发版把译文写成 <base>.vidac.<目标语言>.srt，0.5 及更早版本写的是 <base>.<语言码>.srt：
这两种旧名字仍然可以读（见 Translator），但不再往里写，也不会被当成用户字幕或被删除。

<base> 通常是视频文件名去掉扩展名。同一目录里有同名不同扩展名的视频（movie.mkv 和 movie.mp4）时，
后来的那个用带扩展名的 movie.mp4 做 <base>，进度文件里的 "video" 字段记着这套缓存属于哪个文件。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

CACHE_DIR = Path.home() / "Library" / "Caches" / "vidac"


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


_TAG_RE = re.compile(r"\{\\[^}]*\}|</?(?:i|b|u|s|font|c)(?:\s[^>]*|\.[^>]*)?>", re.IGNORECASE)


def strip_markup(text: str) -> str:
    """去掉别人做的字幕里常见的样式标记（<i>、<font …>、{\\an8}），只留文字。"""
    return "\n".join(ln.strip() for ln in _TAG_RE.sub("", text).split("\n") if ln.strip())


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
    """第 1 条音轨用视频名（不含扩展名）；第 2 条及以后加 .aN（N 从 2 起）。用户自备字幕按这个名字找。"""
    return video.stem + (f".a{track + 1}" if track > 0 else "")


VIDEO_SUFFIXES = {".mkv", ".mp4", ".m4v", ".mov", ".avi", ".webm", ".ts", ".m2ts", ".mts", ".flv",
                  ".wmv", ".mpg", ".mpeg", ".ogv", ".3gp", ".rmvb", ".vob", ".divx"}


def _has_sibling_video(video: Path) -> bool:
    """同一目录里有没有同名（不含扩展名）的另一个视频文件。"""
    try:
        names = os.listdir(video.parent)
    except OSError:
        return False
    stem = video.stem
    return any(n != video.name and Path(n).stem == stem and Path(n).suffix.lower() in VIDEO_SUFFIXES
               for n in names)


def _beside_base(video: Path, track: int, folder: Path) -> str:
    """视频旁边存缓存时的文件名基础部分：通常是 track_stem；和同名视频冲突时带上扩展名。

    进度文件里的 "video" 记着缓存是谁的。没有记录的老缓存（0.5 和 0.6 开发版）只有在没有同名视频时
    才认领，有同名视频就不认领（也不删），免得一个视频动了另一个视频的字幕。
    """
    stem_base = track_stem(video, track)
    name_base = video.name + (f".a{track + 1}" if track > 0 else "")
    if name_base == stem_base:
        return stem_base
    if progress_path(folder, name_base).exists():
        return name_base
    prog = load_progress(progress_path(folder, stem_base))
    owner = prog.get("video") if prog else None
    if isinstance(owner, str):
        return stem_base if owner == video.name else name_base
    return name_base if _has_sibling_video(video) else stem_base


def cache_layout(video: Path, track: int, cache_dir: Optional[Path] = None) -> tuple[Path, str]:
    """返回 (存放字幕的目录, 文件名基础部分)。

    默认放在视频旁边。视频所在目录不可写时（比如只读的外接盘），退到 CACHE_DIR，
    文件名前面加视频绝对路径的哈希，避免不同目录的同名视频互相覆盖。
    """
    folder = video.parent
    if cache_dir is None and not os.access(folder, os.W_OK):
        cache_dir = CACHE_DIR
    if cache_dir is not None:
        cache_dir.mkdir(parents=True, exist_ok=True)
        # 哈希是完整路径的，扩展名不同的同名视频自然不同
        key = hashlib.sha1(str(video.resolve()).encode("utf-8")).hexdigest()[:12]
        return cache_dir, f"{key}-{track_stem(video, track)}"
    return folder, _beside_base(video, track, folder)


def original_srt_path(folder: Path, base: str, language: Optional[str]) -> Path:
    """原文字幕文件。语言未知时用 und。"""
    return folder / f"{base}.vidac.{language or 'und'}.srt"


def translation_srt_path(folder: Path, base: str, target: str) -> Path:
    """译文字幕。名字里的 tr. 保证它和原文字幕（<base>.vidac.<语言>.srt）不会是同一个文件。"""
    return folder / f"{base}.vidac.tr.{target}.srt"


def wip_translation_srt_path(folder: Path, base: str, target: str) -> Path:
    """0.6 开发版的译文文件名。只读，不再写。注意它可能和原文字幕同名，使用前要排除。"""
    return folder / f"{base}.vidac.{target}.srt"


def legacy_translation_srt_path(folder: Path, base: str, target: str) -> Path:
    """0.5 及更早版本的译文文件名。只读，不再写。"""
    return folder / f"{base}.{target}.srt"


def progress_path(folder: Path, base: str) -> Path:
    return folder / f"{base}.vidac.json"


def load_progress(path: Path) -> Optional[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def save_progress(path: Path, data: dict) -> None:
    atomic_write(path, json.dumps(data, ensure_ascii=False, indent=1))


def own_files(folder: Path, base: str) -> list[Path]:
    """这个视频（这条音轨）名下 Vidac 自己写的字幕文件：<base>.vidac.<语言>.srt，加上进度文件里记的那个。"""
    found: set[Path] = set()
    prefix = f"{base}.vidac."
    try:
        names = os.listdir(folder)
    except OSError:
        names = []
    for name in names:
        if not (name.startswith(prefix) and name.endswith(".srt")):
            continue
        mid = name[len(prefix):-4]
        if mid.startswith("tr."):
            mid = mid[3:]
        # 中间只能是一个语言码（译文前面多一个 tr.），免得把 movie.vidac.a2.ja.srt 之类算到别的音轨头上
        if "." not in mid:
            found.add(folder / name)
    # 进度文件里记的名字只有带 .vidac. 的才算 Vidac 自己的。0.5 的 <base>.<语言>.srt 和用户自备的
    # movie.en.srt 是同一个名字，没法确定是谁写的，所以不删、不搬、不覆盖
    prog = load_progress(progress_path(folder, base))
    name = prog.get("srt") if prog else None
    if (isinstance(name, str) and ".vidac." in name and Path(name).name == name
            and (folder / name).exists()):
        found.add(folder / name)
    return sorted(found)


def legacy_original(folder: Path, base: str) -> Optional[Path]:
    """进度文件指向的 0.5 原文字幕（名字不带 .vidac.）。存在才返回。它可能其实是用户的文件，只读。"""
    prog = load_progress(progress_path(folder, base))
    name = prog.get("srt") if prog else None
    if (isinstance(name, str) and name and ".vidac." not in name and Path(name).name == name
            and (folder / name).is_file()):
        return folder / name
    return None


def clear_cache(folder: Path, base: str, *, language: Optional[str] = None,
                target: Optional[str] = None) -> None:
    """重新生成用：删除进度文件和 Vidac 自己写的原文、译文字幕。用户自备的字幕文件不动。

    language / target 是旧接口留下的参数，现在所有 .vidac. 文件一并删除，用不到它们。
    """
    for p in own_files(folder, base) + [progress_path(folder, base)]:
        p.unlink(missing_ok=True)


def migrate_cache(src: tuple[Path, str], dst: tuple[Path, str]) -> bool:
    """字幕保存位置改了：把 src 那边 Vidac 自己的文件搬到 dst。dst 已有进度文件时不动。

    返回是否搬了。搬不动（只读盘等）就留在原处，调用方照常在 dst 重新生成。
    """
    (sf, sb), (df, db) = src, dst
    if (sf, sb) == (df, db):
        return False
    prog = load_progress(progress_path(sf, sb))
    if prog is None or progress_path(df, db).exists():
        return False
    try:
        df.mkdir(parents=True, exist_ok=True)
        old_srt = prog.get("srt")
        legacy = legacy_original(sf, sb)
        for path in own_files(sf, sb):
            shutil.move(str(path), str(df / (db + path.name[len(sb):])))
            if path.name == old_srt:
                prog["srt"] = db + path.name[len(sb):]
        if legacy is not None:
            # 0.5 的原文字幕可能是用户的文件：留在原处，只复制一份过去，让搬过去的缓存仍然完整
            new_name = f"{db}.vidac.{prog.get('language') or 'und'}.srt"
            shutil.copy2(str(legacy), str(df / new_name))
            prog["srt"] = new_name
        save_progress(progress_path(df, db), prog)
        progress_path(sf, sb).unlink(missing_ok=True)
    except OSError:
        return False
    return True

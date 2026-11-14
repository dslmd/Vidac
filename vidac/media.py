"""ffprobe / ffmpeg 封装：列音轨、读时长、把某段音频解码成 16 kHz 单声道 float32。"""

from __future__ import annotations

import json
import logging
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np

log = logging.getLogger("vidac.media")

SAMPLE_RATE = 16000


class MediaError(RuntimeError):
    pass


@dataclass
class AudioTrack:
    index: int          # 在所有音频流中的序号，从 0 开始（对应 ffmpeg 的 0:a:N）
    codec: str
    channels: int
    language: str
    title: str

    def describe(self) -> str:
        bits = [f"{self.codec}", f"{self.channels}ch", f"lang={self.language}"]
        if self.title:
            bits.append(self.title)
        return " ".join(bits)


def check_tools() -> list[str]:
    """只警告不退出：缺 ffmpeg 时视频照常播放，只是没有字幕。返回缺少的工具名。"""
    missing = [t for t in ("ffmpeg", "ffprobe") if shutil.which(t) is None]
    if missing:
        log.warning("找不到 %s，字幕功能不可用（请运行 install.sh 或 brew install ffmpeg）",
                    "、".join(missing))
    return missing


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, **kwargs)
    except FileNotFoundError as exc:
        raise MediaError(f"Vidac cannot find {cmd[0]}, which it needs to read the audio. Reinstall "
                         "Vidac, or run install.sh when running from source.") from exc


def _ffprobe(args: list[str]) -> str:
    proc = _run(
        ["ffprobe", "-v", "error", *args],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        detail = " ".join(proc.stderr.split())[-300:]   # 压成一行：错误文字会直接显示和放进 JSON
        raise MediaError("Vidac could not read this file, so subtitles are unavailable for it"
                         + (f" ({detail})." if detail else "."))
    return proc.stdout


def probe_audio_tracks(path: Path) -> list[AudioTrack]:
    out = _ffprobe([
        "-select_streams", "a",
        "-show_entries", "stream=codec_name,channels:stream_tags=language,title",
        "-of", "json",
        str(path),
    ])
    streams = json.loads(out).get("streams", [])
    tracks = []
    for i, s in enumerate(streams):
        tags = s.get("tags") or {}
        tracks.append(AudioTrack(
            index=i,
            codec=s.get("codec_name", "?"),
            channels=int(s.get("channels") or 0),
            language=tags.get("language", "und"),
            title=tags.get("title", ""),
        ))
    return tracks


def probe_duration(path: Path) -> float:
    """视频时长（秒）。格式层拿不到时，退回到各流时长的最大值。"""
    out = _ffprobe(["-show_entries", "format=duration", "-of", "csv=p=0", str(path)]).strip()
    try:
        value = float(out)
        if value > 0:
            return value
    except ValueError:
        pass
    out = _ffprobe(["-show_entries", "stream=duration", "-of", "csv=p=0", str(path)])
    values = []
    for line in out.split():
        try:
            values.append(float(line))
        except ValueError:
            continue
    if not values or max(values) <= 0:
        raise MediaError("Vidac could not read the length of this video, so subtitles are "
                         "unavailable. The file may be damaged.")
    return max(values)


def read_audio(path: Path, track: int, start: float, duration: float) -> np.ndarray:
    """解码第 track 条音轨从 start 秒开始的 duration 秒，返回 16 kHz 单声道 float32。"""
    if duration <= 0:
        return np.zeros(0, dtype=np.float32)
    cmd = [
        "ffmpeg", "-nostdin", "-v", "error",
        "-ss", f"{start:.3f}",
        "-i", str(path),
        "-map", f"0:a:{track}",
        "-t", f"{duration:.3f}",
        "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE),
        "-f", "f32le", "-",
    ]
    proc = _run(cmd, capture_output=True)
    if proc.returncode != 0:
        msg = " ".join(proc.stderr.decode(errors="replace").split())[-300:]
        raise MediaError(f"Vidac could not decode audio track {track + 1} of this video ({msg}).")
    return np.frombuffer(proc.stdout, dtype=np.float32).copy()

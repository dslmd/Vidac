"""记住每个视频上次看到的位置。保存在 app_dir()/positions.json，最多 500 条。"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from typing import Optional

from .srt import atomic_write

log = logging.getLogger("vidac.positions")

MAX_ENTRIES = 500
NEAR_END_SECONDS = 15.0   # 距结尾这么近就视为看完，不再记住
MIN_RESUME_SECONDS = 5.0  # 太靠前的位置没必要恢复


class PositionStore:
    def __init__(self, path: Path) -> None:
        self.path = Path(path)

    def _load(self) -> dict:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _write(self, data: dict) -> None:
        try:
            atomic_write(self.path, json.dumps(data, ensure_ascii=False, indent=1))
        except OSError as exc:
            log.warning("位置记录保存失败：%s", exc)

    def get(self, video: Path) -> Optional[float]:
        """返回应该恢复到的秒数；没有记录、文件已变化、或已经看到结尾时返回 None。"""
        video = Path(video)
        rec = self._load().get(str(video))
        if not isinstance(rec, dict):
            return None
        try:
            st = video.stat()
            if int(rec.get("size", -1)) != st.st_size or abs(float(rec.get("mtime", -1)) - st.st_mtime) > 1:
                return None
            pos = float(rec["pos"])
        except (OSError, KeyError, TypeError, ValueError):
            return None
        return pos if pos >= MIN_RESUME_SECONDS else None

    def save(self, video: Path, pos: float, duration: Optional[float]) -> None:
        video = Path(video)
        data = self._load()
        key = str(video)
        if duration and duration - pos < NEAR_END_SECONDS:
            data.pop(key, None)
            self._write(data)
            return
        try:
            st = video.stat()
        except OSError:
            return
        data[key] = {
            "pos": round(float(pos), 2),
            "size": st.st_size,
            "mtime": st.st_mtime,
            "updated": time.time(),
        }
        if len(data) > MAX_ENTRIES:
            keep = sorted(data.items(), key=lambda kv: kv[1].get("updated", 0), reverse=True)
            data = dict(keep[:MAX_ENTRIES])
        self._write(data)

    def clear(self, video: Path) -> None:
        data = self._load()
        if str(video) in data:
            data.pop(str(video), None)
            self._write(data)

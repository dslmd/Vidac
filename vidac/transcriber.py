"""后台转写线程：按 30 秒分段，优先转写播放位置附近的段，结果实时写入字幕并落盘。"""

from __future__ import annotations

import bisect
import logging
import math
import threading
from pathlib import Path
from typing import Callable, Optional

from . import media, srt
from .asr.base import Backend
from .filters import clean_cues, is_voiced, keep_segment
from .srt import Cue

log = logging.getLogger("vidac.transcriber")

CHUNK_SECONDS = 30.0
PAD_SECONDS = 2.0       # 每段前后多取 2 秒给模型当上下文；只保留段中心落在本段内的句子
MAX_CONSECUTIVE_FAILURES = 3


class SubtitleStore:
    """线程安全的字幕列表，按开始时间排序。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._starts: list[float] = []
        self._cues: list[Cue] = []

    def add(self, cues: list[Cue]) -> None:
        with self._lock:
            for c in cues:
                i = bisect.bisect_right(self._starts, c.start)
                self._starts.insert(i, c.start)
                self._cues.insert(i, c)

    def apply(self, fn: Callable[[list[Cue]], list[Cue]]) -> None:
        """在锁内把全部字幕交给 fn 处理，返回的列表会按开始时间重新排序。"""
        with self._lock:
            cues = sorted(fn(list(self._cues)), key=lambda c: c.start)
            self._cues = cues
            self._starts = [c.start for c in cues]

    def snapshot(self) -> list[Cue]:
        with self._lock:
            return list(self._cues)

    def active(self, t: float) -> list[Cue]:
        """时间 t 正在显示的字幕。往前看 12 条就够了，不用全表扫描。"""
        with self._lock:
            i = bisect.bisect_right(self._starts, t)
            return [c for c in self._cues[max(0, i - 12):i] if c.end > t]


class Transcriber(threading.Thread):
    def __init__(
        self,
        video: Path,
        track: int,
        backend_factory: Callable[[], Backend],
        *,
        model: str,
        language: Optional[str] = None,
        vad: bool = False,
        rebuild: bool = False,
        cache_dir: Optional[Path] = None,
        chunk_seconds: float = CHUNK_SECONDS,
        pad_seconds: float = PAD_SECONDS,
    ) -> None:
        super().__init__(name=f"transcriber-track{track + 1}", daemon=True)
        self.video = Path(video)
        self.track = track
        self.model = model
        self.backend_factory = backend_factory
        self.requested_language = language  # None 表示自动检测
        self.language = language            # 检测到后锁定在这里
        self.vad = vad
        self.rebuild = rebuild
        self.chunk_seconds = chunk_seconds
        self.pad_seconds = pad_seconds
        self.folder, self.base = srt.cache_layout(self.video, track, cache_dir)
        self.progress_path = srt.progress_path(self.folder, self.base)
        self._written_path: Optional[Path] = None

        self.store = SubtitleStore()
        self.duration = 0.0
        self.total = 0
        self.complete = False
        self.error: Optional[str] = None
        self.warning: Optional[str] = None
        self.processed: list[int] = []  # 实际处理过的段号，按顺序（调试和测试用）
        self.pos = 0.0                  # 播放位置，由主线程更新
        self.loaded = threading.Event() # 缓存已读入 store 之后置位，翻译线程等它

        self._lock = threading.Lock()
        self._done: set[int] = set()
        self._failed: set[int] = set()
        self._stop_event = threading.Event()

    @property
    def srt_path(self) -> Path:
        """当前语言对应的原文字幕文件。语言锁定后会变。"""
        return srt.original_srt_path(self.folder, self.base, self.language)

    # ---- 给主线程用的接口 ----
    def set_position(self, t: float) -> None:
        self.pos = float(t)

    def stop(self) -> None:
        """只置位停止标志，不等待。当前段的结果会被丢弃。"""
        self._stop_event.set()

    def progress(self) -> tuple[int, int]:
        with self._lock:
            return len(self._done), self.total

    # ---- 线程主体 ----
    def run(self) -> None:
        try:
            self._run()
        except media.MediaError as exc:
            self.error = str(exc)
        except Exception as exc:  # 后台线程出错不能把播放器带崩
            log.exception("转写线程出错")
            self.error = f"{type(exc).__name__}: {exc}"
        finally:
            self.loaded.set()

    def _run(self) -> None:
        self.duration = media.probe_duration(self.video)
        self.total = max(1, math.ceil(self.duration / self.chunk_seconds))
        if self.rebuild:
            srt.clear_cache(self.folder, self.base, language=self.requested_language)
        self._load_cache()
        self.loaded.set()
        if len(self._done) >= self.total:
            self.complete = True
            log.info("字幕缓存已完整：%s", self.srt_path)
            return

        backend = self.backend_factory()
        log.info("开始转写：%s 音轨 %d，共 %d 段", self.video.name, self.track + 1, self.total)
        fails = 0
        last_exc: Optional[Exception] = None
        while not self._stop_event.is_set():
            idx = self._pick_next()
            if idx is None:
                break
            try:
                ok = self._process(idx, backend)
                fails = 0
            except Exception as exc:
                log.exception("第 %d 段转写失败，跳过", idx)
                self._failed.add(idx)
                fails += 1
                last_exc = exc
                self.warning = f"第 {idx} 段失败：{exc}"
                ok = True
                if fails >= MAX_CONSECUTIVE_FAILURES:
                    self.error = f"连续 {fails} 段转写失败（最后一次：{last_exc}）"
                    log.error(self.error)
                    break
            if not ok or self._stop_event.is_set():
                break  # 已经停止：丢弃这一段的结果，不落盘
            self._persist()

        if len(self._done) >= self.total and self.error is None:
            self.complete = True
            self._persist()
            log.info("转写完成：%s", self.srt_path)

    # ---- 调度 ----
    def _pick_next(self) -> Optional[int]:
        """离播放位置最近的未完成段。往后的段优先，往回拖的段稍后。"""
        with self._lock:
            skip = self._done | self._failed
        if len(skip) >= self.total:
            return None
        cur = min(max(int(self.pos // self.chunk_seconds), 0), self.total - 1)
        best, best_score = None, None
        for i in range(self.total):
            if i in skip:
                continue
            d = i - cur
            score = d if d >= 0 else -2 * d + 0.5
            if best_score is None or score < best_score:
                best, best_score = i, score
        return best

    # ---- 单段处理 ----
    def _process(self, idx: int, backend: Backend) -> bool:
        """处理一段。返回 False 表示中途被停止，结果已丢弃。"""
        cs = self.chunk_seconds
        core_start = idx * cs
        core_end = core_start + cs
        read_start = max(0.0, core_start - self.pad_seconds)
        read_end = core_end + self.pad_seconds
        if self.duration > 0:
            core_end = min(core_end, self.duration)
            read_end = min(read_end, self.duration)

        self.processed.append(idx)
        cues = self._transcribe_chunk(idx, backend, core_start, core_end, read_start, read_end)
        if self._stop_event.is_set():
            return False
        self.store.add(cues)
        self.store.apply(clean_cues)
        with self._lock:
            self._done.add(idx)
        return True

    def _transcribe_chunk(self, idx: int, backend: Backend, core_start: float,
                          core_end: float, read_start: float, read_end: float) -> list[Cue]:
        audio = media.read_audio(self.video, self.track, read_start, read_end - read_start)
        if audio.size < media.SAMPLE_RATE // 2:
            return []
        voiced = is_voiced(audio)
        if self.vad and not voiced:
            log.info("第 %d 段没有人声，跳过", idx)
            return []

        segs, detected = backend.transcribe(audio, self.language, "transcribe", offset=read_start)
        if self.language is None and detected and voiced:
            # 只在有人声的段上检测语言，然后锁定，之后每段都用这个语言
            self.language = detected
            log.info("检测到语言 %s，之后锁定", detected)

        upper = core_end if idx < self.total - 1 else math.inf
        cues: list[Cue] = []
        for s in segs:
            a = read_start + s.start
            b = read_start + s.end
            mid = (a + b) / 2
            if not (core_start <= mid < upper):
                continue  # 属于前后相邻段的范围，交给相邻段处理
            if not keep_segment(s):
                continue
            cues.append(Cue(a, b, s.text.strip()))
        return cues

    # ---- 缓存 ----
    def _load_cache(self) -> None:
        prog = srt.load_progress(self.progress_path)
        if prog is not None:
            name = prog.get("srt")
            path = self.folder / name if name else None
            if path is not None and path.exists():
                cues = srt.parse_srt(path.read_text(encoding="utf-8", errors="replace"))
                self.store.add(cues)
                self._written_path = path
                log.info("读取已有字幕 %s（%d 条）", path, len(cues))
                self._done = {int(i) for i in prog.get("done", []) if 0 <= int(i) < self.total}
            if self.requested_language is None and prog.get("language"):
                self.language = prog["language"]
            old_model = prog.get("model")
            if old_model and old_model != self.model:
                self.warning = f"已有字幕是 {old_model} 生成的，当前设为 {self.model}。想统一请加 --rebuild"
            return

        # 没有进度文件：可能是用户自备的字幕（movie.<语言>.srt 或 movie.srt），直接当作完整字幕
        user_dir = self.video.parent
        stem = srt.track_stem(self.video, self.track)
        candidates = []
        if self.requested_language:
            candidates.append(user_dir / f"{stem}.{self.requested_language}.srt")
        candidates.append(user_dir / f"{stem}.srt")
        for path in candidates:
            if path.exists():
                cues = srt.parse_srt(path.read_text(encoding="utf-8", errors="replace"))
                self.store.add(cues)
                self._done = set(range(self.total))
                log.info("使用用户字幕 %s（%d 条），不重新转写", path, len(cues))
                return

    def _persist(self) -> None:
        if self._stop_event.is_set():
            return
        with self._lock:
            done = sorted(self._done)
        path = self.srt_path
        srt.atomic_write(path, srt.render_srt(self.store.snapshot()))
        if self._written_path is not None and self._written_path != path:
            self._written_path.unlink(missing_ok=True)  # 语言锁定后删除旧的 und 文件
        self._written_path = path
        srt.save_progress(self.progress_path, {
            "version": 2,
            "model": self.model,
            "language": self.language,
            "srt": path.name,
            "duration": self.duration,
            "total": self.total,
            "done": done,
            "complete": len(done) >= self.total,
        })

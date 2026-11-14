"""后台转写线程：按 30 秒分段，优先转写播放位置附近的段，结果实时写入字幕并落盘。"""

from __future__ import annotations

import bisect
import logging
import math
import os
import threading
from pathlib import Path
from typing import Callable, Optional

import re

from . import media, srt
from .asr import DownloadCancelled, ModelProgress
from .asr.base import Backend
from .filters import clean_cues, is_voiced, keep_segment, normalize
from .langguess import guess_language
from .settings import WHISPER_LANGUAGES, target_for_locale
from .srt import Cue

log = logging.getLogger("vidac.transcriber")

CHUNK_SECONDS = 30.0
PAD_SECONDS = 2.0       # 每段前后多取 2 秒给模型当上下文；只保留段中心落在本段内的句子
# 同一时刻只允许一个转写线程使用识别后端：MLX 的模型和 Stream 要留在一个线程里，两个大模型同时跑
# 还会把内存翻倍。换模型、换音轨、点停止时旧线程先收尾（最多一段），新线程排队等它
_BACKEND_LOCK = threading.Lock()
LEGACY_MTIME_SLACK = 2.0   # 0.5 的原文字幕比进度文件新这么多秒以上，就当作用户后来自己放的

MAX_CONSECUTIVE_FAILURES = 3
REPEAT_NO_SPEECH_PROB = 0.4
PAUSED_LOOKAHEAD_SECONDS = 600.0   # 暂停时只把播放位置往后这么长的部分转写完，然后等继续播放

_SIDECAR_CODE = re.compile(r"^[A-Za-z]{2,3}(?:[-_][A-Za-z]{2,4})?$")
_THREE_LETTER = {"eng": "en", "jpn": "ja", "kor": "ko", "chi": "zh", "zho": "zh", "chs": "zh",
                 "cht": "zh-tw", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "spa": "es",
                 "rus": "ru", "por": "pt", "ita": "it"}


def sidecar_language(code: str) -> Optional[str]:
    """字幕文件名里的语言后缀（en、eng、zh-CN、zh-Hant …）对应的语言码；认不出返回 None。"""
    low = code.lower().replace("_", "-")
    if low in _THREE_LETTER:
        return _THREE_LETTER[low]
    main = low.split("-")[0]
    if main == "zh":
        return target_for_locale(low)
    return main if main in WHISPER_LANGUAGES else None


def find_sidecar(video: Path, track: int, language: Optional[str] = None,
                 target: Optional[str] = None,
                 ignore: Optional[set[str]] = None) -> Optional[tuple[Path, Optional[str]]]:
    """用户自备的字幕文件：(路径, 语言码或 None)。没有返回 None。

    依次找：<名字>.<指定的转写语言>.srt、<名字>.srt、<名字>.<任意语言码>.srt。
    最后一种有多个时，先用不是翻译目标语言的那个（这样还能翻译出双语）。
    名字里带 .vidac. 的是 Vidac 自己写的文件，不算。
    """
    folder = video.parent
    stem = srt.track_stem(video, track)
    ignore = ignore or set()   # 0.5 缓存留下的文件名：已确认是 Vidac 自己的旧产物，不当用户字幕
    if language:
        path = folder / f"{stem}.{language}.srt"
        if path.is_file() and path.name not in ignore:
            return path, language
    path = folder / f"{stem}.srt"
    if path.is_file() and path.name not in ignore:
        return path, None
    found: list[tuple[bool, str, Path, Optional[str]]] = []
    prefix = f"{stem}."
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return None
    for name in names:
        if not (name.startswith(prefix) and name.lower().endswith(".srt")) or name in ignore:
            continue
        code = name[len(prefix):-4]
        if not _SIDECAR_CODE.match(code) or code.lower() == "vidac":
            continue
        lang = sidecar_language(code)
        if lang is None and len(code) > 3:
            continue
        is_target = bool(lang and target and lang.split("-")[0] == target.split("-")[0])
        found.append((is_target, name, folder / name, lang))
    if not found:
        return None
    found.sort(key=lambda item: (item[0], item[1]))
    return found[0][2], found[0][3]


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
        transcribe: bool = True,
        use_sidecar: bool = True,
        target_lang: Optional[str] = None,
        model_progress: Optional[ModelProgress] = None,
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
        self.transcribe = transcribe        # False：只读已有的字幕，不识别（自动字幕关着）
        self.use_sidecar = use_sidecar      # False：用户要求重新生成，不用自备的字幕文件
        self.target_lang = target_lang      # 只用来在几个自备字幕里挑一个
        self.chunk_seconds = chunk_seconds
        self.pad_seconds = pad_seconds
        self.folder, self.base = srt.cache_layout(self.video, track, cache_dir)
        self.progress_path = srt.progress_path(self.folder, self.base)
        self._written_path: Optional[Path] = None
        self.ignored_sidecars: set[str] = set()   # 进度文件里记下的 0.5 旧产物文件名，重建后也不能被当成用户字幕
        self._persist_lock = threading.Lock()   # 写盘期间持有；stop() 借它等正在写的那一次写完
        self._holds_backend = False

        self.store = SubtitleStore()
        self.duration = 0.0
        self.total = 0
        self.complete = False
        self.error: Optional[str] = None       # 给用户看的英文句子
        self.error_code: Optional[str] = None  # offline / model-download / audio / internal
        self.warning: Optional[str] = None
        self.source = "generated"       # generated / cache（Vidac 以前生成的）/ sidecar（用户自备的字幕文件）
        self.sidecar_path: Optional[Path] = None
        self.cache_model: Optional[str] = None  # 缓存是哪个模型生成的
        self.legacy_cache = False       # 缓存是 0.5 及更早版本写的（文件名不带 .vidac.）
        self.model_progress = model_progress or ModelProgress()
        self.model_loading = False      # 从创建识别后端开始，到第一段转写完成为止（第一次运行要下载模型）
        self.processed: list[int] = []  # 实际处理过的段号，按顺序（调试和测试用）
        self.pos = 0.0                  # 播放位置，由主线程更新
        self.paused = False             # 播放暂停着，由主线程更新
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

    def set_paused(self, paused: bool) -> None:
        self.paused = bool(paused)

    def stop(self) -> None:
        """置位停止标志，当前段的结果会被丢弃；正在下载模型的话下载也会中断。

        只会等一件事：正在写盘的那一次写完。stop() 返回之后，这个线程不会再写字幕和进度文件，
        调用方可以放心地清缓存或搬文件。
        """
        self._stop_event.set()
        self.model_progress.cancelled.set()
        with self._persist_lock:
            pass

    @property
    def stopped(self) -> bool:
        return self._stop_event.is_set()

    @property
    def working(self) -> bool:
        """还有段没转写完，并且线程还在干活。"""
        return (self.is_alive() and not self._stop_event.is_set()
                and not self.complete and self.error is None)

    @property
    def downloading(self) -> bool:
        return self.model_loading and self.model_progress.downloading

    @property
    def used_model(self) -> str:
        """屏幕上这些字幕是哪个模型生成的（来自缓存就是当时的模型）。"""
        if self.source == "cache" and self.cache_model:
            return self.cache_model
        return self.model

    def progress(self) -> tuple[int, int]:
        with self._lock:
            return len(self._done), self.total

    def covered(self, t: float) -> bool:
        """时间 t 所在的段是否已经处理过（转写完，或者失败后放弃了）。"""
        if self.total <= 0:
            return False
        idx = min(max(int(t // self.chunk_seconds), 0), self.total - 1)
        with self._lock:
            return idx in self._done or idx in self._failed

    def output_files(self) -> list[Path]:
        """Vidac 为这个视频写出的原文字幕文件（存在才算）。"""
        path = self._written_path
        return [path] if path is not None and path.exists() else []

    # ---- 线程主体 ----
    def run(self) -> None:
        try:
            self._run()
        except DownloadCancelled:
            log.info("模型下载已中断")
        except media.MediaError as exc:
            self._fail(str(exc), "audio")
        except Exception as exc:  # 后台线程出错不能把播放器带崩
            log.exception("转写线程出错")
            code = getattr(exc, "code", None)
            if code in ("offline", "model-download", "audio", "internal"):
                self._fail(str(exc), code)
            else:
                self._fail("Subtitles stopped because of an unexpected problem "
                           f"({type(exc).__name__}: {exc}). Playback is not affected; "
                           "try again to restart subtitles.", "internal")
        finally:
            self.model_loading = False
            if self._holds_backend:
                self._holds_backend = False
                _BACKEND_LOCK.release()
            self.loaded.set()

    def _acquire_backend(self) -> bool:
        """排队等前一个转写线程用完识别后端。等的时候被停掉就放弃。"""
        while not _BACKEND_LOCK.acquire(timeout=0.25):
            if self._stop_event.is_set():
                return False
        self._holds_backend = True
        return not self._stop_event.is_set()

    def _legacy_is_ours(self) -> bool:
        """进度文件指向的 0.5 原文字幕是不是 Vidac 写的：比进度文件新得多就是用户后来自己放的。"""
        legacy = srt.legacy_original(self.folder, self.base)
        if legacy is None:
            return False
        try:
            return legacy.stat().st_mtime <= self.progress_path.stat().st_mtime + LEGACY_MTIME_SLACK
        except OSError:
            return False

    def _legacy_leftovers(self) -> set[str]:
        """0.5 缓存留下的、Vidac 自己写的 <名字>.<语言>.srt（原文和译文）：不比进度文件新得多的那些。"""
        names: set[str] = set()
        try:
            limit = self.progress_path.stat().st_mtime + LEGACY_MTIME_SLACK
        except OSError:
            return names
        prefix = f"{self.base}."
        try:
            listing = os.listdir(self.folder)
        except OSError:
            return names
        for name in listing:
            if not (name.startswith(prefix) and name.endswith(".srt")) or ".vidac." in name:
                continue
            if "." in name[len(prefix):-4]:
                continue
            try:
                if (self.folder / name).stat().st_mtime <= limit:
                    names.add(name)
            except OSError:
                pass
        return names

    def _discard_cache(self) -> None:
        """丢弃 Vidac 自己的缓存。0.5 的缓存留下的 <名字>.<语言>.srt（原文和译文）不能删（可能是用户的），
        也不能让它们接着被当成用户字幕读进来，所以把它们的名字记在一个空的进度文件里作记号
        （ignore_sidecars，之后再重建、重新打开都还在）。整个过程持有写盘锁并检查停止标志，
        停掉的线程不会再动旧位置的文件。"""
        with self._persist_lock:
            if self._stop_event.is_set():
                return
            ignored = set(self.ignored_sidecars)
            prog = srt.load_progress(self.progress_path)
            if prog:
                ignored.update(n for n in prog.get("ignore_sidecars", []) if isinstance(n, str))
            if self._legacy_is_ours():
                ignored |= self._legacy_leftovers()
            srt.clear_cache(self.folder, self.base)
            self.ignored_sidecars = ignored
            if ignored:
                self._write_progress([])

    def _fail(self, message: str, code: str) -> None:
        if self._stop_event.is_set():
            return  # 已经被停掉，这个错误没人关心
        self.error_code = code
        self.error = message

    def _run(self) -> None:
        self.duration = media.probe_duration(self.video)
        self.total = max(1, math.ceil(self.duration / self.chunk_seconds))
        if self._stop_event.is_set():
            return  # 探测时长期间已经被换掉了：不能再去清缓存
        if self.rebuild:
            self._discard_cache()
        self._load_cache()
        self.loaded.set()
        if len(self._done) >= self.total:
            self.complete = True
            log.info("字幕已完整：%s", self.sidecar_path or self.srt_path)
            return
        if not self.transcribe:
            return

        backend: Optional[Backend] = None
        fails = 0
        last_exc: Optional[Exception] = None
        window = max(1, math.ceil(PAUSED_LOOKAHEAD_SECONDS / self.chunk_seconds))
        while not self._stop_event.is_set():
            idx = self._pick_next(window if self.paused else None)
            if idx is None:
                if self.paused and self._pick_next() is not None:
                    self._stop_event.wait(0.25)   # 暂停着，附近的已经转写完，等继续播放或拖动
                    continue
                break
            if backend is None:
                self.model_loading = True
                if not self._acquire_backend():
                    break
                backend = self.backend_factory()   # 出错时由 run() 的 finally 清掉 model_loading
                log.info("开始转写：%s 音轨 %d，共 %d 段", self.video.name, self.track + 1, self.total)
                if self._stop_event.is_set():
                    break
            try:
                try:
                    ok = self._process(idx, backend)
                finally:
                    self.model_loading = False
                fails = 0
            except Exception as exc:
                log.exception("第 %d 段转写失败，跳过", idx)
                self._failed.add(idx)
                fails += 1
                last_exc = exc
                self.warning = f"Part {idx + 1} of this video could not be transcribed ({exc})."
                ok = True
                if fails >= MAX_CONSECUTIVE_FAILURES:
                    if isinstance(last_exc, media.MediaError):
                        self._fail(str(last_exc), "audio")
                    else:
                        self._fail(f"Subtitles stopped after {fails} parts in a row could not be "
                                   f"transcribed ({type(last_exc).__name__}: {last_exc}). "
                                   "Playback is not affected; try again to restart subtitles.",
                                   "internal")
                    log.error("连续 %d 段转写失败（最后一次：%s）", fails, last_exc)
                    break
            if not ok or self._stop_event.is_set():
                break  # 已经停止：丢弃这一段的结果，不落盘
            self.source = "generated"
            self._persist()

        if len(self._done) >= self.total and self.error is None:
            self.complete = True
            self._persist()
            log.info("转写完成：%s", self.srt_path)
        elif (self.error is None and not self._stop_event.is_set()
              and len(self._done | self._failed) >= self.total):
            # 剩下的段都失败过：没有“完成”，也不能一直显示“进行中”
            self._fail(f"{len(self._failed)} part{'s' if len(self._failed) != 1 else ''} of this video "
                       "could not be transcribed and have no subtitles. Playback is not affected; "
                       "choose Retry to try again.", "internal")

    # ---- 调度 ----
    def _pick_next(self, window: Optional[int] = None) -> Optional[int]:
        """离播放位置最近的未完成段。往后的段优先，往回拖的段稍后。

        给了 window 时只看播放位置所在的段和它后面 window 段。
        """
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
            if window is not None and not 0 <= d <= window:
                continue
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
        prev_text: Optional[str] = None
        for s in segs:
            a = read_start + s.start
            b = read_start + s.end
            mid = (a + b) / 2
            if not (core_start <= mid < upper):
                continue  # 属于前后相邻段的范围，交给相邻段处理
            if not keep_segment(s):
                continue
            norm = normalize(s.text)
            if norm == prev_text and s.no_speech_prob > REPEAT_NO_SPEECH_PROB:
                continue  # 同一段里原样重复、又像是没人说话：多半是静音里编出来的
            prev_text = norm
            cues.append(Cue(a, b, s.text.strip()))
        return cues

    # ---- 缓存 ----
    def _load_cache(self) -> None:
        prog = srt.load_progress(self.progress_path)
        if prog is not None:
            self.ignored_sidecars |= {n for n in prog.get("ignore_sidecars", []) if isinstance(n, str)}
        legacy = srt.legacy_original(self.folder, self.base) if prog is not None else None
        if legacy is not None and not self._legacy_is_ours():
            # 这个 movie.en.srt 比进度文件新得多：是用户后来放的（比如换了视频、下了新字幕），
            # 不是 Vidac 的缓存。旧进度作废（不删，下次写盘时会被覆盖），文件当作自备字幕
            log.info("%s 比进度文件新，当作用户字幕", legacy.name)
            prog = None
        if prog is not None:
            try:
                old_duration = float(prog.get("duration") or 0)
            except (TypeError, ValueError):
                old_duration = 0.0
            if old_duration and self.duration and abs(old_duration - self.duration) > 1.0:
                # 同名的视频换过了，旧字幕对不上
                log.info("视频时长变了（%.1f → %.1f 秒），丢弃旧字幕", old_duration, self.duration)
                self._discard_cache()
                prog = None
        if prog is not None:
            name = prog.get("srt")
            path = self.folder / name if name else None
            if path is not None and path.exists():
                cues = srt.parse_srt(path.read_text(encoding="utf-8", errors="replace"))
                self.store.add(cues)
                self._written_path = path
                self.legacy_cache = ".vidac." not in path.name
                log.info("读取已有字幕 %s（%d 条）", path, len(cues))
                self._done = {int(i) for i in prog.get("done", []) if 0 <= int(i) < self.total}
                if self._done:
                    self.source = "cache"
                    self.cache_model = prog.get("model") or None
            cached_lang = prog.get("language") or None
            partial = len(self._done) < self.total
            if (self._done and partial and cached_lang and self.requested_language
                    and cached_lang != self.requested_language):
                # 只做了一部分，而且是按另一种语言识别的：接着做会两种语言混在一起，从头来
                log.info("已有字幕是按 %s 识别的，现在指定 %s，重新生成", cached_lang, self.requested_language)
                self._discard_cache()
                self.store.apply(lambda _cues: [])
                self._done = set()
                self._written_path = None
                self.source, self.cache_model, self.legacy_cache = "generated", None, False
            elif cached_lang and (self.requested_language is None or not partial):
                self.language = cached_lang   # 完整的缓存：实际是什么语言就报什么语言
            return

        # 没有进度文件：看看有没有用户自备的字幕，有就当作完整字幕，不转写
        if not self.use_sidecar:
            return
        found = find_sidecar(self.video, self.track, self.requested_language, self.target_lang,
                             self.ignored_sidecars)
        if found is None:
            return
        path, lang = found
        try:
            text = path.read_text(encoding="utf-8-sig", errors="replace")
        except OSError as exc:
            log.warning("读不了用户字幕 %s：%s", path, exc)
            return
        cues = srt.parse_srt(text)
        for c in cues:
            c.text = srt.strip_markup(c.text)
        cues = [c for c in cues if c.text]
        if not cues:
            return
        self.store.add(cues)
        self._done = set(range(self.total))
        self.source = "sidecar"
        self.sidecar_path = path
        if lang is None:
            lang = guess_language(c.text for c in cues)   # <名字>.srt 没有语言后缀：看文字猜
        if self.language is None:
            self.language = lang
        log.info("使用用户字幕 %s（%d 条），不重新转写", path, len(cues))

    def _write_progress(self, done: list[int], srt_name: Optional[str] = None) -> None:
        srt.save_progress(self.progress_path, {
            "version": 2,
            "video": self.video.name,   # 这套缓存属于哪个文件（同名不同扩展名的视频靠它区分）
            "model": self.model,
            "language": self.language,
            "srt": srt_name,
            "duration": self.duration,
            "total": self.total,
            "done": done,
            "complete": bool(done) and len(done) >= self.total,
            **({"ignore_sidecars": sorted(self.ignored_sidecars)} if self.ignored_sidecars else {}),
        })

    def _persist(self) -> None:
        with self._persist_lock:
            if self._stop_event.is_set():
                return
            with self._lock:
                done = sorted(self._done)
            path = self.srt_path
            srt.atomic_write(path, srt.render_srt(self.store.snapshot()))
            old = self._written_path
            if old is not None and old != path and ".vidac." in old.name:
                old.unlink(missing_ok=True)  # 语言锁定后删除旧的 und 文件；0.5 的旧文件可能是用户的，留着
            self._written_path = path
            self._write_progress(done, path.name)

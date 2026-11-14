"""播放器：启动 mpv 程序负责播放和窗口（通过 JSON IPC 控制，见 mpvipc.py），
字幕、状态和设置菜单用 osd-overlay 画在视频上。

为什么不用 mpv 原生字幕轨：原生字幕要重新加载整个 .srt 才能刷新，边转写边更新很别扭。
设置菜单也做成叠加层而不是独立窗口：内嵌 mpv 到 Qt/Tk 在 macOS 上不稳，叠加层纯键盘即可。
"""

from __future__ import annotations

import json
import logging
import math
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional

from . import ipc, media, mpvipc, srt
from .asr import MODEL_PRESETS, ModelProgress, make_backend
from .overlay import W, H, Line, cue_layout, cue_lines, overlay_width, status_ass, subtitle_ass  # noqa: F401
from .positions import DelayStore, PositionStore
from .settings import (SUBTITLE_LOCATIONS, TARGET_LANGUAGES, WHISPER_LANGUAGES, Settings, app_dir)
from .state import build_state
from .translate import Glossary, Translator, clear_translations, lang_name_en, make_client
from .transcriber import Transcriber

log = logging.getLogger("vidac.player")

SUB_ID, STATUS_ID, MENU_ID = 1, 2, 3
YELLOW = "00FFFF"  # ASS 颜色是 BGR，所以 00FFFF 是黄色
HINT_SECONDS = 10.0   # 提示类状态行显示这么久后自动隐藏
STATE_INTERVAL = 0.5  # vidac-state 最多这么久发布一次
HELP_TEXT = ("Tab menu · v subtitle mode · +/- size · z/x delay · t audio track · "
             "o open · Space play/pause")

DISPLAY_MODES = ("off", "orig", "trans", "bilingual")
DISPLAY_NAMES = {"off": "Off", "orig": "Original", "trans": "Translation", "bilingual": "Bilingual"}
TARGET_CHOICES = list(TARGET_LANGUAGES)
LANGUAGE_CHOICES = ["auto"] + [c for c in TARGET_LANGUAGES if c in WHISPER_LANGUAGES]
SPEED_CHOICES = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
MENU_ROWS = ["display", "translate", "target", "language", "model", "auto", "delay", "track",
             "engine", "translate_model", "scale", "window", "speed"]
ENGINE_NAMES = {"apple": "Apple Intelligence", "openai": "Ollama / LM Studio"}
MENU_LABELS = {
    "display": "Subtitles", "translate": "Translate", "target": "Translate to",
    "language": "Spoken language", "model": "Speech model", "auto": "Automatic subtitles",
    "delay": "Subtitle delay", "track": "Audio track", "engine": "Translation engine",
    "translate_model": "Translation model", "scale": "Subtitle size",
    "window": "Window size", "speed": "Speed",
}
WINDOW_SCALES = [0.5, 1.0, 1.5, 2.0]  # 菜单里“窗口大小”循环的取值
SWIPE_SECONDS = 5.0    # 触控板两指左右滑，每次快进或快退的秒数（trackpad 设置开着时）
VOLUME_STEP = 2        # 两指上下滑，每次音量增减，和 mpv 默认的 WHEEL_UP/DOWN 一样
RESUME_TAIL = 15.0  # 距结尾这么近不恢复位置
GUARD_MOVED = 3.0   # 播放位置离刚打开时这么远，就算“动起来了”
RESUME_NEAR = 2.0   # 已经在离记录位置这么近的地方（宿主已经恢复过），不再跳
SAVE_INTERVAL = 5.0
DELAY_STEP = 0.1
MAX_DELAY = 60.0
MIN_SCALE, MAX_SCALE = 0.5, 3.0


def _same_file(a, b) -> bool:
    try:
        return Path(a).expanduser().resolve() == Path(b).resolve()
    except (OSError, ValueError):
        return False


def _fmt_bytes(n: float) -> str:
    return f"{n / 1e9:.1f} GB" if n >= 1e9 else f"{n / 1e6:.0f} MB"


def menu_ass(rows: list[tuple[str, str]], selected: int, footer: list[str]) -> str:
    """设置菜单：左侧半透明深色底板，逐行文字；当前行黄色并带 ◀ ▶。每个事件一行。"""
    esc = lambda s: " ".join(s.splitlines()).replace("{", "｛").replace("}", "｝")  # noqa: E731
    x, y0, line_h = 24, 150, 34
    height = 24 + line_h * len(rows) + 30 * len(footer) + 16
    events = [f"{{\\an7\\pos(0,0)\\p1\\1c&H1A1A1A&\\1a&H40&\\bord0\\shad0}}"
              f"m 0 0 l 700 0 700 {height} 0 {height}{{\\p0}}"]
    for i, (label, value) in enumerate(rows):
        y = y0 + i * line_h
        if i == selected:
            events.append(f"{{\\an7\\pos({x + 12},{y})\\fs24\\bord1\\shad0\\1c&H{YELLOW}&}}"
                          f"{esc(label)}: ◀ {esc(value)} ▶")
        else:
            events.append(f"{{\\an7\\pos({x + 12},{y})\\fs24\\bord1\\shad0\\1c&HFFFFFF&}}"
                          f"{esc(label)}: {esc(value)}")
    y = y0 + line_h * len(rows) + 8
    for text in footer:
        events.append(f"{{\\an7\\pos({x + 12},{y})\\fs20\\bord1\\shad0\\1c&HCCCCCC&}}{esc(text)}")
        y += 30
    return "\n".join(events)


def _player_options(args) -> dict:
    opts = {
        "input_default_bindings": True,
        "input_vo_keyboard": True,
        "osc": True,
        "idle": "yes",   # 不用 once：拖进打不开的文件时 mpv 不会跟着退出
        "force_window": "yes",
        "keep_open": "yes",
        "ytdl": "no",
        "title": "vidac",
        "aid": str(args.audio_track),
        "log_file": str(app_dir() / "mpv.log"),  # mpv 自己不往终端输出，出问题看这个文件
    }
    for kv in args.mpv_opt:
        key, _, value = kv.partition("=")
        opts[key.replace("-", "_")] = value
    return opts


MENU_KEYS = {"UP": "up", "DOWN": "down", "LEFT": "left", "RIGHT": "right",
             "ENTER": "right", "ESC": "close"}  # TAB 由 toggle 处理（菜单开着时等于关闭）


def _parse_bool(raw) -> bool:
    if isinstance(raw, bool):
        return raw
    if str(raw).lower() in ("true", "false"):
        return str(raw).lower() == "true"
    raise ValueError(f"not a boolean: {raw!r}")


def _parse_number(raw) -> float:
    value = float(raw)
    if not math.isfinite(value):
        raise ValueError(f"not a finite number: {raw!r}")
    return value


def parse_setting(key: str, raw):
    """协议里的设置值转成内部值。不合法抛 ValueError。"""
    raw = raw.strip() if isinstance(raw, str) else raw
    if key == "display_mode":
        if raw in DISPLAY_MODES:
            return raw
    elif key in ("translate", "enabled"):
        return _parse_bool(raw)
    elif key == "target_lang":
        if raw in TARGET_LANGUAGES:
            return raw
    elif key == "language":
        low = str(raw).lower()
        if low == "auto" or low in WHISPER_LANGUAGES:
            return low
    elif key == "model":
        if raw in MODEL_PRESETS:
            return raw
    elif key == "font_scale":
        return min(MAX_SCALE, max(MIN_SCALE, round(_parse_number(raw), 2)))
    elif key == "delay":
        return round(min(MAX_DELAY, max(-MAX_DELAY, _parse_number(raw))), 3)
    elif key == "subtitle_location":
        if raw in SUBTITLE_LOCATIONS:
            return raw
    else:
        raise ValueError(f"unknown setting: {key}")
    raise ValueError(f"invalid value for {key}: {raw!r}")


class App:
    def __init__(self, args) -> None:
        self.args = args
        self.native_ui = os.environ.get("VIDAC_NATIVE_UI") == "1"
        self.subtitle_bottom_margin = 230.0 if self.native_ui else 110.0
        # 宿主重启字幕控制器时用 VIDAC_KEEP_CURRENT_POSITION 保住正在播放的位置：值是正在播放的文件路径时，
        # 只对那个文件生效；旧宿主给的 "1" 不知道是哪个文件，只在播放已经走到了片头之外时才生效
        keep = os.environ.get("VIDAC_KEEP_CURRENT_POSITION", "")
        self._skip_initial_resume = keep == "1"
        self._keep_position_for: Optional[str] = keep if keep and keep != "1" else None
        self._resume_guard: Optional[float] = None     # 这个视频记录的位置；播放真正动起来之前不被更靠前的位置覆盖
        self._guard_first: Optional[float] = None
        self.settings = Settings.from_args(args)
        self.events: queue.Queue = queue.Queue()
        self.positions = PositionStore(app_dir() / "positions.json")
        self.delays = DelayStore(app_dir() / "delays.json")
        self.video: Optional[Path] = None
        self.tracks: list[media.AudioTrack] = []
        self.track = 0
        self.transcriber: Optional[Transcriber] = None
        self.translator: Optional[Translator] = None
        self.error_msg: Optional[str] = None   # 终端模式下的临时提示，例如“只有一条音轨”
        self.open_error: Optional[tuple[str, str]] = None   # (错误码, 英文句子)：文件打不开或没有音轨
        self.rebuild = args.rebuild
        self.retranslate = bool(args.retranslate or args.rebuild)
        # 这个视频的临时状态，换视频时全部重置
        self.stopped = False        # 用户点了“停止”
        self.forced = False         # 自动字幕关着，但用户明确要求为这个视频生成
        self.skip_sidecar = False   # 用户要求重新生成：不再读自备的字幕文件
        self.resumed_from: Optional[float] = None
        self.delay = float(self.settings.get("delay"))
        self.paused = False
        self._hints: dict[str, tuple[str, float]] = {}   # 提示类状态行：键 -> (文字, 首次出现时间)
        self._hints_lock = threading.Lock()
        self.help_until = 0.0 if self.native_ui else time.monotonic() + 8
        self.last_sub_key: Optional[tuple] = None
        self.aspect = W / H
        self.last_status: Optional[list[str]] = None
        self.last_state_json: Optional[str] = None
        self.last_state_at = 0.0
        self.last_aux_poll = 0.0
        self.last_menu: Optional[str] = None
        self.menu_open = False
        self.menu_sel = 0
        self.file_ready = False           # 收到 file-loaded 之后才读取播放位置
        self.last_pos: Optional[float] = None
        self.last_duration: Optional[float] = None
        self.last_saved_pos: Optional[float] = None
        self.last_save_at = 0.0
        self._ignore_aid_until = 0.0
        self._last_err: Optional[str] = None

        self.player = mpvipc.MPV(ipc.socket_path(), **_player_options(args))
        self._bind_keys()

    # ---- 按键、属性和文件事件（回调在 mpv 线程，只往队列里放） ----
    def _bind_keys(self) -> None:
        p = self.player
        put = self.events.put
        keys = {"t": lambda: put(("cycle_audio",))}
        if not self.native_ui:
            # 原生界面自己处理字幕模式、字号、延迟和打开文件，通过设置协议告诉这里；
            # 这些键在那里不绑定，免得悄悄改了字号却没有任何提示
            keys.update({
                "v": lambda: put(("subs",)),
                "+": lambda: put(("scale", 0.1)),
                "=": lambda: put(("scale", 0.1)),
                "-": lambda: put(("scale", -0.1)),
                "z": lambda: put(("delay", -DELAY_STEP)),
                "x": lambda: put(("delay", DELAY_STEP)),
                "o": lambda: put(("dialog",)),
                "TAB": lambda: put(("menu_toggle",)),
            })
        if self.settings.get("trackpad"):
            # 覆盖 mpv 默认的滚轮绑定（默认左右各 10 秒）。触控板两指滑动会发出这些键
            keys["WHEEL_LEFT"] = lambda: put(("swipe", -SWIPE_SECONDS))
            keys["WHEEL_RIGHT"] = lambda: put(("swipe", SWIPE_SECONDS))
            keys["WHEEL_UP"] = lambda: put(("vol", VOLUME_STEP))
            keys["WHEEL_DOWN"] = lambda: put(("vol", -VOLUME_STEP))
        p.set_keys("vidac", keys)

        @p.property_observer("path")
        def _on_path(_name, value):
            # 拖拽文件进窗口、loadfile、或另一个实例交过来，都会改变 path；
            # 变成空（关闭视频，mpv stop）就是没有文件了
            if value:
                self.events.put(("open", value))
            else:
                self.events.put(("close",))

        @p.property_observer("aid")
        def _on_aid(_name, value):
            self.events.put(("aid", value))

        @p.property_observer("pause")
        def _on_pause(_name, value):
            self.events.put(("pause", bool(value)))

        if self.native_ui:
            @p.property_observer("user-data/vidac-subtitle-bottom")
            def _on_subtitle_bottom(_name, value):
                self.events.put(("native_subtitle_bottom", value))

        p.event_callback("file-loaded")(lambda _ev: self.events.put(("loaded",)))
        p.event_callback("client-message")(self._on_native_message)

    def _on_native_message(self, event: dict) -> None:
        args = event.get("args") or []
        if len(args) == 4 and args[:2] == ["vidac-ui", "setting"]:
            self.events.put(("native_setting", args[2], args[3]))
        elif len(args) == 3 and args[:2] == ["vidac-ui", "action"]:
            self.events.put(("action", args[2]))

    # ---- 主循环 ----
    def run(self) -> None:
        if self.args.video:
            self.player.loadfile(str(Path(self.args.video).expanduser().resolve()))
        try:
            while not self._core_down():
                self._safe(self._drain_events)
                self._safe(self._tick)
                time.sleep(0.1)
        except KeyboardInterrupt:
            pass
        finally:
            self._safe(self._save_position, True)
            self._stop_workers()
            self.player.terminate()

    def _core_down(self) -> bool:
        try:
            return bool(self.player.core_shutdown)
        except Exception:
            return True

    def _safe(self, fn, *args) -> None:
        """主循环里的每一步都包起来。同样的错误只记一次，避免刷屏。"""
        try:
            fn(*args)
        except Exception as exc:
            if self._core_down():
                return  # 正在退出，mpv 已经关闭，这里的错误没有意义
            msg = f"{type(exc).__name__}: {exc}"
            if msg != self._last_err:
                self._last_err = msg
                log.exception("主循环出错（播放继续）")

    def _drain_events(self) -> None:
        while True:
            try:
                ev = self.events.get_nowait()
            except queue.Empty:
                return
            self._safe(self._handle_event, ev)

    def _handle_event(self, ev: tuple) -> None:
        kind = ev[0]
        if kind == "open":
            self._open(ev[1])
            self._sync_attached_file_loaded(ev[1])
        elif kind == "close":
            self._on_close()
        elif kind == "loaded":
            self._on_file_loaded()
        elif kind == "aid":
            self._on_aid(ev[1])
        elif kind == "pause":
            self.paused = ev[1]
            if self.transcriber is not None:
                self.transcriber.set_paused(self.paused)
        elif kind == "subs":
            cur = self.settings.get("display_mode")
            nxt = DISPLAY_MODES[(DISPLAY_MODES.index(cur) + 1) % len(DISPLAY_MODES)] \
                if cur in DISPLAY_MODES else DISPLAY_MODES[0]
            self.apply_setting("display_mode", nxt)
        elif kind == "scale":
            self._set_scale(self.settings.get("font_scale") + ev[1])
        elif kind == "delay":
            self._set_delay(self.delay + ev[1])
        elif kind == "swipe":
            # 菜单打开时滚轮不动视频，免得一边调菜单一边跳进度
            if not self.menu_open and self.video is not None and self.file_ready:
                self.player.seek(ev[1], reference="relative", precision="exact")
        elif kind == "vol":
            if not self.menu_open:
                self.player.command("add", "volume", ev[1])
        elif kind == "dialog":
            path = self._choose_file()
            if path:
                self.player.loadfile(path)
        elif kind == "menu_toggle":
            if self.menu_open:
                self._close_menu()
            else:
                self._open_menu()
        elif kind == "menu":
            self._menu_action(ev[1])
        elif kind == "native_setting":
            self._native_setting(ev[1], ev[2])
        elif kind == "action":
            self.do_action(ev[1])
        elif kind == "native_subtitle_bottom":
            try:
                margin = float(ev[1])
            except (TypeError, ValueError):
                return
            if math.isfinite(margin):
                margin = min(420.0, max(20.0, margin))
                if margin != self.subtitle_bottom_margin:
                    self.subtitle_bottom_margin = margin
        elif kind == "cycle_audio":
            # 不用 mpv 的 cycle audio：它会先切到“无音轨”（aid=no），这里直接轮换到下一条
            if self.video is not None and len(self.tracks) > 1:
                idx = (self.track + 1) % len(self.tracks)
                self.player.aid = idx + 1
                self._set_track(idx)

    # ---- 打开文件、音轨、播放位置 ----
    def _open(self, path: str) -> None:
        self._save_position(force=True)     # 先保存旧视频的位置
        self._stop_workers()
        self.error_msg = None
        self.open_error = None
        with self._hints_lock:
            self._hints.clear()             # 换视频，提示重新计时
        self.file_ready = False
        self.last_pos = None
        self.last_saved_pos = None
        self.resumed_from = None
        self._resume_guard = self._guard_first = None
        self.stopped = self.forced = self.skip_sidecar = False
        p = Path(path)
        if not p.is_file():
            self.video = None
            self.tracks = []
            self.delay = float(self.settings.get("delay"))
            self.open_error = ("internal", "Vidac can only make subtitles for video files stored on "
                               "this Mac, not for web links or network streams. Playback is not affected.")
            return
        self.video = p.resolve()
        self._resume_guard = self.positions.get(self.video)
        stored = self.delays.get(self.video)
        self.delay = stored if stored is not None else float(self.settings.get("delay"))
        self._probe_and_start()

    def _on_close(self) -> None:
        """视频关了（回到欢迎页）：存位置，停掉转写和翻译，状态回到 idle，丢掉旧文件的一切。"""
        try:
            current = self.player.path
        except Exception:
            current = None
        if isinstance(current, str) and current:
            return   # 已经有新文件了（它的 open 事件随后就到），不是真的关闭
        self._save_position(force=True)
        self._stop_workers()
        self.video = None
        self.tracks = []
        self.open_error = None
        self.error_msg = None
        with self._hints_lock:
            self._hints.clear()
        self.file_ready = False
        self.last_pos = self.last_duration = self.last_saved_pos = None
        self.resumed_from = None
        self._resume_guard = self._guard_first = None
        self.stopped = self.forced = self.skip_sidecar = False
        self.delay = float(self.settings.get("delay"))
        self.last_sub_key = None   # 字幕叠加层下一次刷新时清掉

    def _probe_and_start(self) -> None:
        """读音轨并启动字幕线程。打开文件和“重试”都走这里。"""
        self.open_error = None
        try:
            self.tracks = media.probe_audio_tracks(self.video)
        except media.MediaError as exc:
            self.tracks = []
            self.open_error = ("audio", str(exc))
            return
        if not self.tracks:
            self.open_error = ("audio", "This video has no audio track, so there is nothing to "
                               "make subtitles from. Playback is not affected.")
            return
        want = self.args.audio_track - 1
        self.track = want if 0 <= want < len(self.tracks) else 0
        self._ignore_aid_until = time.monotonic() + 1.5
        try:
            self.player.aid = self.track + 1
        except Exception:
            pass
        self._start_workers()

    def _sync_attached_file_loaded(self, path: str) -> None:
        """附着可能晚于 file-loaded；用已就绪的当前文件补回该事件。"""
        if not getattr(self.player, "_attached", False) or self.video is None:
            return
        if self.player.path != path:
            return
        if self.player.idle_active is False and self.player.time_pos is not None:
            self._on_file_loaded()

    def _on_file_loaded(self) -> None:
        if self.file_ready:
            return
        self.file_ready = True
        keep_for, self._keep_position_for = getattr(self, "_keep_position_for", None), None
        skip, self._skip_initial_resume = getattr(self, "_skip_initial_resume", False), False
        if self.video is None:
            return
        if keep_for is not None and _same_file(keep_for, self.video):
            return  # 原生宿主恢复字幕控制器时保留当前正在播放的位置。
        if skip:
            # 旧宿主只说“保留当前位置”，没说是哪个文件。播放已经走到片头之外，说明这是它一直在放的文件，
            # 不去动；刚刚才打开的新视频停在片头，照常恢复（否则它的记录会被从头播放覆盖掉）
            try:
                playing = float(self.player.time_pos)
            except (TypeError, ValueError):
                playing = None
            if playing is not None and playing >= RESUME_NEAR:
                return
        pos = self.positions.get(self.video)
        if pos is None:
            return
        try:
            dur = self.player.duration
        except Exception:
            dur = None
        if dur and dur - pos < RESUME_TAIL:
            self.positions.clear(self.video)
            return
        try:
            now = float(self.player.time_pos)
        except (TypeError, ValueError):
            now = None
        if now is not None and abs(now - pos) < RESUME_NEAR:
            return  # 宿主已经从记录的位置开始播放，不需要再跳
        self.player.seek(pos, reference="absolute")
        self.resumed_from = round(pos, 1)
        self.last_pos = pos   # 马上退出时保存的也是恢复后的位置，而不是 0
        log.info("恢复到上次位置 %.1f 秒", pos)

    def _on_aid(self, value) -> None:
        if time.monotonic() < self._ignore_aid_until:
            return  # 刚打开文件时 mpv 自己的默认音轨，忽略
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            return
        idx = value - 1
        if self.video is None or idx >= len(self.tracks) or idx == self.track:
            return
        self._set_track(idx)

    def _set_track(self, idx: int) -> None:
        self.track = idx
        self.error_msg = None
        self._restart_workers()

    def _save_position(self, force: bool = False) -> None:
        if self.video is None or self.last_pos is None or not self.file_ready:
            return
        guard = getattr(self, "_resume_guard", None)
        if guard is not None:
            # 记录的位置在片头之后：播放真正动起来（走了、拖了）之前，不拿更靠前的位置去覆盖它
            first = getattr(self, "_guard_first", None)
            if first is None:
                first = self._guard_first = self.last_pos
            if self.last_pos >= guard - RESUME_NEAR or abs(self.last_pos - first) >= GUARD_MOVED:
                self._resume_guard = None
            else:
                return
        now = time.monotonic()
        if not force:
            if now - self.last_save_at < SAVE_INTERVAL:
                return
            if self.last_saved_pos is not None and abs(self.last_pos - self.last_saved_pos) <= 2:
                return
        self.last_save_at = now
        self.last_saved_pos = self.last_pos
        self.positions.save(self.video, self.last_pos, self.last_duration)

    # ---- 后台线程 ----
    def _generating(self) -> bool:
        """这个视频现在允许生成新字幕吗：没点过“停止”，并且自动字幕开着或用户明确要求了。"""
        return not self.stopped and (bool(self.settings.get("enabled")) or self.forced)

    def _stop_workers(self) -> None:
        """只置位停止标志，不等待线程结束。"""
        for w in (self.transcriber, self.translator):
            if w is not None:
                w.stop()
        self.transcriber = None
        self.translator = None

    def _restart_workers(self) -> None:
        self._start_workers()

    def _start_workers(self) -> None:
        self._stop_workers()
        if self.video is None or not self.tracks:
            return
        self._start_transcriber()
        self._start_translator()

    def _cache_dir(self) -> Optional[Path]:
        if self.settings.get("subtitle_location") == "library":
            return app_dir() / "subtitles"
        return None

    def _start_transcriber(self) -> None:
        s = self.settings
        backend, model = self.args.backend, s.get("model")
        progress = ModelProgress()
        self.transcriber = Transcriber(
            self.video,
            self.track,
            lambda: make_backend(backend, model, progress),
            model=model,
            language=s.get_language(),
            vad=self.args.vad or self.native_ui,   # 原生 app 没有 --vad 开关：默认跳过没有人声的段
            rebuild=self.rebuild,
            cache_dir=self._cache_dir(),
            transcribe=self._generating(),
            use_sidecar=not self.skip_sidecar,
            target_lang=s.get("target_lang"),
            model_progress=progress,
        )
        self.rebuild = False  # --rebuild 只对启动时的第一条音轨生效
        self.transcriber.set_paused(self.paused)
        self.transcriber.set_position(self.last_pos or 0.0)
        self.transcriber.start()
        log.info("转写线程启动：音轨 %d", self.track + 1)

    def _glossary_paths(self) -> list[Path]:
        paths = [app_dir() / "glossary.txt"]
        if self.video is not None:
            paths.append(self.video.parent / f"{self.video.stem}.glossary.txt")
        if self.args.glossary:
            paths.append(Path(self.args.glossary).expanduser())
        return paths

    def _start_translator(self) -> None:
        if self.transcriber is None:
            return
        s = self.settings
        tr = self.transcriber
        target = s.get("target_lang")
        client = make_client(s.get("translate_engine"), s.get("translate_url"), s.get("translate_model"))
        self.translator = Translator(
            tr.store,
            tr,
            client,
            target,
            Glossary.load(self._glossary_paths()),
            srt.translation_srt_path(tr.folder, tr.base, target),
            enabled=bool(s.get("translate")),
            retranslate=self.retranslate,
            legacy_path=srt.legacy_translation_srt_path(tr.folder, tr.base, target),
            wip_path=srt.wip_translation_srt_path(tr.folder, tr.base, target),
            load_only=not self._generating(),
        )
        self.retranslate = False
        self.translator.start()

    def _restart_translator(self, clear: bool = False) -> None:
        """clear 为真（换了目标语言）时，字幕表里旧语言的译文先清掉，再由新的翻译线程读新语言的缓存。"""
        if self.translator is not None:
            self.translator.stop()   # 先停：它已经在飞的一批结果在字幕表锁里被拦下，不会写进来
            self.translator = None
        if clear and self.transcriber is not None:
            clear_translations(self.transcriber.store)
        self._start_translator()

    def _choose_file(self) -> Optional[str]:
        if sys.platform != "darwin":
            log.warning("o 键只在 macOS 上用系统文件选择框，其他系统请用命令行参数")
            return None
        script = 'POSIX path of (choose file with prompt "Choose a video")'
        proc = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        return proc.stdout.strip() or None

    # ---- 设置与动作（原生界面和终端菜单共用） ----
    def _native_setting(self, key: str, value: str) -> None:
        self.apply_setting(key, value)

    def apply_setting(self, key: str, raw) -> bool:
        """校验并应用一项设置。不认识或值不合法时只记日志，设置保持原样（下一次 vidac-state 里仍是旧值）。"""
        try:
            value = parse_setting(key, raw)
        except ValueError as exc:
            log.warning("忽略设置 %s：%s", key, exc)
            return False
        if key == "font_scale":
            self._set_scale(value)
            return True
        if key == "delay":
            self._set_delay(value)
            return True
        s = self.settings
        if s.get(key) == value:
            return True
        s.set(key, value)
        if key == "translate":
            if self.translator is not None:
                self.translator.enabled = value
        elif key == "target_lang":
            if self.transcriber is not None:
                self._restart_translator(clear=True)
        elif key in ("language", "model"):
            self._on_transcription_changed()
        elif key == "enabled":
            # 用户明确改了开关：之前“只为这个视频生成”和“停止”的例外都作废。
            # 否则打开自动字幕之后仍然是 disabled，用户找不到办法继续
            self.forced = self.stopped = False
            if self.video is not None and self.tracks:
                self._restart_workers()
        elif key == "subtitle_location":
            self._on_location_changed()
        return True

    def _on_transcription_changed(self) -> None:
        """换了识别模型或转写语言：改设置就是要求照新设置重做，旧的字幕和译文丢掉。"""
        if self.video is None or not self.tracks:
            return
        ts = self.transcriber
        if ts is None or ts.source != "sidecar":   # 用户自备的字幕不是识别出来的，没什么可重做
            self.rebuild = self.retranslate = True
        self._restart_workers()

    def _on_location_changed(self) -> None:
        """字幕文件的保存位置变了：把 Vidac 自己的文件搬过去，之后在新位置继续。"""
        ts = self.transcriber
        if self.video is None or not self.tracks or ts is None:
            return
        old = (ts.folder, ts.base)
        self._stop_workers()
        srt.migrate_cache(old, srt.cache_layout(self.video, self.track, self._cache_dir()))
        self._start_workers()

    def do_action(self, name: str) -> None:
        """vidac-ui action <name>：regenerate / retry / stop。没有视频时什么也不做。"""
        if name not in ("regenerate", "retry", "stop"):
            log.warning("忽略未知动作：%s", name)
            return
        if self.video is None:
            return
        if name == "stop":
            self.stopped, self.forced = True, False
            if self.tracks:
                self._restart_workers()
            return
        self.stopped = False
        self.forced = not self.settings.get("enabled")   # 点了重试 / 重新生成就是要生成
        if name == "retry" and self.open_error is not None:
            self._probe_and_start()   # 文件读不了或没有音轨：重新探测一次
            return
        if not self.tracks:
            return
        if name == "regenerate":
            self.rebuild = self.retranslate = True
            self.skip_sidecar = True
        self._restart_workers()

    def _set_scale(self, value: float) -> None:
        self.settings.set("font_scale", min(MAX_SCALE, max(MIN_SCALE, round(value, 2))))

    def _set_delay(self, value: float) -> None:
        """有视频时只记在这个视频上（和默认值一样就不记）；没有视频时改默认值。"""
        value = round(min(MAX_DELAY, max(-MAX_DELAY, value)), 3)
        self.delay = value
        default = float(self.settings.get("delay"))
        if self.video is not None:
            self.delays.set(self.video, None if abs(value - default) < 1e-9 else value)
        else:
            self.settings.set("delay", value)

    def _speed(self) -> float:
        """mpv 当前倍速（用户用 [ ] 改过也对）；读不到按 1 倍。"""
        try:
            return float(self.player.speed or 1.0)
        except Exception:
            return 1.0

    def _window_scale(self) -> Optional[float]:
        """mpv 当前的窗口缩放倍数；读不到（窗口还没建好等）返回 None。"""
        try:
            value = self.player.current_window_scale
            return float(value) if value else None
        except Exception:
            return None

    # ---- 终端模式的设置菜单 ----
    def _open_menu(self) -> None:
        """菜单打开时才绑定方向键等，关闭时解绑，方向键恢复 mpv 默认（快进快退）。"""
        self.menu_open = True
        self.menu_sel = 0
        self.last_menu = None
        self.player.set_keys("vidac-menu", {
            keydef: (lambda a=action: self.events.put(("menu", a)))
            for keydef, action in MENU_KEYS.items()
        })

    def _close_menu(self) -> None:
        if self.menu_open:
            try:
                self.player.clear_keys("vidac-menu")
            except Exception:
                pass
        self.menu_open = False
        self.last_menu = None
        self._clear(MENU_ID)

    def _menu_action(self, action: str) -> None:
        if action == "close":
            self._close_menu()
        elif action == "up":
            self.menu_sel = (self.menu_sel - 1) % len(MENU_ROWS)
        elif action == "down":
            self.menu_sel = (self.menu_sel + 1) % len(MENU_ROWS)
        elif action == "left":
            self._menu_change(-1)
        elif action in ("right", "enter"):
            self._menu_change(1)

    def _cycle(self, key: str, choices: list, delta: int) -> None:
        cur = self.settings.get(key)
        i = choices.index(cur) if cur in choices else (0 if delta > 0 else -1)
        self.apply_setting(key, str(choices[(i + delta) % len(choices)]))

    def _menu_change(self, delta: int) -> None:
        s = self.settings
        key = MENU_ROWS[self.menu_sel]
        if key == "display":
            self._cycle("display_mode", list(DISPLAY_MODES), delta)
        elif key == "translate":
            self.apply_setting("translate", str(not bool(s.get("translate"))).lower())
        elif key == "target":
            self._cycle("target_lang", TARGET_CHOICES, delta)
        elif key == "language":
            self._cycle("language", LANGUAGE_CHOICES, delta)
        elif key == "model":
            self._cycle("model", list(MODEL_PRESETS), delta)
        elif key == "auto":
            self.apply_setting("enabled", str(not bool(s.get("enabled"))).lower())
        elif key == "delay":
            self._set_delay(self.delay + DELAY_STEP * delta)
        elif key == "track":
            if len(self.tracks) < 2:
                self._set_error("This file has only one audio track.")
                return
            idx = (self.track + delta) % len(self.tracks)
            self.player.aid = idx + 1
            self._set_track(idx)
        elif key == "engine":
            s.set("translate_engine", "openai" if s.get("translate_engine") == "apple" else "apple")
            if self.transcriber is not None:
                self._restart_translator()
        elif key == "translate_model":
            if s.get("translate_engine") == "apple":
                self._set_error("Apple Intelligence has a single built-in model; there is nothing to switch.")
                return
            models = self.translator.models if self.translator is not None else []
            if not models:
                self._set_error("The translation server is not connected, so the model cannot be changed.")
                return
            cur = s.get("translate_model")
            i = models.index(cur) if cur in models else -1
            new = models[(i + delta) % len(models)]
            s.set("translate_model", new)
            if self.translator is not None:
                self.translator.set_model(new)
        elif key == "scale":
            self._set_scale(s.get("font_scale") + 0.1 * delta)
        elif key == "window":
            self._menu_window(delta)
        elif key == "speed":
            cur = self._speed()
            i = min(range(len(SPEED_CHOICES)), key=lambda k: abs(SPEED_CHOICES[k] - cur))
            self.player.speed = SPEED_CHOICES[(i + delta) % len(SPEED_CHOICES)]

    def _menu_window(self, delta: int) -> None:
        cur = self._window_scale()
        if cur is None:
            self._set_error("Cannot read the window size, so it cannot be changed.")
            return
        i = min(range(len(WINDOW_SCALES)), key=lambda k: abs(WINDOW_SCALES[k] - cur))
        self.player.current_window_scale = WINDOW_SCALES[(i + delta) % len(WINDOW_SCALES)]

    def _menu_rows(self) -> list[tuple[str, str]]:
        s = self.settings
        target = s.get("target_lang")
        rows = []
        for key in MENU_ROWS:
            if key == "display":
                value = DISPLAY_NAMES.get(s.get("display_mode"), s.get("display_mode"))
            elif key == "translate":
                value = "On" if s.get("translate") else "Off"
            elif key == "target":
                value = f"{lang_name_en(target)} ({target})"
            elif key == "language":
                value = str(s.get("language"))
            elif key == "model":
                value = str(s.get("model"))
            elif key == "auto":
                value = "On" if s.get("enabled") else "Off"
            elif key == "delay":
                value = f"{self.delay:+.1f} s"
            elif key == "track":
                value = f"{self.track + 1} / {len(self.tracks)}" if self.tracks else "-"
            elif key == "engine":
                value = ENGINE_NAMES.get(s.get("translate_engine"), str(s.get("translate_engine")))
            elif key == "translate_model":
                value = ("Built in" if s.get("translate_engine") == "apple"
                         else str(s.get("translate_model")))
            elif key == "scale":
                value = f"{s.get('font_scale'):.1f}"
            elif key == "window":
                cur = self._window_scale()
                value = f"{round(cur * 100)}%" if cur else "-"
            else:
                value = f"{round(self._speed(), 2):g}x"
            rows.append((MENU_LABELS[key], value))
        return rows

    # ---- 状态 ----
    def _state(self) -> dict:
        ts = self.transcriber
        ahead = bool(ts is not None and self.video is not None and self.file_ready
                     and ts.working and not ts.covered(self.last_pos or 0.0))
        return build_state(
            video=self.video, open_error=self.open_error, ts=ts, translator=self.translator,
            settings=self.settings.effective(), delay=self.delay, resumed_from=self.resumed_from,
            generating=self._generating(), ahead=ahead)

    # ---- 每 100 ms 刷新一次 ----
    def _tick(self) -> None:
        if self.video is not None and self.file_ready:
            t = self.player.time_pos
            if t is not None:
                self.last_pos = float(t)
                self.last_duration = self.player.duration
        self._save_position()

        tr = self.transcriber
        pos = self.last_pos or 0.0
        if tr is not None:
            tr.set_position(pos)
        if self.translator is not None:
            self.translator.set_position(pos)

        now = time.monotonic()
        if now - self.last_aux_poll >= 0.5:
            self.last_aux_poll = now
            self._poll_window_shape()

        self._draw_subtitles(pos)

        if now - self.last_state_at >= STATE_INTERVAL:
            self._publish_state(now)

        if self.menu_open:
            rows = self._menu_rows()
            footer = [self._translation_line(self._state()) or "Translation: off",
                      "Up/Down select · Left/Right change · Tab or Esc close"]
            data = repr((rows, self.menu_sel, footer))
            if data != self.last_menu:
                self.last_menu = data
                self._overlay(MENU_ID, menu_ass(rows, self.menu_sel, footer))

    def _poll_window_shape(self) -> None:
        """窗口宽高比变了，字幕要按新的形状重排（竖屏、超宽视频里换行宽度不同）。"""
        try:
            w, h = float(self.player.get("osd-width") or 0), float(self.player.get("osd-height") or 0)
        except (TypeError, ValueError):
            return
        if w > 0 and h > 0 and abs(w / h - self.aspect) > 0.01:
            self.aspect = w / h

    def _draw_subtitles(self, pos: float) -> None:
        s = self.settings
        tr = self.transcriber
        lines: list[Line] = []
        if tr is not None and self.video is not None and self.file_ready:
            cues = tr.store.active(pos - self.delay)   # 延迟为正：字幕晚出现
            lines = cue_layout(cues, s.get("display_mode"), bool(s.get("translate")),
                               tr.language, s.get("target_lang"))
        key = (tuple((ln.text, ln.secondary, ln.lang) for ln in lines), s.get("font_scale"),
               self.subtitle_bottom_margin, round(self.aspect, 2))
        if key == self.last_sub_key:
            return
        self.last_sub_key = key
        if lines:
            self._overlay(SUB_ID, subtitle_ass(lines, s.get("font_scale"), self.subtitle_bottom_margin,
                                               self.aspect), overlay_width(self.aspect))
        else:
            self._clear(SUB_ID)

    def _publish_state(self, now: float) -> None:
        state = self._state()
        payload = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
        if payload != self.last_state_json:
            self.last_state_json = payload
            self.last_state_at = now
            self.player.set("user-data/vidac-state", payload)
        if self.native_ui:
            return  # 原生界面只读 vidac-state；画面上的状态行和旧的文字状态都不需要
        lines = self._status_lines(state)
        if lines != self.last_status:
            self.last_status = lines
            self.player.set("user-data/vidac-status", " · ".join(lines))
            if lines:
                self._overlay(STATUS_ID, status_ass(lines))
            else:
                self._clear(STATUS_ID)

    # ---- 终端模式的状态行（由 vidac-state 生成，英文） ----
    @staticmethod
    def _translation_line(state: dict) -> Optional[str]:
        t = state["translation"]
        name = lang_name_en(t["target"]) if t["target"] else "?"
        engine = ENGINE_NAMES.get(t["engine"], str(t["engine"]))
        if t["state"] == "working":
            return f"Translating to {name} · {engine} · {t['done']}/{t['total']}"
        if t["state"] == "ready":
            extra = f" · {t['reason']}" if t["reason"] else ""
            return f"Translation to {name} complete · {t['done']}/{t['total']}{extra}"
        if t["state"] in ("unavailable", "error") and t["reason"]:
            return f"Translation unavailable: {t['reason']}"
        if t["reason"]:
            return t["reason"]
        return None

    def _set_error(self, msg: str) -> None:
        self.error_msg = msg
        with self._hints_lock:
            self._hints.pop("error_msg", None)   # 同样的提示再次出现时重新计时

    def _hint(self, key: str, text: str, now: float, seen: set) -> bool:
        """提示类的行：第一次出现后显示 HINT_SECONDS 秒，之后返回 False。文字变了重新计时。"""
        with self._hints_lock:
            old = self._hints.get(key)
            if old is None or old[0] != text:
                old = self._hints[key] = (text, now)
            seen.add(key)
            return now - old[1] < HINT_SECONDS

    def _status_lines(self, state: Optional[dict] = None) -> list[str]:
        state = state if state is not None else self._state()
        now = time.monotonic()
        lines: list[str] = []
        seen: set[str] = set()
        err_shown = bool(self.error_msg) and self._hint("error_msg", self.error_msg, now, seen)
        if err_shown:
            lines.append(self.error_msg)
        phase, error = state["phase"], state["error"]
        if error:
            lines.append(f"Subtitles unavailable: {error['message']}")
        else:
            tr = self.transcriber
            head = (f"Subtitles {state['language'] or 'detecting language'} · {state['model']}"
                    f" · track {self.track + 1}")
            pct = f"{round(state['progress'] * 100)}%" if state["progress"] is not None else "…"
            if phase == "model-download":
                dl = state["download"] or {}
                got, total = dl.get("received", 0), dl.get("total")
                size = f"{_fmt_bytes(got)} of {_fmt_bytes(total)}" if total else _fmt_bytes(got)
                lines.append(f"Downloading the speech model (first run only) · {size}")
            elif phase == "model-load":
                lines.append("Loading the speech model, one moment")
            elif phase == "transcribing":
                lines.append(f"{head} · {pct}")
            elif phase == "ready":
                text = f"{head} · done"
                if self._hint("transcribe_done", text, now, seen):
                    lines.append(text)
            elif phase == "disabled":
                text = ("Automatic subtitles are off" if not self.settings.get("enabled")
                        else "Subtitle generation stopped")
                lines.append(f"{text} · {pct} done")
            if tr is not None and tr.warning and self._hint("transcribe_warning", tr.warning, now, seen):
                lines.append(tr.warning)
        line = self._translation_line(state)
        if line:
            if state["translation"]["state"] == "working":
                lines.append(line)
            elif self._hint("translate", line, now, seen):
                lines.append(line)
        if self.video is None and not err_shown and not error:
            lines.append("Drag a video into the window, or press o to open one")
        if now < self.help_until:
            lines.append(HELP_TEXT)
        with self._hints_lock:   # 不再出现的提示清掉，下次出现重新计时
            for k in [k for k in self._hints if k not in seen]:
                del self._hints[k]
        return lines

    def _overlay(self, oid: int, data: str, res_x: int = W) -> None:
        self.player.command("osd-overlay", oid, "ass-events", data, res_x, H)

    def _clear(self, oid: int) -> None:
        self.player.command("osd-overlay", oid, "none", "", W, H)

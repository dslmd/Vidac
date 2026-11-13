"""播放器：mpv（libmpv）负责播放和窗口，字幕、状态和设置菜单用 osd-overlay 画在视频上。

为什么不用 mpv 原生字幕轨：原生字幕要重新加载整个 .srt 才能刷新，边转写边更新很别扭。
设置菜单也做成叠加层而不是独立窗口：内嵌 mpv 到 Qt/Tk 在 macOS 上不稳，叠加层纯键盘即可。
"""

from __future__ import annotations

import logging
import queue
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

try:
    import mpv  # python-mpv，运行时需要 brew 装的 libmpv
except OSError as exc:  # 找不到 libmpv.dylib
    raise SystemExit(
        f"加载 libmpv 失败：{exc}\n"
        "请先 brew install mpv，并通过 run.sh 启动（它会设置 DYLD_FALLBACK_LIBRARY_PATH）。"
    )

from . import ipc, media
from .asr import MODEL_PRESETS, make_backend
from .filters import is_filler
from .positions import PositionStore
from .settings import Settings, app_dir
from .srt import Cue, translation_srt_path
from .translate import Glossary, Translator, lang_name_zh, make_client
from .transcriber import Transcriber

log = logging.getLogger("vidac.player")

W, H = 1280, 720          # 叠加层坐标系，mpv 会按视频实际尺寸缩放
SUB_ID, STATUS_ID, MENU_ID = 1, 2, 3
BASE_FONT = 40
WHITE, YELLOW = "FFFFFF", "00FFFF"  # ASS 颜色是 BGR，所以 00FFFF 是黄色
HELP_TEXT = "Tab 菜单 · v 字幕模式 · +/- 字号 · t 切换音轨 · o 打开 · 空格 播放/暂停"

DISPLAY_MODES = ("off", "orig", "trans", "bilingual")
DISPLAY_NAMES = {"off": "关闭", "orig": "原文", "trans": "译文", "bilingual": "双语"}
TARGET_CHOICES = ["zh", "zh-tw", "en", "ja", "ko"]
LANGUAGE_CHOICES = ["auto", "ja", "en", "zh", "ko"]
SPEED_CHOICES = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
MENU_ROWS = ["display", "translate", "target", "language", "model", "track",
             "engine", "translate_model", "scale", "window", "speed"]
ENGINE_NAMES = {"apple": "Apple Intelligence", "openai": "Ollama / LM Studio"}
MENU_LABELS = {
    "display": "字幕显示", "translate": "翻译", "target": "目标语言",
    "language": "转写语言", "model": "转写模型", "track": "音轨",
    "engine": "翻译引擎", "translate_model": "翻译模型", "scale": "字号",
    "window": "窗口大小", "speed": "倍速",
}
WINDOW_SCALES = [0.5, 1.0, 1.5, 2.0]  # 菜单里“窗口大小”循环的取值
SWIPE_SECONDS = 5.0    # 触控板两指左右滑，每次快进或快退的秒数（trackpad 设置开着时）
VOLUME_STEP = 2        # 两指上下滑，每次音量增减，和 mpv 默认的 WHEEL_UP/DOWN 一样
RESUME_TAIL = 15.0  # 距结尾这么近不恢复位置
SAVE_INTERVAL = 5.0


def _esc(s: str) -> str:
    # 全角花括号，免得字幕里的 { } 被当成 ASS 标签
    return s.replace("{", "｛").replace("}", "｝")


def subtitle_ass(lines: list[str], scale: float) -> str:
    fs = round(BASE_FONT * scale)
    parts = []
    for i, line in enumerate(lines):
        color = WHITE if i == 0 else YELLOW
        size = fs if i == 0 else round(fs * 0.8)
        parts.append(f"{{\\fs{size}\\c&H{color}&}}{_esc(line)}")
    # 底部居中，离底边 110px，给 mpv 自带的控制条留位置
    return f"{{\\an2\\pos({W // 2},{H - 110})\\fs{fs}\\bord2\\shad0\\3c&H000000&}}" + "\\N".join(parts)


def status_ass(lines: list[str]) -> str:
    body = "\\N".join(_esc(line) for line in lines)
    return "{\\an7\\pos(24,18)\\fs22\\bord1\\shad0\\1c&HCCCCCC&}" + body


def menu_ass(rows: list[tuple[str, str]], selected: int, footer: list[str]) -> str:
    """设置菜单：左侧半透明深色底板，逐行文字；当前行黄色并带 ◀ ▶。每个事件一行。"""
    x, y0, line_h = 24, 150, 34
    height = 24 + line_h * len(rows) + 30 * len(footer) + 16
    events = [f"{{\\an7\\pos(0,0)\\p1\\1c&H1A1A1A&\\1a&H40&\\bord0\\shad0}}"
              f"m 0 0 l 560 0 560 {height} 0 {height}{{\\p0}}"]
    for i, (label, value) in enumerate(rows):
        y = y0 + i * line_h
        if i == selected:
            events.append(f"{{\\an7\\pos({x + 12},{y})\\fs24\\bord1\\shad0\\1c&H{YELLOW}&}}"
                          f"{_esc(label)}：◀ {_esc(value)} ▶")
        else:
            events.append(f"{{\\an7\\pos({x + 12},{y})\\fs24\\bord1\\shad0\\1c&HFFFFFF&}}"
                          f"{_esc(label)}：{_esc(value)}")
    y = y0 + line_h * len(rows) + 8
    for text in footer:
        events.append(f"{{\\an7\\pos({x + 12},{y})\\fs20\\bord1\\shad0\\1c&HCCCCCC&}}{_esc(text)}")
        y += 30
    return "\n".join(events)


def _player_options(args) -> dict:
    opts = {
        "input_default_bindings": True,
        "input_vo_keyboard": True,
        "osc": True,
        "idle": "once",
        "force_window": "yes",
        "keep_open": "yes",
        "ytdl": "no",
        "title": "vidac",
        "aid": str(args.audio_track),
        "input_ipc_server": ipc.socket_path(),
    }
    for kv in args.mpv_opt:
        key, _, value = kv.partition("=")
        opts[key.replace("-", "_")] = value
    return opts


MENU_KEYS = {"UP": "up", "DOWN": "down", "LEFT": "left", "RIGHT": "right",
             "ENTER": "right", "ESC": "close"}  # TAB 由 toggle 处理（菜单开着时等于关闭）


def _menu_key_handler(events: queue.Queue, action: str):
    def handler(state="d-", *_):
        if state[:1] in ("d", "p"):
            events.put(("menu", action))
    return handler


def cue_lines(cues: list[Cue], mode: str) -> list[str]:
    """把正在显示的字幕转成要画的行。语气词只显示原文；没译好的只显示原文。"""
    if mode == "off":
        return []
    lines: list[str] = []
    for c in cues:
        filler = is_filler(c.text)
        if mode == "orig" or filler:
            lines.append(c.text)
        elif mode == "trans":
            lines.append(c.translation or c.text)
        elif mode == "bilingual":
            if c.translation:
                lines.extend([c.translation, c.text])  # 译文在上，原文在下
            else:
                lines.append(c.text)
    return lines


class App:
    def __init__(self, args) -> None:
        self.args = args
        self.settings = Settings.from_args(args)
        self.events: queue.Queue = queue.Queue()
        self.positions = PositionStore(app_dir() / "positions.json")
        self.video: Optional[Path] = None
        self.tracks: list[media.AudioTrack] = []
        self.track = 0
        self.transcriber: Optional[Transcriber] = None
        self.translator: Optional[Translator] = None
        self.speed = 1.0
        self.error_msg: Optional[str] = None   # 打开文件时的错误，例如不是本地文件
        self.sub_error: Optional[str] = None   # 字幕不可用的原因（视频照常播放）
        self.rebuild = args.rebuild
        self.retranslate = bool(args.retranslate or args.rebuild)
        self.complete_at: Optional[float] = None
        self.help_until = time.monotonic() + 8
        self.last_sub_text: Optional[str] = None
        self.last_status: Optional[list[str]] = None
        self.last_status_draw = 0.0
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

        self.player = mpv.MPV(**_player_options(args))
        self._bind_keys()

    # ---- 按键、属性和文件事件（回调在 mpv 线程，只往队列里放） ----
    def _bind_keys(self) -> None:
        p = self.player
        p.on_key_press("v")(lambda: self.events.put(("subs",)))
        p.on_key_press("+")(lambda: self.events.put(("scale", 0.1)))
        p.on_key_press("=")(lambda: self.events.put(("scale", 0.1)))
        p.on_key_press("-")(lambda: self.events.put(("scale", -0.1)))
        p.on_key_press("o")(lambda: self.events.put(("dialog",)))
        p.on_key_press("TAB")(lambda: self.events.put(("menu_toggle",)))
        p.on_key_press("t")(lambda: self.events.put(("cycle_audio",)))
        if self.settings.get("trackpad"):
            # 覆盖 mpv 默认的滚轮绑定（默认左右各 10 秒）。触控板两指滑动会发出这些键
            p.on_key_press("WHEEL_LEFT")(lambda: self.events.put(("swipe", -SWIPE_SECONDS)))
            p.on_key_press("WHEEL_RIGHT")(lambda: self.events.put(("swipe", SWIPE_SECONDS)))
            p.on_key_press("WHEEL_UP")(lambda: self.events.put(("vol", VOLUME_STEP)))
            p.on_key_press("WHEEL_DOWN")(lambda: self.events.put(("vol", -VOLUME_STEP)))

        @p.property_observer("path")
        def _on_path(_name, value):
            # 拖拽文件进窗口、loadfile、或另一个实例交过来，都会改变 path
            if value:
                self.events.put(("open", value))

        @p.property_observer("aid")
        def _on_aid(_name, value):
            self.events.put(("aid", value))

        p.event_callback("file-loaded")(lambda _ev: self.events.put(("loaded",)))

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
        elif kind == "loaded":
            self._on_file_loaded()
        elif kind == "aid":
            self._on_aid(ev[1])
        elif kind == "subs":
            order = DISPLAY_MODES
            cur = self.settings.get("display_mode")
            nxt = order[(order.index(cur) + 1) % len(order)] if cur in order else order[0]
            self.settings.set("display_mode", nxt)
            self.last_sub_text = None
        elif kind == "scale":
            self._set_scale(self.settings.get("font_scale") + ev[1])
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
        self.sub_error = None
        self.complete_at = None
        self.file_ready = False
        self.last_pos = None
        self.last_saved_pos = None
        p = Path(path)
        if not p.is_file():
            self.video = None
            self.tracks = []
            self.error_msg = f"不是本地文件：{path}"
            return
        self.video = p.resolve()
        try:
            self.tracks = media.probe_audio_tracks(self.video)
        except media.MediaError as exc:
            self.tracks = []
            self.sub_error = str(exc)
            return
        if not self.tracks:
            self.sub_error = "这个文件没有音轨"
            return
        want = self.args.audio_track - 1
        self.track = want if 0 <= want < len(self.tracks) else 0
        self._ignore_aid_until = time.monotonic() + 1.5
        try:
            self.player.aid = self.track + 1
        except Exception:
            pass
        self._start_workers()

    def _on_file_loaded(self) -> None:
        self.file_ready = True
        if self.video is None:
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
        self.player.seek(pos, reference="absolute")
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

    def _start_transcriber(self) -> None:
        s = self.settings
        backend, model = self.args.backend, s.get("model")
        self.transcriber = Transcriber(
            self.video,
            self.track,
            lambda: make_backend(backend, model),
            model=model,
            language=s.get_language(),
            vad=self.args.vad,
            rebuild=self.rebuild,
        )
        self.rebuild = False  # --rebuild 只对启动时的第一条音轨生效
        self.complete_at = None
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
            translation_srt_path(tr.folder, tr.base, target),
            enabled=bool(s.get("translate")),
            retranslate=self.retranslate,
        )
        self.retranslate = False
        self.translator.start()

    def _restart_translator(self) -> None:
        if self.translator is not None:
            self.translator.stop()
            self.translator = None
        self._start_translator()

    def _choose_file(self) -> Optional[str]:
        if sys.platform != "darwin":
            log.warning("o 键只在 macOS 上用系统文件选择框，其他系统请用命令行参数")
            return None
        script = 'POSIX path of (choose file with prompt "选择视频文件")'
        proc = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        return proc.stdout.strip() or None

    # ---- 设置菜单 ----
    def _open_menu(self) -> None:
        """菜单打开时才绑定方向键等，关闭时解绑，方向键恢复 mpv 默认（快进快退）。"""
        self.menu_open = True
        self.menu_sel = 0
        self.last_menu = None
        for keydef, action in MENU_KEYS.items():
            self.player.register_key_binding(keydef, _menu_key_handler(self.events, action))

    def _close_menu(self) -> None:
        if self.menu_open:
            for keydef in MENU_KEYS:
                try:
                    self.player.unregister_key_binding(keydef)
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

    def _menu_change(self, delta: int) -> None:
        s = self.settings
        key = MENU_ROWS[self.menu_sel]
        if key == "display":
            cur = s.get("display_mode")
            i = DISPLAY_MODES.index(cur) if cur in DISPLAY_MODES else 0
            s.set("display_mode", DISPLAY_MODES[(i + delta) % len(DISPLAY_MODES)])
            self.last_sub_text = None
        elif key == "translate":
            on = not bool(s.get("translate"))
            s.set("translate", on)
            if self.translator is not None:
                self.translator.enabled = on
        elif key == "target":
            cur = s.get("target_lang")
            i = TARGET_CHOICES.index(cur) if cur in TARGET_CHOICES else -1
            s.set("target_lang", TARGET_CHOICES[(i + delta) % len(TARGET_CHOICES)])
            self._restart_translator()
        elif key == "language":
            cur = s.get("language")
            i = LANGUAGE_CHOICES.index(cur) if cur in LANGUAGE_CHOICES else 0
            s.set("language", LANGUAGE_CHOICES[(i + delta) % len(LANGUAGE_CHOICES)])
            self._restart_workers()
        elif key == "model":
            names = list(MODEL_PRESETS)
            cur = s.get("model")
            i = names.index(cur) if cur in names else -1
            s.set("model", names[(i + delta) % len(names)])
            self._restart_workers()
        elif key == "track":
            if len(self.tracks) < 2:
                self.error_msg = "这个文件只有一条音轨"
                return
            idx = (self.track + delta) % len(self.tracks)
            self.player.aid = idx + 1
            self._set_track(idx)
        elif key == "engine":
            s.set("translate_engine", "openai" if s.get("translate_engine") == "apple" else "apple")
            self._restart_translator()
        elif key == "translate_model":
            if s.get("translate_engine") == "apple":
                self.error_msg = "Apple Intelligence 只有一个系统模型，不能切换"
                return
            models = self.translator.models if self.translator is not None else []
            if not models:
                self.error_msg = "翻译服务未连接，无法切换翻译模型"
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
            i = SPEED_CHOICES.index(self.speed) if self.speed in SPEED_CHOICES else 2
            self.speed = SPEED_CHOICES[(i + delta) % len(SPEED_CHOICES)]
            self.player.speed = self.speed

    def _set_scale(self, value: float) -> None:
        new = min(3.0, max(0.5, round(value, 2)))
        self.settings.set("font_scale", new)
        self.last_sub_text = None

    def _window_scale(self) -> Optional[float]:
        """mpv 当前的窗口缩放倍数；读不到（窗口还没建好等）返回 None。"""
        try:
            value = self.player.current_window_scale
            return float(value) if value else None
        except Exception:
            return None

    def _menu_window(self, delta: int) -> None:
        cur = self._window_scale()
        if cur is None:
            self.error_msg = "读不到窗口大小，无法修改"
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
                value = "开" if s.get("translate") else "关"
            elif key == "target":
                value = f"{lang_name_zh(target)} ({target})"
            elif key == "language":
                value = str(s.get("language"))
            elif key == "model":
                value = str(s.get("model"))
            elif key == "track":
                value = f"{self.track + 1} / {len(self.tracks)}" if self.tracks else "-"
            elif key == "engine":
                value = ENGINE_NAMES.get(s.get("translate_engine"), str(s.get("translate_engine")))
            elif key == "translate_model":
                value = ("系统自带" if s.get("translate_engine") == "apple"
                         else str(s.get("translate_model")))
            elif key == "scale":
                value = f"{s.get('font_scale'):.1f}"
            elif key == "window":
                cur = self._window_scale()
                value = f"{round(cur * 100)}%" if cur else "-"
            else:
                value = f"{self.speed:g}x"
            rows.append((MENU_LABELS[key], value))
        return rows

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

        if tr is not None and self.video is not None:
            cues = tr.store.active(pos) if self.file_ready else []
            text = "\n".join(cue_lines(cues, self.settings.get("display_mode")))
        else:
            text = ""
        if text != self.last_sub_text:
            self.last_sub_text = text
            if text:
                self._overlay(SUB_ID, subtitle_ass(text.split("\n"), self.settings.get("font_scale")))
            else:
                self._clear(SUB_ID)

        now = time.monotonic()
        if now - self.last_status_draw >= 0.5:
            self.last_status_draw = now
            lines = self._status_lines()
            if lines != self.last_status:
                self.last_status = lines
                if lines:
                    self._overlay(STATUS_ID, status_ass(lines))
                else:
                    self._clear(STATUS_ID)

        if self.menu_open:
            rows = self._menu_rows()
            footer = [self._translate_status_line() or "翻译：未启用",
                      "↑↓ 选择 · ←→ 修改 · Tab 或 Esc 关闭"]
            data = repr((rows, self.menu_sel, footer))
            if data != self.last_menu:
                self.last_menu = data
                self._overlay(MENU_ID, menu_ass(rows, self.menu_sel, footer))

    def _translate_status_line(self) -> Optional[str]:
        tr = self.translator
        if tr is None or not self.settings.get("translate"):
            return None
        apple = self.settings.get("translate_engine") == "apple"
        model = "Apple Intelligence" if apple else self.settings.get("translate_model")
        if apple and tr.status == "offline":
            return f"翻译不可用：{tr.error_msg}。只显示原文"
        if tr.status == "ok":
            return f"翻译 {lang_name_zh(tr.target)} · {model} · {tr.translated}/{tr.total}"
        if tr.status == "offline":
            return "翻译服务未连接，只显示原文"
        if tr.status == "no_model":
            return f"翻译模型未下载：ollama pull {model}"
        if tr.status == "error":
            return f"翻译出错：{tr.error_msg}"
        return None

    def _status_lines(self) -> list[str]:
        lines: list[str] = []
        if self.error_msg:
            lines.append(self.error_msg)
        if self.sub_error:
            lines.append(f"字幕不可用：{self.sub_error}（视频照常播放）")
        tr = self.transcriber
        if tr is not None:
            if tr.error:
                lines.append(f"字幕不可用：{tr.error}（视频照常播放）")
            else:
                done, total = tr.progress()
                head = f"字幕 {tr.language or '检测中'} · {tr.model} · 音轨{tr.track + 1}"
                if tr.complete:
                    if self.complete_at is None:
                        self.complete_at = time.monotonic()
                    if time.monotonic() - self.complete_at < 5:
                        lines.append(f"{head} · 已完成")
                else:
                    lines.append(f"{head} · {done}/{total} 段")
            if tr.warning:
                lines.append(tr.warning)
        translate_line = self._translate_status_line()
        if translate_line:
            lines.append(translate_line)
        if self.video is None and not self.error_msg:
            lines.append("把视频拖进窗口，或按 o 打开")
        if time.monotonic() < self.help_until:
            lines.append(HELP_TEXT)
        return lines

    def _overlay(self, oid: int, data: str) -> None:
        self.player.command("osd-overlay", oid, "ass-events", data, W, H)

    def _clear(self, oid: int) -> None:
        self.player.command("osd-overlay", oid, "none", "", W, H)

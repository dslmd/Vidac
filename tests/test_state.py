"""字幕组件的结构化状态、设置与动作、用户字幕保护、换语言、延迟等（不需要 mpv 窗口）。"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from argparse import Namespace
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from vidac import media, settings as settings_mod, srt  # noqa: E402
from vidac.asr import ModelError, ModelProgress, resolve_mlx_repo  # noqa: E402
from vidac.player import App, parse_setting  # noqa: E402
from vidac.positions import DelayStore  # noqa: E402
from vidac.srt import Cue  # noqa: E402
from vidac.state import build_state, translation_state  # noqa: E402
from vidac.translate import TranslateError  # noqa: E402


def make_args(**kw):
    base = dict(video=None, model=None, language=None, translate_engine="openai",
                translate_url="http://127.0.0.1:9/v1", translate_model=None, target_lang=None,
                display=None, font_scale=None, no_translate=False, backend="fake", audio_track=1,
                mpv_opt=[], rebuild=False, retranslate=False, vad=False, glossary=None)
    base.update(kw)
    return Namespace(**base)


def wait_for(cond, timeout=10.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


class AppCase(unittest.TestCase):
    """用真实的转写线程和假识别后端，但 mpv 是替身。"""

    @classmethod
    def setUpClass(cls):
        if not shutil.which("ffmpeg"):
            raise unittest.SkipTest("需要 ffmpeg")
        cls._tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls._tmp.name)
        cls.video = cls.root / "tone.mp4"
        subprocess.run([
            "ffmpeg", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=5",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=65",
            "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest", str(cls.video),
        ], check=True)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def setUp(self):
        for p in self.root.glob("tone*"):
            if p.suffix != ".mp4":
                p.unlink()
        self._home = tempfile.TemporaryDirectory()
        env = mock.patch.dict(os.environ, {"VIDAC_HOME": self._home.name,
                                           "VIDAC_TARGET_LANG_DEFAULT": "en"}, clear=False)
        env.start()
        self.addCleanup(env.stop)
        settings_mod.default_target_lang.cache_clear()
        self.addCleanup(settings_mod.default_target_lang.cache_clear)
        self.addCleanup(self._home.cleanup)
        self.apps: list[App] = []

    def tearDown(self):
        for app in self.apps:
            app._stop_workers()

    def make_app(self, **kw) -> App:
        with mock.patch("vidac.player.mpvipc.MPV") as mpv:
            mpv.return_value = mock.MagicMock(core_shutdown=False)
            app = App(make_args(**kw))
        app.player.get.return_value = None
        self.apps.append(app)
        return app

    def open(self, app: App, finish=True):
        app._open(str(self.video))
        self.assertIsNotNone(app.transcriber)
        if finish:
            self.assertTrue(wait_for(lambda: app.transcriber.complete or app.transcriber.error))
        return app.transcriber


class StateObjectTests(AppCase):
    def test_idle_state_is_complete_and_json(self):
        app = self.make_app()
        state = app._state()
        json.dumps(state)
        self.assertEqual(state["v"], 1)
        self.assertEqual(state["phase"], "idle")
        self.assertIsNone(state["progress"])
        self.assertFalse(state["ahead"])
        self.assertIsNone(state["download"])
        self.assertIsNone(state["source"])
        self.assertIsNone(state["error"])
        self.assertEqual(state["files"], [])
        self.assertEqual(state["translation"]["state"], "off")
        for key in ("display_mode", "translate", "target_lang", "language", "model", "enabled",
                    "font_scale", "delay", "subtitle_location"):
            self.assertIn(key, state["settings"])

    def test_finished_video_state_is_truthful(self):
        app = self.make_app(no_translate=True)
        self.open(app)
        app.file_ready = True
        state = app._state()
        self.assertEqual(state["phase"], "ready")
        self.assertEqual(state["progress"], 1.0)
        self.assertEqual(state["source"], "generated")
        self.assertEqual(state["language"], "ja")
        self.assertEqual(state["model"], "base")
        self.assertEqual(state["translation"]["state"], "off")
        self.assertEqual(state["files"], [str(self.video.resolve().parent / "tone.vidac.ja.srt")])
        self.assertIsNone(state["error"])
        # 再打开一次：来自缓存
        app2 = self.make_app(no_translate=True)
        self.open(app2)
        self.assertEqual(app2._state()["source"], "cache")

    def test_translation_unavailable_carries_reason(self):
        app = self.make_app()
        self.open(app)
        self.assertTrue(wait_for(lambda: app.translator.status == "offline"))
        t = app._state()["translation"]
        self.assertEqual(t["state"], "unavailable")
        self.assertIn("cannot reach the translation server", t["reason"])
        self.assertEqual((t["target"], t["engine"]), ("en", "openai"))
        self.assertFalse(any("\u4e00" <= ch <= "\u9fff" for ch in json.dumps(app._state(), ensure_ascii=False)
                             .replace(str(self.root), "")))

    def test_state_is_english_only_for_every_error_path(self):
        app = self.make_app()
        app._open("http://example.com/x.mp4")
        err = app._state()["error"]
        self.assertEqual(app._state()["phase"], "error")
        self.assertEqual(err["code"], "internal")
        self.assertIn("Playback is not affected", err["message"])
        app._open(str(self.root / "missing.mp4"))
        self.assertEqual(app._state()["phase"], "error")

    def test_no_audio_track_error(self):
        silent = self.root / "silent.mp4"
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=160x90:rate=5:duration=2", "-c:v", "libx264", str(silent)], check=True)
        app = self.make_app()
        app._open(str(silent))
        state = app._state()
        self.assertEqual(state["phase"], "error")
        self.assertEqual(state["error"]["code"], "audio")
        self.assertIn("no audio track", state["error"]["message"])
        self.assertIsNone(app.transcriber)

    def test_state_published_only_on_change_and_throttled(self):
        app = self.make_app()
        app._publish_state(100.0)
        calls = [c for c in app.player.set.call_args_list if c.args[0] == "user-data/vidac-state"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(json.loads(calls[0].args[1])["phase"], "idle")
        app._publish_state(100.6)                      # 没变：不再发
        self.assertEqual(len([c for c in app.player.set.call_args_list
                              if c.args[0] == "user-data/vidac-state"]), 1)
        app.apply_setting("display_mode", "orig")
        app.last_state_at = 100.0
        app._publish_state(100.7)
        calls = [c for c in app.player.set.call_args_list if c.args[0] == "user-data/vidac-state"]
        self.assertEqual(json.loads(calls[-1].args[1])["settings"]["display_mode"], "orig")

    def test_native_mode_does_not_publish_legacy_status_or_overlay_status(self):
        app = self.make_app()
        app.native_ui = True
        app._publish_state(10.0)
        names = [c.args[0] for c in app.player.set.call_args_list]
        self.assertEqual(names, ["user-data/vidac-state"])
        app.native_ui = False
        app.last_state_json = None
        app._publish_state(20.0)
        self.assertIn("user-data/vidac-status", [c.args[0] for c in app.player.set.call_args_list])


class FakeTs:
    """build_state 需要的转写线程接口。"""

    def __init__(self, **kw):
        self.error = self.error_code = None
        self.complete = False
        self.downloading = False
        self.model_loading = False
        self.language = None
        self.source = "generated"
        self.used_model = "base"
        self.loaded = threading.Event()
        self.loaded.set()
        self.model_progress = ModelProgress()
        self._progress = (0, 10)
        self.__dict__.update(kw)

    def progress(self):
        return self._progress

    def output_files(self):
        return []


def state_of(ts, **kw):
    args = dict(video=Path("/v.mp4"), open_error=None, ts=ts, translator=None,
                settings={"translate": False, "target_lang": "en", "translate_engine": "apple",
                          "model": "base"},
                delay=0.0, resumed_from=None, generating=True, ahead=False)
    args.update(kw)
    return build_state(**args)


class PhaseTests(unittest.TestCase):
    def test_download_phase_reports_bytes(self):
        ts = FakeTs(model_loading=True, downloading=True)
        ts.model_progress.begin()
        ts.model_progress.received, ts.model_progress.total = 50, 200
        state = state_of(ts)
        self.assertEqual(state["phase"], "model-download")
        self.assertEqual(state["download"], {"received": 50, "total": 200})
        ts.model_progress.end()
        ts.downloading = False
        state = state_of(ts)
        self.assertEqual(state["phase"], "model-load")
        self.assertIsNone(state["download"])

    def test_progress_and_disabled_and_error(self):
        ts = FakeTs(_progress=(4, 10))
        self.assertEqual(state_of(ts)["progress"], 0.4)
        self.assertEqual(state_of(ts)["phase"], "transcribing")
        self.assertEqual(state_of(ts, generating=False)["phase"], "disabled")
        ts.error, ts.error_code = "It broke. Try again.", "offline"
        state = state_of(ts)
        self.assertEqual(state["phase"], "error")
        self.assertEqual(state["error"], {"code": "offline", "message": "It broke. Try again."})

    def test_ahead_flag_follows_coverage(self):
        app = App.__new__(App)
        app.settings = mock.Mock(effective=lambda: {"translate": False, "target_lang": "en",
                                                    "translate_engine": "apple", "model": "base",
                                                    "enabled": True})
        app.settings.get = lambda k: True
        app.video, app.open_error, app.translator = Path("/v.mp4"), None, None
        app.delay, app.resumed_from, app.stopped, app.forced = 0.0, None, False, False
        app.file_ready, app.last_pos = True, 100.0
        ts = FakeTs()
        ts.working = True
        ts.covered = lambda t: False
        app.transcriber = ts
        self.assertTrue(app._state()["ahead"])
        ts.covered = lambda t: t < 200
        self.assertFalse(app._state()["ahead"])
        ts.covered = lambda t: False
        ts.working = False                      # 没有活在干了（停止、出错）：不能说“马上会有”
        self.assertFalse(app._state()["ahead"])

    def test_translation_states(self):
        base = {"translate": True, "target_lang": "en", "translate_engine": "apple"}
        ts = FakeTs(language="ja")
        tr = SimpleNamespace(status="offline", error_msg="Apple Intelligence is turned off. "
                             "Turn it on in System Settings.", translated=0, total=5, failed=0)
        t = translation_state(base, ts, tr, True)
        self.assertEqual(t["state"], "unavailable")
        self.assertIn("System Settings", t["reason"])
        tr.status = "error"
        self.assertEqual(translation_state(base, ts, tr, True)["state"], "error")
        tr.status, tr.translated = "ok", 3
        self.assertEqual(translation_state(base, ts, tr, True)["state"], "working")
        ts.complete, tr.translated, tr.failed = True, 4, 1
        t = translation_state(base, ts, tr, True)
        self.assertEqual(t["state"], "ready")
        self.assertIn("1 line could not be translated", t["reason"])
        tr.status = "same_lang"
        t = translation_state(base, ts, tr, True)
        self.assertEqual(t["state"], "off")
        self.assertIn("already in Japanese", t["reason"])
        self.assertEqual(translation_state({**base, "translate": False}, ts, tr, True)["state"], "off")


class SettingsProtocolTests(unittest.TestCase):
    def test_parse_values(self):
        self.assertEqual(parse_setting("display_mode", "trans"), "trans")
        self.assertIs(parse_setting("enabled", "false"), False)
        self.assertEqual(parse_setting("delay", "0.25"), 0.25)
        self.assertEqual(parse_setting("delay", "9999"), 60.0)
        self.assertEqual(parse_setting("font_scale", "0.01"), 0.5)
        self.assertEqual(parse_setting("language", "JA"), "ja")
        self.assertEqual(parse_setting("language", "auto"), "auto")
        self.assertEqual(parse_setting("target_lang", "nl"), "nl")
        self.assertEqual(parse_setting("subtitle_location", "library"), "library")
        for key, bad in [("display_mode", "x"), ("translate", "yes"), ("delay", "nan"),
                         ("target_lang", "xx"), ("language", "xx"), ("model", "nope"),
                         ("subtitle_location", "cloud"), ("nonsense", "1"), ("font_scale", "inf")]:
            with self.assertRaises(ValueError, msg=(key, bad)):
                parse_setting(key, bad)


class DefaultTargetTests(unittest.TestCase):
    def setUp(self):
        settings_mod.default_target_lang.cache_clear()
        self.addCleanup(settings_mod.default_target_lang.cache_clear)

    def test_locale_mapping(self):
        t = settings_mod.target_for_locale
        self.assertEqual(t("zh-Hans-CN"), "zh")
        self.assertEqual(t("zh-Hant-TW"), "zh-tw")
        self.assertEqual(t("zh_HK"), "zh-tw")
        self.assertEqual(t("en_US"), "en")
        self.assertEqual(t("pt-BR"), "pt")
        self.assertEqual(t("de"), "de")
        self.assertEqual(t("xx-YY"), "en")
        self.assertEqual(t(""), "en")

    def test_default_follows_system_and_settings_override(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "settings.json"
            with mock.patch.dict(os.environ, {"VIDAC_TARGET_LANG_DEFAULT": "fr-FR"}):
                s = settings_mod.Settings.load(path)
                self.assertEqual(s.get("target_lang"), "fr")
                s.set("target_lang", "ja")
                self.assertEqual(settings_mod.Settings.load(path).get("target_lang"), "ja")

    def test_unreadable_system_language_falls_back_to_english(self):
        with mock.patch.dict(os.environ, {}, clear=False), \
                mock.patch.object(settings_mod, "_system_languages", return_value=[]):
            os.environ.pop("VIDAC_TARGET_LANG_DEFAULT", None)
            self.assertEqual(settings_mod.default_target_lang(), "en")


class UserSubtitleProtectionTests(AppCase):
    USER_EN = "1\n00:00:01,000 --> 00:00:03,000\nMy own English line\n"
    USER_ZH = "1\n00:00:01,000 --> 00:00:03,000\n我自己的中文字幕\n"

    def test_sidecar_is_read_and_never_overwritten(self):
        en = self.root / "tone.en.srt"
        zh = self.root / "tone.zh.srt"
        en.write_text(self.USER_EN, encoding="utf-8")
        zh.write_text(self.USER_ZH, encoding="utf-8")
        app = self.make_app(target_lang="zh")
        ts = self.open(app)
        app.file_ready = True
        state = app._state()
        self.assertEqual(state["source"], "sidecar")
        self.assertEqual(state["phase"], "ready")
        self.assertEqual([c.text for c in ts.store.snapshot()], ["My own English line"])
        self.assertEqual(state["files"], [])           # 没写任何文件
        # 译文也不会写到用户的 zh.srt 上
        self.assertEqual(en.read_text(encoding="utf-8"), self.USER_EN)
        self.assertEqual(zh.read_text(encoding="utf-8"), self.USER_ZH)

    def test_regenerate_writes_under_vidac_names_and_keeps_user_files(self):
        en = self.root / "tone.en.srt"
        en.write_text(self.USER_EN, encoding="utf-8")
        app = self.make_app(no_translate=True)
        self.open(app)
        self.assertEqual(app.transcriber.source, "sidecar")
        app.do_action("regenerate")
        ts = app.transcriber
        self.assertTrue(wait_for(lambda: ts.complete or ts.error))
        self.assertEqual(ts.source, "generated")
        self.assertTrue((self.root / "tone.vidac.ja.srt").exists())
        self.assertEqual(en.read_text(encoding="utf-8"), self.USER_EN)
        # 又一次打开：已有 Vidac 自己的字幕，不再回头用自备的
        app2 = self.make_app(no_translate=True)
        self.open(app2)
        self.assertEqual(app2.transcriber.source, "cache")
        self.assertEqual(en.read_text(encoding="utf-8"), self.USER_EN)

    def test_clear_cache_never_touches_user_files(self):
        folder, base = srt.cache_layout(self.video, 0)
        mine = [srt.original_srt_path(folder, base, "ja"), srt.translation_srt_path(folder, base, "zh"),
                srt.progress_path(folder, base)]
        theirs = [folder / "tone.srt", folder / "tone.ja.srt", folder / "tone.zh.srt"]
        for p in mine + theirs:
            p.write_text("x", encoding="utf-8")
        srt.clear_cache(folder, base)
        self.assertFalse(any(p.exists() for p in mine))
        self.assertTrue(all(p.exists() for p in theirs))

    def test_legacy_cache_is_still_read(self):
        folder, base = srt.cache_layout(self.video, 0)
        old = folder / "tone.ja.srt"
        old.write_text("1\n00:00:00,000 --> 00:00:01,000\nこんにちは\n", encoding="utf-8")
        srt.save_progress(srt.progress_path(folder, base), {
            "model": "base", "language": "ja", "srt": "tone.ja.srt", "duration": media.probe_duration(self.video),
            "done": [0, 1, 2], "total": 3})
        app = self.make_app(no_translate=True)
        ts = self.open(app)
        self.assertEqual(ts.source, "cache")
        self.assertEqual([c.text for c in ts.store.snapshot()], ["こんにちは"])


class ActionAndChangeTests(AppCase):
    def test_regenerate_discards_and_redoes(self):
        app = self.make_app(no_translate=True)
        self.open(app)
        first = app.transcriber
        app.do_action("regenerate")
        self.assertIsNot(app.transcriber, first)
        self.assertTrue(first.stopped)
        ts = app.transcriber
        self.assertTrue(wait_for(lambda: ts.complete))
        self.assertEqual(ts.processed, [0, 1, 2])      # 没有读缓存，全部重新转写

    def test_model_and_language_change_regenerate_only_when_changed(self):
        app = self.make_app(no_translate=True)
        self.open(app)
        app.apply_setting("model", "base")             # 没变：什么也不发生
        self.assertEqual(app.transcriber.processed, [0, 1, 2])
        first = app.transcriber
        self.assertTrue(app.apply_setting("language", "en"))
        self.assertIsNot(app.transcriber, first)
        ts = app.transcriber
        self.assertTrue(wait_for(lambda: ts.complete))
        self.assertEqual(ts.processed, [0, 1, 2])
        self.assertEqual(app._state()["settings"]["language"], "en")
        self.assertFalse(app.rebuild)                  # 标志已被消耗，不会留给下一个视频
        self.assertTrue(app.apply_setting("model", "small"))
        self.assertTrue(wait_for(lambda: app.transcriber.complete))
        self.assertEqual(app.transcriber.processed, [0, 1, 2])

    def test_setting_change_without_video_does_not_leave_rebuild_flag(self):
        app = self.make_app()
        app.apply_setting("model", "small")
        app.apply_setting("language", "ja")
        self.assertFalse(app.rebuild)
        self.assertFalse(app.retranslate)

    def test_enabled_off_does_no_transcription_but_shows_cache(self):
        app = self.make_app(no_translate=True)
        self.open(app)
        app.apply_setting("enabled", "false")
        ts = app.transcriber
        ts.join(5)
        self.assertTrue(ts.complete)                   # 缓存是完整的：照常显示
        self.assertEqual(app._state()["phase"], "ready")
        # 没有缓存的视频：不起识别后端
        for p in self.root.glob("tone.*"):
            if p.suffix != ".mp4":
                p.unlink()
        with mock.patch("vidac.player.make_backend", side_effect=AssertionError("must not run")):
            app._open(str(self.video))
            app.transcriber.join(5)
            state = app._state()
        self.assertEqual(state["phase"], "disabled")
        self.assertIsNone(state["error"])
        self.assertEqual(app.transcriber.processed, [])

    def test_stop_and_retry_actions(self):
        app = self.make_app(no_translate=True)
        with mock.patch.dict(os.environ, {"VIDAC_FAKE_DELAY": "0.3"}):
            app._open(str(self.video))
            self.assertTrue(wait_for(lambda: app.transcriber.model_loading or app.transcriber.processed))
            app.do_action("stop")
            ts = app.transcriber
            ts.join(5)
            self.assertFalse(ts.complete)
            self.assertEqual(app._state()["phase"], "disabled")
            self.assertFalse(ts.working)
            app.do_action("retry")
            self.assertEqual(app._state()["phase"], "transcribing")
            self.assertTrue(wait_for(lambda: app.transcriber.complete, 15))
            self.assertEqual(app._state()["phase"], "ready")

    def test_retry_after_error_restarts(self):
        app = self.make_app(no_translate=True)
        with mock.patch("vidac.player.make_backend", side_effect=ModelError("offline now", "offline")):
            app._open(str(self.video))
            self.assertTrue(wait_for(lambda: app.transcriber.error))
            state = app._state()
        self.assertEqual(state["phase"], "error")
        self.assertEqual(state["error"], {"code": "offline", "message": "offline now"})
        app.do_action("retry")
        ts = app.transcriber
        self.assertTrue(wait_for(lambda: ts.complete))
        self.assertIsNone(app._state()["error"])

    def test_regenerate_when_automatic_subtitles_are_off_still_generates_this_video(self):
        app = self.make_app(no_translate=True)
        app.apply_setting("enabled", "false")
        app._open(str(self.video))
        app.transcriber.join(5)
        self.assertEqual(app._state()["phase"], "disabled")
        app.do_action("regenerate")
        self.assertTrue(wait_for(lambda: app.transcriber.complete))
        # 换一个视频，例外失效
        self.assertFalse(app._generating() and False)
        app._open(str(self.video))
        self.assertFalse(app.forced)

    def test_flags_reset_on_new_file(self):
        app = self.make_app(no_translate=True)
        self.open(app)
        app.do_action("stop")
        self.assertTrue(app.stopped)
        app.resumed_from = 12.0
        app._open(str(self.video))
        self.assertFalse(app.stopped)
        self.assertIsNone(app.resumed_from)
        self.assertEqual(app._state()["phase"] in ("transcribing", "ready", "model-load"), True)

    def test_unknown_action_is_ignored(self):
        app = self.make_app()
        app.do_action("explode")
        app.do_action("stop")   # 没有视频：什么也不做


class TargetLanguageChangeTests(AppCase):
    class Dead:
        model = "m"
        base_url = "x"

        def list_models(self, timeout=0):
            raise TranslateError("down")

    def test_changing_target_clears_old_language_and_never_writes_it(self):
        app = self.make_app(target_lang="zh")
        with mock.patch("vidac.player.make_client", return_value=self.Dead()):
            ts = self.open(app)
            old_translator = app.translator
            for c in ts.store.snapshot():
                c.translation = "旧语言译文"
            old_file = srt.translation_srt_path(ts.folder, ts.base, "zh")
            old_file.write_text("1\n00:00:00,000 --> 00:00:01,000\n旧语言译文\n", encoding="utf-8")
            before = old_file.read_text(encoding="utf-8")
            app.apply_setting("target_lang", "en")
            self.assertTrue(old_translator._stop_event.is_set())
            self.assertIsNot(app.translator, old_translator)
            self.assertEqual(app.translator.target, "en")
            self.assertTrue(all(c.translation is None for c in ts.store.snapshot()))
            old_translator._persist()                      # 停掉的旧线程补写也不会动任何东西
            self.assertEqual(old_file.read_text(encoding="utf-8"), before)
            self.assertFalse(srt.translation_srt_path(ts.folder, ts.base, "en").exists())
            self.assertEqual(app._state()["translation"]["target"], "en")

    def test_translate_off_hides_existing_translations(self):
        from vidac.overlay import cue_layout
        c = Cue(0, 1, "こんにちは", translation="Hello")
        self.assertEqual([ln.text for ln in cue_layout([c], "bilingual", translate=False)], ["こんにちは"])

    def test_same_language_as_target_does_not_translate(self):
        app = self.make_app(target_lang="ja")
        client = mock.Mock(model="m", base_url="x")
        client.list_models.side_effect = AssertionError("must not be used")
        with mock.patch("vidac.player.make_client", return_value=client):
            self.open(app)
            self.assertTrue(wait_for(lambda: app.translator.status == "same_lang"))
            t = app._state()["translation"]
        self.assertEqual(t["state"], "off")
        self.assertIn("already in Japanese", t["reason"])
        client.list_models.assert_not_called()

    def test_target_change_loads_new_language_cache(self):
        app = self.make_app(target_lang="zh")
        with mock.patch("vidac.player.make_client", return_value=self.Dead()):
            ts = self.open(app)
            en_file = srt.translation_srt_path(ts.folder, ts.base, "en")
            first = ts.store.snapshot()[0]
            en_file.write_text(srt.render_srt([Cue(first.start, first.end, "Hello there")]),
                               encoding="utf-8")
            app.apply_setting("target_lang", "en")
            self.assertTrue(wait_for(lambda: ts.store.snapshot()[0].translation == "Hello there"))


class DelayTests(AppCase):
    def test_delay_is_per_video_and_restored(self):
        app = self.make_app(no_translate=True)
        self.open(app)
        app.apply_setting("delay", "0.5")
        self.assertEqual(app._state()["delay"], 0.5)
        self.assertEqual(app._state()["settings"]["delay"], 0.5)
        self.assertEqual(DelayStore(Path(self._home.name) / "delays.json").get(self.video.resolve()), 0.5)
        self.assertEqual(app.settings.get("delay"), 0.0)       # 默认值不被改
        app2 = self.make_app(no_translate=True)
        app2._open(str(self.video))
        self.assertEqual(app2.delay, 0.5)
        app2._open(str(self.root / "nope.mp4"))                # 换到没有视频：回到默认值
        self.assertEqual(app2.delay, 0.0)
        app.apply_setting("delay", "0")                         # 回到默认值就不再单独记
        self.assertIsNone(DelayStore(Path(self._home.name) / "delays.json").get(self.video.resolve()))

    def test_delay_without_video_sets_default_and_is_clamped(self):
        app = self.make_app()
        app.apply_setting("delay", "1.5")
        self.assertEqual(app.settings.get("delay"), 1.5)
        app.apply_setting("delay", "500")
        self.assertEqual(app.delay, 60.0)

    def test_lookup_uses_delayed_time(self):
        app = self.make_app(no_translate=True)
        ts = self.open(app)
        app.file_ready = True
        ts.store.apply(lambda cs: [Cue(10, 11, "Line")])
        app.apply_setting("display_mode", "orig")
        app.apply_setting("delay", "2")
        app.player.command.reset_mock()
        app._draw_subtitles(12.5)                               # 12.5 - 2 = 10.5：在字幕里
        self.assertEqual(app.player.command.call_args.args[2], "ass-events")
        app.player.command.reset_mock()
        app._draw_subtitles(10.5)                               # 8.5：还没到
        self.assertEqual(app.player.command.call_args.args[2], "none")

    def test_delay_keys_only_in_terminal_mode(self):
        for native in (False, True):
            app = self.make_app()
            with mock.patch.object(app, "native_ui", native):
                app.player.set_keys.reset_mock()
                app._bind_keys()
            keys = app.player.set_keys.call_args.args[1]
            self.assertEqual("z" in keys, not native)
            for leaked in ("+", "-", "=", "v", "o", "TAB"):
                self.assertEqual(leaked in keys, not native, leaked)
            self.assertIn("t", keys)


class ResumeTests(unittest.TestCase):
    def _app(self, now):
        app = App.__new__(App)
        app.file_ready = False
        app.video = Path("/v.mp4")
        app._skip_initial_resume = False
        app.resumed_from = None
        app.last_pos = None
        app.player = mock.Mock(duration=500, time_pos=now)
        app.positions = mock.Mock()
        app.positions.get.return_value = 40.0
        return app

    def test_companion_resume_sets_resumed_from(self):
        app = self._app(0.0)
        app._on_file_loaded()
        app.player.seek.assert_called_once_with(40.0, reference="absolute")
        self.assertEqual(app.resumed_from, 40.0)
        self.assertEqual(app.last_pos, 40.0)

    def test_already_there_means_host_resumed_so_no_seek(self):
        app = self._app(39.5)
        app._on_file_loaded()
        app.player.seek.assert_not_called()
        self.assertIsNone(app.resumed_from)


class ModelDownloadTests(unittest.TestCase):
    def test_byte_progress_reaches_the_progress_object(self):
        seen = []
        progress = ModelProgress()

        def download(repo, **kw):
            if kw.get("local_files_only"):
                raise RuntimeError("not cached")
            if kw.get("dry_run"):
                return [SimpleNamespace(file_size=1000, will_download=True)]
            bar = kw["tqdm_class"](total=1000, unit="B", unit_scale=True)
            self.assertTrue(progress.downloading)
            bar.update(400)
            seen.append(progress.snapshot())
            bar.update(600)
            seen.append(progress.snapshot())
            return "/models/x"

        self.assertEqual(resolve_mlx_repo(["a/b"], download, progress), "/models/x")
        self.assertEqual(seen[0], {"received": 400, "total": 1000})
        self.assertEqual(seen[1], {"received": 1000, "total": 1000})
        self.assertFalse(progress.downloading)
        self.assertIsNone(progress.snapshot())

    def test_offline_is_a_clear_offline_error_and_retry_works(self):
        class ConnectError(Exception):
            pass

        online = {"up": False}

        def download(repo, **kw):
            if kw.get("local_files_only"):
                raise RuntimeError("not cached")
            if kw.get("dry_run"):
                return []
            if not online["up"]:
                raise ConnectError("no route to host")
            return "/models/x"

        with self.assertRaises(ModelError) as cm:
            resolve_mlx_repo(["a/b", "a/c"], download, ModelProgress())
        self.assertEqual(cm.exception.code, "offline")
        self.assertIn("offline", str(cm.exception))
        self.assertIn("Connect to the internet", str(cm.exception))
        online["up"] = True                                    # 不用重启：再来一次就行
        self.assertEqual(resolve_mlx_repo(["a/b"], download, ModelProgress()), "/models/x")

    def test_other_failure_is_model_download_code(self):
        def download(repo, **kw):
            if kw.get("local_files_only"):
                raise RuntimeError("not cached")
            if kw.get("dry_run"):
                return []
            raise RuntimeError("403 forbidden")

        with self.assertRaises(ModelError) as cm:
            resolve_mlx_repo(["a/b"], download, ModelProgress())
        self.assertEqual(cm.exception.code, "model-download")

    def test_stop_cancels_the_download(self):
        from vidac.asr import DownloadCancelled
        progress = ModelProgress()

        def download(repo, **kw):
            if kw.get("local_files_only"):
                raise RuntimeError("not cached")
            if kw.get("dry_run"):
                return []
            bar = kw["tqdm_class"](total=10, unit="B")
            progress.cancelled.set()
            bar.update(1)

        with self.assertRaises(DownloadCancelled):
            resolve_mlx_repo(["a/b"], download, progress)
        self.assertFalse(progress.downloading)

    def test_offline_error_code_reaches_the_state_through_the_transcriber(self):
        # Transcriber.run 把带 code 的异常原样记成 error_code
        from vidac.transcriber import Transcriber
        if not shutil.which("ffmpeg"):
            self.skipTest("需要 ffmpeg")
        with tempfile.TemporaryDirectory() as d:
            video = Path(d) / "a.mp4"
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                            "sine=frequency=440:duration=3", "-c:a", "aac", str(video)], check=True)

            def factory():
                raise ModelError("Offline, connect and retry.", "offline")

            tr = Transcriber(video, 0, factory, model="base")
            tr.run()
        self.assertEqual((tr.error_code, tr.error), ("offline", "Offline, connect and retry."))


class TypographyTests(unittest.TestCase):
    def test_long_cjk_line_wraps_inside_the_window(self):
        from vidac.overlay import Line, subtitle_ass, wrap, W, MAX_LINE_WIDTH
        text = "今日はとてもいい天気なので駅まで一緒に歩いてそれからゆっくり映画を見に行きましょう"
        rows = wrap(text, W * MAX_LINE_WIDTH / 40)
        self.assertGreaterEqual(len(rows), 2)
        self.assertEqual("".join(rows), text)
        self.assertLessEqual(max(len(r) for r in rows) - min(len(r) for r in rows), 8)  # 长度接近
        out = subtitle_ass([Line(text)], 1.0)
        self.assertIn("\\N", out)

    def test_bilingual_hierarchy_translation_primary_original_secondary(self):
        from vidac.overlay import cue_layout, subtitle_ass
        lines = cue_layout([Cue(0, 1, "こんにちは", translation="Hello")], "bilingual", True, "ja", "en")
        self.assertEqual([(ln.text, ln.secondary) for ln in lines], [("Hello", False), ("こんにちは", True)])
        ass = subtitle_ass(lines, 1.0)
        self.assertLess(ass.index("Hello"), ass.index("こんにちは"))
        self.assertIn("\\shad", ass)
        self.assertIn("\\blur", ass)

    def test_size_scales_with_window_shape_and_font_scale(self):
        from vidac.overlay import Line, subtitle_ass
        wide = subtitle_ass([Line("Hello")], 1.0, aspect=16 / 9)
        tall = subtitle_ass([Line("Hello")], 1.0, aspect=9 / 16)
        big = subtitle_ass([Line("Hello")], 2.0, aspect=16 / 9)

        def size(a):
            import re
            return float(re.search(r"\\fs([\d.]+)", a.split("Hello")[0].split("\\fn")[1]).group(1))

        self.assertLess(size(tall), size(wide))
        self.assertGreater(size(big), size(wide))


if __name__ == "__main__":
    unittest.main()

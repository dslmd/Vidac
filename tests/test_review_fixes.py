"""独立审查发现的 22 个问题的回归测试。每个用例的名字里带着发现的序号（f00 ... f21）。"""

from __future__ import annotations

import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_state import AppCase, FakeTs, make_args, wait_for  # noqa: E402

from vidac import media, settings as settings_mod, srt  # noqa: E402
from vidac.asr import DownloadCancelled, ModelError, ModelProgress, resolve_mlx_repo  # noqa: E402
from vidac.asr.base import Segment  # noqa: E402
from vidac.asr.fake_backend import FakeBackend  # noqa: E402
from vidac.filters import is_hallucination_phrase, keep_segment  # noqa: E402
from vidac.langguess import guess_language  # noqa: E402
from vidac.overlay import Line, cue_layout, font_for, status_ass, subtitle_ass  # noqa: E402
from vidac.player import App, menu_ass  # noqa: E402
from vidac.srt import Cue  # noqa: E402
from vidac.state import translation_state  # noqa: E402
from vidac.transcriber import SubtitleStore, Transcriber  # noqa: E402
from vidac.translate import (  # noqa: E402
    AppleClient, Glossary, LineTranslator, TranslateClient, TranslateError, TranslateTimeout,
    TranslationCancelled, Translator,
)

NL = "\n"


def _echo(messages):
    import re
    user = messages[-1]["content"].split("严格输出", 1)[-1]
    out = []
    for ln in user.splitlines():
        m = re.match(r"^(\d+): (.*)$", ln)
        if m:
            out.append(f"{m.group(1)}: 译{m.group(2)}")
    return NL.join(out)


class FakeClient:
    def __init__(self, fn, model="m"):
        self.fn, self.model, self.calls = fn, model, 0

    def chat(self, messages):
        self.calls += 1
        return self.fn(messages)

    def list_models(self, timeout=0):
        return [self.model]


class FakeTr:
    """替代 Transcriber，翻译线程要用的那部分。"""

    def __init__(self, language="ja", srt_path=None, complete=True, legacy_cache=False):
        self.loaded = threading.Event()
        self.loaded.set()
        self.complete, self.error, self.language = complete, None, language
        self.srt_path, self._written_path, self.legacy_cache = srt_path, srt_path, legacy_cache


def fake_translator_state(**kw):
    base = dict(translated=0, total=5, status="disabled", error_msg=None, failed=0, slow=False)
    base.update(kw)
    return SimpleNamespace(**base)


# ---------------------------------------------------------------- f00
class CloseVideoTests(AppCase):
    def test_f00_close_publishes_idle_and_stops_workers(self):
        app = self.make_app(no_translate=True)
        ts = self.open(app, finish=False)
        app.file_ready = True
        app.last_pos = 3.0
        app.player.path = None
        app._handle_event(("close",))
        state = app._state()
        self.assertEqual(state["phase"], "idle")
        self.assertIsNone(state["language"])
        self.assertIsNone(state["progress"])
        self.assertEqual(state["files"], [])
        self.assertIsNone(app.video)
        self.assertIsNone(app.transcriber)
        self.assertTrue(ts.stopped)

    def test_f00_close_clears_an_open_error(self):
        app = self.make_app()
        app._open("https://example.com/video.mp4")
        self.assertEqual(app._state()["phase"], "error")
        app.player.path = None
        app._handle_event(("close",))
        self.assertEqual(app._state()["phase"], "idle")
        self.assertIsNone(app._state()["error"])

    def test_f00_close_is_ignored_when_a_new_file_is_already_loaded(self):
        app = self.make_app(no_translate=True)
        self.open(app, finish=False)
        app.player.path = str(self.video)
        app._handle_event(("close",))
        self.assertIsNotNone(app.video)

    def test_f00_path_observer_queues_close_for_empty_path(self):
        observers = {}
        with mock.patch("vidac.player.mpvipc.MPV") as mpv:
            inst = mock.MagicMock(core_shutdown=False)
            inst.property_observer.side_effect = lambda name: (
                lambda fn: observers.setdefault(name, fn) or fn)
            mpv.return_value = inst
            app = App(make_args())
        observers["path"]("path", None)
        self.assertEqual(app.events.get_nowait(), ("close",))
        observers["path"]("path", "/x/y.mp4")
        self.assertEqual(app.events.get_nowait(), ("open", "/x/y.mp4"))


# ---------------------------------------------------------------- f01 / f11
class StopThenEnableTests(AppCase):
    def test_f01_f11_turning_automatic_subtitles_on_clears_stop(self):
        app = self.make_app(no_translate=True)
        app._open(str(self.video))
        app.do_action("stop")
        self.assertTrue(app.stopped)
        self.assertFalse(app._generating())
        app.apply_setting("enabled", "false")
        app.apply_setting("enabled", "true")
        self.assertFalse(app.stopped)
        self.assertTrue(app._generating())
        ts = app.transcriber
        self.assertTrue(ts.transcribe)
        self.assertTrue(wait_for(lambda: ts.complete or ts.error))
        self.assertEqual(app._state()["phase"], "ready")

    def test_f01_reason_matches_why_generation_is_off(self):
        ts = FakeTs(language="ja")
        tr = fake_translator_state(status="disabled", translated=0, total=5)
        on = translation_state({"translate": True, "enabled": True, "target_lang": "en"}, ts, tr, False)
        self.assertIn("stopped", on["reason"])
        self.assertIn("Retry", on["reason"])
        self.assertNotIn("Turn it on", on["reason"])
        off = translation_state({"translate": True, "enabled": False, "target_lang": "en"}, ts, tr, False)
        self.assertIn("Automatic subtitles are off", off["reason"])


# ---------------------------------------------------------------- f02
class ProtocolDocTests(unittest.TestCase):
    def test_f02_protocol_documents_reason_for_off_and_ready(self):
        text = (ROOT / "docs" / "COMPANION_PROTOCOL.md").read_text(encoding="utf-8")
        row = [ln for ln in text.splitlines() if ln.startswith("| `translation.reason`")][0]
        self.assertIn("`off`", row)
        self.assertIn("`ready`", row)
        self.assertIn("whenever", row)
        self.assertIn("`idle`", text)
        self.assertIn("vidac.tr.", text)   # 译文文件名

    def test_f02_code_keeps_reason_with_state_off(self):
        ts = FakeTs(language="ja")
        out = translation_state({"translate": True, "enabled": True, "target_lang": "ja"}, ts,
                                fake_translator_state(status="same_lang"), True)
        self.assertEqual(out["state"], "off")
        self.assertTrue(out["reason"])


# ---------------------------------------------------------------- f03 / f05
class LegacyCacheTests(AppCase):
    USER = "1\n00:00:01,000 --> 00:00:03,000\nMy own English line\n"

    def _legacy_progress(self, srt_name, duration, done, mtime):
        folder, base = srt.cache_layout(self.video, 0)
        path = srt.progress_path(folder, base)
        srt.save_progress(path, {"model": "base", "language": "ja", "srt": srt_name,
                                 "duration": duration, "done": done, "total": 3})
        os.utime(path, (mtime, mtime))
        return folder, base

    def _legacy_files(self, age):
        now = time.time()
        orig = self.root / "tone.ja.srt"
        trans = self.root / "tone.zh.srt"
        orig.write_text("1\n00:00:00,000 --> 00:00:01,000\nこんにちは\n", encoding="utf-8")
        trans.write_text("1\n00:00:00,000 --> 00:00:01,000\n你好\n", encoding="utf-8")
        for p in (orig, trans):
            os.utime(p, (now + age, now + age))
        return orig, trans, now

    def test_f03_newer_user_file_named_like_legacy_output_is_never_deleted(self):
        user = self.root / "tone.en.srt"
        user.write_text(self.USER, encoding="utf-8")
        now = time.time()
        os.utime(user, (now + 100, now + 100))   # 比 0.5 的进度文件新：用户后来放的
        self._legacy_progress("tone.en.srt", 3000, [0, 1, 2], now)
        app = self.make_app(no_translate=True)
        ts = self.open(app)
        self.assertEqual(user.read_text(encoding="utf-8"), self.USER)
        self.assertEqual(ts.source, "sidecar")
        self.assertEqual([c.text for c in ts.store.snapshot()], ["My own English line"])

    def test_f03_f05_clearing_a_legacy_cache_deletes_nothing_and_ignores_leftovers(self):
        now = time.time()
        orig, trans, _ = self._legacy_files(-100)   # 比进度文件旧：确实是 0.5 写的
        self._legacy_progress("tone.ja.srt", 3000, [0, 1, 2], now)   # 时长对不上，缓存作废
        app = self.make_app(no_translate=True)
        ts = self.open(app)
        self.assertEqual(ts.source, "generated")      # 没有把 0.5 的译文 tone.zh.srt 当成用户字幕
        self.assertIsNone(ts.sidecar_path)
        self.assertTrue(orig.exists() and trans.exists())
        self.assertEqual(trans.read_text(encoding="utf-8").strip().splitlines()[-1], "你好")
        self.assertTrue((self.root / "tone.vidac.ja.srt").exists())
        self.assertNotIn(str(orig), app._state()["files"])
        # 下次打开：新缓存，不再回头去读那些旧文件
        app2 = self.make_app(no_translate=True)
        ts2 = self.open(app2)
        self.assertEqual(ts2.source, "cache")

    def test_f05_rebuild_of_a_legacy_cache_does_not_adopt_the_legacy_translation(self):
        now = time.time()
        orig, trans, _ = self._legacy_files(-100)
        dur = media.probe_duration(self.video)
        self._legacy_progress("tone.ja.srt", dur, [0, 1, 2], now)
        tr = Transcriber(self.video, 0, FakeBackend, model="fake", chunk_seconds=30.0, rebuild=True)
        tr.run()
        self.assertTrue(tr.complete)
        self.assertEqual(tr.source, "generated")
        self.assertIsNone(tr.sidecar_path)
        self.assertTrue(orig.exists() and trans.exists())

    def test_f05_second_rebuild_of_a_legacy_cache_still_ignores_leftovers(self):
        now = time.time()
        orig, trans, _ = self._legacy_files(-100)
        dur = media.probe_duration(self.video)
        self._legacy_progress("tone.ja.srt", dur, [0, 1, 2], now)
        for _ in range(2):
            tr = Transcriber(self.video, 0, FakeBackend, model="fake", chunk_seconds=30.0, rebuild=True)
            tr.run()
            self.assertEqual(tr.source, "generated")
            self.assertIsNone(tr.sidecar_path)
            self.assertTrue(tr.processed)
            self.assertTrue((self.root / "tone.vidac.ja.srt").exists())
        self.assertTrue(orig.exists() and trans.exists())
        # 重新打开（不重建）也不会把旧文件当用户字幕
        tr = Transcriber(self.video, 0, FakeBackend, model="fake", chunk_seconds=30.0)
        tr.run()
        self.assertEqual(tr.source, "cache")

    def test_f10_discard_after_stop_touches_nothing(self):
        now = time.time()
        self._legacy_files(-100)
        dur = media.probe_duration(self.video)
        folder, base = self._legacy_progress("tone.ja.srt", dur, [0, 1, 2], now)
        tr = Transcriber(self.video, 0, FakeBackend, model="fake", chunk_seconds=30.0, rebuild=True)
        tr.stop()
        tr._discard_cache()
        prog = srt.load_progress(srt.progress_path(folder, base))
        self.assertEqual(prog["srt"], "tone.ja.srt")

    def test_f03_resuming_a_partial_legacy_cache_keeps_the_legacy_file(self):
        now = time.time()
        orig, _trans, _ = self._legacy_files(-100)
        dur = media.probe_duration(self.video)
        self._legacy_progress("tone.ja.srt", dur, [0], now)
        tr = Transcriber(self.video, 0, FakeBackend, model="fake", chunk_seconds=30.0)
        tr.run()
        self.assertEqual(tr.processed, [1, 2])
        self.assertTrue(orig.exists())                        # 旧文件不删
        self.assertTrue((self.root / "tone.vidac.ja.srt").exists())
        self.assertEqual(srt.load_progress(tr.progress_path)["srt"], "tone.vidac.ja.srt")

    def test_f03_own_files_and_migrate_leave_legacy_files_alone(self):
        with tempfile.TemporaryDirectory() as d:
            src, dst = Path(d) / "a", Path(d) / "b"
            src.mkdir()
            legacy = src / "m.en.srt"
            legacy.write_text("1\n00:00:00,000 --> 00:00:01,000\nhi\n", encoding="utf-8")
            srt.save_progress(srt.progress_path(src, "m"), {"language": "en", "srt": "m.en.srt",
                                                            "done": [0], "total": 1})
            self.assertEqual(srt.own_files(src, "m"), [])
            self.assertTrue(srt.migrate_cache((src, "m"), (dst, "m")))
            self.assertTrue(legacy.exists())              # 只复制，源文件还在
            moved = srt.load_progress(srt.progress_path(dst, "m"))
            self.assertEqual(moved["srt"], "m.vidac.en.srt")
            self.assertTrue((dst / "m.vidac.en.srt").exists())
            srt.clear_cache(src, "m")
            self.assertTrue(legacy.exists())


# ---------------------------------------------------------------- f04 / f07
class SameLanguageTests(AppCase):
    def test_f04_f07_translation_never_shares_the_original_file(self):
        folder, base = srt.cache_layout(self.video, 0)
        for lang in ("en", "ja", "zh"):
            self.assertNotEqual(srt.translation_srt_path(folder, base, lang),
                                srt.original_srt_path(folder, base, lang))
        self.assertEqual(srt.own_files(folder, base), [])

    def test_f04_f07_restarting_workers_does_not_turn_the_transcript_into_translations(self):
        app = self.make_app(target_lang="ja")     # 假后端识别出的语言就是 ja
        client = mock.Mock(model="m", base_url="x")
        with mock.patch("vidac.player.make_client", return_value=client):
            ts = self.open(app)
            self.assertTrue(wait_for(lambda: app.translator.status == "same_lang"))
            original = ts.srt_path
            self.assertTrue(original.exists())
            text_before = original.read_text(encoding="utf-8")
            for _ in range(2):
                app.retranslate = True               # 最坏的情况：重翻译也不会删原文
                app._restart_workers()
                ts = app.transcriber
                self.assertTrue(wait_for(lambda: ts.loaded.is_set()))
                self.assertTrue(wait_for(lambda: app.translator.status == "same_lang"))
            self.assertTrue(original.exists())
            self.assertEqual(original.read_text(encoding="utf-8"), text_before)
            self.assertTrue(all(c.translation is None for c in ts.store.snapshot()))
            files = app._state()["files"]
            self.assertEqual(files, [str(original.absolute())])

    def test_f04_translator_refuses_to_use_the_transcripts_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "m.vidac.en.srt"
            srt.atomic_write(path, srt.render_srt([Cue(0, 1, "Hello there")]))
            store = SubtitleStore()
            store.add([Cue(0, 1, "Hello there")])
            tr = Translator(store, FakeTr("en", path), FakeClient(_echo), "en", Glossary(), path,
                            retranslate=True)
            tr._stop_event.set()                   # 只测同步的部分
            tr._load_translations()
            self.assertIsNone(store.snapshot()[0].translation)
            store.snapshot()[0].translation = "x"
            tr._stop_event.clear()
            tr._persist()
            self.assertIn("Hello there", path.read_text(encoding="utf-8"))
            tr._stop_event.set()

    def test_f04_bilingual_does_not_double_identical_lines(self):
        c = Cue(0, 1, "Hello there", translation="Hello there")
        self.assertEqual([ln.text for ln in cue_layout([c], "bilingual")], ["Hello there"])
        self.assertEqual([ln.text for ln in cue_layout([c], "trans")], ["Hello there"])

    def test_f04_old_wip_translation_cache_is_still_read_when_it_is_really_a_translation(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            wip = srt.wip_translation_srt_path(folder, "m", "zh")
            srt.atomic_write(wip, srt.render_srt([Cue(0, 1, "旧版译文")]))
            store = SubtitleStore()
            store.add([Cue(0, 1, "こんにちは")])
            new = srt.translation_srt_path(folder, "m", "zh")
            tr = Translator(store, FakeTr("ja", folder / "m.vidac.ja.srt"), FakeClient(_echo), "zh",
                            Glossary(), new, wip_path=wip)
            tr._load_translations()
            self.assertEqual(store.snapshot()[0].translation, "旧版译文")
            # 同一个文件名其实是原文字幕（目标语言就是说的语言）：不能读
            store2 = SubtitleStore()
            store2.add([Cue(0, 1, "你好")])
            tr2 = Translator(store2, FakeTr("zh", wip), FakeClient(_echo), "zh", Glossary(), new,
                             wip_path=wip)
            tr2._load_translations()
            self.assertIsNone(store2.snapshot()[0].translation)


# ---------------------------------------------------------------- f06
class SameStemTests(AppCase):
    def test_f06_names_stay_plain_without_a_sibling(self):
        with tempfile.TemporaryDirectory() as d:
            v = Path(d) / "movie.mkv"
            v.write_bytes(b"")
            self.assertEqual(srt.cache_layout(v, 0)[1], "movie")

    def test_f06_same_stem_videos_get_different_bases_and_old_cache_is_not_claimed(self):
        with tempfile.TemporaryDirectory() as d:
            a, b = Path(d) / "movie.mkv", Path(d) / "movie.mp4"
            a.write_bytes(b"")
            b.write_bytes(b"")
            self.assertEqual(srt.cache_layout(a, 0)[1], "movie.mkv")
            self.assertEqual(srt.cache_layout(b, 0)[1], "movie.mp4")
            self.assertEqual(srt.cache_layout(b, 1)[1], "movie.mp4.a2")
            # 老缓存（没有记名字）：有同名视频时谁也不认领，也不会被删
            old = Path(d) / "movie.vidac.json"
            srt.save_progress(old, {"duration": 3600, "done": [0]})
            self.assertEqual(srt.cache_layout(a, 0)[1], "movie.mkv")
            self.assertEqual(srt.cache_layout(b, 0)[1], "movie.mp4")
            self.assertTrue(old.exists())

    def test_f06_recorded_owner_keeps_its_cache_and_the_other_video_gets_its_own(self):
        with tempfile.TemporaryDirectory() as d:
            a, b = Path(d) / "movie.mkv", Path(d) / "movie.mp4"
            a.write_bytes(b"")
            b.write_bytes(b"")
            srt.save_progress(Path(d) / "movie.vidac.json", {"video": "movie.mkv", "done": [0]})
            self.assertEqual(srt.cache_layout(a, 0)[1], "movie")
            self.assertEqual(srt.cache_layout(b, 0)[1], "movie.mp4")

    def test_f06_opening_the_other_cut_does_not_delete_the_first_videos_subtitles(self):
        first = Transcriber(self.video, 0, FakeBackend, model="fake", chunk_seconds=30.0, rebuild=True)
        first.run()
        self.assertEqual(srt.load_progress(first.progress_path)["video"], "tone.mp4")
        mine = [p for p in self.root.glob("tone.vidac.*")]
        self.assertTrue(mine)
        before = {p: p.read_bytes() for p in mine}
        other = self.root / "tone.mkv"
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                        "sine=frequency=330:duration=20", "-c:a", "aac", str(other)], check=True)
        second = Transcriber(other, 0, FakeBackend, model="fake", chunk_seconds=30.0)
        self.assertEqual(second.base, "tone.mkv")
        second.run()
        self.assertTrue(second.complete)
        self.assertEqual({p: p.read_bytes() for p in mine if p.exists()}, before)
        self.assertEqual(len([p for p in mine if p.exists()]), len(mine))
        self.assertTrue(second.srt_path.name.startswith("tone.mkv.vidac."))


# ---------------------------------------------------------------- f08
class StaleTranslatorTests(unittest.TestCase):
    def test_f08_stopped_line_translator_stops_calling_the_server(self):
        stop = threading.Event()
        client = FakeClient(lambda m: (stop.set(), "garbage")[1])   # 永远答不对，第一次调用后就停
        lt = LineTranslator(client, "ja", "zh", Glossary(), should_stop=stop.is_set)
        with self.assertRaises(TranslationCancelled):
            lt.translate_lines([f"line {i}" for i in range(25)])
        self.assertEqual(client.calls, 1)

    def test_f08_work_once_after_stop_sends_nothing_and_marks_nothing_failed(self):
        store = SubtitleStore()
        store.add([Cue(0, 1, "今日は晴れです")])
        client = FakeClient(_echo)
        tr = Translator(store, FakeTr(), client, "zh", Glossary(), Path(tempfile.gettempdir()) / "x.srt")
        tr._stop_event.set()
        self.assertFalse(tr._work_once("ja"))
        self.assertEqual(client.calls, 0)
        self.assertEqual(tr.failed, 0)


# ---------------------------------------------------------------- f09
class OneBackendAtATimeTests(AppCase):
    def _tr(self, factory, name):
        return Transcriber(self.video, 0, factory, model="fake", chunk_seconds=30.0, rebuild=True,
                           cache_dir=self.root / name)

    def test_f09_transcribers_never_run_inference_at_the_same_time(self):
        state = {"active": 0, "max": 0}
        lock = threading.Lock()

        class Slow(FakeBackend):
            def transcribe(self, *a, **kw):
                with lock:
                    state["active"] += 1
                    state["max"] = max(state["max"], state["active"])
                time.sleep(0.05)
                try:
                    return super().transcribe(*a, **kw)
                finally:
                    with lock:
                        state["active"] -= 1

        threads = [self._tr(Slow, f"c{i}") for i in range(3)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(30)
        self.assertEqual(state["max"], 1)
        self.assertTrue(all(t.complete for t in threads))

    def test_f09_a_waiting_transcriber_can_be_stopped_without_loading_a_model(self):
        gate, started, made = threading.Event(), threading.Event(), []

        class Blocking(FakeBackend):
            def transcribe(self, *a, **kw):
                started.set()
                gate.wait(10)
                return super().transcribe(*a, **kw)

        first = self._tr(Blocking, "a")
        first.start()
        self.assertTrue(started.wait(10))
        second = self._tr(lambda: made.append(1) or FakeBackend(), "b")
        second.start()
        time.sleep(0.6)
        self.assertEqual(made, [])               # 排队中：没有创建第二个模型
        second.stop()
        second.join(5)
        self.assertFalse(second.is_alive())
        self.assertEqual(made, [])
        first.stop()
        gate.set()
        first.join(10)
        self.assertFalse(first.is_alive())


# ---------------------------------------------------------------- f10
class WriteFenceTests(AppCase):
    def test_f10_stop_waits_for_a_write_in_flight_and_blocks_later_writes(self):
        tr = Transcriber(self.video, 0, FakeBackend, model="fake", rebuild=True)
        tr._persist_lock.acquire()               # 假装正在写盘
        t = threading.Thread(target=tr.stop)
        t.start()
        time.sleep(0.2)
        self.assertTrue(t.is_alive())            # stop() 在等
        tr._persist_lock.release()
        t.join(5)
        self.assertFalse(t.is_alive())
        tr._persist()
        self.assertFalse(tr.progress_path.exists())

    def test_f10_translator_stop_is_also_a_write_fence(self):
        store = SubtitleStore()
        store.add([Cue(0, 1, "a", translation="b")])
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "m.vidac.tr.zh.srt"
            tr = Translator(store, FakeTr(), FakeClient(_echo), "zh", Glossary(), path)
            tr._persist_lock.acquire()
            t = threading.Thread(target=tr.stop)
            t.start()
            time.sleep(0.2)
            self.assertTrue(t.is_alive())
            tr._persist_lock.release()
            t.join(5)
            tr._persist()
            self.assertFalse(path.exists())

    def test_f10_location_change_moves_files_and_leaves_nothing_behind(self):
        app = self.make_app(no_translate=True)
        ts = self.open(app)
        old_folder = ts.folder
        app.apply_setting("subtitle_location", "library")
        self.assertTrue(wait_for(lambda: app.transcriber is not None and app.transcriber.complete))
        self.assertEqual(list(old_folder.glob("tone.vidac.*")), [])
        self.assertTrue(list((Path(self._home.name) / "subtitles").glob("*.vidac.json")))


# ---------------------------------------------------------------- f12 / f18
class ModelDownloadFixTests(unittest.TestCase):
    def _download(self, on_fetch):
        def download(repo, **kw):
            if kw.get("local_files_only"):
                raise RuntimeError("not cached")
            if kw.get("dry_run"):
                return []
            return on_fetch(repo, kw)
        return download

    def test_f12_xet_is_disabled_by_default(self):
        self.assertIn("HF_HUB_DISABLE_XET", os.environ)

    def test_f12_cancel_works_even_when_the_download_never_calls_the_progress_bar(self):
        release = threading.Event()
        progress = ModelProgress()
        result = {}

        def stuck(repo, kw):
            release.wait(10)      # 像被 hf_xet 吞掉异常的下载：永远不会碰进度条
            return "/cache/x"

        def run():
            try:
                resolve_mlx_repo(["a/b"], self._download(stuck), progress)
            except BaseException as exc:  # noqa: BLE001
                result["exc"] = exc

        t = threading.Thread(target=run)
        t.start()
        time.sleep(0.4)
        progress.cancelled.set()
        t.join(3)
        self.assertFalse(t.is_alive())
        self.assertIsInstance(result.get("exc"), DownloadCancelled)
        release.set()

    def test_f12_cancel_after_a_download_that_finished_anyway(self):
        progress = ModelProgress()

        def finishes(repo, kw):
            progress.cancelled.set()
            return "/cache/x"

        with self.assertRaises(DownloadCancelled):
            resolve_mlx_repo(["a/b"], self._download(finishes), progress)

    def test_f12_successful_download_still_returns_the_path(self):
        self.assertEqual(resolve_mlx_repo(["a/b"], self._download(lambda r, kw: "/cache/x"),
                                          ModelProgress()), "/cache/x")

    def test_f18_certificate_failure_is_not_reported_as_offline(self):
        class ConnectError(Exception):
            pass

        calls = []

        def fail(repo, kw):
            calls.append(repo)
            try:
                raise ssl.SSLCertVerificationError("self signed certificate")
            except ssl.SSLCertVerificationError as exc:
                raise ConnectError("connect failed") from exc

        with self.assertRaises(ModelError) as cm:
            resolve_mlx_repo(["a/one", "a/two"], self._download(fail), ModelProgress())
        self.assertEqual(cm.exception.code, "model-download")
        self.assertNotIn("offline", str(cm.exception).split("(Tried")[0].lower())
        self.assertIn("proxy", str(cm.exception).lower())
        self.assertEqual(calls, ["a/one"])   # 第一个仓库名就被证书挡了，不再试第二个

    def test_f18_proxy_error_is_not_reported_as_offline_and_stops_the_candidate_loop(self):
        class ProxyError(Exception):
            pass

        tried = []

        def download(repo, **kw):
            if kw.get("local_files_only"):
                raise RuntimeError("not cached")
            tried.append(repo)
            raise ProxyError("407 proxy authentication required")

        with self.assertRaises(ModelError) as cm:
            resolve_mlx_repo(["a/one", "a/two"], download, ModelProgress())
        self.assertEqual(cm.exception.code, "model-download")
        self.assertEqual(tried, ["a/one"])

    def test_f18_plain_connection_failure_is_still_offline(self):
        class ConnectError(Exception):
            pass

        def download(repo, **kw):
            if kw.get("local_files_only"):
                raise RuntimeError("not cached")
            raise ConnectError("no route to host")

        with self.assertRaises(ModelError) as cm:
            resolve_mlx_repo(["a/one"], download, ModelProgress())
        self.assertEqual(cm.exception.code, "offline")


# ---------------------------------------------------------------- f13
class ChineseScriptReasonTests(unittest.TestCase):
    def _reason(self, spoken, target):
        out = translation_state({"translate": True, "enabled": True, "target_lang": target},
                                FakeTs(language=spoken), fake_translator_state(status="same_lang"), True)
        self.assertEqual(out["state"], "off")
        return out["reason"]

    def test_f13_script_difference_gets_an_honest_reason(self):
        reason = self._reason("zh", "zh-tw")
        self.assertIn("does not convert", reason)
        self.assertNotIn("Simplified Chinese, so", reason)
        self.assertIn("does not convert", self._reason("zh-tw", "zh"))

    def test_f13_same_chinese_target_names_the_language_without_a_script(self):
        reason = self._reason("zh", "zh")
        self.assertIn("already in Chinese", reason)
        self.assertNotIn("Simplified", reason)

    def test_f13_other_languages_unchanged(self):
        self.assertIn("already in Japanese", self._reason("ja", "ja"))


# ---------------------------------------------------------------- f14
class LocaleTests(unittest.TestCase):
    def setUp(self):
        settings_mod.default_target_lang.cache_clear()
        self.addCleanup(settings_mod.default_target_lang.cache_clear)

    def test_f14_script_tag_beats_region(self):
        t = settings_mod.target_for_locale
        self.assertEqual(t("zh-Hans-HK"), "zh")
        self.assertEqual(t("zh-Hans-MO"), "zh")
        self.assertEqual(t("zh-Hant-CN"), "zh-tw")
        self.assertEqual(t("zh-HK"), "zh-tw")
        self.assertEqual(t("zh-CN"), "zh")
        self.assertEqual(t("yue-Hant-HK"), "zh-tw")
        self.assertEqual(t("yue-Hans-CN"), "zh")

    def test_f14_first_supported_system_language_is_used(self):
        env = {k: v for k, v in os.environ.items() if k != "VIDAC_TARGET_LANG_DEFAULT"}
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(settings_mod, "_system_languages", return_value=["sv-SE", "ja-JP", "en"]):
            self.assertEqual(settings_mod.default_target_lang(), "ja")
        settings_mod.default_target_lang.cache_clear()
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(settings_mod, "_system_languages", return_value=["sv-SE", "fi"]):
            self.assertEqual(settings_mod.default_target_lang(), "en")


# ---------------------------------------------------------------- f15
class SlowServerTests(unittest.TestCase):
    def test_f15_read_timeout_is_a_timeout_not_unreachable(self):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(5)
        self.addCleanup(srv.close)
        url = f"http://127.0.0.1:{srv.getsockname()[1]}/v1"
        client = TranslateClient(url, "m", timeout=0.4)
        with self.assertRaises(TranslateTimeout) as cm:
            client.chat([{"role": "user", "content": "hi"}])
        self.assertNotIn("cannot reach", str(cm.exception))
        self.assertIn("too slowly", str(cm.exception))
        with self.assertRaises(TranslateError) as cm2:   # 问模型列表超时：照旧当作连不上
            client.list_models(timeout=0.3)
        self.assertNotIsInstance(cm2.exception, TranslateTimeout)
        self.assertIn("cannot reach", str(cm2.exception))

    def test_f15_apple_timeout_is_a_timeout_too(self):
        self.assertTrue(issubclass(TranslateTimeout, TranslateError))
        with tempfile.TemporaryDirectory() as d:
            helper = Path(d) / "h"
            helper.write_text("#!/bin/sh\nsleep 5\n")
            helper.chmod(0o755)
            with self.assertRaises(TranslateTimeout):
                AppleClient(helper, timeout=0.3).chat([{"role": "user", "content": "x"}])

    def test_f15_timed_out_batch_is_halved_instead_of_failing(self):
        def fn(messages):
            lines = []
            import re
            for ln in messages[-1]["content"].split("严格输出", 1)[-1].splitlines():
                m = re.match(r"^(\d+): (.*)$", ln)
                if m:
                    lines.append(m.group(2))
            if len(lines) > 3:
                raise TranslateTimeout("slow")
            return _echo(messages)

        client = FakeClient(fn)
        lt = LineTranslator(client, "ja", "zh", Glossary())
        out = lt.translate_lines([f"l{i}" for i in range(8)])
        self.assertEqual(out, [f"译l{i}" for i in range(8)])
        self.assertTrue(lt.slow_seen)
        self.assertEqual(lt.timed_out, set())

    def test_f15_unreachable_server_is_still_raised_at_once(self):
        def fn(messages):
            raise TranslateError("connection refused")

        client = FakeClient(fn)
        with self.assertRaises(TranslateError):
            LineTranslator(client, "ja", "zh", Glossary()).translate_lines(["a", "b", "c", "d"])
        self.assertEqual(client.calls, 1)

    def test_f15_single_line_timeouts_never_mark_the_service_offline_and_give_up_after_two(self):
        def fn(messages):
            raise TranslateTimeout("slow")

        store = SubtitleStore()
        store.add([Cue(0, 1, "今日は晴れです")])
        tr = Translator(store, FakeTr(), FakeClient(fn), "zh", Glossary(),
                        Path(tempfile.gettempdir()) / "slow.srt")
        tr._service_ok = True
        tr.status = "ok"
        tr._work_once("ja")
        self.assertEqual(tr.status, "ok")          # 没有标成 offline
        self.assertEqual(tr.failed, 0)             # 第一次超时：下次再试
        self.assertTrue(tr.slow)
        tr._work_once("ja")
        self.assertEqual(tr.failed, 1)             # 第二次：放弃这一行
        self.assertFalse(tr._service_ok is False)
        state = translation_state({"translate": True, "enabled": True, "target_lang": "zh"},
                                  FakeTs(language="ja"),
                                  fake_translator_state(status="ok", translated=0, total=3, slow=True),
                                  True)
        self.assertEqual(state["state"], "working")
        self.assertIn("slowly", state["reason"])


# ---------------------------------------------------------------- f16
class HallucinationFilterTests(unittest.TestCase):
    def seg(self, text, nsp=0.0, lp=-0.3):
        return Segment(0.0, 3.0, text, nsp, lp, 1.0)

    def test_f16_real_speech_containing_a_phrase_is_kept(self):
        for text in ["구독과 좋아요 눌러주세요 그리고 알림 설정도 해주세요 오늘 영상은 여기까지입니다",
                     "今天就到这里 感谢观看 我们下期再见",
                     "这个字幕由我们自己翻译",
                     "Thanks for watching the match with me today, it was a great game"]:
            self.assertFalse(is_hallucination_phrase(text), text)
            self.assertTrue(keep_segment(self.seg(text)), text)

    def test_f16_segments_that_are_only_the_phrase_are_still_dropped(self):
        for text in ["感谢观看", "谢谢观看！", "시청해 주셔서 감사합니다", "Thanks for watching!",
                     "Subtitles by the Amara.org community", "ご視聴ありがとうございました"]:
            self.assertTrue(is_hallucination_phrase(text), text)
            self.assertFalse(keep_segment(self.seg(text)), text)

    def test_f16_phrase_plus_content_is_dropped_only_when_it_also_looks_like_non_speech(self):
        text = "今天就到这里 感谢观看 我们下期再见"
        self.assertFalse(keep_segment(self.seg(text, nsp=0.5)))
        self.assertFalse(keep_segment(self.seg(text, lp=-1.4)))


# ---------------------------------------------------------------- f17
class SidecarLanguageTests(AppCase):
    EN = [
        "I don't think that you have been listening to what I said.",
        "We are going to the station and then we will take the train.",
        "It was the best day of my life and I could not stop smiling.",
        "What are you doing here with all of this stuff in your hands?",
        "This is not the way that things are supposed to work for us.",
        "But they said that the road was closed because of the storm.",
    ]

    @staticmethod
    def _srt(lines):
        return srt.render_srt([Cue(i * 5.0, i * 5.0 + 4, t) for i, t in enumerate(lines)])

    def test_f17_guess_language_by_script_and_stopwords(self):
        self.assertEqual(guess_language(self.EN), "en")
        self.assertEqual(guess_language(["今日はとても天気がいいので散歩に行きましょう"]), "ja")
        self.assertEqual(guess_language(["我们今天去公园散步然后一起吃晚饭吧"]), "zh")
        self.assertEqual(guess_language(["오늘은 날씨가 좋아서 공원에 산책하러 갑니다"]), "ko")
        self.assertEqual(guess_language(["Сегодня очень хорошая погода для прогулки"]), "ru")
        self.assertIsNone(guess_language(["Hello"]))            # 太短，不乱猜
        self.assertIsNone(guess_language(["Xyzzy plugh frotz gnusto rezrov"] * 10))

    def test_f17_plain_srt_gets_a_language_and_is_not_translated_into_itself(self):
        (self.root / "tone.srt").write_text(self._srt(self.EN), encoding="utf-8")
        app = self.make_app(target_lang="en")
        client = mock.Mock(model="m", base_url="x")
        with mock.patch("vidac.player.make_client", return_value=client):
            ts = self.open(app)
            self.assertEqual(ts.source, "sidecar")
            self.assertEqual(ts.language, "en")
            self.assertTrue(wait_for(lambda: app.translator.status == "same_lang"))
            self.assertEqual(app._state()["translation"]["state"], "off")
        client.list_models.assert_not_called()
        client.chat.assert_not_called()


# ---------------------------------------------------------------- f19
class ResumeFixTests(AppCase):
    def _bare(self, now, keep_for=None, skip=False):
        app = App.__new__(App)
        app.file_ready = False
        app.video = Path("/v.mp4")
        app._skip_initial_resume = skip
        app._keep_position_for = keep_for
        app.resumed_from = None
        app.last_pos = None
        app.player = mock.Mock(duration=5000, time_pos=now)
        app.positions = mock.Mock()
        app.positions.get.return_value = 1200.0
        return app

    def test_f19_path_scoped_flag_only_protects_that_file(self):
        mine = self._bare(1500.0, keep_for="/v.mp4")
        mine._on_file_loaded()
        mine.player.seek.assert_not_called()
        other = self._bare(0.2, keep_for="/something/else.mp4")
        other._on_file_loaded()
        other.player.seek.assert_called_once_with(1200.0, reference="absolute")

    def test_f19_flag_is_consumed_by_the_first_file(self):
        app = self._bare(1500.0, keep_for="/v.mp4")
        app._on_file_loaded()
        self.assertIsNone(app._keep_position_for)

    def test_f19_legacy_flag_does_not_stop_a_freshly_opened_video_from_resuming(self):
        fresh = self._bare(0.4, skip=True)
        fresh._on_file_loaded()
        fresh.player.seek.assert_called_once_with(1200.0, reference="absolute")
        midway = self._bare(754.0, skip=True)
        midway._on_file_loaded()
        midway.player.seek.assert_not_called()

    def test_f19_saved_position_survives_until_playback_has_moved(self):
        app = self.make_app(no_translate=True)
        app.positions.save(self.video.resolve(), 40.0, 65.0)
        app._open(str(self.video))
        app.file_ready = True
        app.last_pos = 1.0                      # 没能恢复，从头播放
        app._save_position(force=True)
        self.assertEqual(app.positions.get(self.video.resolve()), 40.0)
        app.last_pos = 2.0
        app._save_position(force=True)
        self.assertEqual(app.positions.get(self.video.resolve()), 40.0)
        app.last_pos = 12.0                     # 真的看了一会儿：记录可以更新
        app._save_position(force=True)
        self.assertEqual(app.positions.get(self.video.resolve()), 12.0)

    def test_f19_resumed_position_is_saved_normally(self):
        app = self.make_app(no_translate=True)
        app.positions.save(self.video.resolve(), 40.0, 65.0)
        app._open(str(self.video))
        app.file_ready = True
        app.last_pos = 41.0
        app._save_position(force=True)
        self.assertEqual(app.positions.get(self.video.resolve()), 41.0)


# ---------------------------------------------------------------- f20
class MultiLineTextTests(unittest.TestCase):
    def test_f20_newlines_never_reach_the_ass_text(self):
        for out in (status_ass(["Subtitles unavailable: could not read" + NL + "moov atom not found"]),
                    subtitle_ass([Line("第一行" + NL + "第二行")], 1.0),
                    menu_ass([("Label", "a" + NL + "b")], 0, ["foot" + NL + "note"])
                    .split(NL)[1]):
            self.assertNotIn(NL, out)
        self.assertEqual(status_ass(["a\r\nb\rc"]).count(NL), 0)

    def test_f20_status_text_is_one_event(self):
        text = status_ass(["x\ny", "z"])
        self.assertEqual(len(text.split(NL)), 1)
        self.assertIn("x y", text)

    def test_f20_media_errors_are_single_line(self):
        proc = subprocess.CompletedProcess([], 1, stdout="", stderr="line one\n  line two\n")
        with mock.patch("vidac.media._run", return_value=proc):
            with self.assertRaises(media.MediaError) as cm:
                media.probe_audio_tracks(Path("/x.mp4"))
        self.assertNotIn(NL, str(cm.exception))
        self.assertIn("line one line two", str(cm.exception))


# ---------------------------------------------------------------- f21
class FontTests(unittest.TestCase):
    def test_f21_chinese_with_katakana_marks_keeps_the_chinese_font(self):
        self.assertEqual(font_for("约翰・史密斯说", "zh"), "PingFang SC")
        self.assertEqual(font_for("约翰・史密斯说", None), "PingFang SC")
        self.assertEqual(font_for("コーヒー", None), "Hiragino Sans")
        self.assertEqual(font_for("ー・", None), "Helvetica Neue")

    def test_f21_cjk_language_decides_the_font(self):
        self.assertEqual(font_for("漢字だけ", "ja"), "Hiragino Sans")
        self.assertEqual(font_for("漢字だけ", "zh-tw"), "PingFang TC")
        self.assertEqual(font_for("你好", "zh-TW"), "PingFang TC")
        self.assertEqual(font_for("Hello", "ja"), "Helvetica Neue")

    def test_f21_one_cue_uses_one_font_across_wrapped_rows(self):
        text = "ありがとうございますこんにちは" + "世界中" * 12   # 第一行有假名，后面几行只有汉字
        ass = subtitle_ass([Line(text, lang=None)], 1.0)
        fonts = {part.split("\\fs")[0] for part in ass.split("\\fn")[1:]}
        self.assertEqual(len(fonts), 1)


if __name__ == "__main__":
    unittest.main()

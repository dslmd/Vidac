"""单元测试。不需要 mpv 窗口和 mlx，只需要 numpy 和 ffmpeg（部分用例需要）。

运行：VIDAC_SAMPLES=<素材目录> python -m unittest discover -s tests -v
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from argparse import Namespace
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from vidac import ipc, media, srt  # noqa: E402
from vidac.asr.base import Segment  # noqa: E402
from vidac.asr.fake_backend import FakeBackend  # noqa: E402
from vidac.filters import (  # noqa: E402
    clean_cues, is_filler, is_hallucination_phrase, keep_segment, normalize, voiced_fraction,
)
from vidac.positions import PositionStore  # noqa: E402
from vidac.player import cue_lines, subtitle_ass  # noqa: E402
from vidac.settings import DEFAULTS, Settings  # noqa: E402
from vidac.srt import Cue  # noqa: E402
from vidac.transcriber import SubtitleStore, Transcriber  # noqa: E402
from vidac.translate import (  # noqa: E402
    BATCH_SIZE, Glossary, LineTranslator, TranslateClient, TranslateError, Translator,
    model_present, parse_numbered, same_language,
)


class SrtTests(unittest.TestCase):
    def test_fmt_time(self):
        self.assertEqual(srt.fmt_time(3723.5), "01:02:03,500")
        self.assertEqual(srt.fmt_time(0), "00:00:00,000")

    def test_roundtrip(self):
        cues = [Cue(1.0, 2.5, "今日は晴れです"), Cue(3.0, 4.0, "很好")]
        parsed = srt.parse_srt(srt.render_srt(cues))
        self.assertEqual(len(parsed), 2)
        self.assertAlmostEqual(parsed[0].start, 1.0)
        self.assertAlmostEqual(parsed[0].end, 2.5)
        self.assertEqual(parsed[1].text, "很好")

    def test_parse_crlf_and_bad_blocks(self):
        text = "1\r\n00:00:01,000 --> 00:00:02,000\r\nhello\r\n\r\nbroken block\r\n\r\n"
        cues = srt.parse_srt(text)
        self.assertEqual([c.text for c in cues], ["hello"])


class CacheNamingTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.video = self.dir / "movie.ts"
        self.video.write_bytes(b"")

    def tearDown(self):
        self._tmp.cleanup()

    def test_track_stem(self):
        self.assertEqual(srt.track_stem(self.video, 0), "movie")
        self.assertEqual(srt.track_stem(self.video, 1), "movie.a2")

    def test_file_names(self):
        folder, base = srt.cache_layout(self.video, 1)
        self.assertEqual(folder, self.dir)
        self.assertEqual(srt.original_srt_path(folder, base, "ja").name, "movie.a2.vidac.ja.srt")
        self.assertEqual(srt.original_srt_path(folder, base, None).name, "movie.a2.vidac.und.srt")
        self.assertEqual(srt.translation_srt_path(folder, base, "zh").name, "movie.a2.vidac.tr.zh.srt")
        self.assertEqual(srt.progress_path(folder, base).name, "movie.a2.vidac.json")

    def test_unwritable_folder_falls_back_to_cache_dir(self):
        cache = self.dir / "cache"
        folder, base = srt.cache_layout(self.video, 0, cache_dir=cache)
        self.assertEqual(folder, cache)
        self.assertTrue(base.endswith("-movie"))

    def test_user_subtitle_is_complete_without_progress(self):
        (self.dir / "movie.srt").write_text(
            "1\n00:00:00,000 --> 00:00:04,000\nhello\n", encoding="utf-8")
        tr = Transcriber(self.video, 0, lambda: None, model="base")
        tr.total = 2
        tr._load_cache()
        self.assertEqual(tr._done, {0, 1})
        self.assertEqual([c.text for c in tr.store.snapshot()], ["hello"])
        self.assertFalse(tr.progress_path.exists())  # 用户字幕不写进度文件

    def test_language_specific_user_subtitle_preferred(self):
        (self.dir / "movie.srt").write_text(
            "1\n00:00:00,000 --> 00:00:01,000\nplain\n", encoding="utf-8")
        (self.dir / "movie.ja.srt").write_text(
            "1\n00:00:00,000 --> 00:00:01,000\n日本語\n", encoding="utf-8")
        tr = Transcriber(self.video, 0, lambda: None, model="base", language="ja")
        tr.total = 1
        tr._load_cache()
        self.assertEqual([c.text for c in tr.store.snapshot()], ["日本語"])

    def test_progress_file_points_to_srt_name(self):
        srt.save_progress(self.dir / "movie.vidac.json", {
            "model": "base", "language": "ja", "srt": "movie.ja.srt", "done": [0], "total": 2})
        (self.dir / "movie.ja.srt").write_text(
            "1\n00:00:00,000 --> 00:00:01,000\nこんにちは\n", encoding="utf-8")
        tr = Transcriber(self.video, 0, lambda: None, model="base")
        tr.total = 2
        tr._load_cache()
        self.assertEqual(tr._done, {0})
        self.assertEqual(tr.language, "ja")
        self.assertEqual(tr.srt_path.name, "movie.vidac.ja.srt")  # 新的写入用新名字
        self.assertTrue(tr.legacy_cache)                          # 旧名字的缓存仍然读得到

    def test_clear_cache_removes_everything(self):
        folder, base = srt.cache_layout(self.video, 0)
        for p in [srt.progress_path(folder, base), srt.original_srt_path(folder, base, None),
                  srt.translation_srt_path(folder, base, "zh")]:
            p.write_text("x", encoding="utf-8")
        srt.clear_cache(folder, base, target="zh")
        self.assertFalse(srt.translation_srt_path(folder, base, "zh").exists())
        self.assertFalse(srt.progress_path(folder, base).exists())


class FilterTests(unittest.TestCase):
    def seg(self, text, nsp=0.0, lp=0.0, cr=1.0):
        return Segment(0.0, 1.0, text, nsp, lp, cr)

    def test_empty_and_symbol_only_dropped(self):
        self.assertFalse(keep_segment(self.seg("  ")))
        self.assertFalse(keep_segment(self.seg("♪ ♪")))
        self.assertFalse(keep_segment(self.seg("。。。")))

    def test_silence_hallucination_dropped(self):
        self.assertFalse(keep_segment(self.seg("何か", nsp=0.9, lp=-1.5)))
        self.assertTrue(keep_segment(self.seg("何か", nsp=0.9, lp=-0.2)))

    def test_repetition_loop_dropped(self):
        self.assertFalse(keep_segment(self.seg("ああああ", cr=3.1)))

    def test_known_phrases_dropped(self):
        for text in ["ご視聴ありがとうございました",
                     "ご視聴ありがとうございます",
                     "ご覧いただきありがとうございました",
                     "最後までご視聴ありがとうございました",
                     "ご清聴ありがとうございました"]:
            self.assertTrue(is_hallucination_phrase(text), text)
            self.assertFalse(keep_segment(self.seg(text)), text)

    def test_phrase_match_ignores_punctuation(self):
        self.assertTrue(is_hallucination_phrase("ご視聴、ありがとうございました！"))

    def test_voiced_fraction(self):
        silence = np.zeros(16000, dtype=np.float32)
        tone = (0.3 * np.sin(2 * np.pi * 440 * np.arange(16000) / 16000)).astype(np.float32)
        self.assertEqual(voiced_fraction(silence), 0.0)
        self.assertGreater(voiced_fraction(tone), 0.9)

    def test_filler_detection(self):
        for text in ["あ", "えっと", "えーと", "うーん", "はぁ", "ふぅ", "ああ", "嗯", "哈哈",
                     "um", "uh", "(息)", "[ため息]", "（咳払い）", "[音楽]", "(sighs)"]:
            self.assertTrue(is_filler(text), text)
        for text in ["はい", "今日は晴れです", "ok", "行きましょう"]:
            self.assertFalse(is_filler(text), text)

    def test_repeated_run_keeps_first_only(self):
        cues = [Cue(float(i), i + 0.9, "はい") for i in range(5)]
        out = clean_cues(cues)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0].start, 0.0)

    def test_three_repeats_untouched(self):
        cues = [Cue(float(i), i + 0.9, "はい。") for i in range(3)]
        out = clean_cues(cues)
        self.assertEqual(len(out), 3)

    def test_repeats_are_compared_after_normalize(self):
        cues = [Cue(0, 1, "はい!"), Cue(1, 2, "はい?"), Cue(2, 3, "はい"), Cue(3, 4, "はい。")]
        self.assertEqual(len(clean_cues(cues)), 1)

    def test_filler_run_merged(self):
        cues = [Cue(10, 11, "あ"), Cue(12, 13, "えー"), Cue(14, 15, "うん"),
                Cue(40, 41, "ありがとう")]
        out = clean_cues(cues)
        self.assertEqual(len(out), 2)
        self.assertEqual((out[0].start, out[0].end, out[0].text), (10, 15, "あ"))
        self.assertEqual(out[1].text, "ありがとう")

    def test_filler_gap_respected(self):
        cues = [Cue(10, 11, "あ"), Cue(20, 21, "あ")]
        self.assertEqual(len(clean_cues(cues)), 2)

    def test_clean_is_idempotent(self):
        cues = [Cue(0, 1, "はい")] * 6 + [Cue(10, 11, "あ"), Cue(12, 13, "ん"),
                                          Cue(30, 31, "今日は晴れです")]
        once = clean_cues(cues)
        twice = clean_cues(once)
        self.assertEqual([(c.start, c.end, c.text) for c in once],
                         [(c.start, c.end, c.text) for c in twice])

    def test_clean_keeps_translation_of_surviving_cues(self):
        c = Cue(5, 6, "今日は晴れです", translation="今天晴")
        self.assertEqual(clean_cues([c])[0].translation, "今天晴")


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / "settings.json"
        self._env = {k: os.environ.pop(k, None) for k in
                     ["VIDAC_MODEL", "VIDAC_LANG", "VIDAC_TRANSLATE_URL",
                      "VIDAC_TRANSLATE_MODEL", "VIDAC_TARGET_LANG"]}

    def tearDown(self):
        for k, v in self._env.items():
            if v is not None:
                os.environ[k] = v
            else:
                os.environ.pop(k, None)
        self._tmp.cleanup()

    def args(self, **kw):
        base = dict(model=None, language=None, translate_engine=None, translate_url=None, translate_model=None,
                    target_lang=None, display=None, font_scale=None, no_translate=False)
        base.update(kw)
        return Namespace(**base)

    def test_defaults(self):
        s = Settings.load(self.path)
        self.assertEqual(s.get("model"), "base")
        self.assertEqual(s.get("display_mode"), "bilingual")
        self.assertEqual(s.get_language(), None)
        self.assertEqual(set(DEFAULTS), {"model", "language", "translate", "target_lang",
                                         "translate_engine", "translate_url", "translate_model",
                                         "display_mode", "font_scale", "trackpad", "enabled",
                                         "delay", "subtitle_location"})
        self.assertIs(s.get("enabled"), True)
        self.assertEqual(s.get("delay"), 0.0)
        self.assertEqual(s.get("subtitle_location"), "beside")
        self.assertEqual(s.get("translate_engine"), "apple")
        self.assertIs(s.get("trackpad"), True)

    def test_trackpad_can_be_turned_off_in_file(self):
        self.path.write_text('{"trackpad": false}', encoding="utf-8")
        s = Settings.load(self.path)
        self.assertIs(s.get("trackpad"), False)

    def test_url_or_model_argument_implies_openai_engine(self):
        s = Settings.from_args(self.args(translate_url="http://localhost:1234/v1"), self.path)
        self.assertEqual(s.get("translate_engine"), "openai")
        s = Settings.from_args(self.args(), self.path)
        self.assertEqual(s.get("translate_engine"), "apple")
        s = Settings.from_args(self.args(translate_url="http://x/v1", translate_engine="apple"), self.path)
        self.assertEqual(s.get("translate_engine"), "apple")

    def test_priority_cli_over_env_over_file(self):
        self.path.write_text(json.dumps({"model": "small", "target_lang": "ja"}), encoding="utf-8")
        os.environ["VIDAC_MODEL"] = "medium"
        s = Settings.from_args(self.args(), path=self.path)
        self.assertEqual(s.get("model"), "medium")          # 环境变量 > 文件
        self.assertEqual(s.get("target_lang"), "ja")        # 文件 > 默认
        s = Settings.from_args(self.args(model="large-v3"), path=self.path)
        self.assertEqual(s.get("model"), "large-v3")        # 命令行 > 环境变量

    def test_menu_set_saves_and_drops_override(self):
        os.environ["VIDAC_TARGET_LANG"] = "en"
        s = Settings.from_args(self.args(), path=self.path)
        self.assertEqual(s.get("target_lang"), "en")
        s.set("target_lang", "zh-tw")
        self.assertEqual(s.get("target_lang"), "zh-tw")
        self.assertEqual(json.loads(self.path.read_text(encoding="utf-8"))["target_lang"], "zh-tw")
        s2 = Settings.load(self.path)
        self.assertEqual(s2.get("target_lang"), "zh-tw")

    def test_no_translate_flag_and_language_normalization(self):
        s = Settings.from_args(self.args(no_translate=True, language="auto"), path=self.path)
        self.assertFalse(s.get("translate"))
        s = Settings.from_args(self.args(language="JA"), path=self.path)
        self.assertEqual(s.get_language(), "ja")

    def test_bad_file_is_ignored(self):
        self.path.write_text("{not json", encoding="utf-8")
        self.assertEqual(Settings.load(self.path).get("model"), "base")


class GlossaryAndParseTests(unittest.TestCase):
    def test_glossary_parse_separators_and_comments(self):
        text = "# 注释\n\n天気 = 天气\nA => B\nC -> D\nE\tF\nG：H\n无分隔符的行\n"
        self.assertEqual(Glossary.parse(text),
                         {"天気": "天气", "A": "B", "C": "D", "E": "F", "G": "H"})

    def test_glossary_load_later_files_override(self):
        with tempfile.TemporaryDirectory() as d:
            a = Path(d) / "a.txt"
            b = Path(d) / "b.txt"
            a.write_text("x = 1\ny = 2\n", encoding="utf-8")
            b.write_text("x = 9\n", encoding="utf-8")
            g = Glossary.load([a, b, Path(d) / "missing.txt"])
            self.assertEqual(g.entries, {"x": "9", "y": "2"})

    def test_relevant_only_returns_terms_in_text(self):
        g = Glossary({"天気": "天气", "Whisper": "耳语模型"})
        self.assertEqual(g.relevant(["今日は天気がいい"]), {"天気": "天气"})
        self.assertEqual(g.relevant(["use whisper here"]), {"Whisper": "耳语模型"})

    def test_parse_numbered_accepts_good_output(self):
        self.assertEqual(parse_numbered("1: 一\n2: 二\n3：三", 3), ["一", "二", "三"])

    def test_parse_numbered_rejects_bad_output(self):
        self.assertIsNone(parse_numbered("1: 一\n3: 三", 3))        # 缺 2
        self.assertIsNone(parse_numbered("1: 一\n2: 二\n3: 三\n4: 四", 3))  # 多 4
        self.assertIsNone(parse_numbered("1: 一\n1: 再一\n2: 二", 2))      # 重复
        self.assertIsNone(parse_numbered("1: \n2: 二", 2))                 # 空译文

    def test_parse_numbered_single_line_without_number(self):
        self.assertEqual(parse_numbered("天气很好", 1), ["天气很好"])
        self.assertIsNone(parse_numbered("   ", 1))

    def test_same_language_and_model_presence(self):
        self.assertTrue(same_language("zh", "zh"))
        self.assertTrue(same_language("zh", "zh-tw"))
        self.assertFalse(same_language("ja", "zh"))
        self.assertTrue(model_present(["qwen2.5:7b"], "qwen2.5:7b"))
        self.assertTrue(model_present(["qwen2.5:7b"], "qwen2.5:7b:latest"))
        self.assertTrue(model_present(["qwen2.5:latest"], "qwen2.5"))
        self.assertFalse(model_present(["qwen2.5:3b"], "qwen2.5:7b"))


class FakeChatClient:
    """替代 TranslateClient：fn(messages) 返回模型输出。记录每次请求。"""

    def __init__(self, fn, model="fake-model"):
        self.fn = fn
        self.model = model
        self.calls = []

    def chat(self, messages):
        self.calls.append(messages)
        return self.fn(messages)


def _user_lines(messages) -> list[tuple[int, str]]:
    import re
    user = messages[-1]["content"]
    out = []
    after = user.split("严格输出", 1)[-1]
    for ln in after.splitlines():
        m = re.match(r"^(\d+): (.*)$", ln)
        if m:
            out.append((int(m.group(1)), m.group(2)))
    return out


def _echo_fn(messages):
    return "\n".join(f"{n}: 译{t}" for n, t in _user_lines(messages))


class LineTranslatorTests(unittest.TestCase):
    def test_success_single_request(self):
        client = FakeChatClient(_echo_fn)
        lt = LineTranslator(client, "ja", "zh", Glossary())
        self.assertEqual(lt.translate_lines(["A", "B"]), ["译A", "译B"])
        self.assertEqual(len(client.calls), 1)

    def test_retry_once_on_bad_count(self):
        state = {"n": 0}

        def flaky(messages):
            state["n"] += 1
            out = _echo_fn(messages)
            if state["n"] == 1:
                out = "\n".join(out.splitlines()[:-1])  # 少返回最后一行
            return out

        client = FakeChatClient(flaky)
        lt = LineTranslator(client, "ja", "zh", Glossary())
        self.assertEqual(lt.translate_lines(["A", "B", "C"]), ["译A", "译B", "译C"])
        self.assertEqual(len(client.calls), 2)

    def test_split_isolates_bad_line(self):
        def fn(messages):
            lines = [t for _, t in _user_lines(messages)]
            if "BAD" in lines:
                return "\n".join(f"{n}: 译{t}" for n, t in _user_lines(messages)[:-1])
            return _echo_fn(messages)

        client = FakeChatClient(fn)
        lt = LineTranslator(client, "ja", "zh", Glossary())
        out = lt.translate_lines(["A", "B", "BAD", "C"])
        self.assertEqual(out, ["译A", "译B", None, "译C"])

    def test_split_passes_left_results_as_context(self):
        def fn(messages):
            lines = [t for _, t in _user_lines(messages)]
            if "BAD" in lines:
                return "1: x\n1: y"  # 编号重复，校验失败
            return _echo_fn(messages)

        client = FakeChatClient(fn)
        lt = LineTranslator(client, "ja", "zh", Glossary())
        out = lt.translate_lines(["A", "B", "BAD", "D"])
        self.assertEqual(out, ["译A", "译B", None, "译D"])
        with_ctx = [m[-1]["content"] for m in client.calls if "前文" in m[-1]["content"]]
        self.assertTrue(any("A => 译A" in c for c in with_ctx))  # 右半拆分带上左半的译文

    def test_network_error_propagates(self):
        def fn(messages):
            raise TranslateError("connection refused")

        lt = LineTranslator(FakeChatClient(fn), "ja", "zh", Glossary())
        with self.assertRaises(TranslateError):
            lt.translate_lines(["A", "B"])

    def test_glossary_in_system_prompt_only_when_relevant(self):
        client = FakeChatClient(_echo_fn)
        lt = LineTranslator(client, "ja", "zh", Glossary({"天気": "天气", "雨": "雨水"}))
        lt.translate_lines(["今日は天気です"])
        system = client.calls[-1][0]["content"]
        self.assertIn("天気 = 天气", system)
        self.assertNotIn("雨", system)

    def test_context_limited_to_five(self):
        client = FakeChatClient(_echo_fn)
        lt = LineTranslator(client, "ja", "zh", Glossary())
        ctx = [(f"s{i}", f"t{i}") for i in range(9)]
        lt.translate_lines(["X"], ctx)
        user = client.calls[-1][1]["content"]
        self.assertIn("s8 => t8", user)
        self.assertIn("s4 => t4", user)
        self.assertNotIn("s3 => t3", user)

    def test_think_block_and_fence_removed(self):
        from vidac.translate import clean_output
        self.assertEqual(clean_output("<think>想想</think>\n```\n1: 好\n```"), "1: 好")


class TranslatorBatchTests(unittest.TestCase):
    class Tr:
        """替代 Transcriber：翻译线程只读 loaded/complete/error/language。"""

        def __init__(self, language="ja", complete=True):
            self.loaded = threading.Event()
            self.loaded.set()
            self.complete = complete
            self.error = None
            self.language = language

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _translator(self, store, client, tr=None, path=None):
        return Translator(store, tr or self.Tr(), client, "zh", Glossary(),
                          path or (self.dir / "movie.zh.srt"))

    def test_batch_follows_playback_position(self):
        store = SubtitleStore()
        store.add([Cue(float(i * 10), float(i * 10 + 5), f"字{i}") for i in range(30)])
        tr = self._translator(store, FakeChatClient(_echo_fn))
        tr.set_position(150)
        batch = tr._pick_batch(store.snapshot())
        self.assertEqual(batch[0].start, 150.0)
        self.assertEqual(len(batch), 15)  # 150 秒往后只有 15 条，不足一批

    def test_batch_falls_back_to_earliest_when_nothing_ahead(self):
        store = SubtitleStore()
        store.add([Cue(float(i), float(i) + 0.5, f"字{i}") for i in range(5)])
        tr = self._translator(store, FakeChatClient(_echo_fn))
        tr.set_position(1000)
        self.assertEqual(tr._pick_batch(store.snapshot())[0].start, 0.0)

    def test_batch_size_capped(self):
        store = SubtitleStore()
        store.add([Cue(float(i), float(i) + 0.5, f"字{i}") for i in range(60)])
        tr = self._translator(store, FakeChatClient(_echo_fn))
        self.assertEqual(len(tr._pick_batch(store.snapshot())), BATCH_SIZE)

    def test_work_once_writes_translation_file_and_skips_filler(self):
        store = SubtitleStore()
        store.add([Cue(0, 1, "今日は晴れです"), Cue(2, 3, "あ"), Cue(4, 5, "行きましょう")])
        client = FakeChatClient(_echo_fn)
        tr = self._translator(store, client)
        self.assertTrue(tr._work_once("ja"))
        cues = {c.start: c for c in store.snapshot()}
        self.assertEqual(cues[0.0].translation, "译今日は晴れです")
        self.assertIsNone(cues[2.0].translation)  # 语气词不翻译
        self.assertEqual(cues[4.0].translation, "译行きましょう")
        written = srt.parse_srt(tr.path.read_text(encoding="utf-8"))
        self.assertEqual([c.text for c in written], ["译今日は晴れです", "译行きましょう"])
        self.assertEqual(tr.translated, 2)

    def test_translation_cache_is_loaded_by_start_time(self):
        srt.atomic_write(self.dir / "movie.zh.srt",
                         srt.render_srt([Cue(0.0, 1.0, "缓存译文")]))
        store = SubtitleStore()
        store.add([Cue(0.0, 1.0, "今日は晴れです")])
        tr = self._translator(store, FakeChatClient(_echo_fn))
        tr._load_translations()
        self.assertEqual(store.snapshot()[0].translation, "缓存译文")
        self.assertEqual(store.snapshot()[0].text, "今日は晴れです")  # 时间和原文不变

    def test_failed_lines_are_not_retried_in_session(self):
        store = SubtitleStore()
        store.add([Cue(0, 1, "BAD line"), Cue(2, 3, "good")])

        def fn(messages):
            lines = [t for _, t in _user_lines(messages)]
            if any("BAD" in t for t in lines):
                return "1: x\n1: y"  # 编号重复，校验失败
            return _echo_fn(messages)

        client = FakeChatClient(fn)
        tr = self._translator(store, client)
        self.assertTrue(tr._work_once("ja"))
        self.assertIn(0, tr._failed)
        by_start = {c.start: c for c in store.snapshot()}
        self.assertIsNone(by_start[0.0].translation)
        self.assertEqual(by_start[2.0].translation, "译good")
        calls = len(client.calls)
        self.assertFalse(tr._work_once("ja"))  # 失败的那句本会话内不再重试
        self.assertEqual(len(client.calls), calls)

    def test_offline_service_sets_status(self):
        def fn(messages):
            raise TranslateError("connection refused")

        store = SubtitleStore()
        store.add([Cue(0, 1, "今日は晴れです")])
        tr = self._translator(store, FakeChatClient(fn))
        self.assertFalse(tr._work_once("ja"))
        self.assertEqual(tr.status, "offline")

    def test_client_list_models_failure_sets_offline(self):
        client = TranslateClient("http://127.0.0.1:9/v1", "m", timeout=1)
        store = SubtitleStore()
        tr = self._translator(store, client)
        self.assertFalse(tr._ensure_service())
        self.assertEqual(tr.status, "offline")


class PositionTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.video = self.dir / "a.mp4"
        self.video.write_bytes(b"x" * 100)
        self.store = PositionStore(self.dir / "positions.json")

    def tearDown(self):
        self._tmp.cleanup()

    def test_save_and_get(self):
        self.store.save(self.video, 40.0, 180.0)
        self.assertAlmostEqual(self.store.get(self.video), 40.0)

    def test_near_end_clears_record(self):
        self.store.save(self.video, 40.0, 180.0)
        self.store.save(self.video, 170.0, 180.0)
        self.assertIsNone(self.store.get(self.video))

    def test_start_is_not_resumed(self):
        self.store.save(self.video, 2.0, 180.0)
        self.assertIsNone(self.store.get(self.video))

    def test_changed_file_not_resumed(self):
        self.store.save(self.video, 40.0, 180.0)
        self.video.write_bytes(b"y" * 200)
        self.assertIsNone(self.store.get(self.video))

    def test_clear(self):
        self.store.save(self.video, 40.0, 180.0)
        self.store.clear(self.video)
        self.assertIsNone(self.store.get(self.video))

    def test_max_entries(self):
        import vidac.positions as P
        old = P.MAX_ENTRIES
        P.MAX_ENTRIES = 3
        try:
            files = []
            for i in range(5):
                f = self.dir / f"v{i}.mp4"
                f.write_bytes(b"x")
                files.append(f)
                self.store.save(f, 30.0, 600.0)
            data = json.loads((self.dir / "positions.json").read_text(encoding="utf-8"))
            self.assertEqual(len(data), 3)
        finally:
            P.MAX_ENTRIES = old


class DisplayTests(unittest.TestCase):
    def test_modes(self):
        c = Cue(0, 1, "今日は晴れです", translation="今天晴")
        self.assertEqual(cue_lines([c], "off"), [])
        self.assertEqual(cue_lines([c], "orig"), ["今日は晴れです"])
        self.assertEqual(cue_lines([c], "trans"), ["今天晴"])
        self.assertEqual(cue_lines([c], "bilingual"), ["今天晴", "今日は晴れです"])

    def test_untranslated_falls_back_to_original(self):
        c = Cue(0, 1, "今日は晴れです")
        self.assertEqual(cue_lines([c], "trans"), ["今日は晴れです"])
        self.assertEqual(cue_lines([c], "bilingual"), ["今日は晴れです"])

    def test_filler_shows_original_only(self):
        c = Cue(0, 1, "あ", translation="啊")
        self.assertEqual(cue_lines([c], "bilingual"), ["あ"])

    def test_multiple_cues_joined(self):
        a = Cue(0, 1, "一", translation="1")
        b = Cue(0, 1, "二")
        self.assertEqual(cue_lines([a, b], "bilingual"), ["1", "一", "二"])

    def test_ass_escapes_braces_and_joins_lines(self):
        out = subtitle_ass(["{x}", "second"], 1.0)
        self.assertNotIn("{x}", out.split("}", 1)[1])
        self.assertIn("｛x｝", out)
        self.assertIn("\\N", out)


class AppleClientTests(unittest.TestCase):
    """用 tests/fake_apple_helper.py 冒充 Swift 小工具，测 Python 这一侧的协议处理。"""

    HELPER = Path(__file__).resolve().parent / "fake_apple_helper.py"

    def setUp(self):
        self._old = os.environ.get("FAKE_APPLE_MODE")

    def tearDown(self):
        if self._old is None:
            os.environ.pop("FAKE_APPLE_MODE", None)
        else:
            os.environ["FAKE_APPLE_MODE"] = self._old

    def client(self, mode="ok"):
        from vidac.translate import AppleClient
        os.environ["FAKE_APPLE_MODE"] = mode
        return AppleClient(self.HELPER)

    def test_check_and_translate(self):
        from vidac.translate import Glossary, LineTranslator
        c = self.client()
        self.assertEqual(c.list_models(), ["apple"])
        lt = LineTranslator(c, "ja", "zh", Glossary())
        self.assertEqual(lt.translate_lines(["こんにちは", "ありがとう"]),
                         ["中文こんにちは", "中文ありがとう"])

    def test_unavailable_reports_reason(self):
        from vidac.translate import TranslateError
        with self.assertRaises(TranslateError) as cm:
            self.client("disabled").list_models()
        self.assertIn("turned off", str(cm.exception))
        self.assertIn("System Settings", str(cm.exception))

    def test_missing_helper_is_a_translate_error(self):
        from vidac.translate import AppleClient, TranslateError
        with self.assertRaises(TranslateError) as cm:
            AppleClient(Path("/nonexistent/apple-translate")).list_models()
        self.assertIn("install.sh", str(cm.exception))

    def test_refused_batch_is_split_until_it_passes(self):
        from vidac.translate import Glossary, LineTranslator
        lt = LineTranslator(self.client("refuse_big"), "ja", "zh", Glossary())
        lines = [f"行{i}" for i in range(7)]
        self.assertEqual(lt.translate_lines(lines), [f"中文行{i}" for i in range(7)])

    def test_make_client_picks_engine(self):
        from vidac.translate import AppleClient, TranslateClient, make_client
        self.assertIsInstance(make_client("apple", "http://x/v1", "m"), AppleClient)
        self.assertIsInstance(make_client("openai", "http://x/v1", "m"), TranslateClient)


class IpcTests(unittest.TestCase):
    def test_send_loadfile_to_fake_mpv(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s.sock")
            received = {}
            srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            srv.bind(path)
            srv.listen(1)

            def serve():
                conn, _ = srv.accept()
                with conn:
                    buf = b""
                    while b"\n" not in buf:
                        buf += conn.recv(4096)
                    received["cmd"] = json.loads(buf.split(b"\n")[0].decode())
                    conn.sendall(b'{"error":"success"}\n')

            th = threading.Thread(target=serve, daemon=True)
            th.start()
            self.assertTrue(ipc.send_loadfile("/videos/a.mp4", path))
            th.join(2)
            srv.close()
            self.assertEqual(received["cmd"], {"command": ["loadfile", "/videos/a.mp4"]})

    def test_send_fails_without_server(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertFalse(ipc.send_loadfile("/x.mp4", os.path.join(d, "none.sock"), timeout=0.5))


class SubtitleStoreTests(unittest.TestCase):
    def test_active_window(self):
        store = SubtitleStore()
        store.add([Cue(0, 2, "a"), Cue(2, 4, "b"), Cue(3.5, 5, "c")])
        self.assertEqual([c.text for c in store.active(3.6)], ["b", "c"])
        self.assertEqual(store.active(10), [])

    def test_apply_resorts(self):
        store = SubtitleStore()
        store.add([Cue(5, 6, "b"), Cue(1, 2, "a")])
        store.apply(lambda cs: cs)
        self.assertEqual([c.text for c in store.snapshot()], ["a", "b"])


class SchedulerTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.video = Path(self._tmp.name) / "v.mp4"
        self.video.write_bytes(b"")
        self.tr = Transcriber(self.video, 0, lambda: None, model="base")
        self.tr.total = 10
        self.tr.chunk_seconds = 30.0

    def tearDown(self):
        self._tmp.cleanup()

    def test_starts_at_playback_position_then_forward(self):
        self.tr.pos = 0.0
        self.assertEqual(self.tr._pick_next(), 0)
        self.tr.pos = 150.0  # 第 5 段
        self.assertEqual(self.tr._pick_next(), 5)
        self.tr._done.add(5)
        self.assertEqual(self.tr._pick_next(), 6)  # 往前的优先

    def test_seek_backwards_then_falls_back_to_earlier_segments(self):
        self.tr.pos = 290.0  # 第 9 段，最后一段
        self.assertEqual(self.tr._pick_next(), 9)
        self.tr._done.update({9})
        self.assertEqual(self.tr._pick_next(), 8)
        self.tr._done.update(range(10))
        self.assertIsNone(self.tr._pick_next())


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "需要 ffmpeg")
class TranscriberIntegrationTests(unittest.TestCase):
    """用 ffmpeg 生成 65 秒的音频，跑完整转写流程，再验证缓存。"""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.dir = Path(cls._tmp.name)
        cls.video = cls.dir / "tone.mp4"
        subprocess.run([
            "ffmpeg", "-nostdin", "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=5",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=65",
            "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac",
            "-shortest", str(cls.video),
        ], check=True)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def setUp(self):
        for p in self.dir.glob("tone*"):  # 每个用例从没有缓存开始
            if p.suffix != ".mp4":
                p.unlink()

    def test_model_loading_flag_covers_backend_creation_until_first_chunk(self):
        seen = {}

        def slow_factory():
            seen["during_create"] = tr.model_loading
            return FakeBackend()

        tr = Transcriber(self.video, 0, slow_factory, model="fake", chunk_seconds=30.0, rebuild=True)
        self.assertFalse(tr.model_loading)
        orig = tr._process

        def spy(idx, backend):
            seen.setdefault("first_chunk_start", tr.model_loading)
            return orig(idx, backend)

        tr._process = spy
        tr.run()
        self.assertTrue(seen["during_create"])
        self.assertTrue(seen["first_chunk_start"])
        self.assertFalse(tr.model_loading)

    def test_model_loading_flag_cleared_when_backend_fails(self):
        def broken():
            raise RuntimeError("下载失败")

        tr = Transcriber(self.video, 0, broken, model="fake", chunk_seconds=30.0, rebuild=True)
        tr.run()
        self.assertIn("下载失败", tr.error)
        self.assertFalse(tr.model_loading)

    def test_full_run_then_cache_reuse(self):
        before = FakeBackend.calls
        tr = Transcriber(self.video, 0, FakeBackend, model="fake", chunk_seconds=30.0,
                         rebuild=True)
        tr.run()
        self.assertIsNone(tr.error)
        self.assertTrue(tr.complete)
        self.assertEqual(tr.total, 3)
        self.assertEqual(tr.processed, [0, 1, 2])
        self.assertEqual(tr.language, "ja")  # 第一段有声，检测后锁定
        self.assertEqual(tr.srt_path.name, "tone.vidac.ja.srt")
        self.assertFalse((self.dir / "tone.vidac.und.srt").exists())  # 旧的 und 文件已删除
        self.assertGreater(len(tr.store.snapshot()), 20)
        cues = srt.parse_srt(tr.srt_path.read_text(encoding="utf-8"))
        self.assertLessEqual(max(c.end for c in cues), 65.1)
        self.assertGreater(FakeBackend.calls, before)

        calls_before = FakeBackend.calls
        tr2 = Transcriber(self.video, 0, FakeBackend, model="fake", chunk_seconds=30.0)
        tr2.run()
        self.assertTrue(tr2.complete)
        self.assertEqual(tr2.processed, [])
        self.assertEqual(FakeBackend.calls, calls_before)
        self.assertEqual(len(tr2.store.snapshot()), len(cues))

    def test_partial_cache_only_fills_missing_segments(self):
        tr = Transcriber(self.video, 0, FakeBackend, model="fake", chunk_seconds=30.0,
                         rebuild=True)
        tr.run()
        prog = srt.load_progress(tr.progress_path)
        prog["done"] = [0, 1]
        prog["complete"] = False
        srt.save_progress(tr.progress_path, prog)
        tr2 = Transcriber(self.video, 0, FakeBackend, model="fake", chunk_seconds=30.0)
        tr2.run()
        self.assertEqual(tr2.processed, [2])
        self.assertTrue(tr2.complete)

    def test_three_consecutive_failures_stop_with_error(self):
        class Broken(FakeBackend):
            def transcribe(self, *a, **kw):
                raise RuntimeError("boom")

        tr = Transcriber(self.video, 0, Broken, model="fake", chunk_seconds=30.0, rebuild=True)
        tr.run()
        self.assertIsNotNone(tr.error)
        self.assertIn("3 parts in a row", tr.error)
        self.assertEqual(tr.error_code, "internal")
        self.assertFalse(tr.complete)
        self.assertEqual(len(tr.processed), 3)

    def test_stopped_transcriber_writes_nothing(self):
        tr = Transcriber(self.video, 0, FakeBackend, model="fake", chunk_seconds=30.0,
                         rebuild=True)
        tr.stop()
        tr.run()
        self.assertFalse(tr.srt_path.exists())
        self.assertEqual(tr.processed, [])

    def test_read_audio_matches_ffmpeg_length(self):
        pcm = media.read_audio(self.video, 0, 10.0, 5.0)
        self.assertAlmostEqual(pcm.size / media.SAMPLE_RATE, 5.0, delta=0.05)

    def test_missing_ffprobe_is_media_error(self):
        old = os.environ.get("PATH")
        os.environ["PATH"] = str(self.dir / "nothing")
        try:
            with self.assertRaises(media.MediaError):
                media.probe_duration(self.video)
        finally:
            os.environ["PATH"] = old


SAMPLES = Path(os.environ.get("VIDAC_SAMPLES", ROOT / "samples"))


@unittest.skipUnless(
    (SAMPLES / "multi_audio.ts").exists() and shutil.which("ffprobe"),
    "先运行 scripts/make_samples.sh 生成测试素材",
)
class MultiTrackTests(unittest.TestCase):
    def test_track_list_and_selection(self):
        tracks = media.probe_audio_tracks(SAMPLES / "multi_audio.ts")
        self.assertEqual([t.language for t in tracks], ["jpn", "eng"])
        ja = media.read_audio(SAMPLES / "multi_audio.ts", 0, 0.0, 4.0)
        en = media.read_audio(SAMPLES / "multi_audio.ts", 1, 0.0, 4.0)
        self.assertEqual(ja.size, en.size)
        self.assertFalse(np.allclose(ja, en))

        raw = subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "error", "-i", str(SAMPLES / "multi_audio.ts"),
             "-map", "0:a:1", "-t", "4", "-ac", "1", "-ar", "16000", "-f", "f32le", "-"],
            capture_output=True, check=True).stdout
        np.testing.assert_allclose(en, np.frombuffer(raw, dtype=np.float32), atol=1e-6)

    def test_multitrack_cache_names(self):
        tr = Transcriber(SAMPLES / "multi_audio.ts", 1, lambda: None, model="base",
                         cache_dir=Path(tempfile.mkdtemp()))
        self.assertEqual(tr.base.split("-", 1)[1], "multi_audio.a2")


class ResolveModelTests(unittest.TestCase):
    def test_presets_have_candidate_lists(self):
        from vidac.asr import MODEL_PRESETS, resolve_model
        for name, preset in MODEL_PRESETS.items():
            self.assertIsInstance(preset["mlx"], list, name)
            self.assertGreaterEqual(len(preset["mlx"]), 2, name)
        self.assertEqual(resolve_model("base")["mlx"][0], "mlx-community/whisper-base-mlx")
        self.assertIn("mlx-community/whisper-base", resolve_model("base")["mlx"])
        self.assertEqual(resolve_model("tiny")["mlx"][0], "mlx-community/whisper-tiny")

    def test_repo_name_is_single_candidate(self):
        from vidac.asr import resolve_model
        self.assertEqual(resolve_model("someone/whisper-x")["mlx"], ["someone/whisper-x"])

    def test_second_candidate_used_when_first_is_404(self):
        from vidac.asr import resolve_mlx_repo
        calls = []

        def download(repo, **kw):
            calls.append((repo, bool(kw.get("local_files_only"))))
            if kw.get("local_files_only") or repo == "a/one":
                raise RuntimeError("404 not found")
            return f"/cache/{repo}"

        self.assertEqual(resolve_mlx_repo(["a/one", "a/two"], download), "/cache/a/two")
        self.assertEqual(calls, [("a/one", True), ("a/two", True), ("a/one", False), ("a/two", False)])

    def test_local_copy_wins_without_network(self):
        from vidac.asr import resolve_mlx_repo
        calls = []

        def download(repo, **kw):
            calls.append((repo, bool(kw.get("local_files_only"))))
            if repo == "a/two" and kw.get("local_files_only"):
                return "/cache/a/two"
            raise AssertionError("不应该联网")

        self.assertEqual(resolve_mlx_repo(["a/one", "a/two"], download), "/cache/a/two")
        self.assertTrue(all(local for _, local in calls))

    def test_all_fail_error_lists_every_name_and_hint(self):
        from vidac.asr import resolve_mlx_repo

        def download(repo, **kw):
            raise RuntimeError("404 " + repo)

        with self.assertRaises(RuntimeError) as cm:
            resolve_mlx_repo(["a/one", "a/two"], download)
        msg = str(cm.exception)
        self.assertIn("a/one", msg)
        self.assertIn("a/two", msg)
        self.assertIn("--model", msg)

    def test_incomplete_local_dir_is_not_used(self):
        from vidac.asr import resolve_mlx_repo
        with tempfile.TemporaryDirectory() as d:
            partial = Path(d) / "partial"
            partial.mkdir()
            (partial / "config.json").write_text("{}")   # 没有权重，中断的下载
            full = Path(d) / "full"
            full.mkdir()
            (full / "config.json").write_text("{}")
            (full / "weights.npz").write_bytes(b"x")

            def download(repo, **kw):
                if kw.get("local_files_only"):
                    return str(partial)
                return str(full)

            self.assertEqual(resolve_mlx_repo(["a/one"], download), str(full))

    def test_local_directory_given_as_model(self):
        from vidac.asr import resolve_mlx_repo
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(resolve_mlx_repo([d], lambda *a, **k: 1 / 0), d)


class StatusHintTests(unittest.TestCase):
    """提示类状态行 10 秒后隐藏的计时逻辑（不需要 mpv）。"""

    def _app(self):
        import threading
        from vidac.player import App
        app = App.__new__(App)
        app._hints = {}
        app._hints_lock = threading.Lock()
        return app

    def test_hint_hides_after_ten_seconds_and_restarts_when_text_changes(self):
        app = self._app()
        seen: set = set()
        self.assertTrue(app._hint("k", "文字", 100.0, seen))
        self.assertTrue(app._hint("k", "文字", 109.9, seen))
        self.assertFalse(app._hint("k", "文字", 110.1, seen))
        self.assertTrue(app._hint("k", "新的文字", 111.0, seen))

    def test_set_error_restarts_timer(self):
        app = self._app()
        app._set_error("只有一条音轨")
        seen: set = set()
        self.assertTrue(app._hint("error_msg", app.error_msg, 0.0, seen))
        self.assertFalse(app._hint("error_msg", app.error_msg, 11.0, seen))
        app._set_error("只有一条音轨")
        self.assertTrue(app._hint("error_msg", app.error_msg, 12.0, seen))


class MpvIpcTests(unittest.TestCase):
    def test_option_formatting(self):
        from vidac.mpvipc import _opt
        self.assertEqual(_opt("keep_open", "yes"), "--keep-open=yes")
        self.assertEqual(_opt("osc", True), "--osc=yes")
        self.assertEqual(_opt("osc", False), "--osc=no")

    def test_missing_mpv_gives_clear_error(self):
        from unittest import mock
        from vidac import mpvipc
        with mock.patch.dict(os.environ, {}, clear=False), \
                mock.patch.object(mpvipc.shutil, "which", return_value=None), \
                mock.patch.object(mpvipc, "MPV_CANDIDATES", ()):
            os.environ.pop("VIDAC_MPV", None)
            with self.assertRaises(mpvipc.MpvError) as cm:
                mpvipc.find_mpv()
        self.assertIn("install.sh", str(cm.exception))

    def test_cli_prints_hint_and_exits_1_without_mpv(self):
        from unittest import mock
        from vidac import cli, mpvipc
        with tempfile.TemporaryDirectory() as d, \
                mock.patch.dict(os.environ, {"VIDAC_HOME": d, "VIDAC_SOCKET": os.path.join(d, "s.sock")}), \
                mock.patch.object(mpvipc, "find_mpv", side_effect=mpvipc.MpvError("找不到 mpv，请先运行 ./install.sh")), \
                mock.patch("sys.stderr") as err:
            with self.assertRaises(SystemExit) as cm:
                cli.main(["--no-translate"])
        self.assertEqual(cm.exception.code, 1)
        printed = "".join(c.args[0] for c in err.write.call_args_list if c.args)
        self.assertIn("install.sh", printed)


if __name__ == "__main__":
    unittest.main()

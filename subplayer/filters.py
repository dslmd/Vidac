"""转写结果过滤：幻觉字幕、连续重复、语气词合并，以及人声检测（能量阈值版）。"""

from __future__ import annotations

import re

import numpy as np

from .asr.base import Segment
from .srt import Cue

# Whisper 在静音、音乐段常见的编造台词（主要是日语 / 英语视频片尾套话）
HALLUCINATION_PHRASES = (
    "ご視聴ありがとうございました",
    "ご視聴ありがとうございます",
    "ご視聴いただきありがとうございます",
    "ご覧いただきありがとうございました",
    "ご覧いただきありがとうございます",
    "最後までご視聴ありがとうございました",
    "ご清聴ありがとうございました",
    "チャンネル登録",
    "字幕作成",
    "Thanks for watching",
    "Thank you for watching",
    "Subtitles by",
    "Amara.org",
)

NO_SPEECH_PROB = 0.6      # 与 Whisper 默认 no_speech_threshold 一致
LOGPROB_THRESHOLD = -1.0  # 与 Whisper 默认 logprob_threshold 一致
COMPRESSION_MAX = 2.4     # 压缩比过高 = 重复循环

_NON_WORD = re.compile(r"[\W_]+")


def normalize(text: str) -> str:
    """去掉空白、标点和符号，用于比较两句话是否相同。长音符 ー 保留。"""
    return _NON_WORD.sub("", text).lower()


_PHRASES_NORM = tuple(normalize(p) for p in HALLUCINATION_PHRASES)


def is_hallucination_phrase(text: str) -> bool:
    norm = normalize(text)
    return any(p in norm for p in _PHRASES_NORM)


def keep_segment(seg: Segment) -> bool:
    """判断一段识别结果是否保留（静音判定、压缩比、黑名单）。重复由 clean_cues 处理。"""
    text = seg.text.strip()
    if not normalize(text):  # 只有标点、音符、空白
        return False
    if seg.no_speech_prob > NO_SPEECH_PROB and seg.avg_logprob < LOGPROB_THRESHOLD:
        return False
    if seg.compression_ratio > COMPRESSION_MAX:
        return False
    if is_hallucination_phrase(text):
        return False
    return True


# ---- 语气词和括号噪音 ----

_FILLER_TOKENS = [
    # 日语平假名
    "あ", "ぁ", "え", "ぇ", "う", "ぅ", "ん", "ー", "っ", "は", "ふ", "ほ", "お", "ひ", "へ",
    # 日语片假名
    "ア", "ァ", "エ", "ェ", "ウ", "ゥ", "ン", "ッ", "ハ", "フ", "ホ", "オ", "ヒ", "ヘ",
    # 日语多字组合
    "えっと", "えーと", "あのー", "うーん", "んー", "はぁ", "ふぅ",
    # 中文
    "嗯", "啊", "呃", "哦", "唉", "哈",
    # 英文
    "uh", "um", "ah", "oh", "hmm", "mm", "huh",
]
_FILLER_RE = re.compile(
    "^(?:" + "|".join(sorted({normalize(t) for t in _FILLER_TOKENS if normalize(t)},
                             key=len, reverse=True)) + ")+$"
)
_NOISE_RE = re.compile(r"^\s*[\(\[（【][^\)\]）】]*[\)\]）】]\s*$")


def is_filler(text: str) -> bool:
    """语气词、喘息声，或整条都是括号标注的噪音，如 (息) [音楽] (sighs)。"""
    if _NOISE_RE.match(text):
        return True
    norm = normalize(text).lower()
    return bool(norm) and _FILLER_RE.match(norm) is not None


def clean_cues(cues: list[Cue], max_repeat: int = 3, filler_gap: float = 3.0) -> list[Cue]:
    """按时间排序后处理：

    1. 连续相同（归一化后相同）的字幕超过 max_repeat 条时，只保留第一条。
    2. 连续的语气词字幕（间隔 <= filler_gap 秒）合并成一条，取第一条的文本。

    幂等：对结果再次调用不会改变它。
    """
    items = sorted(cues, key=lambda c: c.start)

    kept: list[Cue] = []
    i = 0
    while i < len(items):
        key = normalize(items[i].text)
        j = i + 1
        if key:
            while j < len(items) and normalize(items[j].text) == key:
                j += 1
        if j - i > max_repeat:
            kept.append(items[i])
        else:
            kept.extend(items[i:j])
        i = j

    out: list[Cue] = []
    group: list[Cue] = []
    for c in kept:
        if is_filler(c.text):
            if group and c.start - group[-1].end <= filler_gap:
                group.append(c)
                continue
            if group:
                out.append(_merge(group))
            group = [c]
        else:
            if group:
                out.append(_merge(group))
                group = []
            out.append(c)
    if group:
        out.append(_merge(group))
    return out


def _merge(group: list[Cue]) -> Cue:
    if len(group) == 1:
        return group[0]
    first, last = group[0], group[-1]
    return Cue(first.start, last.end, first.text, first.translation)


def voiced_fraction(audio: np.ndarray, sample_rate: int = 16000,
                    frame_s: float = 0.03, threshold_db: float = -45.0) -> float:
    """按 30 ms 一帧算 RMS，超过阈值的帧占比。"""
    n = int(sample_rate * frame_s)
    if audio.size < n:
        return 0.0
    frames = audio[: (audio.size // n) * n].reshape(-1, n)
    rms = np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1))
    return float(np.mean(rms > 10 ** (threshold_db / 20)))


def is_voiced(audio: np.ndarray, min_fraction: float = 0.05) -> bool:
    return voiced_fraction(audio) >= min_fraction

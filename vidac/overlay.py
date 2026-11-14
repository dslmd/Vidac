"""字幕叠加层的排版：选哪几行、怎么换行、用什么字体和描边，最后生成 ASS 文本。

坐标系高度固定 720，宽度按窗口的宽高比算（16:9 时是 1280），这样竖屏视频和超宽视频里
字号、换行宽度都按真实的窗口形状来。
"""

from __future__ import annotations

import math
import unicodedata
from dataclasses import dataclass
from typing import Optional, Union

from .filters import is_filler
from .srt import Cue

W, H = 1280, 720          # 叠加层坐标系，mpv 会按窗口实际尺寸缩放
BASE_FONT = 40            # 主字幕字号：窗口高度的 5.6%
SECONDARY_RATIO = 0.7     # 双语时原文相对译文的字号
MAX_LINE_WIDTH = 0.86     # 一行最多占窗口宽度的比例
MIN_MARGIN, MAX_MARGIN = 20.0, 420.0

LATIN_FONT = "Helvetica Neue"
CJK_FONTS = {"zh": "PingFang SC", "zh-tw": "PingFang TC", "ja": "Hiragino Sans",
             "ko": "Apple SD Gothic Neo"}


@dataclass
class Line:
    text: str
    secondary: bool = False        # 双语显示里的原文：小一号、淡一点
    lang: Optional[str] = None     # 用来选字体；None 时看文字本身


def cue_layout(cues: list[Cue], mode: str, translate: bool = True,
               src_lang: Optional[str] = None, target: Optional[str] = None) -> list[Line]:
    """把正在显示的字幕转成要画的行。语气词只显示原文；没译好的只显示原文。

    translate 为 False（用户关了翻译）时，已有的译文也不显示。
    """
    if mode == "off":
        return []
    lines: list[Line] = []
    for c in cues:
        translation = c.translation if translate and not is_filler(c.text) else None
        if translation and " ".join(translation.split()) == " ".join(c.text.split()):
            translation = None   # 译文和原文一模一样：只显示一次，双语模式不重复同一句
        if mode == "trans" and translation:
            lines.append(Line(translation, lang=target))
        elif mode == "bilingual" and translation:
            lines.append(Line(translation, lang=target))            # 译文在上，原文在下
            lines.append(Line(c.text, secondary=True, lang=src_lang))
        else:
            lines.append(Line(c.text, lang=src_lang))
    return lines


def cue_lines(cues: list[Cue], mode: str, translate: bool = True) -> list[str]:
    return [line.text for line in cue_layout(cues, mode, translate)]


# ---- 换行 ----

_CLOSERS = set("、。，．！？：；）」』】〉》”’…‥ー～,.!?:;)]}%")
_OPENERS = set("（「『【〈《“‘([{")
_BREAK_AFTER = set("、。，！？；,;.!?")
_NARROW = set("iljtfrI.,:;'!|()[]`\"")
_WIDE_LATIN = set("mwMW@%")


def _is_wide(ch: str) -> bool:
    return unicodedata.east_asian_width(ch) in ("W", "F")


def char_width(ch: str) -> float:
    """一个字符大约占多少个字高（em）。只用来决定在哪里换行，宁可估宽一点。"""
    if ch == " ":
        return 0.3
    if _is_wide(ch):
        return 1.0
    if unicodedata.combining(ch):
        return 0.0
    if ch in _NARROW:
        return 0.34
    if ch in _WIDE_LATIN:
        return 0.9
    if ch.isupper() or ch.isdigit():
        return 0.68
    return 0.57


def text_width(text: str) -> float:
    return sum(char_width(ch) for ch in text)


def _tokens(text: str) -> list[str]:
    """能在中间换行的最小单位：一个西文单词，或一个全角字；标点跟着它该跟的那一边。"""
    raw: list[str] = []
    word = ""
    for ch in text:
        if ch == " ":
            if word:
                raw.append(word)
                word = ""
            raw.append(" ")
        elif _is_wide(ch):
            if word:
                raw.append(word)
                word = ""
            raw.append(ch)
        else:
            word += ch
    if word:
        raw.append(word)
    out: list[str] = []
    glue_next = False
    for tok in raw:
        if out and out[-1] != " " and tok != " " and (glue_next or tok[0] in _CLOSERS):
            out[-1] += tok
        else:
            out.append(tok)
        glue_next = tok != " " and tok[-1] in _OPENERS
    return out


def wrap(text: str, max_width: float) -> list[str]:
    """把一行字幕按 max_width（单位 em）拆成长度接近的几行。原文里已有的换行保留。"""
    out: list[str] = []
    for part in text.split("\n"):
        part = " ".join(part.split())
        if part:
            out.extend(_wrap_one(part, max_width))
    return out


def _wrap_one(text: str, max_width: float) -> list[str]:
    total = text_width(text)
    if total <= max_width:
        return [text]
    count = math.ceil(total / max_width)
    target = total / count
    lines: list[str] = []
    cur = ""
    for tok in _tokens(text):
        if tok == " ":
            if cur:
                cur += " "
            continue
        cur_w = text_width(cur.rstrip())
        tok_w = text_width(tok)
        last = len(lines) >= count - 1
        over = cur_w + tok_w > max_width
        # 已经够一行的平均长度了，或者到了标点而且离平均长度不远：在这里断开
        full = not last and (cur_w + tok_w / 2 > target
                             or (cur_w > target * 0.8 and cur.rstrip()[-1:] in _BREAK_AFTER))
        if cur.strip() and (over or full):
            lines.append(cur.rstrip())
            cur = ""
        cur += tok
    if cur.strip():
        lines.append(cur.rstrip())
    return lines


# ---- ASS ----

def _esc(s: str) -> str:
    # 换行变空格：osd-overlay 把每个原始换行当作一个新事件，后面几行就没有位置和字号了。
    # 全角花括号，免得字幕里的 { } 被当成 ASS 标签；反斜杠后面垫一个零宽字符，免得 \N 之类被解释
    s = " ".join(s.splitlines())
    return s.replace("\\", "\\​").replace("{", "｛").replace("}", "｝")


# 中文里也常用的日文区符号：中点 ・ 和长音符 ー，不能拿它们当作“这是日文”的证据
_NOT_KANA = {0x30FB, 0x30FC}


def font_for(text: str, lang: Optional[str]) -> str:
    """选字体。语言是中日韩之一时直接用那种语言的字体（同一个字在不同语言里字形不同）；
    语言不明（None 或别的）时看文字本身：假名用日文字体，谚文用韩文字体，汉字用中文字体。"""
    kana = hangul = han = False
    for ch in text:
        code = ord(ch)
        if 0x3040 <= code <= 0x30FF and code not in _NOT_KANA:
            kana = True
        elif 0xAC00 <= code <= 0xD7AF or 0x1100 <= code <= 0x11FF:
            hangul = True
        elif 0x4E00 <= code <= 0x9FFF or 0x3400 <= code <= 0x4DBF:
            han = True
    if not (kana or hangul or han):
        return LATIN_FONT   # 没有中日韩文字（含只有 ・ ー 的）：不用中日韩字体
    code = (lang or "").lower().replace("_", "-")
    if code in CJK_FONTS:
        return CJK_FONTS[code]
    parts = code.split("-")
    if parts[0] == "zh":
        return CJK_FONTS["zh-tw"] if {"tw", "hk", "mo", "hant"} & set(parts[1:]) else CJK_FONTS["zh"]
    if parts[0] in CJK_FONTS:
        return CJK_FONTS[parts[0]]
    if kana:
        return CJK_FONTS["ja"]
    if hangul:
        return CJK_FONTS["ko"]
    return CJK_FONTS["zh"]


def _num(value: float) -> str:
    return f"{value:.1f}".rstrip("0").rstrip(".")


def overlay_width(aspect: float = W / H) -> int:
    """高度 720 的坐标系里，宽高比为 aspect 的窗口有多宽。要和 ASS 文本一起交给 osd-overlay。"""
    if not math.isfinite(aspect) or aspect <= 0:
        aspect = W / H
    return round(H * min(4.0, max(0.4, aspect)))


def subtitle_ass(lines: list[Union[Line, str]], scale: float, bottom_margin: float = 110,
                 aspect: float = W / H) -> str:
    """生成字幕叠加层的 ASS 文本，坐标系是 overlay_width(aspect) x 720。

    样式：白色半粗体，细的深色描边加一层柔和的投影，亮背景上也看得清；双语时译文在上是主行，
    原文在下小一号、浅灰、常规粗细。窗口比 16:9 窄时字号按比例收小，免得一行放不下几个字。
    """
    res_x = overlay_width(aspect)
    aspect = res_x / H
    narrow = min(1.0, max(0.62, math.sqrt(aspect / (W / H))))
    fs = BASE_FONT * scale * narrow
    margin = min(MAX_MARGIN, max(MIN_MARGIN, bottom_margin))
    y = H - margin

    parts: list[str] = []
    prev: Optional[Line] = None
    for item in lines:
        line = item if isinstance(item, Line) else Line(str(item))
        size = fs * (SECONDARY_RATIO if line.secondary else 1.0)
        rows = wrap(line.text, res_x * MAX_LINE_WIDTH / size)
        if not rows:
            continue
        if prev is not None and not line.secondary:
            # 两条字幕（或两组双语）之间留一道小空隙，同一组的译文和原文挨着
            parts.append(f"{{\\fs{_num(fs * 0.22)}}} ")
        look = ("\\b0\\1c&HE2E2E2&" if line.secondary else "\\b1\\1c&HFFFFFF&")
        font = font_for(line.text, line.lang)   # 一条字幕只用一种字体，换行出来的几行不各选各的
        for row in rows:
            parts.append(f"{{\\fn{font}\\fs{_num(size)}{look}}}{_esc(row)}")
        prev = line
    if not parts:
        return ""
    head = (f"{{\\an2\\pos({_num(res_x / 2)},{_num(y)})\\q0"
            f"\\bord{_num(max(1.0, fs * 0.04))}\\blur{_num(max(0.4, fs * 0.012))}"
            f"\\shad{_num(max(0.8, fs * 0.03))}"
            "\\3c&H0A0A0A&\\3a&H18&\\4c&H000000&\\4a&H70&}")
    return head + "\\N".join(parts)


def status_ass(lines: list[str]) -> str:
    body = "\\N".join(_esc(line) for line in lines)
    return "{\\an7\\pos(24,18)\\fs22\\bord1\\shad0\\1c&HCCCCCC&}" + body

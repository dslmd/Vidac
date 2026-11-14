"""从字幕文字猜语言：用户自备的 <名字>.srt 没有语言后缀时，靠文字本身判断。

文字系统（假名、谚文、汉字、西里尔字母……）一眼就能分；西文字母的语言靠常见虚词计数，
没有把握就返回 None（宁可不知道，也不要报错语言）。
"""

from __future__ import annotations

import re
from typing import Iterable, Optional

_STOPWORDS = {
    "en": "the and you that have for not with this but are was what just your it's i'm don't of to in is it on".split(),
    "fr": "le la les des est que pas vous nous une pour dans je qui ce mais et du au sur elle il c'est".split(),
    "de": "der die das und ich nicht ist sie zu den mit ein eine auch wir er es von dem aber".split(),
    "es": "el los las que una por con para pero como esto está yo usted más del se lo su y".split(),
    "it": "il che non per una sono con del della gli questo come anche io tu lei lui di è".split(),
    "pt": "não uma que para com você mas ele isso está os as muito dos mais um se é".split(),
    "nl": "de het een niet ik je dat is van en we zijn maar ze hij wat dit ook voor met".split(),
}
_WORD_RE = re.compile(r"[^\W\d_]+(?:'[^\W\d_]+)?", re.UNICODE)
MIN_WORDS = 20      # 西文字幕至少要有这么多词才下判断
MIN_SCORE = 6       # 最好的语言至少命中这么多个虚词
MARGIN = 1.4        # 并且要比第二名多出这么多


def guess_language(texts: Iterable[str], sample: int = 300) -> Optional[str]:
    """返回语言码（en、ja、zh、ko、ru、uk、th、ar、hi、fr、de、es、it、pt、nl）；没把握返回 None。"""
    text = "\n".join(list(texts)[:sample])
    kana = hangul = han = cyr = thai = arabic = deva = latin = 0
    for ch in text:
        code = ord(ch)
        if 0x3040 <= code <= 0x30FF and code not in (0x30FB, 0x30FC):
            kana += 1
        elif 0xAC00 <= code <= 0xD7AF or 0x1100 <= code <= 0x11FF:
            hangul += 1
        elif 0x4E00 <= code <= 0x9FFF or 0x3400 <= code <= 0x4DBF:
            han += 1
        elif 0x0400 <= code <= 0x04FF:
            cyr += 1
        elif 0x0E00 <= code <= 0x0E7F:
            thai += 1
        elif 0x0600 <= code <= 0x06FF:
            arabic += 1
        elif 0x0900 <= code <= 0x097F:
            deva += 1
        elif ch.isalpha() and code < 0x250:
            latin += 1
    letters = kana + hangul + han + cyr + thai + arabic + deva + latin
    if letters < 8:
        return None
    if kana >= max(3, 0.05 * letters):
        return "ja"
    if hangul >= 0.3 * letters:
        return "ko"
    if han >= 0.3 * letters:
        return "zh"
    if cyr >= 0.5 * letters:
        return "uk" if re.search("[іїєґІЇЄҐ]", text) else "ru"
    if thai >= 0.5 * letters:
        return "th"
    if arabic >= 0.5 * letters:
        return "ar"
    if deva >= 0.5 * letters:
        return "hi"
    if latin < 0.6 * letters:
        return None
    words = [w.lower().replace("’", "'") for w in _WORD_RE.findall(text)]
    if len(words) < MIN_WORDS:
        return None
    scores = {lang: sum(1 for w in words if w in set(sw)) for lang, sw in _STOPWORDS.items()}
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    best, second = ranked[0], ranked[1]
    if best[1] >= MIN_SCORE and best[1] >= second[1] * MARGIN:
        return best[0]
    return None

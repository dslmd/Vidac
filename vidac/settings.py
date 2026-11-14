"""设置读写。优先级：命令行 > 环境变量 > settings.json > 默认值。

菜单里改的设置写入 settings.json；命令行和环境变量只影响本次运行，不会写回文件。
"""

from __future__ import annotations

import functools
import json
import logging
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Optional

from .srt import atomic_write

log = logging.getLogger("vidac.settings")

DEFAULTS: dict[str, Any] = {
    "model": "base",
    "language": "auto",
    "translate": True,
    "target_lang": "en",           # 设置文件里没写时跟随系统语言，见 default_target_lang()
    "translate_engine": "apple",   # apple：macOS 自带的 Apple Intelligence；openai：Ollama / LM Studio
    "translate_url": "http://localhost:11434/v1",
    "translate_model": "qwen2.5:7b",
    "display_mode": "bilingual",   # off / orig / trans / bilingual
    "font_scale": 1.0,
    "trackpad": True,              # 触控板两指滑动：左右快进快退 5 秒，上下音量。false 则保留 mpv 默认的滚轮绑定
    "enabled": True,               # false：不自动生成字幕（已有的字幕照常显示）
    "delay": 0.0,                  # 字幕时间偏移的默认值（秒，正数=晚出现）。每个视频自己调过的值另存
    "subtitle_location": "beside",  # beside：字幕文件放在视频旁边；library：放在 app_dir()/subtitles
}

# 翻译目标语言。键同时是 Whisper 语言码（zh-tw 除外），值是给翻译模型看的英文名
TARGET_LANGUAGES = {
    "zh": "Simplified Chinese", "zh-tw": "Traditional Chinese", "en": "English",
    "ja": "Japanese", "ko": "Korean", "fr": "French", "de": "German", "es": "Spanish",
    "ru": "Russian", "pt": "Portuguese", "it": "Italian", "th": "Thai", "vi": "Vietnamese",
    "nl": "Dutch", "pl": "Polish", "tr": "Turkish", "uk": "Ukrainian", "id": "Indonesian",
    "hi": "Hindi", "ar": "Arabic",
}

# Whisper 认识的全部语言码，“转写语言”接受其中任何一个（再加 auto）
WHISPER_LANGUAGES = frozenset("""
en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr
bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn
yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su
yue
""".split())

SUBTITLE_LOCATIONS = ("beside", "library")

ENV_NAMES = {
    "model": "VIDAC_MODEL",
    "language": "VIDAC_LANG",
    "translate_engine": "VIDAC_TRANSLATE_ENGINE",
    "translate_url": "VIDAC_TRANSLATE_URL",
    "translate_model": "VIDAC_TRANSLATE_MODEL",
    "target_lang": "VIDAC_TARGET_LANG",
}


def target_for_locale(tag: str) -> str:
    """系统语言标记（zh-Hans-CN、en_US、pt-BR …）对应的翻译目标语言；不认识的一律英语。"""
    parts = [x for x in re.split(r"[-_]", tag.strip().lower()) if x]
    if not parts:
        return "en"
    rest = set(parts[1:])
    if parts[0] in ("zh", "yue"):   # 粤语 yue 书面上就是繁体中文
        # 文字标记（Hans/Hant）比地区更可靠：zh-Hans-HK 是香港用户选的简体
        if "hans" in rest:
            return "zh"
        if "hant" in rest or parts[0] == "yue":
            return "zh-tw"
        return "zh-tw" if {"tw", "hk", "mo"} & rest else "zh"
    return parts[0] if parts[0] in TARGET_LANGUAGES else "en"


def _supported_target(tag: str) -> Optional[str]:
    """tag 对应的翻译目标语言；系统不认识这种语言时返回 None（和 target_for_locale 的“一律英语”不同）。"""
    parts = [x for x in re.split(r"[-_]", tag.strip().lower()) if x]
    if not parts:
        return None
    if parts[0] in ("zh", "yue") or parts[0] in TARGET_LANGUAGES:
        return target_for_locale(tag)
    return None


def _system_languages() -> list[str]:
    """用户在“系统设置 > 语言与地区”里排的首选语言，第一个在前。读不到返回空列表。"""
    if sys.platform != "darwin":
        return [v.split(".")[0] for v in (os.environ.get("LC_ALL"), os.environ.get("LANG"))
                if v and v.split(".")[0] not in ("C", "POSIX")]
    try:
        proc = subprocess.run(["/usr/bin/defaults", "read", "-g", "AppleLanguages"],
                              capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return []
    return re.findall(r"[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)*", proc.stdout) if proc.returncode == 0 else []


@functools.lru_cache(maxsize=1)
def default_target_lang() -> str:
    """没设置过翻译目标语言时用的默认值：跟随系统语言，读不到或不支持就用英语。

    VIDAC_TARGET_LANG_DEFAULT 可以直接给出语言标记（原生宿主或测试用），它只是默认值，不覆盖设置。
    """
    env = os.environ.get("VIDAC_TARGET_LANG_DEFAULT")
    if env:
        return target_for_locale(env)
    langs = _system_languages()
    # 按用户排的顺序，用第一个支持的语言（排第一的是瑞典语、第二是日语，就译成日语，而不是英语）
    for tag in langs:
        found = _supported_target(tag)
        if found:
            return found
    return "en"


def app_dir() -> Path:
    """设置、位置记录等文件所在目录。VIDAC_HOME 优先。"""
    env = os.environ.get("VIDAC_HOME")
    if env:
        path = Path(env).expanduser()
    elif sys.platform == "darwin":
        path = Path.home() / "Library" / "Application Support" / "vidac"
    else:
        path = Path.home() / ".local" / "share" / "vidac"
    path.mkdir(parents=True, exist_ok=True)
    return path


class Settings:
    def __init__(self, file_values: Optional[dict] = None,
                 overrides: Optional[dict] = None, path: Optional[Path] = None) -> None:
        self.path = path if path is not None else app_dir() / "settings.json"
        self.file_values: dict[str, Any] = dict(file_values or {})
        self.overrides: dict[str, Any] = dict(overrides or {})

    @classmethod
    def load(cls, path: Optional[Path] = None) -> "Settings":
        path = path if path is not None else app_dir() / "settings.json"
        values: dict[str, Any] = {}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                values = {k: v for k, v in data.items() if k in DEFAULTS}
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as exc:
            log.warning("设置文件读取失败，使用默认值：%s", exc)
        return cls(values, path=path)

    @classmethod
    def from_args(cls, args, path: Optional[Path] = None) -> "Settings":
        s = cls.load(path)
        for key, env in ENV_NAMES.items():
            value = os.environ.get(env)
            if value:
                s.overrides[key] = value
        arg_map = {
            "model": getattr(args, "model", None),
            "language": getattr(args, "language", None),
            "translate_engine": getattr(args, "translate_engine", None),
            "translate_url": getattr(args, "translate_url", None),
            "translate_model": getattr(args, "translate_model", None),
            "target_lang": getattr(args, "target_lang", None),
            "display_mode": getattr(args, "display", None),
            "font_scale": getattr(args, "font_scale", None),
        }
        for key, value in arg_map.items():
            if value is not None:
                s.overrides[key] = value
        if (arg_map["translate_url"] or arg_map["translate_model"]) and not arg_map["translate_engine"] \
                and "translate_engine" not in s.overrides:
            s.overrides["translate_engine"] = "openai"  # 给了地址或模型名，说明想用外部服务
        if getattr(args, "no_translate", False):
            s.overrides["translate"] = False
        return s

    def get(self, key: str) -> Any:
        if key not in DEFAULTS:
            raise KeyError(key)
        if key in self.overrides:
            return self.overrides[key]
        if key == "target_lang" and key not in self.file_values:
            return default_target_lang()
        return self.file_values.get(key, DEFAULTS[key])

    def effective(self) -> dict[str, Any]:
        """全部设置当前生效的值。"""
        return {key: self.get(key) for key in DEFAULTS}

    def set(self, key: str, value: Any) -> None:
        """菜单修改：写入 settings.json，并去掉同名的命令行覆盖。"""
        if key not in DEFAULTS:
            raise KeyError(key)
        self.file_values[key] = value
        self.overrides.pop(key, None)
        self.save()

    def save(self) -> None:
        try:
            atomic_write(self.path, json.dumps(self.file_values, ensure_ascii=False, indent=2))
        except OSError as exc:
            log.warning("设置保存失败：%s", exc)

    def get_language(self) -> Optional[str]:
        """转写语言代码；None 表示自动检测。"""
        value = str(self.get("language") or "").strip().lower()
        if value in ("", "auto"):
            return None
        return value

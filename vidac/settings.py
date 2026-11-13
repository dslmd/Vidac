"""设置读写。优先级：命令行 > 环境变量 > settings.json > 默认值。

菜单里改的设置写入 settings.json；命令行和环境变量只影响本次运行，不会写回文件。
"""

from __future__ import annotations

import json
import logging
import os
import sys
from pathlib import Path
from typing import Any, Optional

from .srt import atomic_write

log = logging.getLogger("vidac.settings")

DEFAULTS: dict[str, Any] = {
    "model": "base",
    "language": "auto",
    "translate": True,
    "target_lang": "zh",
    "translate_engine": "apple",   # apple：macOS 自带的 Apple Intelligence；openai：Ollama / LM Studio
    "translate_url": "http://localhost:11434/v1",
    "translate_model": "qwen2.5:7b",
    "display_mode": "bilingual",   # off / orig / trans / bilingual
    "font_scale": 1.0,
    "trackpad": True,              # 触控板两指滑动：左右快进快退 5 秒，上下音量。false 则保留 mpv 默认的滚轮绑定
}

ENV_NAMES = {
    "model": "VIDAC_MODEL",
    "language": "VIDAC_LANG",
    "translate_engine": "VIDAC_TRANSLATE_ENGINE",
    "translate_url": "VIDAC_TRANSLATE_URL",
    "translate_model": "VIDAC_TRANSLATE_MODEL",
    "target_lang": "VIDAC_TARGET_LANG",
}


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
        return self.file_values.get(key, DEFAULTS[key])

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

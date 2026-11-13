"""字幕翻译：调用本地 OpenAI 兼容接口（Ollama、LM Studio 等），只用标准库。

后台线程 Translator 按播放位置挑选未译的字幕，分批翻译，结果写入字幕对象和译文文件。
时间轴始终用原字幕的，译文只写进 Cue.translation。
"""

from __future__ import annotations

import json
import subprocess
import os
import logging
import re
import socket
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

from . import srt
from .filters import is_filler
from .srt import Cue

log = logging.getLogger("subplayer.translate")

BATCH_SIZE = 25          # 每批最多多少行，测试可改
CONTEXT_SIZE = 5         # 前文最多几条已译字幕
NEAR_SECONDS = 2.0       # 播放位置往前多少秒内的字幕算"当前"
MIN_BATCH_TO_WAIT = 8    # 批次不足这么多条、且离播放位置很远时，等转写跟上
FAR_SECONDS = 20.0
RECHECK_SECONDS = 10.0   # 服务不可用时多久重新检测一次

LANG_NAMES_EN = {
    "zh": "Simplified Chinese", "zh-tw": "Traditional Chinese", "en": "English",
    "ja": "Japanese", "ko": "Korean", "fr": "French", "de": "German", "es": "Spanish",
    "ru": "Russian", "pt": "Portuguese", "it": "Italian", "th": "Thai", "vi": "Vietnamese",
}
LANG_NAMES_ZH = {
    "zh": "中文", "zh-tw": "繁体中文", "en": "英语", "ja": "日语", "ko": "韩语",
    "fr": "法语", "de": "德语", "es": "西班牙语", "ru": "俄语", "pt": "葡萄牙语",
    "it": "意大利语", "th": "泰语", "vi": "越南语",
}


def lang_name_en(code: str) -> str:
    return LANG_NAMES_EN.get(code, code)


def lang_name_zh(code: str) -> str:
    return LANG_NAMES_ZH.get(code, code)


def same_language(src: str, target: str) -> bool:
    """比较主语言码：zh 与 zh-tw 都算 zh。"""
    return src.lower().split("-")[0] == target.lower().split("-")[0]


class TranslateError(RuntimeError):
    """网络、HTTP 或返回格式错误。"""


# ---- HTTP 客户端 ----

_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL)


def clean_output(text: str) -> str:
    text = _THINK_RE.sub("", text)
    lines = [ln for ln in text.splitlines() if not ln.strip().startswith("```")]
    return "\n".join(lines).strip()


class TranslateClient:
    def __init__(self, base_url: str, model: str, timeout: float = 120.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout = timeout

    def _request(self, method: str, path: str, payload: Optional[dict] = None,
                 timeout: Optional[float] = None) -> object:
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = urllib.request.Request(
            self.base_url + path, data=data, method=method,
            headers={"Content-Type": "application/json", "Authorization": "Bearer ollama"},
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as resp:
                body = resp.read()
        except urllib.error.HTTPError as exc:
            raise TranslateError(f"HTTP {exc.code}") from exc
        except (urllib.error.URLError, OSError, socket.timeout) as exc:
            reason = getattr(exc, "reason", exc)
            raise TranslateError(str(reason)) from exc
        try:
            return json.loads(body.decode("utf-8"))
        except ValueError as exc:
            raise TranslateError("返回的不是 JSON") from exc

    def list_models(self, timeout: float = 2.0) -> list[str]:
        data = self._request("GET", "/models", timeout=timeout)
        items = data.get("data") if isinstance(data, dict) else None
        if not isinstance(items, list):
            raise TranslateError("模型列表格式不对")
        return [str(m.get("id")) for m in items if isinstance(m, dict) and m.get("id")]

    def chat(self, messages: list[dict]) -> str:
        payload = {"model": self.model, "messages": messages, "temperature": 0, "stream": False}
        data = self._request("POST", "/chat/completions", payload)
        try:
            text = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise TranslateError("返回内容里没有 choices") from exc
        return clean_output(text or "")


# ---- Apple Intelligence 本机模型 ----

def apple_helper_path() -> Path:
    """Swift 小工具的位置。SUBPLAYER_APPLE_HELPER 优先，否则是项目里的 bin/apple-translate。"""
    env = os.environ.get("SUBPLAYER_APPLE_HELPER")
    if env:
        return Path(env)
    return Path(__file__).resolve().parents[1] / "bin" / "apple-translate"


class AppleClient:
    """通过 bin/apple-translate 调用 macOS 26 自带的 Apple Intelligence 模型。

    接口和 TranslateClient 一样（list_models / chat），所以批量、校验、拆分逻辑共用。
    """

    model = "apple"
    label = "Apple Intelligence"
    batch_size = 20  # 本机模型上下文只有约 4096 token，每批少放一点

    def __init__(self, helper: Optional[Path] = None, timeout: float = 120.0) -> None:
        self.helper = Path(helper) if helper else apple_helper_path()
        self.timeout = timeout

    def _run(self, args: list[str], data: Optional[str], timeout: float):
        if not self.helper.exists():
            raise TranslateError("Apple 翻译组件没有编译，请运行 ./install.sh")
        try:
            return subprocess.run([str(self.helper), *args], input=data, capture_output=True,
                                  text=True, encoding="utf-8", timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            raise TranslateError("Apple Intelligence 响应超时") from exc
        except OSError as exc:
            raise TranslateError(f"Apple 翻译组件无法运行：{exc}") from exc

    def list_models(self, timeout: float = 15.0) -> list[str]:
        proc = self._run(["--check"], None, timeout)
        if proc.returncode != 0:
            raise TranslateError(proc.stderr.strip() or "Apple Intelligence 不可用")
        return [self.model]

    def chat(self, messages: list[dict]) -> str:
        payload = json.dumps({
            "instructions": "\n".join(m["content"] for m in messages if m["role"] == "system"),
            "prompt": "\n".join(m["content"] for m in messages if m["role"] != "system"),
        }, ensure_ascii=False)
        proc = self._run([], payload, self.timeout)
        if proc.returncode == 0:
            return clean_output(proc.stdout)
        if proc.returncode == 3:
            # 这批被模型拒绝或太长：返回空串，上层按校验失败处理（重试，再拆小）
            log.info("Apple Intelligence 没有给出结果：%s", proc.stderr.strip()[:200])
            return ""
        raise TranslateError(proc.stderr.strip() or f"Apple 翻译组件退出码 {proc.returncode}")


def make_client(engine: str, url: str, model: str):
    if engine == "openai":
        return TranslateClient(url, model)
    return AppleClient()


# ---- 术语表 ----

_GLOSS_RE = re.compile(r"^(.*?)\s*(=>|->|=|\t|：)\s*(.*)$")


class Glossary:
    def __init__(self, entries: Optional[dict[str, str]] = None) -> None:
        self.entries: dict[str, str] = dict(entries or {})

    @classmethod
    def parse(cls, text: str) -> dict[str, str]:
        out: dict[str, str] = {}
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            m = _GLOSS_RE.match(line)
            if not m:
                continue
            src, dst = m.group(1).strip(), m.group(3).strip()
            if src and dst:
                out[src] = dst
        return out

    @classmethod
    def load(cls, paths: list[Path]) -> "Glossary":
        """按顺序读取，后面的文件覆盖前面的同名条目。读不到的文件跳过。"""
        entries: dict[str, str] = {}
        for p in paths:
            try:
                entries.update(cls.parse(Path(p).read_text(encoding="utf-8")))
            except OSError:
                continue
        return cls(entries)

    def relevant(self, texts: list[str]) -> dict[str, str]:
        """只返回原文出现在这些文本里的条目（英文不区分大小写）。"""
        joined = "\n".join(texts).lower()
        return {k: v for k, v in self.entries.items() if k.lower() in joined}


# ---- 批量翻译 ----

_LINE_RE = re.compile(r"^\s*(\d+)\s*[:：.、)）]\s*(.+?)\s*$")


def parse_numbered(text: str, n: int) -> Optional[list[str]]:
    """解析 `编号: 译文` 格式的输出。编号必须恰好是 1..n 且各出现一次，译文非空。

    只有 1 行输入时，输出没有编号但有非空文本也接受。失败返回 None。
    """
    lines = [ln for ln in text.splitlines() if ln.strip()]
    found: dict[int, str] = {}
    for ln in lines:
        m = _LINE_RE.match(ln)
        if not m:
            continue
        num = int(m.group(1))
        if num in found:
            return None
        found[num] = m.group(2).strip()
    if not found:
        if n == 1 and text.strip():
            return [" ".join(text.split())]
        return None
    if set(found) != set(range(1, n + 1)):
        return None
    vals = [found[i] for i in range(1, n + 1)]
    if any(not v for v in vals):
        return None
    return vals


class LineTranslator:
    """把一组字幕行翻译成译文，校验失败时重试一次，仍失败就对半拆开。"""

    def __init__(self, client: TranslateClient, src_lang: Optional[str], target: str,
                 glossary: Glossary) -> None:
        self.client = client
        self.src_lang = src_lang
        self.target = target
        self.glossary = glossary

    def _messages(self, lines: list[str], context: list[tuple[str, str]]) -> list[dict]:
        tgt = lang_name_en(self.target)
        if self.src_lang:
            head = f"这是 {lang_name_en(self.src_lang)} 视频字幕，译成 {tgt}。"
        else:
            head = f"这是视频字幕，译成 {tgt}。"
        system = (
            head + "\n"
            "日语常省略主语，要结合上下文补全。保持口语和简短。只输出译文，不要解释。"
        )
        terms = self.glossary.relevant(lines + [c[0] for c in context])
        if terms:
            system += "\n术语表（必须严格使用这些译法）：\n"
            system += "\n".join(f"- {k} = {v}" for k, v in terms.items())

        user = []
        if context:
            user.append("前文（仅供参考，不要输出它们）：")
            user.extend(f"{s} => {t}" for s, t in context)
            user.append("")
        user.append(f"逐行翻译下面带编号的行，严格输出 {len(lines)} 行，格式 `编号: 译文`，"
                    "不要合并或拆分，不要加说明。")
        user.extend(f"{i}: {ln}" for i, ln in enumerate(lines, 1))
        return [{"role": "system", "content": system},
                {"role": "user", "content": "\n".join(user)}]

    def _try(self, lines: list[str], context: list[tuple[str, str]]) -> Optional[list[str]]:
        for _ in range(2):
            out = self.client.chat(self._messages(lines, context))
            res = parse_numbered(out, len(lines))
            if res is not None:
                return res
            log.debug("输出格式不对，重试：%r", out[:200])
        return None

    def translate_lines(self, lines: list[str],
                        context: Optional[list[tuple[str, str]]] = None) -> list[Optional[str]]:
        """返回与 lines 等长的列表，翻不出来的位置为 None。网络错误直接抛出。"""
        context = list(context or [])[-CONTEXT_SIZE:]
        if not lines:
            return []
        res = self._try(lines, context)
        if res is not None:
            return res
        if len(lines) == 1:
            return [None]
        mid = len(lines) // 2
        left = self.translate_lines(lines[:mid], context)
        ctx = context + [(s, t) for s, t in zip(lines[:mid], left) if t]
        right = self.translate_lines(lines[mid:], ctx[-CONTEXT_SIZE:])
        return left + right


def model_present(models: list[str], name: str) -> bool:
    """Ollama 里 name 与 name:latest 视为相同。"""
    if name in models:
        return True
    if name.endswith(":latest"):
        return name[: -len(":latest")] in models
    return f"{name}:latest" in models


# ---- 后台线程 ----

def _key(c: Cue) -> int:
    return int(round(c.start * 1000))


class Translator(threading.Thread):
    def __init__(
        self,
        store,
        transcriber,
        client: TranslateClient,
        target: str,
        glossary: Glossary,
        translation_path: Path,
        *,
        enabled: bool = True,
        retranslate: bool = False,
    ) -> None:
        super().__init__(name=f"translator-{target}", daemon=True)
        self.store = store
        self.transcriber = transcriber
        self.client = client
        self.target = target
        self.glossary = glossary
        self.path = Path(translation_path)
        self.retranslate = retranslate
        self.enabled = enabled
        self.status = "checking"
        self.error_msg: Optional[str] = None
        self.models: list[str] = []
        self.translated = 0
        self.total = 0
        self.position = 0.0
        self.batches = 0
        self._stop_event = threading.Event()
        self._failed: set[int] = set()
        self._service_ok: Optional[bool] = None
        self._next_check = 0.0

    # ---- 给主线程用 ----
    def set_position(self, t: float) -> None:
        self.position = float(t)

    def stop(self) -> None:
        self._stop_event.set()

    def set_model(self, name: str) -> None:
        self.client.model = name
        self._failed.clear()
        self._service_ok = None
        self._next_check = 0.0

    # ---- 线程主体 ----
    def run(self) -> None:
        try:
            self._run()
        except Exception as exc:  # 翻译出错不能影响播放
            log.exception("翻译线程出错")
            self.status = "error"
            self.error_msg = f"{type(exc).__name__}: {exc}"

    def _sleep(self, seconds: float) -> None:
        self._stop_event.wait(seconds)

    def _run(self) -> None:
        tr = self.transcriber
        while not self._stop_event.is_set() and not tr.loaded.wait(0.2):
            pass
        if self._stop_event.is_set():
            return
        if self.retranslate:
            self.path.unlink(missing_ok=True)
        self._load_translations()

        while not self._stop_event.is_set():
            if not self.enabled:
                self.status = "disabled"
                self._sleep(0.5)
                continue
            src = tr.language
            if src and same_language(src, self.target):
                self.status = "same_lang"
                self._sleep(1.0)
                continue
            if src is None and not tr.complete and not tr.error:
                self.status = "checking"  # 还没检测到语言
                self._sleep(0.5)
                continue
            if not self._ensure_service():
                self._sleep(0.5)
                continue
            if not self._work_once(src):
                self._sleep(0.5)

    def _ensure_service(self) -> bool:
        if self._service_ok:
            return True
        if time.monotonic() < self._next_check:
            return False
        self.status = "checking"
        try:
            models = self.client.list_models()
        except TranslateError as exc:
            self._mark_offline(str(exc), "offline")
            return False
        self.models = models
        if not model_present(models, self.client.model):
            self._mark_offline(f"模型 {self.client.model} 不在列表里", "no_model")
            return False
        self._service_ok = True
        self.error_msg = None
        self.status = "ok"
        return True

    def _mark_offline(self, msg: str, status: str) -> None:
        self._service_ok = False
        self.status = status
        self.error_msg = msg
        self._next_check = time.monotonic() + RECHECK_SECONDS

    def _pick_batch(self, cues: list[Cue]) -> list[Cue]:
        cands = [c for c in cues
                 if c.translation is None and not is_filler(c.text) and _key(c) not in self._failed]
        pos = self.position
        near = [c for c in cands if c.start >= pos - NEAR_SECONDS]
        return (near or cands)[:min(BATCH_SIZE, getattr(self.client, 'batch_size', BATCH_SIZE))]

    def _work_once(self, src: Optional[str]) -> bool:
        """处理一批。返回 False 表示这次没有活可干（或要等待）。"""
        tr = self.transcriber
        self._count_stats()
        cues = self.store.snapshot()
        batch = self._pick_batch(cues)
        if not batch:
            if tr.complete or tr.error:
                self.status = "ok"
            return False
        if (len(batch) < MIN_BATCH_TO_WAIT and not tr.complete
                and batch[0].start - self.position > FAR_SECONDS):
            return False  # 转写还没跟上，等一等

        first = batch[0].start
        context = [(c.text, c.translation) for c in cues
                   if c.translation and c.start < first and not is_filler(c.text)][-CONTEXT_SIZE:]
        lines = [" ".join(c.text.split()) for c in batch]
        lt = LineTranslator(self.client, src, self.target, self.glossary)
        try:
            results = lt.translate_lines(lines, context)
        except TranslateError as exc:
            self._mark_offline(str(exc), "offline")
            return False
        except Exception as exc:  # 结构性错误：这一批跳过，不重试
            log.exception("批次翻译出错")
            self.status = "error"
            self.error_msg = f"{type(exc).__name__}: {exc}"
            self._failed.update(_key(c) for c in batch)
            return True

        if self._stop_event.is_set():
            return False
        pairs: dict[int, str] = {}
        for c, res in zip(batch, results):
            if res:
                pairs[_key(c)] = res
            else:
                self._failed.add(_key(c))
        self.batches += 1
        if pairs:
            self.store.apply(lambda cs: _apply_translations(cs, pairs))
            self._persist()
        self._count_stats()
        self.status = "ok"
        self.error_msg = None
        return True

    def _count_stats(self) -> None:
        content = [c for c in self.store.snapshot() if not is_filler(c.text)]
        self.total = len(content)
        self.translated = sum(1 for c in content if c.translation)

    # ---- 译文缓存 ----
    def _load_translations(self) -> None:
        if not self.path.exists():
            return
        try:
            cues = srt.parse_srt(self.path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            return
        pairs = {_key(c): c.text for c in cues}
        self.store.apply(lambda cs: _apply_translations(cs, pairs))
        log.info("读取译文缓存 %s（%d 条）", self.path, len(cues))

    def _persist(self) -> None:
        if self._stop_event.is_set():
            return
        out = [Cue(c.start, c.end, c.translation)
               for c in self.store.snapshot() if c.translation]
        if out:
            srt.atomic_write(self.path, srt.render_srt(out))


def _apply_translations(cues: list[Cue], pairs: dict[int, str]) -> list[Cue]:
    """把译文按开始时间（毫秒）挂到原字幕上。只改还没有译文的非语气词字幕。"""
    for c in cues:
        t = pairs.get(_key(c))
        if t and c.translation is None and not is_filler(c.text):
            c.translation = t
    return cues

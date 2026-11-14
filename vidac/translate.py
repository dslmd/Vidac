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
from typing import Callable, Optional

from . import srt
from .filters import is_filler
from .settings import TARGET_LANGUAGES
from .srt import Cue

log = logging.getLogger("vidac.translate")

BATCH_SIZE = 25          # 每批最多多少行，测试可改
CONTEXT_SIZE = 5         # 前文最多几条已译字幕
NEAR_SECONDS = 2.0       # 播放位置往前多少秒内的字幕算"当前"
MIN_BATCH_TO_WAIT = 8    # 批次不足这么多条、且离播放位置很远时，等转写跟上
FAR_SECONDS = 20.0
RECHECK_SECONDS = 10.0   # 服务不可用时多久重新检测一次
MAX_LINE_TIMEOUTS = 2    # 同一行单独翻译也超时这么多次就放弃，只显示原文

LANG_NAMES_EN = dict(TARGET_LANGUAGES)
LANG_NAMES_ZH = {
    "zh": "中文", "zh-tw": "繁体中文", "en": "英语", "ja": "日语", "ko": "韩语",
    "fr": "法语", "de": "德语", "es": "西班牙语", "ru": "俄语", "pt": "葡萄牙语",
    "it": "意大利语", "th": "泰语", "vi": "越南语", "nl": "荷兰语", "pl": "波兰语",
    "tr": "土耳其语", "uk": "乌克兰语", "id": "印尼语", "hi": "印地语", "ar": "阿拉伯语",
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


class TranslateTimeout(TranslateError):
    """服务连着，但这一次没在限定时间内答完（模型慢、批次太大）。和“连不上”不同：不能标成离线，
    也不该劝用户去启动一个已经在运行的服务；应该把批次拆小再试。"""


class TranslationCancelled(Exception):
    """翻译线程已经被停掉（换了目标语言、换了视频、点了停止），这一批不用再翻了。"""


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
            raise TranslateError(
                f"The translation server at {self.base_url} answered with an error (HTTP {exc.code}). "
                "Check that it is an OpenAI-compatible server such as Ollama or LM Studio; "
                "Vidac will try again shortly.") from exc
        except (TimeoutError, socket.timeout) as exc:   # 读响应时超时：服务在，只是慢
            raise self._timeout_error() from exc
        except (urllib.error.URLError, OSError) as exc:
            if isinstance(getattr(exc, "reason", None), (TimeoutError, socket.timeout)):
                raise self._timeout_error() from exc
            reason = getattr(exc, "reason", exc)
            raise TranslateError(
                f"Vidac cannot reach the translation server at {self.base_url} ({reason}). "
                "Start Ollama or LM Studio and translation will begin automatically.") from exc
        try:
            return json.loads(body.decode("utf-8"))
        except ValueError as exc:
            raise TranslateError(
                f"The translation server at {self.base_url} sent a reply Vidac could not read. "
                "Check that it is an OpenAI-compatible server such as Ollama or LM Studio.") from exc

    def _timeout_error(self) -> TranslateTimeout:
        return TranslateTimeout(
            f"The translation server at {self.base_url} is responding too slowly "
            f"(no answer within {self.timeout:.0f} seconds). Vidac keeps trying with smaller batches; "
            "a smaller or faster model on the server will speed this up.")

    def list_models(self, timeout: float = 2.0) -> list[str]:
        try:
            data = self._request("GET", "/models", timeout=timeout)
        except TranslateTimeout as exc:   # 问模型列表都超时：当作连不上
            raise TranslateError(
                f"Vidac cannot reach the translation server at {self.base_url} (it did not answer "
                "in time). Start Ollama or LM Studio and translation will begin automatically.") from exc
        items = data.get("data") if isinstance(data, dict) else None
        if not isinstance(items, list):
            raise TranslateError(
                f"The translation server at {self.base_url} did not return a model list. "
                "Check that it is an OpenAI-compatible server such as Ollama or LM Studio.")
        return [str(m.get("id")) for m in items if isinstance(m, dict) and m.get("id")]

    def chat(self, messages: list[dict]) -> str:
        payload = {"model": self.model, "messages": messages, "temperature": 0, "stream": False}
        data = self._request("POST", "/chat/completions", payload)
        try:
            text = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as exc:
            raise TranslateError(
                f"The translation server at {self.base_url} sent a reply Vidac could not read. "
                "Vidac will try again shortly.") from exc
        return clean_output(text or "")


# ---- Apple Intelligence 本机模型 ----

def apple_helper_path() -> Path:
    """Swift 小工具的位置。VIDAC_APPLE_HELPER 优先，否则是项目里的 bin/apple-translate。"""
    env = os.environ.get("VIDAC_APPLE_HELPER")
    if env:
        return Path(env)
    return Path(__file__).resolve().parents[1] / "bin" / "apple-translate"


# apple-translate 在 stderr 第一行写 "[代码] 英文原因"。旧版本只写原因，所以也按原因里的字眼认。
APPLE_REASONS = {
    "not-enabled": "Apple Intelligence is turned off. Turn it on in System Settings > "
                   "Apple Intelligence & Siri to translate subtitles.",
    "model-not-ready": "Apple Intelligence is still downloading its model. Translation will "
                       "start automatically when it is ready.",
    "not-eligible": "This Mac does not support Apple Intelligence, so subtitles cannot be "
                    "translated on this Mac. They are shown in the original language.",
    "unavailable": "Apple Intelligence is not available right now. Check System Settings > "
                   "Apple Intelligence & Siri; Vidac will try again shortly.",
}
_APPLE_HINTS = (("turned off", "not-enabled"), ("not enabled", "not-enabled"),
                ("not finished downloading", "model-not-ready"), ("not ready", "model-not-ready"),
                ("does not support", "not-eligible"), ("not eligible", "not-eligible"))
_APPLE_CODE_RE = re.compile(r"^\[([a-z-]+)\]\s*(.*)$")


def apple_reason(stderr: str) -> str:
    """把 apple-translate 说的原因变成给用户看的一句话：发生了什么，可以怎么办。"""
    text = stderr.strip()
    first = text.splitlines()[0].strip() if text else ""
    m = _APPLE_CODE_RE.match(first)
    if m and m.group(1) in APPLE_REASONS:
        return APPLE_REASONS[m.group(1)]
    low = first.lower()
    for hint, code in _APPLE_HINTS:
        if hint in low:
            return APPLE_REASONS[code]
    if not first:
        return APPLE_REASONS["unavailable"]
    detail = (m.group(2) if m else first).rstrip(".")
    return f"Apple Intelligence is not available ({detail}). Vidac will try again shortly."


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
            raise TranslateError(
                "The translation component (apple-translate) is missing from this copy of Vidac. "
                "Reinstall Vidac to translate subtitles, or run install.sh when running from source.")
        try:
            return subprocess.run([str(self.helper), *args], input=data, capture_output=True,
                                  text=True, encoding="utf-8", timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            raise TranslateTimeout("Apple Intelligence did not respond in time. "
                                   "Vidac will try again with smaller batches.") from exc
        except OSError as exc:
            raise TranslateError(
                f"The translation component could not be started ({exc}). "
                "Reinstall Vidac to translate subtitles.") from exc

    def list_models(self, timeout: float = 15.0) -> list[str]:
        proc = self._run(["--check"], None, timeout)
        if proc.returncode != 0:
            raise TranslateError(apple_reason(proc.stderr))
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
        if proc.returncode == 2:
            raise TranslateError(apple_reason(proc.stderr))
        detail = proc.stderr.strip()[:200] or f"exit code {proc.returncode}"
        raise TranslateError(f"Apple Intelligence could not translate ({detail}). "
                             "Vidac will try again shortly.")


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
                 glossary: Glossary, should_stop: Optional[Callable[[], bool]] = None) -> None:
        self.client = client
        self.src_lang = src_lang
        self.target = target
        self.glossary = glossary
        self.should_stop = should_stop
        self.timed_out: set[str] = set()   # 单独发出去也超时的行（调用方据此决定放弃还是下次再试）
        self.slow_seen = False             # 任何一次请求超时过

    def _check_stop(self) -> None:
        if self.should_stop is not None and self.should_stop():
            raise TranslationCancelled()

    def _messages(self, lines: list[str], context: list[tuple[str, str]]) -> list[dict]:
        tgt = lang_name_en(self.target)
        if self.src_lang:
            head = f"这是 {lang_name_en(self.src_lang)} 视频字幕，译成 {tgt}。"
        else:
            head = f"这是视频字幕，译成 {tgt}。"
        hint = "日语常省略主语，要结合上下文补全。" if self.src_lang in (None, "ja") else ""
        system = head + "\n" + hint + "保持口语和简短。只输出译文，不要解释。"
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
            self._check_stop()
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
        self._check_stop()
        try:
            res = self._try(lines, context)
        except TranslateTimeout:
            self.slow_seen = True
            # 服务在，只是这一批太慢：拆小再试。只剩一行还超时就记下来，不当作离线
            if len(lines) == 1:
                self.timed_out.add(lines[0])
                return [None]
            res = None
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
        legacy_path: Optional[Path] = None,
        wip_path: Optional[Path] = None,
        load_only: bool = False,
    ) -> None:
        super().__init__(name=f"translator-{target}", daemon=True)
        self.store = store
        self.transcriber = transcriber
        self.client = client
        self.target = target
        self.glossary = glossary
        self.path = Path(translation_path)
        # 0.5 及更早版本写的译文文件：新文件还没有时读它，但不往里写
        self.legacy_path = Path(legacy_path) if legacy_path else None
        # 0.6 开发版写的译文文件（<base>.vidac.<目标语言>.srt）：同样只读。它可能和原文字幕是同一个文件，
        # 读之前要确认不是
        self.wip_path = Path(wip_path) if wip_path else None
        self.retranslate = retranslate
        self.enabled = enabled
        self.load_only = load_only   # 只把已有的译文读进来，不翻译（自动字幕关着或已停止）
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
        self._timeouts: dict[int, int] = {}   # 单行翻译超时的次数，到 MAX_LINE_TIMEOUTS 次就放弃这一行
        self.slow = False                     # 最近一批超时了：服务器在，但很慢
        self._persist_lock = threading.Lock()

    # ---- 给主线程用 ----
    def set_position(self, t: float) -> None:
        self.position = float(t)

    def stop(self) -> None:
        """置位停止标志，并等正在写盘的那一次写完；返回之后这个线程不会再写译文文件。"""
        self._stop_event.set()
        with self._persist_lock:
            pass

    @property
    def failed(self) -> int:
        """试过但没译出来的行数（模型拒绝或格式不对），这些行只显示原文。"""
        return len(self._failed)

    def output_files(self) -> list[Path]:
        return [self.path] if self.path.exists() else []

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
            self.error_msg = _internal_error(exc)

    def _sleep(self, seconds: float) -> None:
        self._stop_event.wait(seconds)

    def _run(self) -> None:
        tr = self.transcriber
        while not self._stop_event.is_set() and not tr.loaded.wait(0.2):
            pass
        if self._stop_event.is_set():
            return
        if self.retranslate:
            originals = self._original_paths()
            with self._persist_lock:   # stop() 返回后不能再删旧位置的文件
                if self._stop_event.is_set():
                    return
                for p in (self.path, self.wip_path):
                    if p is not None and p not in originals:   # 绝不能删转写线程自己的原文字幕
                        p.unlink(missing_ok=True)
        self._load_translations()
        self._count_stats()
        if self.load_only:
            self.status = "disabled"
            return

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
            name = self.client.model
            self._mark_offline(
                f"The translation model “{name}” is not installed on the translation server. "
                f"Install it (for Ollama: ollama pull {name}) and translation will begin "
                "automatically.", "no_model")
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
        lt = LineTranslator(self.client, src, self.target, self.glossary,
                            should_stop=self._stop_event.is_set)
        try:
            results = lt.translate_lines(lines, context)
        except TranslationCancelled:
            return False   # 已经被停掉：这一批的结果没人要
        except TranslateError as exc:
            self._mark_offline(str(exc), "offline")
            return False
        except Exception as exc:  # 结构性错误：这一批跳过，不重试
            log.exception("批次翻译出错")
            self.status = "error"
            self.error_msg = _internal_error(exc)
            self._failed.update(_key(c) for c in batch)
            return True

        pairs: dict[int, str] = {}
        for c, line, res in zip(batch, lines, results):
            key = _key(c)
            if res:
                pairs[key] = res
                self._timeouts.pop(key, None)
            elif line in lt.timed_out:
                # 超时不算“译不出来”：下一轮再试，试了 MAX_LINE_TIMEOUTS 次还不行才放弃这一行
                self._timeouts[key] = self._timeouts.get(key, 0) + 1
                if self._timeouts[key] >= MAX_LINE_TIMEOUTS:
                    self._failed.add(key)
            else:
                self._failed.add(key)
        self.slow = lt.slow_seen
        # 停止标志在字幕表的锁里检查：停掉之后（比如换了目标语言）这一批绝不会再写进去
        applied = []
        self.store.apply(lambda cs: cs if self._stop_event.is_set()
                         else (applied.append(True), _apply_translations(cs, pairs))[1])
        if not applied:
            return False
        self.batches += 1
        if pairs:
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
    def _original_paths(self) -> set[Path]:
        """转写线程的原文字幕文件。译文文件绝不能是它们中的任何一个。"""
        tr = self.transcriber
        out: set[Path] = set()
        for name in ("srt_path", "_written_path"):
            p = getattr(tr, name, None)
            if p is not None:
                out.add(Path(p))
        return out

    def _load_translations(self) -> None:
        originals = self._original_paths()
        tr = self.transcriber
        path: Optional[Path] = None
        if self.path.exists() and self.path not in originals:
            path = self.path
        elif not self.retranslate:
            # 旧名字的译文只读不写，而且要确认它真的是译文
            wip = self.wip_path
            lang = getattr(tr, "language", None)
            if (wip is not None and wip.exists() and wip not in originals
                    and lang and not same_language(lang, self.target)):
                path = wip   # 0.6 开发版：Vidac 自己的名字，原文说的不是目标语言
            elif getattr(tr, "legacy_cache", False):
                # 0.5 的 <视频>.<语言>.srt 只有在确认是 Vidac 旧版本写的缓存时才读，否则那可能是用户自己的字幕
                legacy = self.legacy_path
                if legacy is not None and legacy.exists() and legacy not in originals:
                    path = legacy
        if path is None:
            return
        try:
            cues = srt.parse_srt(path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            return
        pairs = {_key(c): c.text for c in cues}
        self.store.apply(lambda cs: cs if self._stop_event.is_set()
                         else _apply_translations(cs, pairs))
        log.info("读取译文缓存 %s（%d 条）", path, len(cues))

    def _persist(self) -> None:
        with self._persist_lock:
            if self._stop_event.is_set() or self.path in self._original_paths():
                return
            out: list[Cue] = []

            def grab(cues: list[Cue]) -> list[Cue]:
                # 在字幕表的锁里拿快照并检查停止标志：换目标语言时旧线程不会把新语言的译文写进旧文件
                if not self._stop_event.is_set():
                    out.extend(Cue(c.start, c.end, c.translation) for c in cues if c.translation)
                return cues

            self.store.apply(grab)
            if out and not self._stop_event.is_set():
                srt.atomic_write(self.path, srt.render_srt(out))


def _internal_error(exc: Exception) -> str:
    return ("Translation stopped because of an unexpected problem "
            f"({type(exc).__name__}: {exc}). Subtitles are shown in the original language.")


def clear_translations(store) -> None:
    """换目标语言时用：字幕表里已有的译文是旧语言的，全部清掉。"""
    def clear(cues: list[Cue]) -> list[Cue]:
        for c in cues:
            c.translation = None
        return cues
    store.apply(clear)


def _apply_translations(cues: list[Cue], pairs: dict[int, str]) -> list[Cue]:
    """把译文按开始时间（毫秒）挂到原字幕上。只改还没有译文的非语气词字幕。"""
    for c in cues:
        t = pairs.get(_key(c))
        if t and c.translation is None and not is_filler(c.text):
            c.translation = t
    return cues

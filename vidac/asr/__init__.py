"""模型预设和后端选择。

换模型：--model small（或 VIDAC_MODEL=small）。
想用别的 mlx 仓库：--model 直接写 HuggingFace 仓库名，例如 mlx-community/whisper-medium-mlx。
"""

from __future__ import annotations

import importlib.util
import logging
import os
import platform
import ssl
import threading
from typing import Callable, Optional

from .base import Backend, Segment

# huggingface_hub 新版默认用 Xet 下载大文件：进度回调在 hf_xet 的 Rust 线程里，那里抛出的异常会被吞掉，
# 点“停止”或换模型都打断不了下载。用普通 HTTP 下载时回调里的异常能中断数据流，所以默认关掉 Xet
# （要在 huggingface_hub 被导入之前设置；用户自己设了就听用户的）
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

log = logging.getLogger("vidac.asr")

# mlx 值是候选仓库名列表，按顺序解析（先找本地已有的，再联网依次尝试）。
# 只有 mlx-community/whisper-tiny 确认存在，其余名字没有验证过，所以每个预设都留了备用名。
MODEL_PRESETS: dict[str, dict] = {
    "tiny":           {"mlx": ["mlx-community/whisper-tiny", "mlx-community/whisper-tiny-mlx"],
                       "faster": "tiny"},
    "base":           {"mlx": ["mlx-community/whisper-base-mlx", "mlx-community/whisper-base"],
                       "faster": "base"},
    "small":          {"mlx": ["mlx-community/whisper-small-mlx", "mlx-community/whisper-small"],
                       "faster": "small"},
    "medium":         {"mlx": ["mlx-community/whisper-medium-mlx", "mlx-community/whisper-medium"],
                       "faster": "medium"},
    "large-v3":       {"mlx": ["mlx-community/whisper-large-v3-mlx", "mlx-community/whisper-large-v3"],
                       "faster": "large-v3"},
    "large-v3-turbo": {"mlx": ["mlx-community/whisper-large-v3-turbo", "mlx-community/whisper-turbo"],
                       "faster": "large-v3-turbo"},
}

BACKENDS = ("auto", "mlx", "faster", "fake")


def resolve_model(model: str) -> dict:
    """预设名返回候选列表；直接写仓库名（或本地目录）时候选就是那一个。"""
    if model in MODEL_PRESETS:
        return MODEL_PRESETS[model]
    return {"mlx": [model], "faster": model}


def _looks_complete(path: str) -> bool:
    """本地目录里要有配置和权重，中断的下载不算。不是真实目录（测试里的假路径）不检查。"""
    if not os.path.isdir(path):
        return True
    names = set(os.listdir(path))
    return "config.json" in names and bool(names & {"weights.safetensors", "weights.npz"})


class ModelError(RuntimeError):
    """识别模型拿不到。code 是 docs/COMPANION_PROTOCOL.md 里的错误码：offline 或 model-download。"""

    def __init__(self, message: str, code: str = "model-download") -> None:
        super().__init__(message)
        self.code = code


class DownloadCancelled(Exception):
    """下载途中被停止（换了视频、换了模型或用户点了停止）。"""


class ModelProgress:
    """识别模型的下载进度，转写线程写、主线程读。"""

    def __init__(self) -> None:
        self.downloading = False
        self.received = 0
        self.total: Optional[int] = None
        self.seen_bytes = False     # 进度条回调给过字节数（否则靠看缓存目录大小）
        self.cancelled = threading.Event()

    def begin(self) -> None:
        self.received, self.total, self.seen_bytes, self.downloading = 0, None, False, True

    def end(self) -> None:
        self.downloading = False

    def snapshot(self) -> Optional[dict]:
        if not self.downloading:
            return None
        total = self.total
        received = self.received if not total else min(self.received, total)
        return {"received": int(received), "total": int(total) if total else None}


_OFFLINE_NAMES = {"LocalEntryNotFoundError", "OfflineModeIsEnabled", "ConnectError", "ConnectTimeout",
                  "ReadTimeout", "TimeoutException", "ConnectionError", "NetworkError", "gaierror",
                  "ReadError", "RemoteProtocolError", "TimeoutError",
                  "ConnectionResetError", "ConnectionRefusedError", "NameResolutionError"}
# 网络是通的，但证书验证或代理把连接挡了（公司代理、杀毒软件的 HTTPS 扫描、配错的代理）。
# 这和“没联网”不同，换仓库名或重试都一样会失败
_BLOCKED_NAMES = {"SSLError", "SSLCertVerificationError", "ProxyError"}


def _chain_has(exc: Optional[BaseException], names: set[str]) -> bool:
    """异常链（__cause__ / __context__）上有没有名字在 names 里的异常，库换了网络层也认得。"""
    seen = 0
    while exc is not None and seen < 8:
        if any(cls.__name__ in names for cls in type(exc).__mro__):
            return True
        exc = exc.__cause__ or exc.__context__
        seen += 1
    return False


def _is_offline(exc: BaseException) -> bool:
    """这个错误是不是“连不上网”。"""
    return _chain_has(exc, _OFFLINE_NAMES)


def _is_blocked(exc: BaseException) -> bool:
    """这个错误是不是证书或代理造成的。"""
    seen = 0
    cur: Optional[BaseException] = exc
    while cur is not None and seen < 8:
        if isinstance(cur, ssl.SSLError):
            return True
        cur = cur.__cause__ or cur.__context__
        seen += 1
    return _chain_has(exc, _BLOCKED_NAMES)


def _progress_tqdm(progress: ModelProgress):
    """给 snapshot_download 用的进度条类：不往终端画，只把字节数记进 progress。

    huggingface_hub 会建几条进度条，其中 unit 是 B 的才是字节数（另一条数的是文件个数）。
    """
    from tqdm.std import tqdm as base_tqdm

    bars: list = []

    class _Null:
        def write(self, _s): pass
        def flush(self): pass

    class Bar(base_tqdm):
        def __init__(self, *args, **kwargs):
            kwargs.pop("name", None)
            kwargs["file"] = _Null()
            kwargs["disable"] = False
            super().__init__(*args, **kwargs)
            if getattr(self, "unit", None) == "B":
                bars.append(self)
                self._report()

        def display(self, *args, **kwargs):
            return True

        def _report(self):
            byte_bars = [b for b in bars if getattr(b, "unit", None) == "B"]
            if byte_bars:
                total = max(int(b.total or 0) for b in byte_bars)
                progress.received = max(int(b.n or 0) for b in byte_bars)
                if total > 0:
                    progress.total = max(total, progress.total or 0)
                progress.seen_bytes = True

        def update(self, n=1):
            if progress.cancelled.is_set():
                raise DownloadCancelled()
            out = super().update(n)
            self._report()
            return out

        def refresh(self, *args, **kwargs):
            # snapshot_download 在知道文件大小后直接改 total 再 refresh，不经过 update
            self._report()
            return True

    return Bar


def _download_size(download: Callable, repo: str) -> Optional[int]:
    """还要下载多少字节。老版本的 huggingface_hub 没有 dry_run（TypeError），那就返回 None。

    连不上网、仓库不存在这类错误照常抛出：正式下载也会遇到同样的错，不必再等一次超时。
    """
    try:
        files = download(repo, dry_run=True)
    except TypeError:
        return None
    try:
        sizes = [int(f.file_size) for f in files if getattr(f, "will_download", True) and f.file_size]
    except (AttributeError, TypeError, ValueError):
        return None
    return sum(sizes) or None


def _watch_cache_size(repo: str, progress: ModelProgress, stop: threading.Event) -> None:
    """进度条回调没给字节数时（老版本 huggingface_hub）的退路：看缓存目录长了多少。"""
    try:
        from huggingface_hub import constants
        folder = os.path.join(constants.HF_HUB_CACHE, "models--" + repo.replace("/", "--"))
    except Exception:
        return

    def size() -> int:
        total = 0
        for root, _dirs, names in os.walk(folder):
            for name in names:
                try:
                    st = os.lstat(os.path.join(root, name))
                except OSError:
                    continue
                if not os.path.islink(os.path.join(root, name)):
                    total += st.st_size
        return total

    start = size()
    while not stop.wait(0.5):
        if not progress.seen_bytes:
            progress.received = max(0, size() - start)


def _fetch(download: Callable, repo: str, progress: Optional[ModelProgress]) -> str:
    if progress is None:
        return str(download(repo))
    progress.begin()
    progress.total = _download_size(download, repo)
    stop = threading.Event()
    threading.Thread(target=_watch_cache_size, args=(repo, progress, stop),
                     name="model-download-size", daemon=True).start()
    # 下载放在单独的线程里，这里每 0.2 秒看一次有没有被取消：不能只靠进度条回调里抛异常，
    # 有的下载路径（Xet）会把那个异常吞掉
    result: dict = {}
    finished = threading.Event()

    def work() -> None:
        try:
            result["path"] = str(download(repo, tqdm_class=_progress_tqdm(progress)))
        except BaseException as exc:  # noqa: BLE001 在调用线程里原样抛出
            result["exc"] = exc
        finally:
            finished.set()

    threading.Thread(target=work, name="model-download", daemon=True).start()
    try:
        while not finished.wait(0.2):
            if progress.cancelled.is_set():
                _abort_xet()
                raise DownloadCancelled()   # 下载线程丢在一边，它下一次更新进度时会自己退出
        if "exc" in result:
            raise result["exc"]
        if progress.cancelled.is_set():
            raise DownloadCancelled()   # 下载刚好完成，但这个模型已经没人要了
        return result["path"]
    finally:
        stop.set()


def _abort_xet() -> None:
    """尽力中断正在进行的 Xet 下载。这是 huggingface_hub 的私有接口，没有或出错都无所谓。"""
    try:
        from huggingface_hub.utils._xet import abort_xet_session  # type: ignore[attr-defined]
        abort_xet_session()
    except Exception:
        pass


def resolve_mlx_repo(candidates: list[str], download: Optional[Callable] = None,
                     progress: Optional[ModelProgress] = None) -> str:
    """把候选仓库名解析成本地模型目录，不依赖 mlx。

    先用 local_files_only 找本地已有的；都没有再联网依次尝试，用第一个成功的。
    download 默认是 huggingface_hub.snapshot_download，测试里可以换成假的。
    联网下载期间 progress.downloading 为真，字节数随下载更新；progress.cancelled 置位会中断下载。
    """
    if download is None:
        from huggingface_hub import snapshot_download as download
    for repo in candidates:
        if os.path.isdir(repo):
            return repo  # --model 直接给了本地目录
    for repo in candidates:
        try:
            path = download(repo, local_files_only=True)
        except Exception:
            continue
        if _looks_complete(str(path)):
            return str(path)
    errors = []
    offline = False
    blocked = False
    try:
        for repo in candidates:
            if progress is not None and progress.cancelled.is_set():
                raise DownloadCancelled()
            try:
                return _fetch(download, repo, progress)
            except DownloadCancelled:
                raise
            except Exception as exc:
                if progress is not None and progress.cancelled.is_set():
                    raise DownloadCancelled() from exc
                errors.append(f"{repo} ({type(exc).__name__}: {exc})")
                if _is_blocked(exc):
                    blocked = True
                    break  # 证书或代理挡着，换个仓库名也一样
                if _is_offline(exc):
                    offline = True
                    break  # 没有网络，换个仓库名也一样
    finally:
        if progress is not None:
            progress.end()
    detail = "; ".join(errors)
    if blocked:
        raise ModelError(
            "Vidac could not connect securely to huggingface.co to download the speech model. "
            "A proxy, VPN or security software may be blocking or inspecting the connection; "
            "allow huggingface.co, or turn the proxy off for it, and try again. "
            f"(Tried: {detail})", "model-download")
    if offline:
        raise ModelError(
            "The speech model has not been downloaded yet and this Mac appears to be offline. "
            "Connect to the internet and try again. The model is downloaded only once; "
            f"after that subtitles work offline. (Tried: {detail})", "offline")
    raise ModelError(
        "The speech model could not be downloaded. Check your internet connection and free disk "
        "space, then try again, or choose a different model (--model on the command line). "
        f"(Tried: {detail})", "model-download")


def pick_backend(kind: str) -> str:
    if kind != "auto":
        return kind
    on_apple_silicon = platform.system() == "Darwin" and platform.machine() == "arm64"
    if on_apple_silicon and importlib.util.find_spec("mlx_whisper"):
        return "mlx"
    if importlib.util.find_spec("faster_whisper"):
        return "faster"
    raise ModelError("The speech recognition component (mlx-whisper) is missing. Reinstall Vidac, "
                     "or run install.sh when running from source.", "internal")


def make_backend(kind: str, model: str, progress: Optional[ModelProgress] = None) -> Backend:
    """在转写线程里调用，保证 mlx 的模型和 Stream 都在同一个线程里用。"""
    kind = pick_backend(kind)
    names = resolve_model(model)
    if kind == "mlx":
        from .mlx_backend import MlxBackend
        return MlxBackend(names["mlx"], progress)
    if kind == "faster":
        from .faster_backend import FasterWhisperBackend
        return FasterWhisperBackend(names["faster"])
    if kind == "fake":
        from .fake_backend import FakeBackend
        return FakeBackend()
    raise ValueError(f"未知后端：{kind}")


__all__ = ["Backend", "Segment", "MODEL_PRESETS", "ModelError", "ModelProgress", "DownloadCancelled",
           "make_backend", "resolve_model", "resolve_mlx_repo", "pick_backend"]

"""启动 mpv 程序并通过它的 JSON IPC 控制它。

为什么不用 libmpv（python-mpv）：macOS 要求窗口事件循环跑在进程主线程上，
Python 进程里用 libmpv 开窗口很容易不出窗口或卡死。直接启动 mpv 程序，它自己就是
完整的 Mac 应用：窗口、菜单栏、拖拽、触控板手势都是原生的。我们只发命令、收事件。

原生 Vidac App 由 Swift 在主线程持有 libmpv；VIDAC_ATTACH_SOCKET 模式只附着它的
IPC，不创建窗口，也不拥有或结束该宿主。
"""

from __future__ import annotations

import atexit
import json
import logging
import os
import queue
import shutil
import socket
import subprocess
import threading
import time
from typing import Any, Callable, Optional

log = logging.getLogger("vidac.mpv")

MPV_CANDIDATES = (
    "/opt/homebrew/bin/mpv",
    "/usr/local/bin/mpv",
    "/Applications/mpv.app/Contents/MacOS/mpv",
)
KEY_MESSAGE = "vidac-key"


class MpvError(RuntimeError):
    pass


def find_mpv() -> str:
    path = os.environ.get("VIDAC_MPV") or shutil.which("mpv")
    if path:
        return path
    for cand in MPV_CANDIDATES:
        if os.access(cand, os.X_OK):
            return cand
    raise MpvError("找不到 mpv，请先运行 ./install.sh 或 brew install mpv")


def socket_alive(path: str) -> bool:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            s.connect(path)
            return True
    except OSError:
        return False


def _opt(key: str, value: Any) -> str:
    if value is True:
        value = "yes"
    elif value is False:
        value = "no"
    return f"--{key.replace('_', '-')}={value}"


class MPV:
    """只实现本项目用到的那部分接口。属性读写：player.time_pos、player.aid = 2 等。"""

    _OWN = {"proc", "sock_path", "core_shutdown"}

    def __init__(self, sock_path: str, **options: Any) -> None:
        object.__setattr__(self, "core_shutdown", False)
        self._attached = bool(os.environ.get("VIDAC_ATTACH_SOCKET"))
        self._terminating = False
        if self._attached:
            # 原生 App 已在主线程创建 libmpv；这里只拥有一条 IPC 连接。
            sock_path = os.environ["VIDAC_ATTACH_SOCKET"]
        elif socket_alive(sock_path):
            sock_path = f"{sock_path}.{os.getpid()}"  # 已有一个窗口在用默认路径
        else:
            try:
                os.unlink(sock_path)  # 上次异常退出留下的
            except OSError:
                pass
        object.__setattr__(self, "sock_path", sock_path)
        self._lock = threading.Lock()
        self._next_id = 0
        self._pending: dict[int, list] = {}
        self._observers: dict[int, Callable] = {}
        self._event_cbs: dict[str, list[Callable]] = {}
        self._sections: dict[str, dict[str, Callable]] = {}
        self._dispatch: queue.Queue = queue.Queue()

        proc = None
        if self._attached:
            log.info("连接原生播放器的字幕控制接口")
        else:
            cmd = [find_mpv(), f"--input-ipc-server={sock_path}", "--input-terminal=no",
                   "--terminal=no", *(_opt(k, v) for k, v in options.items())]
            log.debug("启动 mpv：%s", cmd)
            try:
                proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
            except OSError as exc:
                raise MpvError(f"mpv 启动失败：{exc}") from exc
        object.__setattr__(self, "proc", proc)
        atexit.register(self.terminate)

        self._sock = self._connect()
        threading.Thread(target=self._reader, name="mpv-reader", daemon=True).start()
        threading.Thread(target=self._dispatcher, name="mpv-dispatch", daemon=True).start()

    # ---- 连接和收发 ----
    def _connect(self) -> socket.socket:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.proc is not None and self.proc.poll() is not None:
                raise MpvError(f"mpv 启动后立刻退出了（退出码 {self.proc.returncode}），"
                               "可以在终端里运行 mpv 看报错")
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                s.connect(self.sock_path)
                return s
            except OSError:
                s.close()
                time.sleep(0.05)
        if not self._attached:
            self._kill()
        raise MpvError("连不上 mpv 的控制接口")

    def _reader(self) -> None:
        buf = b""
        try:
            while True:
                chunk = self._sock.recv(65536)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        msg = json.loads(line.decode("utf-8", errors="replace"))
                    except ValueError:
                        continue
                    self._on_message(msg)
        except OSError:
            pass
        finally:
            object.__setattr__(self, "core_shutdown", True)
            with self._lock:
                pending = list(self._pending.values())
                self._pending.clear()
            for slot in pending:
                slot[1] = {"error": "mpv 已退出"}
                slot[0].set()
            self._dispatch.put(None)

    def _on_message(self, msg: dict) -> None:
        if "request_id" in msg and "event" not in msg:
            with self._lock:
                slot = self._pending.pop(msg["request_id"], None)
            if slot is not None:
                slot[1] = msg
                slot[0].set()
            return
        if "event" in msg:
            self._dispatch.put(msg)

    def _dispatcher(self) -> None:
        """回调放在单独的线程里跑，这样回调里也能同步发命令。"""
        while True:
            msg = self._dispatch.get()
            if msg is None:
                return
            try:
                self._handle_event(msg)
            except Exception:
                log.exception("处理 mpv 事件出错")

    def _handle_event(self, msg: dict) -> None:
        name = msg.get("event")
        if name == "property-change":
            cb = self._observers.get(msg.get("id"))
            if cb:
                cb(msg.get("name"), msg.get("data"))
        elif name == "client-message":
            args = msg.get("args") or []
            if len(args) >= 3 and args[0] == KEY_MESSAGE:
                fn = self._sections.get(args[1], {}).get(args[2])
                if fn:
                    fn()
        for cb in self._event_cbs.get(name, []):
            cb(msg)

    def command(self, *args: Any, timeout: float = 5.0) -> Any:
        if self.core_shutdown:
            raise MpvError("mpv 已退出")
        slot = [threading.Event(), None]
        with self._lock:
            self._next_id += 1
            rid = self._next_id
            self._pending[rid] = slot
            data = json.dumps({"command": list(args), "request_id": rid}, ensure_ascii=False)
            try:
                self._sock.sendall(data.encode("utf-8") + b"\n")
            except OSError as exc:
                self._pending.pop(rid, None)
                raise MpvError(f"mpv 连接断开：{exc}") from exc
        if not slot[0].wait(timeout):
            with self._lock:
                self._pending.pop(rid, None)
            raise MpvError(f"mpv 没有响应：{args[0]}")
        reply = slot[1] or {}
        if reply.get("error") != "success":
            raise MpvError(f"{args[0]}: {reply.get('error')}")
        return reply.get("data")

    # ---- 属性 ----
    def get(self, name: str) -> Any:
        """读属性；属性当前不可用（比如还没载入文件）返回 None。"""
        try:
            return self.command("get_property", name.replace("_", "-"))
        except MpvError:
            return None

    def set(self, name: str, value: Any) -> None:
        self.command("set_property", name.replace("_", "-"), value)

    def __getattr__(self, name: str) -> Any:
        if name.startswith("_"):
            raise AttributeError(name)
        return self.get(name)

    def __setattr__(self, name: str, value: Any) -> None:
        if name.startswith("_") or name in self._OWN:
            object.__setattr__(self, name, value)
        else:
            self.set(name, value)

    # ---- 事件、属性观察、按键 ----
    def property_observer(self, name: str):
        def register(fn: Callable) -> Callable:
            with self._lock:
                self._next_id += 1
                oid = self._next_id
            self._observers[oid] = fn
            self.command("observe_property", oid, name)
            return fn
        return register

    def event_callback(self, name: str):
        def register(fn: Callable) -> Callable:
            self._event_cbs.setdefault(name, []).append(fn)
            return fn
        return register

    def set_keys(self, section: str, keys: dict[str, Callable]) -> None:
        """把一组按键绑到回调上。优先级高于 mpv 默认绑定；后启用的 section 优先。"""
        self._sections[section] = dict(keys)
        contents = "\n".join(f"{key} script-message {KEY_MESSAGE} {section} {key}" for key in keys)
        self.command("define-section", section, contents, "force")
        self.command("enable-section", section)

    def clear_keys(self, section: str) -> None:
        """解除这组按键，恢复 mpv 默认行为。"""
        self._sections.pop(section, None)
        self.command("disable-section", section)

    # ---- 常用命令 ----
    def loadfile(self, path: str) -> None:
        self.command("loadfile", path)

    def keypress(self, name: str) -> None:
        self.command("keypress", name)

    def seek(self, amount: float, reference: str = "relative", precision: str = "default") -> None:
        """precision：default（mpv 默认，绝对定位是精确的）、exact、keyframes。"""
        flags = reference if precision in ("default", "default-precise") else f"{reference}+{precision}"
        self.command("seek", amount, flags)

    def screenshot_to_file(self, path: str, includes: str = "subtitles") -> None:
        self.command("screenshot-to-file", path, includes)

    def quit(self) -> None:
        try:
            self.command("quit", timeout=2)
        except MpvError:
            pass

    def _kill(self) -> None:
        if self._attached:
            return
        proc = self.proc
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        try:
            os.unlink(self.sock_path)
        except OSError:
            pass

    def terminate(self) -> None:
        if self._terminating:
            return
        self._terminating = True
        if self._attached:
            # 关闭控制器不能结束原生窗口，也不能删除宿主拥有的 socket。
            object.__setattr__(self, "core_shutdown", True)
            sock = self.__dict__.get("_sock")
            if sock is None:
                return  # 连接失败后的 atexit 清理
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
            return
        proc = self.proc
        if proc.poll() is None:
            try:
                self.quit()
                proc.wait(timeout=3)
            except Exception:
                pass
        self._kill()

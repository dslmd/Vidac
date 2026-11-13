"""单实例：新进程把视频交给已经在运行的窗口（通过 mpv 的 IPC socket）。"""

from __future__ import annotations

import json
import os
import socket


def socket_path() -> str:
    """socket 路径要短：macOS 限制 104 字符。SUBPLAYER_SOCKET 可覆盖，测试用。"""
    return os.environ.get("SUBPLAYER_SOCKET") or f"/tmp/subplayer-{os.getuid()}.sock"


def send_loadfile(path: str, sock: str | None = None, timeout: float = 1.0) -> bool:
    """让已在运行的 mpv 播放 path。成功返回 True；没有在运行或失败返回 False。"""
    if not hasattr(socket, "AF_UNIX"):
        return False
    sock = sock or socket_path()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(sock)
            msg = json.dumps({"command": ["loadfile", path]}) + "\n"
            s.sendall(msg.encode("utf-8"))
            buf = b""
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    return False
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        obj = json.loads(line.decode("utf-8"))
                    except ValueError:
                        continue
                    if isinstance(obj, dict) and "error" in obj:
                        return obj.get("error") == "success"
    except OSError:
        return False

"""本地假的 OpenAI 兼容服务，用来测翻译流程，不需要真的 Ollama。

  GET  /v1/models            返回 models 列表
  POST /v1/chat/completions   解析用户消息里带编号的行，返回 `编号: 中文<原文>`；
                             原文里出现术语表的词时替换成译名（术语表从 system 消息里读）

每次请求都记录在 requests 里（批大小、是否带前文、system 内容），供测试断言。
故障注入：short_next=N 让接下来 N 次少返回最后一行；fail_next=N 让接下来 N 次返回 HTTP 500。

用法：
    mock = MockLLM(models=["qwen2.5:7b"]); port = mock.start(); mock.url  # http://127.0.0.1:port/v1
    ...
    mock.stop()
"""

from __future__ import annotations

import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional

_NUMBERED = re.compile(r"^(\d+): (.*)$")
_TERM = re.compile(r"^- (.+?) = (.+)$", re.MULTILINE)


class MockLLM:
    def __init__(self, models: Optional[list[str]] = None) -> None:
        self.models = list(models or ["qwen2.5:7b"])
        self.requests: list[dict] = []
        self.short_next = 0
        self.fail_next = 0
        self._lock = threading.Lock()
        self._server: Optional[ThreadingHTTPServer] = None
        self.port = 0

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}/v1"

    def start(self) -> int:
        mock = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):  # 不往标准输出打印请求日志
                pass

            def _send(self, code: int, obj: dict) -> None:
                body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path.rstrip("/").endswith("/models"):
                    self._send(200, {"object": "list",
                                     "data": [{"id": m, "object": "model"} for m in mock.models]})
                else:
                    self._send(404, {"error": "not found"})

            def do_POST(self):
                if not self.path.rstrip("/").endswith("/chat/completions"):
                    self._send(404, {"error": "not found"})
                    return
                length = int(self.headers.get("Content-Length", 0))
                req = json.loads(self.rfile.read(length).decode("utf-8"))
                with mock._lock:
                    if mock.fail_next > 0:
                        mock.fail_next -= 1
                        self._send(500, {"error": "injected failure"})
                        return
                    content = mock._answer(req)
                self._send(200, {"choices": [{"index": 0, "finish_reason": "stop",
                                              "message": {"role": "assistant",
                                                          "content": content}}]})

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self.port = self._server.server_address[1]
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self.port

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None

    def _answer(self, req: dict) -> str:
        messages = req.get("messages", [])
        system = messages[0].get("content", "") if messages else ""
        user = messages[-1].get("content", "") if messages else ""
        terms = dict(_TERM.findall(system))
        after = user.split("严格输出", 1)[-1]
        lines = []
        for ln in after.splitlines():
            m = _NUMBERED.match(ln)
            if m:
                lines.append((int(m.group(1)), m.group(2)))
        self.requests.append({
            "model": req.get("model"),
            "n": len(lines),
            "has_context": "前文" in user,
            "system": system,
            "terms": terms,
        })
        out = []
        for n, text in lines:
            for src, dst in terms.items():
                text = text.replace(src, dst)
            out.append(f"{n}: 中文{text}")
        if self.short_next > 0 and out:
            self.short_next -= 1
            out = out[:-1]
        return "\n".join(out)

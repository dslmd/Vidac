"""原生宿主的 IPC 生命周期测试；不模拟识别或翻译通过。"""

from __future__ import annotations

import json
import os
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from vidac import mpvipc
from vidac.player import App
from vidac.settings import Settings


class ProtocolHost:
    """只实现本测试使用的 JSON IPC，宿主与客户端分别拥有其资源。"""

    def __init__(self, path):
        self.path = path
        self.commands = []
        self.connections = []
        self.hold_received = threading.Event()
        self.stopped = threading.Event()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(4)
        self.listener.settimeout(0.1)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stopped.is_set():
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.connections.append(conn)
            threading.Thread(target=self.serve_connection, args=(conn,), daemon=True).start()

    def serve_connection(self, conn):
        try:
            with conn, conn.makefile("rb") as stream:
                for line in stream:
                    request = json.loads(line)
                    cmd = request["command"]
                    self.commands.append(cmd)
                    if cmd[0] == "hold":
                        self.hold_received.set()
                        continue
                    data = None
                    if cmd[0] == "get_property":
                        data = {"path": "/video.mp4", "time-pos": 1.25}.get(cmd[1])
                    if cmd[0] == "observe_property":
                        event = {"event": "property-change", "id": cmd[1],
                                 "name": cmd[2], "data": "/video.mp4"}
                        conn.sendall(json.dumps(event).encode() + b"\n")
                    reply = {"request_id": request["request_id"],
                             "error": "success", "data": data}
                    conn.sendall(json.dumps(reply).encode() + b"\n")
        except OSError:
            pass

    def close_connections(self):
        for conn in self.connections:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def stop(self):
        self.stopped.set()
        self.close_connections()
        self.listener.close()
        self.thread.join(1)


class NativeAttachTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="vidac-attach-", dir="/tmp")
        self.path = str(Path(self.tmp.name) / "host.sock")
        self.host = ProtocolHost(self.path)
        self.environment = mock.patch.dict(os.environ, {"VIDAC_ATTACH_SOCKET": self.path})
        self.environment.start()
        self.no_child = mock.patch.object(mpvipc.subprocess, "Popen",
                                          side_effect=AssertionError("must not spawn mpv"))
        self.no_child.start()
        self.clients = []

    def tearDown(self):
        for client in self.clients:
            client.terminate()
        self.no_child.stop()
        self.environment.stop()
        self.host.stop()
        self.tmp.cleanup()

    def client(self):
        client = mpvipc.MPV("/tmp/unused-vidac-default.sock")
        self.clients.append(client)
        return client

    def test_attach_observes_existing_file_and_detaches_without_ending_host(self):
        client = self.client()
        received = threading.Event()
        paths = []

        @client.property_observer("path")
        def observed(_name, value):
            paths.append(value)
            received.set()

        self.assertTrue(received.wait(1))
        self.assertEqual(paths, ["/video.mp4"])
        self.assertEqual(client.time_pos, 1.25)
        self.assertIsNone(client.proc)
        self.assertEqual(client.sock_path, self.path)
        client.terminate()
        client.terminate()  # atexit 和显式关闭都可以执行
        self.assertTrue(Path(self.path).exists())
        self.assertNotIn(["quit"], self.host.commands)
        next_client = self.client()
        self.assertEqual(next_client.path, "/video.mp4")

    def test_host_disconnect_wakes_pending_request_and_marks_core_down(self):
        client = self.client()
        errors = []

        def request():
            try:
                client.command("hold", timeout=5)
            except mpvipc.MpvError as exc:
                errors.append(str(exc))

        th = threading.Thread(target=request)
        th.start()
        self.assertTrue(self.host.hold_received.wait(1))
        start = time.monotonic()
        self.host.close_connections()
        th.join(1)
        self.assertFalse(th.is_alive())
        self.assertLess(time.monotonic() - start, 1)
        self.assertTrue(client.core_shutdown)
        self.assertIn("mpv 已退出", errors[0])
        self.assertTrue(Path(self.path).exists())

    def test_attach_timeout_preserves_host_path_and_cleanup_is_safe(self):
        self.host.stop()
        callbacks = []
        with mock.patch.object(mpvipc.time, "monotonic", side_effect=[0, 16]), \
                mock.patch.object(mpvipc.atexit, "register", side_effect=callbacks.append):
            with self.assertRaisesRegex(mpvipc.MpvError, "连不上"):
                mpvipc.MPV(self.path)
        self.assertTrue(Path(self.path).exists())
        self.assertEqual(len(callbacks), 1)
        callbacks[0]()  # _sock 尚未建立，也必须能清理

    def test_late_attach_restores_file_ready_without_repeating_resume(self):
        app = App.__new__(App)
        app.player = mock.Mock(_attached=True, path="/video.mp4", idle_active=False,
                               time_pos=1.25, duration=100)
        app.video = Path("/video.mp4")
        app.file_ready = False
        app.positions = mock.Mock()
        app.positions.get.return_value = None
        app._sync_attached_file_loaded("/video.mp4")
        self.assertTrue(app.file_ready)
        app._on_file_loaded()  # 宿主稍后又发真正的 file-loaded
        app.positions.get.assert_called_once_with(Path("/video.mp4"))

    def test_path_in_loading_transition_is_not_marked_ready(self):
        app = App.__new__(App)
        app.player = mock.Mock(_attached=True, path="/next.mp4", idle_active=False,
                               time_pos=1.25)
        app.video = Path("/old.mp4")
        app.file_ready = False
        app._sync_attached_file_loaded("/old.mp4")
        self.assertFalse(app.file_ready)

    def test_restarted_controller_skips_resume_once_then_resumes_next_file(self):
        app = App.__new__(App)
        app._skip_initial_resume = True
        app.file_ready = False
        app.video = Path("/already-playing.mp4")
        app.player = mock.Mock(duration=500, time_pos=30.0)
        app.positions = mock.Mock()
        app.positions.get.return_value = 40.0
        app._on_file_loaded()
        self.assertTrue(app.file_ready)
        self.assertFalse(app._skip_initial_resume)
        app.positions.get.assert_not_called()
        app.player.seek.assert_not_called()
        # 同一控制器中，之后打开其他文件仍按正常记录恢复。
        app.video = Path("/next-file.mp4")
        app.file_ready = False
        app._on_file_loaded()
        app.positions.get.assert_called_once_with(Path("/next-file.mp4"))
        app.player.seek.assert_called_once_with(40.0, reference="absolute")

    def test_legacy_keep_flag_still_resumes_when_time_pos_unavailable(self):
        app = App.__new__(App)
        app._skip_initial_resume = True
        app.file_ready = False
        app.video = Path("/fresh.mp4")
        app.player = mock.Mock(duration=500, time_pos=None)
        app.positions = mock.Mock()
        app.positions.get.return_value = 40.0
        app._on_file_loaded()
        app.player.seek.assert_called_once_with(40.0, reference="absolute")

    def test_native_settings_reject_bad_values_and_apply_background_change(self):
        app = App.__new__(App)
        with tempfile.TemporaryDirectory() as d:
            app.settings = Settings(path=Path(d) / "settings.json")
            app.video = Path("/video.mp4")
            app.tracks = [object()]
            app.transcriber = mock.Mock(source="generated")
            app.translator = mock.Mock()
            app.rebuild = app.retranslate = False
            app.delay = 0.0
            app._restart_workers = mock.Mock()
            app._restart_translator = mock.Mock()
            app._native_setting("model", "small")
            app._restart_workers.assert_called_once()
            self.assertEqual(app.settings.get("model"), "small")
            self.assertTrue(app.rebuild and app.retranslate)   # 换模型 = 要求重做
            app._native_setting("translate", "false")
            self.assertFalse(app.translator.enabled)
            app._native_setting("model", "not-a-model")
            app._native_setting("font_scale", "nan")
            app._native_setting("font_scale", "100")
            self.assertEqual(app.settings.get("font_scale"), 3.0)
            self.assertEqual(app.settings.get("model"), "small")
            self.assertEqual(app._restart_workers.call_count, 1)


if __name__ == "__main__":
    unittest.main()

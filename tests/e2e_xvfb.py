"""端到端测试（Linux + Xvfb，真的打开 mpv 窗口播放）。

用假识别后端（占位日语字幕）加 mock_llm.py（假翻译服务）跑完整流程。每个阶段用 VIDAC_HOME
和 VIDAC_SOCKET 指向测试目录，视频先复制到 OUTDIR/work，缓存文件只写在那里。

用法（先 Xvfb :99 &，并 export DISPLAY=:99）：
    python tests/e2e_xvfb.py SAMPLES_DIR OUTDIR
SAMPLES_DIR 里需要 ja_180s.mp4 和 multi_audio.ts（scripts/make_samples.sh 生成）。

阶段：
  A   没有翻译服务：视频照常播放，原文字幕出现，状态行显示翻译服务未连接；
      --backend mlx（沙箱里没有 mlx）：播放照常，状态行显示字幕不可用
  B   mock 翻译服务：译文逐步出现，批大小、前文、术语表；v 循环四种模式；
      拖动优先转写；Tab 菜单导航修改字号并保存；菜单关闭后方向键恢复
  C   重启：原文和译文都从缓存读出，转写和翻译请求都为 0
  D   记住位置：seek 到 40 秒退出，再打开从 40 秒附近开始
  E   单实例：已有窗口时另一个进程把文件交过来后立即退出
  F   双音轨 .ts 用 --audio-track 2；缓存名 multi_audio.a2.ja.srt / .a2.zh.srt；按 t 切换音轨
  T   触控板：WHEEL_LEFT/RIGHT 快退快进 5 秒，WHEEL_UP/DOWN 音量；菜单打开时滚轮不动进度；
      菜单“窗口大小”循环；Alt+0/1/2 设置 current-window-scale（mpv 默认绑定）
  T2  settings 里 trackpad=false 时不覆盖滚轮，WHEEL_RIGHT 仍是 mpv 默认的 10 秒
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(TESTS))
os.environ["VIDAC_FAKE_DELAY"] = "1.5"  # 每段假装要 1.5 秒，才能看出分段进度

OUT = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
SAMPLES = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
WORK = OUT / "work" if OUT else None
HOME = OUT / "home" if OUT else None
SOCK = OUT / "s.sock" if OUT else None
if OUT is not None:
    os.environ["VIDAC_HOME"] = str(HOME)
    os.environ["VIDAC_SOCKET"] = str(SOCK)
for k in ["VIDAC_MODEL", "VIDAC_LANG", "VIDAC_TRANSLATE_URL",
          "VIDAC_TRANSLATE_MODEL", "VIDAC_TARGET_LANG"]:
    os.environ.pop(k, None)

from mock_llm import MockLLM  # noqa: E402
from vidac import srt  # noqa: E402
from vidac.asr.fake_backend import FakeBackend  # noqa: E402
from vidac.cli import build_parser  # noqa: E402
from vidac.player import MENU_ROWS, App  # noqa: E402
from vidac.settings import app_dir  # noqa: E402

RESULTS: dict = {}
FAILS: list[str] = []


def check(name: str, ok: bool, detail=None) -> None:
    RESULTS[name] = {"ok": bool(ok), "detail": None if detail is None else str(detail)}
    print(("PASS " if ok else "FAIL ") + name + (f"  -> {detail}" if detail is not None else ""), flush=True)
    if not ok:
        FAILS.append(name)


def wait_for(cond, timeout: float) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        try:
            if cond():
                return True
        except Exception:
            pass
        time.sleep(0.1)
    return False


def pos(app: App) -> float:
    try:
        return float(app.player.time_pos or 0.0)
    except Exception:
        return 0.0


def status(app: App) -> list[str]:
    return app._status_lines()


def translated_count(app: App) -> int:
    tr = app.transcriber
    return sum(1 for c in tr.store.snapshot() if c.translation) if tr else 0


def make_args(video: Path, extra: list[str]):
    parser = build_parser()
    return parser.parse_args([
        str(video), "--backend", "fake", "--model", "base",
        "--mpv-opt", "vo=x11", "--mpv-opt", "ao=null",
        *extra,
    ])


def run_phase(name: str, video: Path, extra: list[str], script) -> App:
    """在主线程跑播放器循环，script 在另一个线程里驱动。"""
    app = App(make_args(video, extra))
    holder = {}

    def runner():
        try:
            script(app)
        except Exception:
            tb = traceback.format_exc()
            holder["tb"] = tb
            check(f"{name}: 脚本异常", False, tb[-400:])
        finally:
            try:
                app.player.quit()
            except Exception:
                pass

    th = threading.Thread(target=runner, daemon=True)
    th.start()
    app.run()
    th.join(timeout=10)
    check(f"{name}: 主循环无异常", app._last_err is None, app._last_err)
    return app


def shot(app: App, name: str) -> None:
    # "window" 才包含 osd-overlay 画的字幕、状态和菜单（"subtitles" 不含 OSD 层）
    app.player.screenshot_to_file(str(OUT / name), includes="window")


def key(app: App, name: str, wait: float = 0.3) -> None:
    app.player.keypress(name)
    time.sleep(wait)


def fresh_copy(src: Path, name: str) -> Path:
    dst = WORK / name
    shutil.copy(src, dst)
    for p in WORK.glob(f"{dst.stem}*"):
        if p != dst and p.suffix in (".srt", ".json", ".tmp"):
            p.unlink()
    return dst


def read_settings() -> dict:
    try:
        return json.loads((app_dir() / "settings.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def main() -> None:
    if OUT is None:
        raise SystemExit("用法：python tests/e2e_xvfb.py SAMPLES_DIR OUTDIR")
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    HOME.mkdir(parents=True, exist_ok=True)
    (HOME / "glossary.txt").write_text("# 测试术语表\n天気 = 天气\n", encoding="utf-8")
    ja = SAMPLES / "ja_180s.mp4"
    ts = SAMPLES / "multi_audio.ts"
    dead_url = "http://127.0.0.1:9/v1"  # 没人监听
    mock = MockLLM(models=["qwen2.5:7b"])
    mock_url = None

    # ---------- A：没有翻译服务 ----------
    video_a = fresh_copy(ja, "a.mp4")

    def phase_a(app: App):
        check("A: 转写线程启动", wait_for(lambda: app.transcriber is not None, 20))
        check("A: 播放前进", wait_for(lambda: pos(app) > 3, 30), round(pos(app), 2))
        p1 = pos(app)
        time.sleep(2)
        check("A: 没有翻译服务时视频照常播放", pos(app) > p1 + 1.5, [round(p1, 2), round(pos(app), 2)])
        check("A: 原文字幕出现", wait_for(lambda: app.transcriber.store.snapshot(), 20))
        check("A: 状态行显示翻译服务未连接",
              wait_for(lambda: any("翻译服务未连接" in ln for ln in status(app)), 15), status(app))
        check("A: 没有字幕不可用的提示", not any("字幕不可用" in ln for ln in status(app)))
        shot(app, "1_no_translate.png")

    run_phase("A", video_a, ["--translate-url", dead_url], phase_a)

    video_m = fresh_copy(ja, "mlx.mp4")

    def phase_mlx(app: App):
        check("A2: 播放前进（mlx 不可用）", wait_for(lambda: pos(app) > 3, 30), round(pos(app), 2))
        p1 = pos(app)
        time.sleep(2)
        check("A2: 视频照常播放", pos(app) > p1 + 1.5, [round(p1, 2), round(pos(app), 2)])
        check("A2: 状态行显示字幕不可用",
              wait_for(lambda: any("字幕不可用" in ln and "视频照常播放" in ln for ln in status(app)), 20),
              status(app))

    app_m = App(make_args(video_m, ["--backend", "mlx", "--translate-url", dead_url]))

    def runner_m():
        try:
            phase_mlx(app_m)
        except Exception:
            check("A2: 脚本异常", False, traceback.format_exc()[-400:])
        finally:
            app_m.player.quit()

    threading.Thread(target=runner_m, daemon=True).start()
    app_m.run()
    check("A2: 主循环无异常", app_m._last_err is None, app_m._last_err)

    # ---------- B：mock 翻译服务，拖动，显示模式，菜单 ----------
    mock_url = None
    mock.start()
    mock_url = mock.url
    video_b = fresh_copy(ja, "b.mp4")

    def phase_b(app: App):
        check("B: 转写线程启动", wait_for(lambda: app.transcriber is not None, 20))
        tr = app.transcriber
        check("B: 译文逐步出现", wait_for(lambda: translated_count(app) >= 3, 60), translated_count(app))
        n0 = len(tr.processed)
        app.player.time_pos = 150
        check("B: 拖到 150 秒后第 5 段被优先转写",
              wait_for(lambda: 5 in tr.processed[n0:n0 + 2], 30), tr.processed[n0:])
        check("B: 翻译完成", wait_for(lambda: tr.complete and app.translator.total > 0
                                      and app.translator.translated == app.translator.total, 150),
              [translated_count(app), app.translator.total if app.translator else None])
        reqs = list(mock.requests)
        check("B: 批大小不超过 25", bool(reqs) and max(r["n"] for r in reqs) <= 25,
              max((r["n"] for r in reqs), default=0))
        check("B: 后续批带上前文", any(r["has_context"] for r in reqs))
        check("B: 术语表进入提示词", any("天気 = 天气" in r["system"] for r in reqs))
        term_cues = [c for c in tr.store.snapshot() if "天気" in c.text and c.translation]
        check("B: 术语表生效", bool(term_cues) and all("天气" in c.translation for c in term_cues),
              term_cues[0].translation if term_cues else None)
        check("B: 状态行显示翻译进度",
              any("翻译 中文 · qwen2.5:7b" in ln for ln in status(app)), status(app))

        # v 键循环四种显示模式
        modes = []
        for _ in range(4):
            key(app, "v")
            modes.append(app.settings.get("display_mode"))
        check("B: v 键循环 off/orig/trans/bilingual", modes == ["off", "orig", "trans", "bilingual"], modes)

        check("B: 双语字幕显示译文", wait_for(lambda: bool(app.last_sub_text) and "中文" in app.last_sub_text, 20),
              app.last_sub_text)
        shot(app, "2_bilingual.png")

        # Tab 菜单：下移到字号，右键加 0.1，ESC 关闭
        key(app, "TAB", 0.5)
        check("B: Tab 打开菜单", wait_for(lambda: app.menu_open, 5))
        scale_row = MENU_ROWS.index("scale")
        for _ in range(scale_row):
            key(app, "DOWN", 0.15)
        check("B: 菜单移到字号行", app.menu_sel == scale_row, app.menu_sel)
        key(app, "RIGHT", 0.5)
        check("B: 菜单修改字号并保存", read_settings().get("font_scale") == 1.1, read_settings().get("font_scale"))
        check("B: 菜单画面已绘制", wait_for(lambda: app.last_menu is not None, 5))
        time.sleep(0.5)
        shot(app, "3_menu.png")
        key(app, "ESC", 0.5)
        check("B: ESC 关闭菜单", not app.menu_open)

        p0 = pos(app)
        key(app, "RIGHT", 0.6)
        time.sleep(0.5)
        delta = pos(app) - p0
        # mpv 默认 RIGHT 是 seek 5 且按关键帧定位；测试视频关键帧间隔 10 秒，所以可能多跳到下一个关键帧
        check("B: 菜单关闭后方向键恢复快进（至少 4 秒，关键帧定位可能多跳）", delta >= 4.0, round(delta, 2))

    app_b = run_phase("B", video_b, ["--translate-url", mock_url, "--display", "bilingual"], phase_b)
    check("B: 翻译请求都发到 mock 服务", len(mock.requests) > 0, len(mock.requests))

    # ---------- C：重启，缓存直接读出 ----------
    calls_before = FakeBackend.calls
    reqs_before = len(mock.requests)

    def phase_c(app: App):
        check("C: 转写线程启动", wait_for(lambda: app.transcriber is not None, 20))
        tr = app.transcriber
        check("C: 原文缓存已完整", wait_for(lambda: tr.complete, 10))
        check("C: 没有重新识别", tr.processed == [], tr.processed)
        check("C: 译文从缓存读出",
              wait_for(lambda: app.translator is not None and app.translator.total > 0
                       and app.translator.translated == app.translator.total, 15),
              [translated_count(app), app.translator.total if app.translator else None])
        time.sleep(2)
        check("C: 字幕立即可用", bool(tr.store.snapshot()) and wait_for(
            lambda: bool(tr.store.active(pos(app))), 10), round(pos(app), 2))
        check("C: 没有重新翻译（请求数不变）", len(mock.requests) == reqs_before,
              len(mock.requests) - reqs_before)
        check("C: 没有重新识别（后端调用数不变）", FakeBackend.calls == calls_before,
              FakeBackend.calls - calls_before)

    run_phase("C", video_b, ["--translate-url", mock_url], phase_c)

    # ---------- D：记住位置 ----------
    def phase_d1(app: App):
        check("D: 播放就绪", wait_for(lambda: pos(app) > 1, 20))
        app.player.time_pos = 40
        check("D: 跳到 40 秒", wait_for(lambda: 39 <= pos(app) <= 44, 10), round(pos(app), 2))
        time.sleep(1.0)

    run_phase("D1", video_b, ["--translate-url", mock_url], phase_d1)

    def phase_d2(app: App):
        check("D: 重新打开后从约 40 秒开始",
              wait_for(lambda: 37.0 <= pos(app) <= 50.0, 15), round(pos(app), 2))

    run_phase("D2", video_b, ["--translate-url", mock_url], phase_d2)

    # ---------- E：单实例 ----------
    video_e = fresh_copy(ja, "e.mp4")
    other = fresh_copy(ts, "other.ts")

    def phase_e(app: App):
        check("E: 第一个窗口就绪", wait_for(lambda: pos(app) > 1, 20))
        t0 = time.time()
        env = dict(os.environ)
        env["PYTHONPATH"] = str(ROOT)
        proc = subprocess.run([sys.executable, "-m", "vidac", str(other)],
                              cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=30)
        elapsed = time.time() - t0
        check("E: 第二个进程退出码为 0", proc.returncode == 0, proc.returncode)
        check("E: 第二个进程立即退出", elapsed < 10, round(elapsed, 2))
        check("E: 原窗口切换到新文件", wait_for(lambda: app.video is not None and app.video.name == "other.ts", 15),
              app.video.name if app.video else None)

    run_phase("E", video_e, ["--translate-url", mock_url], phase_e)

    # ---------- F：双音轨 .ts，第 2 条音轨 ----------
    video_f = fresh_copy(ts, "multi.ts")

    def phase_f(app: App):
        check("F: 启动第 2 条音轨", wait_for(lambda: app.transcriber is not None, 20)
              and app.transcriber.track == 1)
        tr = app.transcriber
        check("F: 检测到语言后原文缓存为 multi.a2.ja.srt",
              wait_for(lambda: tr.language == "ja" and tr.srt_path.exists(), 25), tr.srt_path.name)
        check("F: 译文缓存为 multi.a2.zh.srt",
              wait_for(lambda: (WORK / "multi.a2.zh.srt").exists(), 60))
        check("F: 字幕时间和播放时间对齐",
              wait_for(lambda: bool(tr.store.active(pos(app))) and abs(
                  tr.store.active(pos(app))[-1].start - pos(app)) <= 2.5, 20),
              round(pos(app), 2))
        key(app, "t", 1.0)
        check("F: 按 t 切换到第 1 条音轨", wait_for(lambda: app.track == 0, 10), app.track + 1)
        check("F: 转写跟随切换到第 1 条音轨",
              wait_for(lambda: app.transcriber is not None and app.transcriber.track == 0, 10))

    run_phase("F", video_f, ["--audio-track", "2", "--translate-url", mock_url], phase_f)

    # ---------- T：触控板（滚轮事件）、窗口大小 ----------
    video_t = fresh_copy(ja, "t.mp4")

    def phase_t(app: App):
        check("T: 播放就绪", wait_for(lambda: pos(app) > 1, 20))
        app.player.pause = True
        time.sleep(0.5)
        app.player.time_pos = 60
        time.sleep(1.0)
        p0 = pos(app)
        key(app, "WHEEL_RIGHT", 0.6)
        d = pos(app) - p0
        check("T: 两指右滑快进 5 秒（覆盖了 mpv 默认的 10 秒）", 4.5 <= d <= 6.5, round(d, 2))
        p1 = pos(app)
        key(app, "WHEEL_LEFT", 0.6)
        d = pos(app) - p1
        check("T: 两指左滑快退 5 秒", -6.5 <= d <= -4.5, round(d, 2))

        v0 = float(app.player.volume)
        key(app, "WHEEL_UP", 0.4)
        v1 = float(app.player.volume)
        check("T: 两指上滑音量加 2", abs(v1 - v0 - 2) < 0.01, [v0, v1])
        key(app, "WHEEL_DOWN", 0.4)
        v2 = float(app.player.volume)
        check("T: 两指下滑音量减 2", abs(v2 - v0) < 0.01, [v1, v2])

        # 菜单打开时滚轮不动进度
        key(app, "TAB", 0.5)
        p2 = pos(app)
        key(app, "WHEEL_RIGHT", 0.6)
        check("T: 菜单打开时滚轮不快进", abs(pos(app) - p2) < 0.5, round(pos(app) - p2, 2))
        key(app, "ESC", 0.5)
        check("T: ESC 关闭菜单", not app.menu_open)

        # 菜单里的窗口大小：50 / 100 / 150 / 200 循环
        app.player.current_window_scale = 1.0
        time.sleep(0.5)
        key(app, "TAB", 0.5)
        win_row = MENU_ROWS.index("window")
        for _ in range(win_row):
            key(app, "DOWN", 0.15)
        check("T: 菜单移到窗口大小行", app.menu_sel == win_row, app.menu_sel)
        seq = []
        for _ in range(3):
            key(app, "RIGHT", 0.5)
            seq.append(round(float(app.player.current_window_scale), 2))
        check("T: 窗口大小菜单按 100% 到 150%、200%、50% 循环", seq == [1.5, 2.0, 0.5], seq)
        check("T: 菜单显示窗口大小", dict(app._menu_rows()).get("窗口大小") == "50%",
              dict(app._menu_rows()).get("窗口大小"))
        key(app, "ESC", 0.5)

        # mpv 默认的 Alt+0/1/2 也应该生效
        for combo, want in [("Alt+2", 2.0), ("Alt+1", 1.0), ("Alt+0", 0.5)]:
            key(app, combo, 0.6)
            got = round(float(app.player.current_window_scale), 2)
            check(f"T: {combo} 把窗口缩放设为 {want}", got == want, got)

    run_phase("T", video_t, ["--no-translate"], phase_t)

    # ---------- T2：trackpad 设为 false，保留 mpv 默认的滚轮绑定 ----------
    settings_file = app_dir() / "settings.json"
    saved = read_settings()
    settings_file.write_text(json.dumps({**saved, "trackpad": False}, ensure_ascii=False), encoding="utf-8")

    def phase_t2(app: App):
        check("T2: 设置 trackpad=false 时关闭触控板绑定", app.settings.get("trackpad") is False)
        check("T2: 播放就绪", wait_for(lambda: pos(app) > 1, 20))
        app.player.pause = True
        time.sleep(0.5)
        app.player.time_pos = 60
        time.sleep(1.0)
        p0 = pos(app)
        key(app, "WHEEL_RIGHT", 0.6)
        d = pos(app) - p0
        check("T2: 不覆盖时 WHEEL_RIGHT 仍是 mpv 默认的快进 10 秒", 9 <= d <= 11, round(d, 2))

    run_phase("T2", video_t, ["--no-translate"], phase_t2)
    settings_file.write_text(json.dumps({**saved, "trackpad": True}, ensure_ascii=False), encoding="utf-8")

    # ---------- G：默认引擎 Apple Intelligence（用假的小工具冒充 Swift 组件） ----------
    helper = TESTS / "fake_apple_helper.py"
    apple_log = OUT / "apple_calls.jsonl"
    os.environ["VIDAC_APPLE_HELPER"] = str(helper)
    os.environ["FAKE_APPLE_LOG"] = str(apple_log)
    before_mock = len(mock.requests)

    os.environ["FAKE_APPLE_MODE"] = "disabled"
    video_g0 = fresh_copy(ja, "g0.mp4")

    def phase_g0(app: App):
        check("G0: 播放前进", wait_for(lambda: pos(app) > 3, 30), round(pos(app), 2))
        check("G0: 状态行说明 Apple Intelligence 没开启，只显示原文",
              wait_for(lambda: any("没有开启" in ln and "只显示原文" in ln for ln in status(app)), 20),
              status(app))
        check("G0: 原文字幕照常出现", wait_for(lambda: app.transcriber.store.snapshot(), 20))
        p1 = pos(app)
        time.sleep(2)
        check("G0: 视频照常播放", pos(app) > p1 + 1.5)
        shot(app, "4_apple_disabled.png")

    run_phase("G0", video_g0, [], phase_g0)

    os.environ["FAKE_APPLE_MODE"] = "ok"
    video_g = fresh_copy(ja, "g.mp4")

    def phase_g(app: App):
        check("G: 默认引擎是 apple", app.settings.get("translate_engine") == "apple")
        check("G: 译文逐步出现",
              wait_for(lambda: sum(1 for c in app.transcriber.store.snapshot() if c.translation) > 0, 40))
        def all_translated():
            # 按字幕库里的实际句数判断，不用翻译线程的计数（它可能还没把最后一段算进去）
            cues = app.transcriber.store.snapshot()
            return app.transcriber.complete and len(cues) >= 85 and all(c.translation for c in cues)

        check("G: 翻译完成", wait_for(all_translated, 120),
              [sum(1 for c in app.transcriber.store.snapshot() if c.translation),
               len(app.transcriber.store.snapshot())])
        check("G: 状态行显示 Apple Intelligence",
              wait_for(lambda: any("Apple Intelligence" in ln for ln in status(app)), 10), status(app))
        calls = [json.loads(x) for x in apple_log.read_text(encoding="utf-8").splitlines()]
        check("G: 每批不超过 20 行", max(c["n"] for c in calls) <= 20, max(c["n"] for c in calls))
        check("G: 术语表进入提示词", any("天気 = 天气" in c["instructions"] for c in calls))
        check("G: 译文缓存 g.zh.srt 已写出", (WORK / "g.zh.srt").exists())
        shot(app, "5_apple_bilingual.png")

    run_phase("G", video_g, ["--display", "bilingual"], phase_g)
    check("G: 没有请求发到 Ollama 接口", len(mock.requests) == before_mock, len(mock.requests) - before_mock)

    n_calls = len(apple_log.read_text(encoding="utf-8").splitlines())

    def phase_g2(app: App):
        check("G2: 译文从缓存读出", wait_for(
            lambda: app.translator is not None and app.translator.total > 0
            and app.translator.translated == app.translator.total, 20))

    run_phase("G2", video_g, [], phase_g2)
    check("G2: 重开后没有再调用翻译组件",
          len(apple_log.read_text(encoding="utf-8").splitlines()) == n_calls)

    mock.stop()
    (OUT / "results.json").write_text(json.dumps(RESULTS, ensure_ascii=False, indent=2), encoding="utf-8")
    print("\n结果：", "全部通过" if not FAILS else f"失败 {len(FAILS)} 项：{FAILS}")
    print(f"检查项 {len(RESULTS)} 个，失败 {len(FAILS)} 个")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()

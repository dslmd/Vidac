"""命令行入口：python -m vidac <视频> [选项]"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

from . import ipc, media
from .asr import BACKENDS, MODEL_PRESETS


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="vidac",
        description="本地视频播放器：边播边用 Whisper 生成字幕，并用本地大模型翻译（完全离线）。",
    )
    p.add_argument("video", nargs="?",
                   help="视频文件（mp4 / mkv / mov / ts 等）。不填则启动后拖入文件或按 o 打开")
    p.add_argument("--model", default=None,
                   help=f"转写模型：{' / '.join(MODEL_PRESETS)}，或直接写 mlx 仓库名"
                        "（默认 base，也可用环境变量 VIDAC_MODEL 或 settings.json）")
    p.add_argument("--backend", choices=BACKENDS, default="auto",
                   help="识别后端。auto：有 mlx-whisper 用 mlx，否则 faster-whisper。"
                        "fake 只产生占位字幕，用于测试流程")
    p.add_argument("--language", default=None,
                   help="转写语言：auto（只在开头检测一次）、ja、en、zh、ko 等 Whisper 语言代码")
    p.add_argument("--audio-track", type=int, default=1,
                   help="转写第几条音轨，从 1 开始（默认 1）。播放中按 t 可以切换")
    p.add_argument("--list-tracks", action="store_true", help="只列出音轨然后退出")
    p.add_argument("--vad", action="store_true",
                   help="用能量阈值跳过没有人声的段，减少静音段的幻觉字幕")
    p.add_argument("--rebuild", action="store_true",
                   help="忽略已有字幕缓存，从头转写（同时重新翻译）")
    p.add_argument("--translate-engine", choices=["apple", "openai"], default=None,
                   help="翻译引擎：apple 用 macOS 自带的 Apple Intelligence（默认）；"
                        "openai 用 Ollama / LM Studio 这类 OpenAI 兼容服务")
    p.add_argument("--translate-url", default=None,
                   help="openai 引擎的服务地址（默认 http://localhost:11434/v1，即 Ollama）")
    p.add_argument("--translate-model", default=None,
                   help="openai 引擎的模型名（默认 qwen2.5:7b）")
    p.add_argument("--target-lang", default=None,
                   help="翻译目标语言：zh、zh-tw、en、ja、ko 等（默认跟随系统语言，读不到就用 en）")
    p.add_argument("--no-translate", action="store_true", help="不翻译，只显示原文字幕")
    p.add_argument("--retranslate", action="store_true", help="删除译文缓存，重新翻译")
    p.add_argument("--glossary", metavar="FILE", help="术语表文件，覆盖其他位置的同名条目")
    p.add_argument("--display", choices=["off", "orig", "trans", "bilingual"], default=None,
                   help="字幕显示：off 关闭，orig 原文，trans 译文，bilingual 双语（默认 bilingual）")
    p.add_argument("--font-scale", type=float, default=None,
                   help="字幕字号倍数（默认 1.0，播放中按 +/- 或 Tab 菜单调）")
    p.add_argument("--mpv-opt", action="append", default=[], metavar="KEY=VALUE",
                   help="额外传给 mpv 的选项，可重复，例如 --mpv-opt volume=80")
    p.add_argument("-v", "--verbose", action="store_true", help="打印调试日志")
    return p


def main(argv: list[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )
    media.check_tools()  # 只警告：缺 ffmpeg 时视频照常播放

    if args.video is not None:
        if not Path(args.video).is_file():
            parser.error(f"找不到文件：{args.video}")
        if args.list_tracks:
            try:
                for i, t in enumerate(media.probe_audio_tracks(Path(args.video)), 1):
                    print(f"音轨 {i}: {t.describe()}")
            except media.MediaError as exc:
                parser.exit(1, f"{exc}\n")
            return
        # 已有窗口在运行：把文件交给它，本进程直接退出
        abs_path = str(Path(args.video).expanduser().resolve())
        if not os.environ.get("VIDAC_ATTACH_SOCKET") and ipc.send_loadfile(abs_path):
            sys.exit(0)
    elif args.list_tracks:
        parser.error("--list-tracks 需要指定视频文件")

    from .mpvipc import MpvError
    from .player import App

    try:
        app = App(args)
    except MpvError as exc:
        print(f"无法启动 mpv：{exc}", file=sys.stderr)
        sys.exit(1)
    app.run()
    sys.exit(0)

#!/usr/bin/env bash
# 启动播放器。所有参数原样传给 subplayer，例如：
#   ./run.sh movie.mkv --language ja --model small
#   ./run.sh show.ts --audio-track 2 --target-lang en
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x .venv/bin/python ]; then
  echo "还没有安装，请先运行 ./install.sh" >&2
  exit 1
fi

# 从 Finder 启动（build_app.sh 生成的 App）时 PATH 很短，找不到 brew 装的 ffmpeg / ffprobe
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# brew 装的 libmpv 在 /opt/homebrew/lib（Intel Mac 是 /usr/local/lib），
# python-mpv 用 ctypes 加载，需要告诉它去哪找。
export DYLD_FALLBACK_LIBRARY_PATH="/opt/homebrew/lib:/usr/local/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"

exec .venv/bin/python -m subplayer "$@"

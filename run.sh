#!/usr/bin/env bash
# 启动播放器。所有参数原样传给 vidac，例如：
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

exec .venv/bin/python -m vidac "$@"

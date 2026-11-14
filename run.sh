#!/usr/bin/env bash
# Launch the player. All arguments are passed to vidac unchanged, for example:
#   ./run.sh movie.mkv --language ja --model small
#   ./run.sh show.ts --audio-track 2 --target-lang en
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x .venv/bin/python ]; then
  echo "Not installed yet. Run ./install.sh first." >&2
  exit 1
fi

# When launched from Finder (the app built by build_app.sh), PATH is short and brew-installed ffmpeg / ffprobe cannot be found
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

exec .venv/bin/python -m vidac "$@"

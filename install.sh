#!/usr/bin/env bash
# One-step install (macOS, Apple Silicon): brew installs ffmpeg / mpv, pip installs Python dependencies, and the default model is prefetched.
# Usage: ./install.sh            install and prefetch the default transcription model (base)
#       PREFETCH_MODEL=small ./install.sh   prefetch a different model
#       SKIP_PREFETCH=1 ./install.sh        install dependencies only; the model is downloaded on first open
#       WITH_OLLAMA=1 ./install.sh          also install Ollama as an alternative translation engine (not installed by default; Apple Intelligence is the default)
#       WITH_OLLAMA=1 TRANSLATE_MODEL=qwen2.5:3b ./install.sh   use a smaller translation model
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script only supports macOS." >&2; exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "Warning: not Apple Silicon, so mlx-whisper cannot be installed; falling back to faster-whisper (CPU)." >&2
fi

# ---- 1. Homebrew dependencies ----
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install it from https://brew.sh, then run this script again." >&2
  exit 1
fi
say "Installing ffmpeg and mpv with Homebrew"
brew install ffmpeg mpv

# ---- 2. Python 3.10+ ----
PY=""
for cand in python3.12 python3.11 python3.10; do
  if command -v "$cand" >/dev/null 2>&1; then PY="$(command -v "$cand")"; break; fi
done
if [ -z "$PY" ]; then
  say "Installing python@3.12"
  brew install python@3.12
  PY="$(brew --prefix)/bin/python3.12"
fi
echo "Using Python: $PY ($("$PY" --version))"

# ---- 3. Virtual environment and pip dependencies ----
say "Creating the .venv virtual environment and installing Python dependencies"
"$PY" -m venv .venv
.venv/bin/python -m pip install --upgrade pip >/dev/null
.venv/bin/python -m pip install -r requirements.txt

# ---- 4. Prefetch the transcription model ----
MODEL="${PREFETCH_MODEL:-base}"
if [ -z "${SKIP_PREFETCH:-}" ]; then
  say "Prefetching transcription model: ${MODEL} (downloaded from Hugging Face on first run, then available offline)"
  .venv/bin/python - "$MODEL" <<'PY'
import sys
sys.path.insert(0, ".")
from vidac.asr import resolve_mlx_repo, resolve_model
try:
    path = resolve_mlx_repo(resolve_model(sys.argv[1])["mlx"])
except Exception as exc:
    print(f"Model prefetch failed: {exc}", file=sys.stderr)
    print("This does not affect the installation; it will be retried the first time a video is opened.", file=sys.stderr)
    sys.exit(0)
print("Cached at", path)
PY
fi

# ---- 5. Build the Apple Intelligence translation component ----
# Translation uses the Apple Intelligence model built into macOS 26 by default, which requires compiling a small Swift tool.
# If the build fails, playback and original-language subtitles still work; only translation is unavailable.
say "Building the Apple Intelligence translation component"
mkdir -p bin
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Run xcode-select --install first, then run this script again. Translation is unavailable for now." >&2
elif swiftc -O -parse-as-library swift/apple_translate.swift -o bin/apple-translate 2>bin/build.log; then
  rm -f bin/build.log
  if bin/apple-translate --check >/dev/null 2>bin/.check.log; then
    echo "Apple Intelligence is available."
  else
    echo "The component was built, but Apple Intelligence is not available right now: $(cat bin/.check.log)" >&2
  fi
  rm -f bin/.check.log
else
  echo "Build failed (requires macOS 26 and the matching Xcode command line tools). Translation is unavailable for now; playback is not affected." >&2
  echo "swiftc errors are saved in: $(pwd)/bin/build.log" >&2
fi

# ---- 6. Optional: Ollama translation service (alternative when not using Apple Intelligence) ----
TRANSLATE_MODEL="${TRANSLATE_MODEL:-qwen2.5:7b}"
if [ -n "${WITH_OLLAMA:-}" ]; then
  say "Installing Ollama (local translation service)"
  brew install ollama
  brew services start ollama
  echo "Waiting for Ollama to start (up to 30 seconds)..."
  up=""
  for _ in $(seq 1 30); do
    if curl -sf http://localhost:11434 >/dev/null 2>&1; then up=1; break; fi
    sleep 1
  done
  if [ -z "$up" ]; then
    echo "Ollama did not start within 30 seconds. Run brew services list to see why, then run manually:" >&2
    echo "  ollama pull $TRANSLATE_MODEL" >&2
  else
    say "Downloading translation model: $TRANSLATE_MODEL"
    ollama pull "$TRANSLATE_MODEL"
  fi
fi

say "Installation complete. To start:"
echo "  ./run.sh /path/to/video.mkv"
echo "  ./run.sh            (no arguments; drag in a file or press o after launch)"
echo
echo "Translation uses the built-in Apple Intelligence on macOS by default (requires macOS 26 and enabling it in System Settings)."
echo "  When it is unavailable, playback and original-language subtitles work as usual; only translation is skipped."
echo "  To use Ollama instead: WITH_OLLAMA=1 ./install.sh, then ./run.sh video.mp4 --translate-engine openai"
echo
echo "Build the native Mac app: bash build_app.sh; build the portable version: bash build_app.sh --portable (see README)"

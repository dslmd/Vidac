#!/usr/bin/env bash
# 一键安装（macOS，Apple Silicon）：brew 装 ffmpeg / mpv，pip 装 Python 依赖，预下载默认模型。
# 用法：./install.sh            安装并预下载默认转写模型（base）
#       PREFETCH_MODEL=small ./install.sh   预下载别的模型
#       SKIP_PREFETCH=1 ./install.sh        只装依赖，模型等第一次打开时再下
#       WITH_OLLAMA=1 ./install.sh          同时装 Ollama 作为备选翻译引擎（默认不装，默认用 Apple Intelligence）
#       WITH_OLLAMA=1 TRANSLATE_MODEL=qwen2.5:3b ./install.sh   用更小的翻译模型
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "这个脚本只支持 macOS。" >&2; exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "警告：不是 Apple Silicon，mlx-whisper 会装不上，将改用 faster-whisper（CPU）。" >&2
fi

# ---- 1. Homebrew 依赖 ----
if ! command -v brew >/dev/null 2>&1; then
  echo "没有找到 Homebrew，请先到 https://brew.sh 安装，然后重新运行本脚本。" >&2
  exit 1
fi
say "用 Homebrew 安装 ffmpeg 和 mpv"
brew install ffmpeg mpv

# ---- 2. Python 3.10+ ----
PY=""
for cand in python3.12 python3.11 python3.10; do
  if command -v "$cand" >/dev/null 2>&1; then PY="$(command -v "$cand")"; break; fi
done
if [ -z "$PY" ]; then
  say "安装 python@3.12"
  brew install python@3.12
  PY="$(brew --prefix)/bin/python3.12"
fi
echo "使用 Python：$PY ($("$PY" --version))"

# ---- 3. 虚拟环境和 pip 依赖 ----
say "创建虚拟环境 .venv 并安装 Python 依赖"
"$PY" -m venv .venv
.venv/bin/python -m pip install --upgrade pip >/dev/null
.venv/bin/python -m pip install -r requirements.txt

# ---- 4. 预下载转写模型 ----
MODEL="${PREFETCH_MODEL:-base}"
if [ -z "${SKIP_PREFETCH:-}" ]; then
  say "预下载转写模型：$MODEL（第一次运行会从 Hugging Face 下载，之后离线可用）"
  .venv/bin/python - "$MODEL" <<'PY'
import sys
from huggingface_hub import snapshot_download
sys.path.insert(0, ".")
from vidac.asr import resolve_model
repo = resolve_model(sys.argv[1])["mlx"]
path = snapshot_download(repo)
print("已缓存到", path)
PY
fi

# ---- 5. 编译 Apple Intelligence 翻译组件 ----
# 翻译默认用 macOS 26 自带的 Apple Intelligence 模型，需要编译一个 Swift 小工具。
# 编译失败不影响播放和原文字幕，只是没有翻译。
say "编译 Apple Intelligence 翻译组件"
mkdir -p bin
if ! command -v swiftc >/dev/null 2>&1; then
  echo "没有找到 swiftc。请先运行 xcode-select --install，再重新运行本脚本。翻译暂时不可用。" >&2
elif swiftc -O -parse-as-library swift/apple_translate.swift -o bin/apple-translate; then
  if bin/apple-translate --check >/dev/null 2>bin/.check.log; then
    echo "Apple Intelligence 可用。"
  else
    echo "组件已编译，但 Apple Intelligence 现在不可用：$(cat bin/.check.log)" >&2
  fi
  rm -f bin/.check.log
else
  echo "编译失败（需要 macOS 26 和对应的 Xcode 命令行工具）。翻译暂时不可用，播放不受影响。" >&2
fi

# ---- 6. 可选：Ollama 翻译服务（不用 Apple Intelligence 时的备选） ----
TRANSLATE_MODEL="${TRANSLATE_MODEL:-qwen2.5:7b}"
if [ -n "${WITH_OLLAMA:-}" ]; then
  say "安装 Ollama（本地翻译服务）"
  brew install ollama
  brew services start ollama
  echo "等待 Ollama 启动（最多 30 秒）..."
  up=""
  for _ in $(seq 1 30); do
    if curl -sf http://localhost:11434 >/dev/null 2>&1; then up=1; break; fi
    sleep 1
  done
  if [ -z "$up" ]; then
    echo "Ollama 没有在 30 秒内启动，请运行 brew services list 查看原因，然后手动执行：" >&2
    echo "  ollama pull $TRANSLATE_MODEL" >&2
  else
    say "下载翻译模型：$TRANSLATE_MODEL"
    ollama pull "$TRANSLATE_MODEL"
  fi
fi

say "安装完成。启动方法："
echo "  ./run.sh /路径/到/视频.mkv"
echo "  ./run.sh            （不带参数，启动后拖入文件或按 o）"
echo
echo "翻译默认用 macOS 自带的 Apple Intelligence（需要 macOS 26 并在系统设置里开启）。"
echo "  不可用时照常播放和显示原文字幕，只是不翻译。"
echo "  想改用 Ollama：WITH_OLLAMA=1 ./install.sh，然后 ./run.sh 视频.mp4 --translate-engine openai"
echo
echo "想做成 Mac 软件（可拖到图标上打开）：./build_app.sh（没有在 Mac 上验证过，见 README）"

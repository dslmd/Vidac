#!/usr/bin/env bash
# Build the native macOS Vidac application. --install deploys this Mac's runtime.
set -euo pipefail
cd "$(dirname "$0")"
PROJECT="$(pwd)"
INSTALL=0
PORTABLE=0
for argument in "$@"; do
  case "$argument" in
    --install) INSTALL=1 ;;
    --portable) PORTABLE=1 ;;
    *) echo "Usage: bash build_app.sh [--portable] [--install]" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != Darwin ]; then
  echo "build_app.sh can only run on macOS." >&2
  exit 1
fi
if [ ! -x .venv/bin/python ]; then
  echo "Dependencies are not installed yet. Run bash install.sh first." >&2
  exit 1
fi
MPV_PREFIX="$(brew --prefix mpv)"
if [ ! -f "$MPV_PREFIX/include/mpv/client.h" ]; then
  echo "libmpv development files not found. Run brew install mpv." >&2
  exit 1
fi

RUNTIME="$PROJECT"
if [ "$INSTALL" = 1 ] && [ "$PORTABLE" = 0 ]; then
  RUNTIME="$HOME/Library/Application Support/vidac/Application"
  mkdir -p "$RUNTIME"
  if [ "$(cd "$RUNTIME" && pwd -P)" != "$(pwd -P)" ]; then
    for folder in vidac swift bin macos assets; do
      [ ! -d "$folder" ] || ditto "$folder" "$RUNTIME/$folder"
    done
    for file in run.sh install.sh build_app.sh requirements.txt requirements-fallback.txt README.md LICENSE; do
      cp "$file" "$RUNTIME/$file"
    done
    if [ ! -x "$RUNTIME/.venv/bin/python" ]; then
      ditto .venv "$RUNTIME/.venv"
    fi
  fi
fi

APP="$PROJECT/build/Vidac.app"
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos26.0" \
  -import-objc-header macos/MPVBridge.h \
  -I "$MPV_PREFIX/include" -L "$MPV_PREFIX/lib" -lmpv \
  -Xlinker -rpath -Xlinker "$MPV_PREFIX/lib" \
  -framework AppKit -framework OpenGL -framework QuartzCore -framework UniformTypeIdentifiers -framework MediaPlayer \
  macos/*.swift -o "$APP/Contents/MacOS/Vidac"
printf '%s\n' "$RUNTIME" > "$APP/Contents/Resources/runtime-path.txt"
cp assets/Vidac.icns "$APP/Contents/Resources/Vidac.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
.venv/bin/python scripts/make_info_plist.py "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
if [ "$PORTABLE" = 1 ]; then
  .venv/bin/python scripts/build_portable_app.py --app "$APP" --output "$PROJECT/dist/Vidac.app"
  APP="$PROJECT/dist/Vidac.app"
  RUNTIME="$APP/Contents/Resources/runtime"
fi
if [ "$INSTALL" = 1 ]; then
  if [ -d /Applications/Vidac.app ]; then
    mkdir -p "$HOME/.Trash"
    mv /Applications/Vidac.app "$HOME/.Trash/Vidac-replaced-$(date +%Y%m%d-%H%M%S).app"
  fi
  ditto "$APP" /Applications/Vidac.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Vidac.app
  echo "Installed: /Applications/Vidac.app"
  echo "Runtime directory: $RUNTIME"
fi
echo "Log: $HOME/Library/Logs/vidac-native.log"

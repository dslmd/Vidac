#!/usr/bin/env bash
# 生成 Vidac.app：一个 AppleScript droplet，启动时调用本项目的 run.sh。
# 用法：./build_app.sh             生成 build/Vidac.app
#       ./build_app.sh --install  生成后复制到 /Applications
#
# 注意：App 里记录的是本项目目录的绝对路径，项目目录移动或重命名后要重新运行本脚本。
# 只能在 macOS 上运行（需要 osacompile 和 PlistBuddy）。
set -euo pipefail
cd "$(dirname "$0")"
PROJECT="$(pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "build_app.sh 只能在 macOS 上运行。" >&2
  exit 1
fi
for tool in osacompile /usr/libexec/PlistBuddy; do
  if [ ! -x "$tool" ] && ! command -v "$tool" >/dev/null 2>&1; then
    echo "找不到 $tool，请确认安装了 Xcode 命令行工具（xcode-select --install）。" >&2
    exit 1
  fi
done
if [ ! -x .venv/bin/python ]; then
  echo "还没有安装依赖，请先运行 ./install.sh" >&2
  exit 1
fi

APP="$PROJECT/build/Vidac.app"
SCRIPT="$PROJECT/build/Vidac.applescript"
mkdir -p "$PROJECT/build"

# 项目路径写进 AppleScript 字符串，先转义反斜杠和双引号
ESC_PROJECT="$(printf '%s' "$PROJECT" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"

cat > "$SCRIPT" <<EOF
-- 由 build_app.sh 生成。拖文件到图标上、右键“打开方式”、双击关联都会走 on open。
property projectDir : "$ESC_PROJECT"

on launchWith(filePath)
	set cmd to "cd " & quoted form of projectDir & " && ./run.sh"
	if filePath is not "" then
		set cmd to cmd & " " & quoted form of filePath
	end if
	set cmd to cmd & " >> \\"\$HOME/Library/Logs/vidac.log\\" 2>&1 &"
	do shell script cmd
end launchWith

on run
	launchWith("")
end run

on open theFiles
	set firstFile to POSIX path of (item 1 of theFiles)
	launchWith(firstFile)
end open
EOF

rm -rf "$APP"
osacompile -o "$APP" "$SCRIPT"

PLIST="$APP/Contents/Info.plist"
set_plist() {  # set_plist <键> <类型> <值>：有就改，没有就加
  /usr/libexec/PlistBuddy -c "Set :$1 $3" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST"
}
set_plist CFBundleName string Vidac
set_plist CFBundleIdentifier string local.vidac
set_plist CFBundleDisplayName string Vidac
# 让 Finder 把视频文件关联到这个 App（双击打开方式）
/usr/libexec/PlistBuddy -c "Delete :CFBundleDocumentTypes" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleDocumentTypes array" \
  -c "Add :CFBundleDocumentTypes:0 dict" \
  -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string Video" \
  -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string public.movie" \
  -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:1 string public.audiovisual-content" \
  "$PLIST"

echo "已生成：$APP"
echo "日志：\$HOME/Library/Logs/vidac.log"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/Vidac.app"
  cp -R "$APP" "/Applications/Vidac.app"
  echo "已复制到 /Applications/Vidac.app"
fi

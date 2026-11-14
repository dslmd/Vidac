#!/usr/bin/env bash
# Build a downloadable disk image of Vidac, optionally signed, notarized and
# published as a draft GitHub release.
#
# Environment (both optional; set both for a notarized public release):
#   VIDAC_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   VIDAC_NOTARY_PROFILE  keychain profile for notarytool, created once with:
#                           xcrun notarytool store-credentials vidac-notary \
#                             --apple-id you@example.com --team-id TEAMID
#                         The app-specific password is typed at the prompt and
#                         kept in the keychain, never in this repository.
#
# Usage:
#   bash scripts/release.sh                      build the disk image into dist/
#   bash scripts/release.sh --publish            also create a draft GitHub release
#   bash scripts/release.sh --notes-only [signed|unnotarized]
#                                                print the release notes and exit
#                                                (default: unnotarized)
#
# With both variables set the app and the disk image are signed with the
# Developer ID, notarized and stapled, and the result is
#   dist/Vidac-<version>-arm64.dmg
# Without them the app is ad-hoc signed and the result is clearly named
#   dist/Vidac-<version>-arm64-unnotarized.dmg
# Either way a .sha256 file is written next to the disk image, and the
# intermediate ZIP is removed so dist/ holds a single download.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
REPO_URL="https://github.com/dslmd/Vidac"
README_NAME="Read Me First - 请先阅读.txt"

die() { echo "error: $*" >&2; exit 1; }

# --- Text shown to users ------------------------------------------------------

# Plain-text file placed inside the disk image. $1 = signed | unnotarized
write_readme() {
  local mode="$1" out="$2"
  {
    echo "Vidac $VERSION"
    echo
    echo "INSTALL"
    echo "1. Drag Vidac onto the Applications folder in this window."
    echo "2. Eject this disk image, then open Vidac from Applications."
    if [ "$mode" = unnotarized ]; then
      echo
      echo "FIRST OPEN (this build is not notarized by Apple)"
      echo "macOS blocks the first open and says it cannot verify the app."
      echo "1. Click Done (do not move it to the Trash)."
      echo "2. Open System Settings > Privacy & Security."
      echo "3. Scroll down to the message about Vidac and click \"Open Anyway\","
      echo "   then confirm with your password or Touch ID."
      echo "This is only needed once; afterwards Vidac opens normally."
    fi
    echo
    echo "SUBTITLES"
    echo "Speech-recognition models are not included in the download. The first"
    echo "time you generate subtitles, Vidac downloads the default \"base\" model"
    echo "from Hugging Face automatically. After that it works offline."
    echo
    echo "Requires a Mac with Apple Silicon and macOS 26.2 or later."
    echo "License: GPL-3.0-or-later. Source code: $REPO_URL"
    echo
    echo "------------------------------------------------------------"
    echo
    echo "Vidac $VERSION"
    echo
    echo "安装"
    echo "1. 在此窗口中把 Vidac 拖到“应用程序”（Applications）文件夹。"
    echo "2. 推出此磁盘映像，然后从“应用程序”中打开 Vidac。"
    if [ "$mode" = unnotarized ]; then
      echo
      echo "首次打开（此版本未经 Apple 公证）"
      echo "首次打开时 macOS 会阻止并提示无法验证此 App。"
      echo "1. 点击“完成”（不要移到废纸篓）。"
      echo "2. 打开 系统设置 > 隐私与安全性。"
      echo "3. 向下滚动到关于 Vidac 的提示，点击“仍要打开”，"
      echo "   再用密码或触控 ID 确认。"
      echo "只需操作一次，之后即可正常打开。"
    fi
    echo
    echo "字幕"
    echo "下载包中不含语音识别模型。第一次生成字幕时，Vidac 会自动从"
    echo "Hugging Face 下载默认的 \"base\" 模型，之后即可离线使用。"
    echo
    echo "需要 Apple 芯片的 Mac，macOS 26.2 或更高版本。"
    echo "许可证：GPL-3.0-or-later。源代码：$REPO_URL"
  } > "$out"
}

# Markdown release notes on stdout. $1 = signed | unnotarized
release_notes() {
  local mode="$1" dmg changes
  if [ "$mode" = signed ]; then dmg="Vidac-$VERSION-arm64.dmg"; else dmg="Vidac-$VERSION-arm64-unnotarized.dmg"; fi
  changes="$(awk -v v="## $VERSION" '$0 == v {on=1; next} on && /^## / {exit} on' CHANGELOG.md)"
  [ -n "$(printf '%s' "$changes" | tr -d '[:space:]')" ] || die "CHANGELOG.md has no \"## $VERSION\" section."

  echo "## Install / 安装"
  echo
  if [ "$mode" = unnotarized ]; then
    echo "> **Notice:** this build is **not notarized by Apple** (it is ad-hoc signed). macOS will block the first open; follow step 3 below once. Verify the download with the \`.sha256\` file if you like."
    echo ">"
    echo "> **注意：**此版本**未经 Apple 公证**（仅为临时签名）。首次打开会被 macOS 阻止，请按下面第 3 步操作一次。可用 \`.sha256\` 文件校验下载。"
    echo
  fi
  echo "**English**"
  echo
  echo "1. Download \`$dmg\` and open it."
  echo "2. Drag **Vidac** onto the **Applications** folder, then eject the disk image."
  if [ "$mode" = unnotarized ]; then
    echo "3. Open Vidac from Applications. When macOS says it cannot verify the app, click **Done**, go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the message about Vidac, then confirm. This is needed only once."
  else
    echo "3. Open Vidac from Applications."
  fi
  echo
  echo "Requirements: a Mac with Apple Silicon, macOS 26.2 or later."
  echo
  echo "Speech-recognition models are not included in the download. The first time you generate subtitles, Vidac downloads the default \`base\` model from Hugging Face automatically; after that it works offline."
  echo
  echo "**中文**"
  echo
  echo "1. 下载 \`$dmg\` 并打开。"
  echo "2. 把 **Vidac** 拖到 **应用程序**（Applications）文件夹，然后推出磁盘映像。"
  if [ "$mode" = unnotarized ]; then
    echo "3. 从“应用程序”打开 Vidac。macOS 提示无法验证此 App 时，点击 **完成**，前往 **系统设置 → 隐私与安全性**，向下滚动，在关于 Vidac 的提示旁点击 **仍要打开** 并确认。只需操作一次。"
  else
    echo "3. 从“应用程序”打开 Vidac。"
  fi
  echo
  echo "系统要求：Apple 芯片的 Mac，macOS 26.2 或更高版本。"
  echo
  echo "下载包中不含语音识别模型。第一次生成字幕时，Vidac 会自动从 Hugging Face 下载默认的 \`base\` 模型，之后即可离线使用。"
  echo
  echo "## Changes / 更新内容"
  echo
  printf '%s\n' "$changes" | sed -e '/./,$!d'
  echo
  echo "---"
  echo
  echo "Third-party components and their licenses: see [THIRD_PARTY_NOTICES.md]($REPO_URL/blob/v$VERSION/THIRD_PARTY_NOTICES.md). Vidac is licensed under [GPL-3.0-or-later]($REPO_URL/blob/v$VERSION/LICENSE)."
}

# --- Disk image ---------------------------------------------------------------

# make_dmg <app> <dmg> <signed|unnotarized> <work dir>
# Stages a copy of the app, an Applications link and the read-me file in
# <work dir>/stage and builds a compressed (ULMO) disk image from it.
make_dmg() {
  local app="$1" dmg="$2" mode="$3" work="$4" stage
  stage="$work/stage"
  rm -rf "$stage"
  mkdir -p "$stage"
  ditto "$app" "$stage/$(basename "$app")"
  ln -s /Applications "$stage/Applications"
  write_readme "$mode" "$stage/$README_NAME"
  rm -f "$dmg"
  hdiutil create -volname "Vidac $VERSION" -srcfolder "$stage" -ov -format ULMO "$dmg"
  rm -rf "$stage"
}

write_sha256() {
  local file="$1"
  (cd "$(dirname "$file")" && shasum -a 256 "$(basename "$file")" > "$(basename "$file").sha256")
}

# notarize <file> <work dir>: submit and wait; fail unless Accepted.
notarize() {
  local file="$1" result
  result="$2/notarization-$(basename "$file").json"
  echo "Submitting $(basename "$file") for notarization (usually a few minutes)..."
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json | tee "$result"
  echo
  grep -q '"status" *: *"Accepted"' "$result" || \
    die "Notarization of $(basename "$file") was not accepted. See why: xcrun notarytool log <submission id> --keychain-profile $PROFILE"
}

# --- Main ---------------------------------------------------------------------

main() {
  local publish=0
  case "${1:-}" in
    "") ;;
    --publish) publish=1 ;;
    --notes-only)
      case "${2:-unnotarized}" in
        signed|unnotarized) release_notes "${2:-unnotarized}"; return 0 ;;
        *) die "--notes-only takes \"signed\" or \"unnotarized\"." ;;
      esac ;;
    *) echo "Usage: bash scripts/release.sh [--publish | --notes-only [signed|unnotarized]]" >&2; exit 2 ;;
  esac

  IDENTITY="${VIDAC_SIGN_IDENTITY:-}"
  PROFILE="${VIDAC_NOTARY_PROFILE:-}"
  local mode=unnotarized
  if [ -n "$IDENTITY" ] || [ -n "$PROFILE" ]; then
    [ -n "$IDENTITY" ] && [ -n "$PROFILE" ] || die "Set both VIDAC_SIGN_IDENTITY and VIDAC_NOTARY_PROFILE, or neither."
    security find-identity -v -p codesigning | grep -F "$IDENTITY" >/dev/null || \
      die "Signing identity not found in the keychain: $IDENTITY"
    mode=signed
  fi

  # Release preconditions are checked before the long build, and again after.
  local head_commit=""
  if [ "$publish" = 1 ]; then
    command -v gh >/dev/null || die "--publish needs the GitHub CLI (gh)."
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "--publish must run inside the git repository."
    local status
    status="$(git status --porcelain)"
    [ -z "$status" ] || die "The working tree is not clean; commit or stash first."
    head_commit="$(git rev-parse HEAD)"
    git fetch --quiet origin
    remote_branches="$(git branch -r --contains "$head_commit")"
    [ -n "$remote_branches" ] || die "The current commit is not on any branch of origin; push it first."
    release_notes "$mode" > /dev/null
  fi

  local app="dist/Vidac.app"
  local zip="dist/Vidac-$VERSION-arm64.zip"
  local dmg
  if [ "$mode" = signed ]; then dmg="dist/Vidac-$VERSION-arm64.dmg"; else dmg="dist/Vidac-$VERSION-arm64-unnotarized.dmg"; fi

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/vidac-release.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT

  VIDAC_SIGN_IDENTITY="${IDENTITY:--}" bash build_app.sh --portable
  [ -d "$app" ] || die "build_app.sh did not produce $app"

  if [ "$mode" = signed ]; then
    codesign --verify --deep --strict --verbose=2 "$app"
    notarize "$zip" "$WORK"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
  else
    echo "VIDAC_SIGN_IDENTITY not set: the app is ad-hoc signed and will not be notarized."
  fi

  # One download in dist/: the disk image and its checksum.
  rm -f "$zip" "$zip.sha256" \
        "dist/Vidac-$VERSION-arm64.dmg" "dist/Vidac-$VERSION-arm64.dmg.sha256" \
        "dist/Vidac-$VERSION-arm64-unnotarized.dmg" "dist/Vidac-$VERSION-arm64-unnotarized.dmg.sha256"
  make_dmg "$app" "$dmg" "$mode" "$WORK"

  if [ "$mode" = signed ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$dmg"
    codesign --verify --verbose=2 "$dmg"
    notarize "$dmg" "$WORK"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  fi
  hdiutil verify "$dmg"
  write_sha256 "$dmg"
  echo "Done: $dmg"
  echo "      $dmg.sha256"

  if [ "$publish" = 1 ]; then
    [ "$(git rev-parse HEAD)" = "$head_commit" ] || die "HEAD changed during the build; not publishing."
    [ -z "$(git status --porcelain)" ] || die "The working tree changed during the build; not publishing."
    local notes="$WORK/release-notes.md"
    release_notes "$mode" > "$notes"
    gh release create "v$VERSION" "$dmg" "$dmg.sha256" --draft --target "$head_commit" \
      --title "Vidac $VERSION" --notes-file "$notes"
    echo
    echo "Draft release v$VERSION created. To publish it, review it on"
    echo "  $REPO_URL/releases"
    echo "and click \"Publish release\", or run:"
    echo "  gh release edit v$VERSION --draft=false"
  fi
}

# Run only when executed, so the functions can be sourced for testing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

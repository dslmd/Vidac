#!/usr/bin/env bash
# Build, sign, notarize and staple a release of Vidac.
#
#   VIDAC_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   VIDAC_NOTARY_PROFILE  keychain profile created once with:
#                         xcrun notarytool store-credentials vidac-notary \
#                           --apple-id you@example.com --team-id TEAMID
#                         (the app-specific password is typed at the prompt
#                          and kept in the keychain, never in this repository)
#
#   bash scripts/release.sh            build + sign + notarize + staple
#   bash scripts/release.sh --publish  additionally create a draft GitHub release
#
# Without VIDAC_SIGN_IDENTITY the result is ad-hoc signed and clearly named
# "-unnotarized"; it is not suitable as the public download.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1
IDENTITY="${VIDAC_SIGN_IDENTITY:-}"
PROFILE="${VIDAC_NOTARY_PROFILE:-}"
APP="dist/Vidac.app"
ZIP="dist/Vidac-$VERSION-arm64.zip"

if [ -n "$IDENTITY" ]; then
  security find-identity -v -p codesigning | grep -F "$IDENTITY" >/dev/null || {
    echo "Signing identity not found in the keychain: $IDENTITY" >&2; exit 1; }
  [ -n "$PROFILE" ] || { echo "Set VIDAC_NOTARY_PROFILE (see the top of this script)." >&2; exit 1; }
fi

VIDAC_SIGN_IDENTITY="${IDENTITY:--}" bash build_app.sh --portable

if [ -z "$IDENTITY" ]; then
  UNSIGNED="dist/Vidac-$VERSION-arm64-unnotarized.zip"
  mv "$ZIP" "$UNSIGNED"; rm -f "$ZIP.sha256"
  (cd dist && shasum -a 256 "$(basename "$UNSIGNED")" > "$(basename "$UNSIGNED").sha256")
  echo "VIDAC_SIGN_IDENTITY not set: built a locally signed, unnotarized $UNSIGNED"
  exit 0
fi

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Submitting for notarization (usually takes a few minutes)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json | tee dist/notarization.json
grep -q '"status" *: *"Accepted"' dist/notarization.json || {
  echo "Notarization failed. See why: xcrun notarytool log <id> --keychain-profile $PROFILE" >&2; exit 1; }
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
# The stapled ticket lives inside the bundle, so the archive is made again.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Done: $ZIP"

if [ "$PUBLISH" = 1 ]; then
  git diff --quiet && git diff --cached --quiet || { echo "The working tree has uncommitted changes." >&2; exit 1; }
  # The tag must name exactly the commit this archive was built from.
  HEAD_COMMIT="$(git rev-parse HEAD)"
  git fetch --quiet origin
  git branch -r --contains "$HEAD_COMMIT" | grep -q . || { echo "The current commit has not been pushed to origin." >&2; exit 1; }
  NOTES="$(mktemp)"
  awk -v v="## $VERSION" '$0 ~ "^"v {on=1; next} on && /^## / {exit} on' CHANGELOG.md > "$NOTES"
  gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" --draft --target "$HEAD_COMMIT" --title "Vidac $VERSION" --notes-file "$NOTES"
  echo "Draft release created. Review it, then click Publish on GitHub."
fi

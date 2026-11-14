# Releasing

Target platform: Apple Silicon, macOS 26.0 or later (the `LSMinimumSystemVersion` written by `scripts/make_info_plist.py`). The version number is written only in `VERSION` at the repository root, and release notes go in `CHANGELOG.md` under a `## <version>` heading. `scripts/release.sh` copies that whole section (both the English and 中文 subsections) into the GitHub release notes, so write both before releasing.

The public download is a disk image. Users open it, drag Vidac onto the `Applications` link, and open it from there. Speech-recognition models are not in the download: the default `base` model is fetched from Hugging Face the first time subtitles are generated, and Vidac works offline afterwards.

There are two kinds of release, chosen by the environment:

| | Signed and notarized | Un-notarized (current) |
| --- | --- | --- |
| Environment | `VIDAC_SIGN_IDENTITY` and `VIDAC_NOTARY_PROFILE` both set | neither set |
| App signature | Developer ID, hardened runtime, notarized, stapled | ad-hoc |
| Download | `dist/Vidac-<version>-arm64.dmg` | `dist/Vidac-<version>-arm64-unnotarized.dmg` |
| First open | opens normally | blocked once; user clicks **Open Anyway** in System Settings → Privacy & Security |

Setting only one of the two variables is an error. Vidac currently has no Developer ID certificate, so releases are un-notarized.

## One-time setup (for notarized releases)

1. Join the Apple Developer Program and install a **Developer ID Application** certificate in your keychain. `security find-identity -v -p codesigning` should list it.
2. Generate an app-specific password at <https://account.apple.com>, then store the notarization credentials in the keychain:

   ```bash
   xcrun notarytool store-credentials vidac-notary --apple-id <Apple ID> --team-id <TEAMID>
   ```

   Enter the password at the prompt; it is kept only in the keychain. Never put certificates, passwords or private keys in source code, scripts or GitHub workflows.

## Each release

```bash
# Only for a notarized release:
export VIDAC_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
export VIDAC_NOTARY_PROFILE=vidac-notary

bash scripts/release.sh --notes-only            # preview the release notes (un-notarized wording)
bash scripts/release.sh --notes-only signed     # preview the notarized wording
bash scripts/release.sh                         # build the disk image into dist/
bash scripts/release.sh --publish               # same, then create a draft GitHub release
```

`--notes-only` only prints the notes to stdout; it does not build anything. It fails if `CHANGELOG.md` has no section for the current version.

What `scripts/release.sh` does:

1. With `--publish`, checks first (before the long build) that `gh` is installed, the work tree is clean (`git status --porcelain` is empty), and that after `git fetch origin` the current commit is contained in a branch on `origin`.
2. Runs `VIDAC_SIGN_IDENTITY="${IDENTITY:--}" bash build_app.sh --portable`, which assembles the self-contained `dist/Vidac.app`, signs every Mach-O in the bundle from the inside out (with a Developer ID: hardened runtime, secure timestamp, and `macos/Vidac.entitlements` on executables, since the embedded Python's Numba/LLVM needs the JIT entitlement), and writes `dist/Vidac-<version>-arm64.zip` with its `.sha256`.
3. Signed release only: `codesign --verify --deep --strict` on the app, `notarytool submit --wait` on the ZIP (the script stops unless the status is `Accepted`), `stapler staple` and `stapler validate` on the app, and `spctl --assess --type execute`.
4. Deletes the intermediate ZIP and its `.sha256` (and any older disk image of the same version), then builds the disk image from a temporary staging folder containing a `ditto` copy of `Vidac.app`, an `Applications` symlink to `/Applications`, and a bilingual (English and Simplified Chinese) `Read Me First - 请先阅读.txt` with the install steps, the model-download note and, for un-notarized builds only, the Gatekeeper **Open Anyway** steps (系统设置 → 隐私与安全性 → 仍要打开). It uses `hdiutil create -volname "Vidac <version>" -srcfolder <staging> -ov -format ULMO`. The staging folder lives in a temporary directory that a `trap` removes on exit.
5. Signed release only: signs the disk image with the same identity (`--timestamp`), notarizes it with `notarytool --wait`, staples and validates it, and checks it with `spctl --assess --type open`.
6. Runs `hdiutil verify`, writes `<dmg>.sha256` (`shasum -a 256`, basename only), so `dist/` holds a single download: the disk image and its checksum next to `Vidac.app`.
7. With `--publish` (allowed for both kinds of release): re-checks that HEAD and the work tree did not change during the build, generates the release notes into a temporary file, and runs

   ```bash
   gh release create "v$VERSION" <dmg> <dmg>.sha256 --draft --target "$(git rev-parse HEAD)" \
     --title "Vidac $VERSION" --notes-file <notes>
   ```

   The release is only a draft. Review it on GitHub and click **Publish release**, or run `gh release edit v<version> --draft=false`. GitHub creates the `v<version>` tag on the target commit when the draft is published.

The release notes consist of:

- an **Install / 安装** section, English then Chinese: download and drag-to-Applications steps, the Gatekeeper **Open Anyway** steps and a clearly worded "not notarized by Apple" notice for un-notarized builds, the system requirements, and the note that models download on first use;
- the `CHANGELOG.md` section for this version (the lines after `## <version>` up to the next `## ` heading);
- a closing line pointing to `THIRD_PARTY_NOTICES.md` and the GPL-3.0-or-later license.

If notarization fails, run `xcrun notarytool log <submission ID> --keychain-profile vidac-notary` to see which file is at fault. A common cause is an embedded binary that is unsigned or lacks the hardened runtime.

## Pre-release checks

- `CHANGELOG.md` has a `## <version>` section matching `VERSION`; preview the result with `bash scripts/release.sh --notes-only`.
- The dependency audit of `bash build_app.sh --portable` passes (no load paths pointing to `/Users/…` or `/opt/homebrew/…`).
- On an M-series Mac that has no development environment, open the disk image, drag Vidac to Applications, open it (for an un-notarized build, through **Open Anyway**), play a video, generate subtitles (this downloads the model the first time) and quit. Testing from a different folder on the same machine is not a substitute.
- `THIRD_PARTY_NOTICES.md` matches the components actually in the package; update it after upgrading IINA, Python packages or FFmpeg.
- `git status` shows no models, media, subtitle caches or personal configuration.

## License obligations

The release includes GPL-licensed libmpv and FFmpeg libraries. When distributing the binaries you must also provide: the source of this repository at the corresponding tag, `LICENSE`, `THIRD_PARTY_NOTICES.md`, and the upstream source access methods listed there. The dynamic libraries come from the official IINA release package and are unmodified apart from install-name rewriting, trimming to arm64 and re-signing.

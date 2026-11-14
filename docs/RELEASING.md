# Releasing

Target platform: Apple Silicon, macOS 26.2 or later. The version number is written only in `VERSION` at the repository root, and release notes go in `CHANGELOG.md`.

## One-time setup

1. Join the Apple Developer Program and install a **Developer ID Application** certificate in your keychain. `security find-identity -v -p codesigning` should list it.
2. Generate an app-specific password at <https://account.apple.com>, then store the notarization credentials in the keychain:

   ```bash
   xcrun notarytool store-credentials vidac-notary --apple-id <Apple ID> --team-id <TEAMID>
   ```

   Enter the password at the prompt; it is kept only in the keychain. Never put certificates, passwords or private keys in source code, scripts or GitHub workflows.

## Each release

```bash
export VIDAC_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
export VIDAC_NOTARY_PROFILE=vidac-notary
bash scripts/release.sh            # build, sign, notarize, staple; output goes to dist/
bash scripts/release.sh --publish  # same, and create a draft Release with gh
```

What the script does:

- `build_app.sh --portable` assembles the self-contained `dist/Vidac.app` and signs every Mach-O in the bundle from the inside out, with the hardened runtime and a secure timestamp enabled; executables get `macos/Vidac.entitlements` attached (the embedded Python's Numba/LLVM needs the JIT entitlement).
- `notarytool submit --wait` submits for notarization; once it passes, `stapler staple` staples the ticket into the app, and `spctl --assess` verifies the Gatekeeper verdict.
- It re-creates the ZIP and generates a SHA256. `--publish` only creates a draft; confirm and publish it manually on GitHub.

When `VIDAC_SIGN_IDENTITY` is not set, the script produces `Vidac-<version>-arm64-unnotarized.zip`: it is only locally (ad-hoc) signed, can be copied between your own Macs, and should not be used as a public download.

If notarization fails, run `xcrun notarytool log <submission ID> --keychain-profile vidac-notary` to see which file is at fault. A common cause is an embedded binary that is unsigned or lacks the hardened runtime.

## Pre-release checks

- The dependency audit of `bash build_app.sh --portable` passes (no load paths pointing to `/Users/…` or `/opt/homebrew/…`).
- Actually open the app, play a video, generate subtitles and quit on an M-series Mac that has no development environment. Testing from a different folder on the same machine is not a substitute.
- `THIRD_PARTY_NOTICES.md` matches the components actually in the package; update it after upgrading IINA, Python packages or FFmpeg.
- `git status` shows no models, media, subtitle caches or personal configuration.

## License obligations

The release includes GPL-licensed libmpv and FFmpeg libraries. When distributing the binaries you must also provide: the source of this repository at the corresponding tag, `LICENSE`, `THIRD_PARTY_NOTICES.md`, and the upstream source access methods listed there. The dynamic libraries come from the official IINA release package and are unmodified apart from install-name rewriting, trimming to arm64 and re-signing.

# Development and verification

The native app currently targets Apple Silicon. The minimum OS version of the portable package is determined by all of its native dependencies together, not only by the main program's compile flags. The current release target is macOS 26.2+.

## Installing development dependencies

```bash
xcode-select --install
bash install.sh
```

The install script installs mpv and ffmpeg through Homebrew, creates `.venv`, installs `requirements.txt` and builds `bin/apple-translate`. `SKIP_PREFETCH=1 bash install.sh` skips the model prefetch. Development dependencies and model downloads require an internet connection.

## Building

```bash
bash build_app.sh
bash build_app.sh --install
bash build_app.sh --portable
```

The development build uses local dependencies; the portable release build additionally collects the runtime and dynamic libraries, and the build machine also needs the official IINA's companion player libraries. Users who receive the app do not need to install IINA. For the complete inputs, sources and build steps, see [PACKAGING.md](../PACKAGING.md).

The release tooling records sources, checks dynamic linking and produces the archive. `bash build_app.sh --portable --install` installs that same portable artifact. Do not treat the development build as a dependency-free release build. The Python package versions of the verified environment are recorded in `requirements-macos-arm64.lock`, and can be reproduced in a matching macOS arm64 / Python 3.12 virtual environment with `python -m pip install -r requirements-macos-arm64.lock`.

## Automated checks

```bash
.venv/bin/python -m unittest discover -s tests -v
swiftc macos/TrackpadGestures.swift tests/trackpad_gestures.swift -o /tmp/vidac-gesture-tests
/tmp/vidac-gesture-tests
bash -n install.sh run.sh build_app.sh
```

The Python tests use synthetic audio or fake backends to verify the cache, IPC, subtitle and translation protocols; some are skipped when samples are missing. The Swift behavior tests verify deltas, boundaries, cancellation and end actions. They do not prove how real fingers feel, recognition accuracy, translation quality, or how it actually runs on other Macs.

`.github/workflows/checks.yml` only runs source behavior checks; it does not produce a signed release, does not use release credentials and does not upload the app. Signing and notarization are done on the maintainer's own machine with `scripts/release.sh`.

## Manual regression

On a real trackpad, check short and slow pinches, immediate reversal, several gestures in a row, screen edges and the minimum window size. Confirm that regular window zooming follows the fingers without drifting, with a single haptic tap on reaching a boundary, and that full screen zooms only the video. Open landscape, portrait and ultrawide videos and confirm the window fits the video's aspect ratio. With natural scrolling both on and off, check that swiping right fast-forwards and swiping up raises the volume. Run the seek gesture in both the playing and paused states.

Also check opening files, dragging in files, bilingual subtitles, playback position restore, control bar show/hide, the settings panels and switching to full screen. With the system "Reduce Motion" setting on, confirm the interface is still fully usable.

## Local files

Settings and position records are in `~/Library/Application Support/vidac/`; the native log is at `~/Library/Logs/vidac-native.log`. These files may contain media paths. Model caches, user subtitles, test media and the local environment are not part of the source release.

The original command-line mode keeps arguments such as `--language`, `--model`, `--target-lang` and `--no-translate`; `bash run.sh --help` is the authority for the full list. The Apple Intelligence translation helper can be checked for availability on the current system with `bin/apple-translate --check`.

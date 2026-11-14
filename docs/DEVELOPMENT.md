# Development and verification

The native app currently targets Apple Silicon. The minimum OS version of the portable package is determined by all of its native dependencies together, not only by the main program's compile flags. The current release target is macOS 26.0+, matching `LSMinimumSystemVersion` in `scripts/make_info_plist.py`.

## Source layout

`build_app.sh` compiles every `macos/*.swift` file together, so a new file needs no registration. The frameworks it links include AppKit, OpenGL, QuartzCore, UniformTypeIdentifiers and MediaPlayer.

| File | Role |
| --- | --- |
| `VidacApp.swift` | The mpv engine, the video surface, `PlayerController` and the app delegate |
| `PlayerLoading.swift` | Opening and closing videos, load events and errors, recents, display sleep, window memory, companion lifecycle |
| `PlayerActions.swift` | Key handling, actions, context menu, menu validation |
| `PlayerQueue.swift` | Playlist from a folder or several files, Next/Previous, Up Next |
| `PlayerChrome.swift`, `PlayerOverlays.swift` | Title strip, scrub bubble, notice card, duration label, hover and auto-hide logic, update notice |
| `AppMenus.swift`, `PlayerHooks.swift` | Menu bar; Help menu |
| `Shortcuts.swift` | `ShortcutTable`, the list behind Help → Keyboard Shortcuts and Gestures |
| `WelcomeView.swift` | Welcome page, recent videos, resume points |
| `NowPlaying.swift` | Now Playing info and remote commands |
| `UpdateCheck.swift` | The once-a-day update check (api.github.com) |
| `SettingsWindow.swift` | Settings window: General, Subtitles, Trackpad |
| `SubtitleModel.swift` | Decodes the companion's state; language and model tables; the wording of notices |
| `SubtitleStatus.swift`, `SubtitleViews.swift` | Status label and badge, "catching up" note, resume card, subtitle margin |
| `SubtitleControls.swift`, `SubtitlePopover.swift` | Subtitle menu, keys and actions; the popover on the control bar |
| `TrackpadGestures.swift`, `TrackpadVideoSurface.swift`, `NativeMotion.swift` | Gesture reducer, surface that feeds it, window motion |
| `VideoFormats.swift` | Registered video types |

`ShortcutTable` is not wired to the key handler or the menus: when you change a binding in `PlayerActions.swift`, `AppMenus.swift` or the subtitle controls, update `Shortcuts.swift` and the keyboard table in both READMEs by hand.

## Companion protocol and state

The Swift app and the Python subtitle companion (`vidac/player.py`) share one libmpv core and talk through it; `docs/COMPANION_PROTOCOL.md` is the contract. The companion publishes a single JSON object, `user-data/vidac-state` (built in `vidac/state.py`, decoded by `SubtitleModel.swift`), and the app builds every status label, badge and error from its fields instead of parsing text. The app sends `setting` and `action` script messages and publishes `user-data/vidac-subtitle-bottom`. In native mode (`VIDAC_NATIVE_UI=1`) the companion draws no status overlay and does not publish the old `user-data/vidac-status`. Change the protocol document together with both sides.

Subtitle files written by the companion always have `.vidac.` in the name (`<name>.vidac.<lang>.srt`, `<name>.vidac.tr.<lang>.srt`, `<name>.vidac.json`); user-supplied subtitle files are read-only to it. Keep it that way: anything that writes, moves or deletes subtitle files must check for `.vidac.`.

Preferences the app writes (UserDefaults) include `AutoAdvance`, `ShowRemainingTime`, `AutomaticUpdateCheck`, `SettingsPane`, `Volume`, `FloatOnTop`, `SubtitleLastDisplayMode` and the trackpad keys; per-video subtitle settings and playback positions live under `~/Library/Application Support/vidac/`.

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

The Python tests use synthetic audio or fake backends to verify the cache, IPC, subtitle and translation protocols and the companion state (`tests/test_state.py`, `tests/test_review_fixes.py`); some are skipped when samples are missing. `tests/e2e_xvfb.py` (Linux/Xvfb) still asserts the old status text and is out of date. The Swift behavior tests verify deltas, boundaries, cancellation and end actions. They do not prove how real fingers feel, recognition accuracy, translation quality, or how it actually runs on other Macs.

`.github/workflows/checks.yml` only runs source behavior checks; it does not produce a signed release, does not use release credentials and does not upload the app. Signing and notarization are done on the maintainer's own machine with `scripts/release.sh`.

## Manual regression

On a real trackpad, check short and slow pinches, immediate reversal, several gestures in a row, screen edges and the minimum window size. Confirm that regular window zooming follows the fingers without drifting, with a single haptic tap on reaching a boundary, and that full screen zooms only the video. Open landscape, portrait and ultrawide videos and confirm the window fits the video's aspect ratio. With natural scrolling both on and off, check that swiping right fast-forwards and swiping up raises the volume. Run the seek gesture in both the playing and paused states.

Also check the Settings window, the subtitle badge and popover (model download, offline, translation unavailable), the playlist and Up Next, the keyboard shortcuts against the Help window, and the first-run model download. None of the AppKit interface is covered by automated tests. Also check opening files, dragging in files, bilingual subtitles, playback position restore, control bar show/hide, the settings panels and switching to full screen. With the system "Reduce Motion" setting on, confirm the interface is still fully usable.

## Local files

Settings and position records are in `~/Library/Application Support/vidac/`; the native log is at `~/Library/Logs/vidac-native.log`; screenshots go to `~/Pictures/Vidac`. These files may contain media paths. Model caches, user subtitles, test media and the local environment are not part of the source release.

The original command-line mode keeps arguments such as `--language`, `--model`, `--target-lang` and `--no-translate`; `bash run.sh --help` is the authority for the full list. The Apple Intelligence translation helper can be checked for availability on the current system with `bin/apple-translate --check`.

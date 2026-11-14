# Vidac

English | [简体中文](README.zh-CN.md)

A native macOS video player with on-device transcription and bilingual subtitles.

Vidac is a native video player for Apple Silicon Macs. Open a file to play it; speech is recognized in the background to generate subtitles, which Apple Intelligence can translate into bilingual subtitles.

## Download

Download the latest disk image from [GitHub Releases](https://github.com/dslmd/Vidac/releases/latest).

## Usage

Vidac requires **Apple Silicon (M-series) and macOS 26.2 or later**.

1. Download `Vidac-<version>-arm64-unnotarized.dmg` from the release page.
2. Open the disk image and drag `Vidac` into the Applications folder.
3. Open Vidac from Applications.

The player, audio tools and Python subtitle runtime ship with the app, so you do not need to install Homebrew or Python. Speech-recognition models are not included in the download: the first time you generate subtitles, Vidac downloads the model automatically from Hugging Face (the default is the "base" model), which requires an internet connection; after that, subtitles work offline. For the compatibility and verification scope of the actual release package, see the [release notes](docs/RELEASING.md).

### First open of an un-notarized build

Current builds are only ad-hoc signed and are not yet notarized by Apple, which is why the file name contains `-unnotarized`. The first time you open one, macOS blocks it. To allow it:

1. Try to open Vidac once and dismiss the warning.
2. Open "System Settings → Privacy & Security".
3. Scroll down to the message about Vidac being blocked and click "Open Anyway".
4. Confirm, and Vidac opens. You only need to do this once.

Once builds are signed with a Developer ID and notarized by Apple (`scripts/release.sh`), the disk image will be named `Vidac-<version>-arm64.dmg` and these steps will no longer be needed.

### Playback

- Choose "Open Video…", press `⌘O`, or drag a local video into the window.
- Press Space to play or pause, and `F` to toggle full screen.
- "Vidac → Subtitle Settings…" adjusts the display mode, recognition language, model and target language.
- "Vidac → Trackpad Settings…" adjusts swipe sensitivity or turns off the on-screen gestures.
- `⌘0` (Actual Size) resets the zoom; the Window menu also offers Zoom In and Zoom Out.
- "Vidac → Make Default Video Player…" makes Vidac the default app for video files in Finder.

Vidac registers more than 60 extensions, including MP4, MKV, MOV, AVI, WMV, FLV, WebM, TS/M2TS, RMVB, MPEG, 3GP, OGV, MXF and raw H.264/HEVC streams; see `scripts/make_info_plist.py` for the full list. Whether a file plays depends on whether libmpv can decode its codecs; DRM-protected video is not supported.

## Trackpad

| Gesture | Result |
| --- | --- |
| Two-finger swipe right / left | Continuous fast-forward / rewind; seeks precisely on release |
| Two-finger swipe up / down | Increase / decrease volume |
| Pinch in a regular window | Enlarge / shrink the window by the video's aspect ratio, anchored at the window center |
| Pinch in full screen | Zoom the video; subtitles and the control bar keep their size |
| `⌘0` | Reset zoom |

A pinch takes effect as soon as the gesture event arrives, with no interpolation or trailing animation; after a video opens, the window fits the video's aspect ratio. Once the gesture direction is locked, a diagonal swipe does not change position and volume at the same time, and release inertia does not keep adjusting. A regular window is limited by the visible area of the current screen; the full-screen zoom range is 50–300%.

## Automatic subtitles and privacy

- Recognition uses mlx-whisper by default, and models are downloaded on demand. Video and audio are processed on this Mac by default.
- Translation uses macOS Foundation Models by default, which requires Apple Intelligence to be enabled and the model to be available. If it is unavailable or refuses a sentence, the original text is kept and playback continues.
- A same-named `.srt` and any existing subtitle cache are read first. Original and translated text can be shown as bilingual subtitles or turned off separately.
- Subtitles and recognition progress are saved next to the video when possible; if that folder is not writable, the user cache folder is used.
- Settings, playback positions and logs are stored under the current user's Library and should not be committed to the source repository.
- The optional Ollama / LM Studio compatible interface is configured by the user; with the default settings, media is not uploaded to any cloud translation service.

Recognition accuracy and translation quality depend on the audio, language, model and system availability; there is no guarantee that every segment can be recognized or translated.

## Building from source

The development environment requires an Apple Silicon Mac, the macOS 26 SDK or later, Xcode Command Line Tools, Homebrew and Python 3.12.

```bash
bash install.sh
bash build_app.sh
```

The local development build is written to `build/Vidac.app` and can still rely on the local development environment. For the portable release build, use:

```bash
bash build_app.sh --portable
```

That process needs to download the release runtime and compile some audio dependencies, and writes its output to `dist/`. For development, dependency and test commands, see [DEVELOPMENT.md](docs/DEVELOPMENT.md); for pre-release signing, licensing and verification on another Mac, see [RELEASING.md](docs/RELEASING.md). Do not upload `.venv`, `build`, `dist`, models or personal subtitles to GitHub.

## Project structure

```text
macos/       AppKit window, video rendering, gestures and native UI
vidac/       Subtitle recognition, translation, caching and player IPC
swift/       Apple Intelligence translation component
scripts/     Build and release tools
tests/       Python regression tests and Swift gesture behavior tests
assets/      App icon
```

Swift/AppKit and libmpv play in the same process, and a Python subprocess handles local subtitles; no separate player window is opened. The original command-line entry point is still available: `bash run.sh /path/to/video.mp4`; see `bash run.sh --help` for its arguments. The legacy scroll-wheel bindings of the command-line window differ from the native app's continuous gestures.

## License

Vidac is released under the [GNU General Public License, version 3 or later](LICENSE) (GPL-3.0-or-later). This license was chosen because the libmpv and FFmpeg libraries in the release package are GPL builds, and a program distributed together with them must use a compatible license.

Third-party components in the release package keep their own licenses; for the list and how to obtain the corresponding source, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), the same file that is also included in the app at `Vidac.app/Contents/Resources/ThirdParty/`. Speech recognition models are not distributed with the package; users download them on first use and must comply with their respective licenses.

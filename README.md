# Vidac

English | [简体中文](README.zh-CN.md)

A native macOS video player with on-device transcription and bilingual subtitles.

Vidac is a native video player for Apple Silicon Macs. Open a file to play it; speech is recognized in the background to generate subtitles, which Apple Intelligence can translate into bilingual subtitles.

## Download

Download the latest disk image from [GitHub Releases](https://github.com/dslmd/Vidac/releases/latest).

## Usage

Vidac requires **Apple Silicon (M-series) and macOS 26.0 or later**.

1. Download `Vidac-<version>-arm64-unnotarized.dmg` from the release page.
2. Open the disk image and drag `Vidac` into the Applications folder.
3. Open Vidac from Applications.

The player, audio tools and Python subtitle runtime ship with the app, so you do not need to install Homebrew or Python. Speech-recognition models are not included in the download: the first time Vidac generates subtitles it downloads the model from Hugging Face (the default is the "Base" model, about 140 MB; the app shows the progress and a Cancel button), which requires an internet connection; after that, subtitles work offline. Translation with Apple Intelligence needs Apple Intelligence to be turned on in System Settings. For the compatibility and verification scope of the actual release package, see the [release notes](docs/RELEASING.md).

### First open of an un-notarized build

Current builds are only ad-hoc signed and are not yet notarized by Apple, which is why the file name contains `-unnotarized`. The first time you open one, macOS blocks it. To allow it:

1. Try to open Vidac once and dismiss the warning.
2. Open "System Settings → Privacy & Security".
3. Scroll down to the message about Vidac being blocked and click "Open Anyway".
4. Confirm, and Vidac opens. You only need to do this once.

Once builds are signed with a Developer ID and notarized by Apple (`scripts/release.sh`), the disk image will be named `Vidac-<version>-arm64.dmg` and these steps will no longer be needed.

### Playback

- Choose File → Open…, press `⌘O`, or drag local videos or a folder into the window. Several videos, or a folder, become a queue in natural order; `⌘→` / `⌘←` move to the next and previous video, and "Up Next" counts down 5 seconds at the end (Esc cancels). Playback → Play Next Automatically turns this on or off.
- Hover over the progress bar for a time bubble; dragging seeks by keyframes and releasing seeks exactly. Click the duration to show the remaining time instead.
- The welcome page lists recent videos with their resume points. Playback resumes where you stopped.
- Playback speed, Go to Time… (`⌘J`), Float on Top, screenshots (`S`, saved to `~/Pictures/Vidac` without subtitles) and a right-click menu are available; see the Playback, Video and Help menus.
- Vidac registers Now Playing and the media keys, keeps the display awake while a video plays, and remembers window position, picture size and volume.
- "Vidac → Make Default Video Player…" makes Vidac the default app for video files in Finder.

Vidac registers more than 60 extensions, including MP4, MKV, MOV, AVI, WMV, FLV, WebM, TS/M2TS, RMVB, MPEG, 3GP, OGV, MXF and raw H.264/HEVC streams; see `scripts/make_info_plist.py` for the full list. Whether a file plays depends on whether libmpv can decode its codecs; DRM-protected video is not supported. A file that cannot be opened shows a message saying why.

## Keyboard shortcuts

The same list is in Help → Keyboard Shortcuts and Gestures. Keys on the left are alternatives.

| Keys | Action |
| --- | --- |
| **Playback** | |
| `Space` / `K` | Play or pause (Replay at the end) |
| `←` / `→` | Skip back or forward 5 seconds |
| `⇧←` / `⇧→` | Skip back or forward 1 second |
| `⌥←` / `⌥→` | Skip back or forward 30 seconds |
| `J` / `L` | Skip back or forward 10 seconds |
| `0` – `9` | Jump to 0% – 90% of the video |
| `Home` | Go to the beginning |
| `⌘J` | Go to a time |
| `,` / `.` | Previous or next frame |
| `[` / `]` | Slower or faster |
| `⌫` | Normal speed |
| **Playlist** | |
| `⌘→` / `⌘←` | Next or previous video in the folder or selection |
| `Esc` | Cancel "Up Next" |
| **Sound** | |
| `↑` / `↓` | Volume up or down |
| `M` | Mute |
| **Picture and window** | |
| `F` / `⌃⌘F` | Enter or leave full screen |
| `Esc` | Leave full screen |
| `⌘=` / `⌘-` | Zoom in or out |
| `⌘0` | Actual size |
| `⌃⌘T` | Float on top |
| `S` | Take a screenshot |
| `⌘O` | Open a video… |
| `⌘W` | Close the video (or the window) |
| **Subtitles** | |
| `C` | Show or hide subtitles |
| `V` | Cycle bilingual, original and translation |
| `-` / `=` | Smaller or larger subtitles |
| `Z` / `X` | Show subtitles earlier or later by 0.1 seconds (`⌥` for 0.5) |
| `T` | Next audio track |
| `⌘,` | Settings… |

Mouse and trackpad: click plays or pauses; double-click toggles full screen; right-click opens a menu; drag the picture to move the window; drop videos or a folder to open them as a queue. The two-finger gestures are in the next section.

## Trackpad

| Gesture | Result |
| --- | --- |
| Two-finger swipe right / left | Continuous fast-forward / rewind; seeks precisely on release |
| Two-finger swipe up / down | Increase / decrease volume |
| Pinch in a regular window | Enlarge / shrink the window by the video's aspect ratio, anchored at the window center |
| Pinch in full screen | Zoom the video; subtitles and the control bar keep their size |
| Two-finger double-tap | Actual size |
| `⌘0` | Reset zoom |

A pinch takes effect as soon as the gesture event arrives, with no interpolation or trailing animation; after a video opens, the window fits the video's aspect ratio. Once the gesture direction is locked, a diagonal swipe does not change position and volume at the same time, and release inertia does not keep adjusting. A regular window is limited by the visible area of the current screen; the full-screen zoom range is 50–300%.

## Settings

Press `⌘,` (Vidac → Settings…). The window has three panes and remembers the last one you used.

- **General**: Play Next Automatically; Check for Updates Automatically, with a Check Now button.
- **Subtitles**: automatic subtitles on or off; speech model (Tiny, Base, Small, Medium, Large v3 Turbo, Large v3, with approximate download sizes and a speed/accuracy note); spoken language (Auto or a specific language); translation on or off and the target language; display mode (bilingual, original only, translation only); size; delay; where subtitle files are kept; Regenerate and Show Files. Changing the model or language for a video that already has generated subtitles asks first, because the subtitles are created again.
- **Trackpad**: turn the gestures on or off and set the sensitivity.

The Subtitles menu and the captions button on the control bar offer the same quick controls for the current video.

## Automatic subtitles and privacy

- Recognition uses mlx-whisper by default, and models are downloaded on demand. Video and audio are processed on this Mac by default.
- Translation uses macOS Foundation Models by default, which requires Apple Intelligence to be enabled and the model to be available. If it is unavailable, Vidac shows the reason; if it refuses a sentence, the original text is kept and playback continues. The translation target language defaults to the system language.
- Subtitle files written by Vidac are named `<name>.vidac.<lang>.srt` for the original and `<name>.vidac.tr.<lang>.srt` for the translation, with progress in `<name>.vidac.json`. By default they are next to the video; if that folder is not writable they go to the user cache folder, and Settings → Subtitles can instead keep them in `~/Library/Application Support/vidac/subtitles`.
- Your own subtitle files (for example `movie.srt` or `movie.en.srt`) are used when present and are never overwritten, moved or deleted: Vidac only changes files with `.vidac.` in the name. Subtitles that 0.5 and earlier wrote under plain names are still read.
- Settings, playback positions and logs are stored under the current user's Library and should not be committed to the source repository.
- The optional Ollama / LM Studio compatible interface is configured by the user; with the default settings, media is not uploaded to any cloud translation service.
- Network use: the speech model is downloaded from Hugging Face the first time it is needed. Once a day Vidac asks `api.github.com` for the latest release to show an update notice; no personal data and nothing about your videos is sent. Turn this off in Settings → General (Check for Updates Automatically). Nothing else is sent.

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
macos/       AppKit window, video rendering, gestures, menus, Settings and subtitle UI
vidac/       Subtitle recognition, translation, caching and the companion state
swift/       Apple Intelligence translation component
scripts/     Build and release tools
tests/       Python regression tests and Swift gesture behavior tests
assets/      App icon
```

Swift/AppKit and libmpv play in the same process, and a Python subprocess handles local subtitles; no separate player window is opened. The original command-line entry point is still available: `bash run.sh /path/to/video.mp4`; see `bash run.sh --help` for its arguments. The legacy scroll-wheel bindings of the command-line window differ from the native app's continuous gestures.

## License

Vidac is released under the [GNU General Public License, version 3 or later](LICENSE) (GPL-3.0-or-later). This license was chosen because the libmpv and FFmpeg libraries in the release package are GPL builds, and a program distributed together with them must use a compatible license.

Third-party components in the release package keep their own licenses; for the list and how to obtain the corresponding source, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), the same file that is also included in the app at `Vidac.app/Contents/Resources/ThirdParty/`. Speech recognition models are not distributed with the package; users download them on first use and must comply with their respective licenses.

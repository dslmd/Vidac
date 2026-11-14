# Changelog

## 0.5.0

- Pinch zoom takes effect directly inside the gesture event instead of waiting for the next screen refresh; the window size and video update in the same commit, with a single haptic tap on reaching the maximum or minimum size.
- After a video opens, the window automatically fits the video's aspect ratio with no black bars; later zooming and manual resizing keep that ratio.
- The control bar slides in and out, with the window buttons and pointer hiding along with it; the progress and volume bars use a slimmer style; the welcome screen fades out to the first frame; drag the video to move the window.
- Window changes from `⌘=`, `⌘-` and `⌘0` now animate smoothly (applied immediately when "Reduce Motion" is on).
- Registers more than 60 video extensions (including `.ts`, `.mkv`, `.rmvb` and raw streams) and adds "Vidac → Make Default Video Player…".
- The app identifier is now `io.github.dslmd.vidac`; existing recent files and trackpad settings are migrated automatically.
- The project is released under GPL-3.0-or-later; adds a third-party component list and signing and notarization scripts.

## 0.4.0

- Native window, trackpad gestures, automatic bilingual subtitles and a portable build.

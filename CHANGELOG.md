# Changelog

## 0.5.0

### English

- PyTorch is no longer bundled; transcription uses MLX, which removes about 620 MB from the installed app and makes the download and installation smaller.
- Distributed as a DMG disk image: open it and drag Vidac into Applications.
- The interface is in English.
- The README is now bilingual (English and Simplified Chinese).
- Pinch zoom takes effect directly inside the gesture event instead of waiting for the next screen refresh; the window size and video update in the same commit, with a single haptic tap on reaching the maximum or minimum size.
- After a video opens, the window automatically fits the video's aspect ratio with no black bars; later zooming and manual resizing keep that ratio.
- The control bar slides in and out, with the window buttons and pointer hiding along with it; the progress and volume bars use a slimmer style; the welcome screen fades out to the first frame; drag the video to move the window.
- Window changes from `⌘=`, `⌘-` and `⌘0` now animate smoothly (applied immediately when "Reduce Motion" is on).
- Registers more than 60 video extensions (including `.ts`, `.mkv`, `.rmvb` and raw streams) and adds "Vidac → Make Default Video Player…".
- The app identifier is now `io.github.dslmd.vidac`; existing recent files and trackpad settings are migrated automatically.
- The project is released under GPL-3.0-or-later; adds a third-party component list and signing and notarization scripts.

### 中文

- 不再内置 PyTorch；语音识别改用 MLX，安装后的应用减少约 620 MB，下载和安装体积都更小。
- 以 DMG 磁盘映像分发：打开后将 Vidac 拖入“应用程序”文件夹即可。
- 界面改为英文。
- README 提供英文和简体中文两个版本。
- 捏合缩放直接在手势事件中生效，不再等待下一次屏幕刷新；窗口尺寸与视频在同一次提交中更新，达到最大或最小尺寸时触发一次触觉反馈。
- 视频打开后，窗口自动适配视频宽高比，不留黑边；之后的缩放和手动调整大小都保持该比例。
- 控制栏滑入滑出，窗口按钮和指针随之隐藏；进度条和音量条采用更细的样式；欢迎界面淡出到视频首帧；拖动视频即可移动窗口。
- `⌘=`、`⌘-` 和 `⌘0` 引起的窗口变化现在有平滑动画（开启“减弱动态效果”时立即生效）。
- 注册 60 多种视频扩展名（包括 `.ts`、`.mkv`、`.rmvb` 和裸流），并新增 “Vidac → Make Default Video Player…”（设为默认视频播放器）。
- 应用标识符改为 `io.github.dslmd.vidac`；已有的最近文件和触控板设置会自动迁移。
- 项目以 GPL-3.0-or-later 发布；新增第三方组件列表以及签名和公证脚本。

## 0.4.0

### English

- Native window, trackpad gestures, automatic bilingual subtitles and a portable build.

### 中文

- 原生窗口、触控板手势、自动双语字幕以及可移植版本。

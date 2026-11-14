# Vidac

[English](README.md) | 简体中文

一款原生 macOS 视频播放器，支持本机语音识别与双语字幕。

Vidac 是为 Apple Silicon Mac 打造的原生视频播放器。打开文件即可播放；后台会识别语音并生成字幕，还可以借助 Apple Intelligence 翻译成双语字幕。

## 下载

请从 [GitHub Releases](https://github.com/dslmd/Vidac/releases/latest) 下载最新的磁盘映像（DMG）。

## 使用

Vidac 需要 **Apple Silicon（M 系列）芯片及 macOS 26.2 或更高版本**。

1. 从发布页面下载 `Vidac-<version>-arm64-unnotarized.dmg`。
2. 打开磁盘映像，将 `Vidac` 拖入“应用程序”文件夹。
3. 从“应用程序”中打开 Vidac。

播放器、音频工具和 Python 字幕运行环境都已随应用附带，无需安装 Homebrew 或 Python。下载包中不包含语音识别模型：第一次生成字幕时，Vidac 会自动从 Hugging Face 下载模型（默认为 “base” 模型），此时需要联网；之后即可离线生成字幕。实际发布包的兼容性与验证范围，请参阅[发布说明](docs/RELEASING.md)。

### 首次打开未公证的版本

目前的版本仅做了 ad-hoc 签名，尚未经过 Apple 公证，因此文件名中带有 `-unnotarized`。首次打开时 macOS 会阻止运行。允许打开的步骤如下：

1. 先尝试打开一次 Vidac，然后关闭弹出的警告。
2. 打开“系统设置 → 隐私与安全性”。
3. 向下滚动，找到 Vidac 被阻止的提示，点击“仍要打开”。
4. 确认后 Vidac 即可打开。此操作只需进行一次。

待版本使用 Developer ID 签名并经 Apple 公证后（`scripts/release.sh`），磁盘映像将改名为 `Vidac-<version>-arm64.dmg`，届时不再需要上述步骤。

### 播放

- 选择 “Open Video…”（打开视频）、按 `⌘O`，或将本地视频拖入窗口。
- 按空格键播放或暂停，按 `F` 切换全屏。
- “Vidac → Subtitle Settings…”（字幕设置）可调整显示模式、识别语言、模型和目标语言。
- “Vidac → Trackpad Settings…”（触控板设置）可调整滑动灵敏度或关闭屏幕手势。
- `⌘0`（Actual Size，实际大小）重置缩放；Window 菜单中还有 Zoom In 和 Zoom Out（放大、缩小）。
- “Vidac → Make Default Video Player…”（设为默认视频播放器）可将 Vidac 设为访达中视频文件的默认应用。

Vidac 注册了 60 多种扩展名，包括 MP4、MKV、MOV、AVI、WMV、FLV、WebM、TS/M2TS、RMVB、MPEG、3GP、OGV、MXF 以及 H.264/HEVC 裸流；完整列表见 `scripts/make_info_plist.py`。文件能否播放取决于 libmpv 能否解码其编码格式；不支持受 DRM 保护的视频。

## 触控板

| 手势 | 效果 |
| --- | --- |
| 双指向右 / 向左滑动 | 连续快进 / 快退；松开时精确定位 |
| 双指向上 / 向下滑动 | 增大 / 减小音量 |
| 在普通窗口中捏合 | 以窗口中心为锚点，按视频宽高比放大 / 缩小窗口 |
| 在全屏中捏合 | 缩放视频；字幕和控制栏保持原有大小 |
| `⌘0` | 重置缩放 |

捏合在手势事件到达时立即生效，没有插值或拖尾动画；视频打开后，窗口会适配视频的宽高比。手势方向锁定后，斜向滑动不会同时改变进度和音量，松手后的惯性也不会继续调节。普通窗口受当前屏幕可见区域限制；全屏缩放范围为 50–300%。

## 自动字幕与隐私

- 识别默认使用 mlx-whisper，模型按需下载。视频和音频默认在这台 Mac 上处理。
- 翻译默认使用 macOS Foundation Models，需要启用 Apple Intelligence 且模型可用。若不可用或某句被拒绝翻译，则保留原文，播放不受影响。
- 优先读取同名 `.srt` 文件和已有的字幕缓存。原文和译文可以显示为双语字幕，也可以分别关闭。
- 字幕和识别进度尽可能保存在视频旁边；如果该文件夹不可写，则使用用户缓存文件夹。
- 设置、播放位置和日志保存在当前用户的 Library 下，不应提交到源码仓库。
- 可选的 Ollama / LM Studio 兼容接口由用户自行配置；在默认设置下，媒体不会上传到任何云端翻译服务。

识别准确率和翻译质量取决于音频、语言、模型和系统可用性；不保证每一段都能被识别或翻译。

## 从源码构建

开发环境需要 Apple Silicon Mac、macOS 26 SDK 或更高版本、Xcode Command Line Tools、Homebrew 和 Python 3.12。

```bash
bash install.sh
bash build_app.sh
```

本地开发版本输出到 `build/Vidac.app`，仍可依赖本地开发环境。如需构建可移植的发布版本，请使用：

```bash
bash build_app.sh --portable
```

该过程需要下载发布用的运行环境并编译部分音频依赖，输出写入 `dist/`。开发、依赖和测试命令见 [DEVELOPMENT.md](docs/DEVELOPMENT.md)；发布前的签名、许可证以及在另一台 Mac 上的验证，见 [RELEASING.md](docs/RELEASING.md)。请勿将 `.venv`、`build`、`dist`、模型或个人字幕上传到 GitHub。

## 项目结构

```text
macos/       AppKit 窗口、视频渲染、手势和原生界面
vidac/       字幕识别、翻译、缓存和播放器 IPC
swift/       Apple Intelligence 翻译组件
scripts/     构建和发布工具
tests/       Python 回归测试和 Swift 手势行为测试
assets/      应用图标
```

Swift/AppKit 与 libmpv 在同一进程中播放，由一个 Python 子进程负责本地字幕；不会另外打开播放器窗口。原有的命令行入口仍然可用：`bash run.sh /path/to/video.mp4`；参数见 `bash run.sh --help`。命令行窗口沿用的滚轮绑定与原生应用的连续手势不同。

## 许可证

Vidac 以 [GNU 通用公共许可证第 3 版或更高版本](LICENSE)（GPL-3.0-or-later）发布。选择该许可证，是因为发布包中的 libmpv 和 FFmpeg 库是 GPL 构建，与之一起分发的程序必须使用兼容的许可证。

发布包中的第三方组件保留各自的许可证；组件列表及获取相应源代码的方式见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，该文件也包含在应用内的 `Vidac.app/Contents/Resources/ThirdParty/` 中。语音识别模型不随发布包分发；用户在首次使用时自行下载，并须遵守各模型的许可证。

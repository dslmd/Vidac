# subplayer

本地视频播放器。打开视频后立即播放，字幕在后台边播边生成，生成的字幕再交给本地大模型翻译。

- 播放器优先：没有字幕、模型没下载、转写失败、翻译服务没开，视频都照常播放。
- 完全离线：识别用本机的 Whisper，翻译默认用 macOS 自带的 Apple Intelligence。也可以改用本机的 Ollama 或 LM Studio。不调用任何云端 API。
- 播放：mpv（通过 python-mpv 控制）。识别：mlx-whisper（Apple Silicon），装不上时用 faster-whisper（CPU）。
  解码：ffmpeg。支持 mp4、mkv、mov、ts 等，多音轨可选。

## 功能

- 打开本地视频：命令行传路径、拖进窗口、按 `o`，或在 Finder 里拖到 App 上（见“制作 Mac 软件”）。
- 边播边转写：每 30 秒一段，从播放位置开始往后转；拖动后优先转写新位置附近的段。
- 翻译：逐行翻译成中文（或其他目标语言），支持术语表。默认用 Apple Intelligence，备选 Ollama / LM Studio。
- 双语字幕：译文在上，原文在下。可以切换为只看原文、只看译文或关闭。
- 设置菜单：按 `Tab` 打开，叠加在视频上，不占画面。改字幕模式、翻译开关、目标语言、转写语言和模型、音轨、字号、倍速。
- 记住上次播放位置，同一个视频下次从原来的位置继续。
- 触控板：两指左右滑快进快退，上下滑调音量，双击全屏，设置菜单里能切换窗口大小（见“触控板”一节）。
- 单实例：窗口已经开着时，再用命令行或 Finder 打开另一个视频，会切换到原窗口里播放。
- 同名字幕优先：视频旁边有 `.srt` 时直接加载，不重新转写。

## 安装

需要 macOS（Apple Silicon）和 [Homebrew](https://brew.sh)。

```bash
cd subplayer
./install.sh
```

脚本会做这些事：`brew install ffmpeg mpv`，创建 `.venv` 虚拟环境并安装 `requirements.txt`，预下载默认转写模型 `base`，然后用 `swiftc` 编译翻译组件 `bin/apple-translate`。编译需要 Xcode 命令行工具，没有的话先运行 `xcode-select --install`。编译失败时播放照常，只是没有译文。

可选环境变量：

- `PREFETCH_MODEL=small ./install.sh`：预下载别的转写模型
- `SKIP_PREFETCH=1 ./install.sh`：不下载转写模型，等第一次打开时再下
- `WITH_OLLAMA=1 ./install.sh`：同时安装 Ollama 并下载翻译模型，作为备选翻译引擎（默认不装）
- `WITH_OLLAMA=1 TRANSLATE_MODEL=qwen2.5:3b ./install.sh`：下载更小的翻译模型

### 翻译引擎：Apple Intelligence（默认）

用的是 macOS 26 自带的 Apple Intelligence 本机模型（Foundation Models 框架）。完全离线，不需要 Ollama，也不用下载别的模型。要求：

- macOS 26 或更新，并且是支持 Apple Intelligence 的 Mac。
- 系统设置里已开启 Apple Intelligence，模型也已经下载完。
- 翻译组件已经编译（`install.sh` 会做，需要 Xcode 命令行工具）。

只能用系统自带的这一个模型。菜单里的“翻译模型”一行显示“系统自带”，不能切换。

不可用时（没开启、设备不支持、模型没下载完、组件没编译），状态行会显示“翻译不可用：<原因>。只显示原文”，播放不受影响。

**没有在 Mac 上验证过。** `swift/apple_translate.swift` 没有在 Mac 上编译和运行过，Linux 上也没有这个框架。日译中的质量没有实测，系统模型也可能对某些内容触发安全护栏而拒绝翻译。被拒绝或超长的批次会自动拆小重试，拆到单行仍然失败的那一行只显示原文。

### 备选：安装 Ollama

只有想用 Ollama、而不用 Apple Intelligence 时才需要这一节。

方法一：让安装脚本装。`WITH_OLLAMA=1 ./install.sh`，它会 `brew install ollama`、启动服务、下载 `qwen2.5:7b`。

方法二：手动装。`brew install ollama`（或到 ollama.com 下载应用），然后：

```bash
brew services start ollama       # 或者打开 Ollama 应用
ollama pull qwen2.5:7b
```

内存紧张可以换 `qwen2.5:3b`，用 `--translate-model qwen2.5:3b` 或在菜单里改翻译模型。

装好后，启动时加 `--translate-engine openai`，或在菜单里把“翻译引擎”改成 Ollama / LM Studio。

**翻译质量没有实测。** 我没有在真实的日译中数据上比较过 `qwen2.5:7b` 和 `qwen2.5:3b` 的效果，请自己试几段再决定用哪个。

## 启动

```bash
./run.sh /路径/到/视频.mkv
./run.sh 节目.ts --audio-track 2 --language ja
./run.sh                     # 不带参数，启动后把文件拖进窗口，或按 o
```

只想看有哪些音轨：

```bash
./run.sh 节目.ts --list-tracks
```

## 翻译设置

翻译引擎默认是 `apple`（Apple Intelligence）。选 `openai` 引擎时，服务地址默认是 `http://localhost:11434/v1`（Ollama），模型默认 `qwen2.5:7b`。目标语言默认 `zh`（简体中文）。

有四种改法，优先级从高到低是：命令行 > 环境变量 > 设置文件 > 默认值。菜单里改的会写回设置文件。

| 项目 | 命令行 | 环境变量 | 设置文件键名 | 菜单 |
| --- | --- | --- | --- | --- |
| 翻译引擎 | `--translate-engine` | `SUBPLAYER_TRANSLATE_ENGINE` | `translate_engine`（`apple` 或 `openai`） | 翻译引擎行，在两者之间切换 |
| 翻译服务地址 | `--translate-url` | `SUBPLAYER_TRANSLATE_URL` | `translate_url` | 不能改，只能用前三种 |
| 翻译模型 | `--translate-model` | `SUBPLAYER_TRANSLATE_MODEL` | `translate_model` | 翻译模型行，从服务列出的模型里选（只在 `openai` 引擎下有效） |
| 目标语言 | `--target-lang` | `SUBPLAYER_TARGET_LANG` | `target_lang` | 目标语言行 |
| 关闭翻译 | `--no-translate` | | `translate`（true/false） | 翻译行 |

只给了 `--translate-url` 或 `--translate-model`、没有给引擎时，自动当作 `openai`。

菜单里切换引擎后，已有的译文不会重新翻译，因为译文文件名（如 `movie.zh.srt`）不含引擎名。想用新引擎重翻，启动时加 `--retranslate`。

设置文件位置：macOS 上是 `~/Library/Application Support/subplayer/settings.json`，其他系统是 `~/.local/share/subplayer/settings.json`。可以用环境变量 `SUBPLAYER_HOME` 改掉这个目录。

例子：用 LM Studio 代替 Ollama（在 LM Studio 里启动本地服务器，默认端口 1234）：

```bash
./run.sh 视频.mp4 --translate-url http://localhost:1234/v1 --translate-model 你在LM Studio里加载的模型名
```

`openai` 引擎只要求服务提供 OpenAI 兼容的 `GET /models` 和 `POST /chat/completions`。

目标语言可选：`zh`（简体中文）、`zh-tw`（繁体中文）、`en`、`ja`、`ko`，以及 `fr`、`de`、`es`、`ru`、`pt`、`it`、`th`、`vi`。其他代码会原样交给模型。

## 术语表

术语表是纯文本，每行一条：

```
# 注释以 # 开头，空行忽略
天気 = 天气
Whisper => 耳语模型
ダンジョン -> 地下城
```

分隔符可以是 `=`、`=>`、`->`、Tab 或全角冒号。

术语表从三个位置读取，后面的覆盖前面的同名条目：

1. `设置目录/glossary.txt`（对所有视频生效）
2. 视频旁边的 `<视频名>.glossary.txt`（只对这个视频生效）
3. `--glossary 文件路径`（本次运行生效）

每一批翻译只把出现在这批原文或前文里的术语写进提示词，不会把整个表都发给模型。

## 显示模式和键位

字幕显示有四种模式，按 `v` 循环：关闭、原文、译文、双语。双语时译文在上，原文在下。没有译文的字幕只显示原文。语气词只显示原文。

| 键 | 作用 |
| --- | --- |
| 空格 | 播放 / 暂停（mpv 默认） |
| ← → ↑ ↓ | 拖动进度（mpv 默认）。设置菜单打开时，方向键用来选择和修改菜单项 |
| 9 / 0 | 音量（mpv 默认） |
| `[` `]` `{` `}` `Backspace` | 倍速（mpv 默认） |
| `f` | 全屏（mpv 默认） |
| `v` | 切换字幕显示模式 |
| `+` / `-` | 字幕字号 |
| `t` | 切换到下一条音轨（转写也跟着切换，每条音轨各有自己的字幕文件） |
| `Tab` | 打开或关闭设置菜单 |
| `o` | 打开文件（macOS 上用系统选择框） |
| 拖入窗口 | 打开文件 |

设置菜单里：`↑` `↓` 选择条目，`←` `→` 或回车修改，`Tab` 或 `Esc` 关闭。菜单底部显示翻译服务的状态。

## 触控板

下面的手势用的是 mpv 的滚轮事件。mpv 内嵌的默认配置（`etc/input.conf`）注释里写着：鼠标滚轮、触控板或其他带轴的输入设备都发出 `WHEEL_*` 键。所以触控板的两指滑动，理论上和鼠标滚轮是同一组键。

| 手势 | 作用 | 来源 |
| --- | --- | --- |
| 两指左右滑 | 快退 / 快进 5 秒 | 本项目绑定。mpv 默认是 10 秒 |
| 两指上下滑 | 音量减 / 加 2 | 本项目绑定，和 mpv 默认一样 |
| 双击画面 | 全屏切换 | mpv 默认（`MBTN_LEFT_DBL cycle fullscreen`） |
| `Alt+0` / `Alt+1` / `Alt+2` | 窗口 50% / 100% / 200% | mpv 默认（`current-window-scale`） |
| 设置菜单里的“窗口大小” | 50%、100%、150%、200% 循环 | 本项目加的菜单行 |
| 两指捏合 | 放大缩小窗口 | 没有实现，见下 |

- 菜单打开时，滚轮不会快进快退或改音量，免得调菜单时视频跳走。
- 设置文件里的 `trackpad` 控制左右滑和上下滑，默认 `true`。写成 `false` 时不覆盖 mpv 的滚轮绑定：左右滑恢复 mpv 默认的 10 秒，上下滑仍是 mpv 默认的音量。这个设置只能改设置文件，改完重新打开播放器生效。

**捏合没有实现，也没有查清楚。** 我查不到 mpv 在 macOS 上会不会把捏合原生变成窗口缩放。GitHub 访问不了，apt 也没有 mpv 的源码源。本机 mpv 0.37 的 Linux 版里没有捏合相关的键名（`mpv --input-keylist` 里没有 PINCH、MAGNIFY 之类）。要做的话需要原生代码，在 `NSView` 的 `magnifyWithEvent:` 里改窗口大小，这个项目里没有写。如果在 Mac 上试出 mpv 原生支持捏合，就不需要改代码。

**没有在真实触控板上测试。** 测试是在 Linux 上用 `keypress` 模拟 `WHEEL_LEFT` 等键。没有验证 Mac 上的触控板是不是真的发出这些键，也没有验证一次滑动发出几个事件、快进的步长和手感。这些都要在 Mac 上试。

## 缓存文件

字幕和进度都放在视频旁边。`base` 是视频名，第 2 条及以后的音轨是 `movie.a2` 这种形式。

| 文件 | 内容 |
| --- | --- |
| `movie.subplayer.json` | 进度：转写用的模型、语言、已完成的段、当前原文字幕文件名 |
| `movie.ja.srt` | 原文字幕，语言是检测到或指定的语言码 |
| `movie.und.srt` | 原文字幕，语言还没检测到时使用。检测到语言后写入 `movie.<语言>.srt`，并删除它 |
| `movie.zh.srt` | 译文字幕，目标语言码为 `zh` |
| `movie.a2.ja.srt`、`movie.a2.zh.srt` | 第 2 条音轨的原文和译文 |

规则：

- 字幕是边做边存的，关掉播放器后下次打开从上次停下的地方继续。
- 只有 `movie.srt`（或 `movie.<语言>.srt`），没有进度文件时，当作完整字幕直接使用，不转写。这是你自己准备的字幕。
- 缓存是用某个模型生成的，现在换了模型：会显示提示，但仍然用旧缓存。想统一请加 `--rebuild`，它会删掉原文、进度和译文，从头转写和翻译。
- 只想重新翻译：`--retranslate`，只删译文。
- 视频所在目录不可写（比如只读的外接盘）时，字幕放到 `~/Library/Caches/subplayer/`。

## 记住位置和单实例

- 播放中每 5 秒记一次位置，退出时再记一次。记录在 `设置目录/positions.json`，最多保留 500 个视频。
- 打开时如果位置在开头 5 秒之后、结尾 15 秒之前，就跳到上次的位置。快看完的视频会删除记录。
- 文件大小或修改时间变了，不恢复位置。
- 单实例靠 mpv 的 IPC socket 实现。socket 路径默认是 `/tmp/subplayer-<uid>.sock`，可用环境变量 `SUBPLAYER_SOCKET` 改。新进程发现已有窗口，就把文件交给它，自己立即退出。

## 转写质量处理

Whisper 在静音和片尾容易编造文字，这里做三件事：

1. 连续重复：同一句话（去掉标点后相同）连续出现超过 3 次，只保留第一条。
2. 黑名单：常见的片尾套话（如“ご視聴ありがとうございました”）直接丢弃，列表在 `subplayer/filters.py`。
3. 语气词：“あ”“えっと”“嗯”“um”这类语气词，或 `(息)`、`[音楽]` 这样的括号噪音，如果相邻间隔不超过 3 秒就合并成一条。语气词不送去翻译。

另外还保留了 Whisper 自带的静音判定（no_speech_prob 和 avg_logprob）和压缩比判定。

## 制作 Mac 软件

目标是能拖文件到图标上打开，或右键“打开方式”选它。

```bash
./install.sh            # 先装好依赖
./build_app.sh          # 生成 build/Subplayer.app
./build_app.sh --install  # 再复制到 /Applications
```

- 生成的 App 是 AppleScript droplet，启动时执行本项目的 `run.sh`。所以本项目的目录要保持不动。移动或重命名项目后，要重新运行 `build_app.sh`。
- 翻译组件 `bin/apple-translate` 也在项目目录里，App 调用的就是它，所以要先运行 `./install.sh` 编译。
- 日志写在 `~/Library/Logs/subplayer.log`，出问题先看这里。
- Dock 里显示的是 Python 图标，这是 droplet 方案的限制。想换图标要自己改 App 包里的 `.icns`。
- 从 Finder 启动时 PATH 很短，`run.sh` 已经把 `/opt/homebrew/bin` 和 `/usr/local/bin` 加进去，所以能找到 brew 装的 ffmpeg。

**这部分没有在 Mac 上验证过。** 我在 Linux 上只做了 `bash -n` 语法检查和代码审阅。`build_app.sh`、`install.sh`（包括 `swiftc` 编译、`brew install ollama` 和 `WITH_OLLAMA` 分支），都需要你在 Mac 上运行一次确认。

## 设计选择

- 字幕不用 mpv 的原生字幕轨，而是用 `osd-overlay` 画在视频上。原生字幕轨要整个文件重新加载才能刷新，边转写边更新做不好。
- 设置菜单是 mpv 的叠加层，不是独立窗口。内嵌 mpv 到 Qt 或 Tk 窗口在 macOS 上不稳定。叠加层纯键盘操作，也能在 Linux 下完整测试。
- 翻译有两个引擎，共用同一套批量、校验、术语表和缓存逻辑。`openai` 引擎用标准库 `urllib` 调用 OpenAI 兼容接口，没有新增第三方依赖，Ollama 和 LM Studio 都支持。`apple` 引擎通过小的 Swift 工具 `bin/apple-translate` 调用系统模型，用标准输入输出交换 JSON。
- 默认引擎选 Apple Intelligence：不用装 Ollama，也不用下载模型，完全离线。代价是只能用系统这一个模型，质量没有实测，还可能被安全护栏拒绝。
- 备选的 Ollama 默认模型是 `qwen2.5:7b`，这是我选的默认值，没有和其他模型做过比较。内存小的机器可以改用 `qwen2.5:3b`。
- 打包用 AppleScript droplet，不用 py2app。py2app 需要在 Mac 上构建，而且包里要带 Python、mlx 和 ffmpeg，体积大，出问题也难排查。droplet 只是一段调用 `run.sh` 的脚本，本项目保持原样即可。
- 翻译服务不可用时只显示原文，不卡播放，不弹窗。状态行会说明原因。

## 测试情况

在 Linux 沙箱里（Xvfb、mpv 0.37、ffmpeg）验证过的：

- 单元测试：`python -m unittest discover -s tests`，84 项通过。覆盖字幕读写、缓存命名和查找、用户字幕、清理重复和语气词（并检查幂等）、黑名单、设置优先级、术语表、翻译输出解析、翻译重试和对半拆分、批次选择、位置记录、显示模式、单实例通信、Apple 引擎的调用协议、触控板设置的默认值。
- 端到端：`tests/e2e_xvfb.py`，真的打开 mpv 窗口，用假识别后端、`tests/mock_llm.py` 假翻译服务，以及 `tests/fake_apple_helper.py`（冒充 Swift 工具）。共 90 项检查，全部通过。检查了：
  - 没有翻译服务时视频照常播放，状态行显示“翻译服务未连接”
  - mlx 不可用时视频照常播放，状态行显示“字幕不可用”
  - 译文逐步出现，批大小不超过 25，后续批带前文，术语表生效
  - 拖动到 150 秒后，该段被优先转写
  - `v` 循环四种模式；`Tab` 打开菜单，方向键选择并修改字号，设置写入文件，菜单关闭后方向键恢复快进
  - 重启后原文和译文都从缓存读出，识别和翻译请求都为 0
  - 记住位置：跳到 40 秒后退出，再打开从约 40 秒开始
  - 单实例：另一个进程把文件交过来后立即退出，原窗口切换到新文件
  - 双音轨 `.ts` 用 `--audio-track 2`，缓存名 `multi_audio.a2.ja.srt` 和 `multi_audio.a2.zh.srt`；按 `t` 切换音轨
  - 触控板：两指左右滑快进快退 5 秒，上下滑改音量，菜单打开时滚轮不动视频；`trackpad` 设为 false 时保持 mpv 默认的 10 秒
  - 窗口大小：菜单里 50%、100%、150%、200% 循环；`Alt+0/1/2` 设置 `current-window-scale`（只检查这个 mpv 属性，没有看 X 窗口的实际大小）
  - Apple 引擎（假小工具）：没有开启时状态行说明原因，只显示原文，播放照常；可用时每批不超过 20 行，术语表进入提示词，重开后不再调用

**没有验证的部分**（需要在 Mac 上确认）：

- mlx-whisper 和 faster-whisper 的真实识别质量。测试用的是占位后端，只生成带时间标签的日语句子。沙箱访问不到 huggingface.co，也没有 Ollama 模型。
- Ollama 真实翻译质量。测试用的是 mock 服务，只检查流程和格式，不检查译文好坏。
- macOS 上的 mpv 窗口、拖拽、`o` 键的文件选择框、Finder 拖到 App 上。
- `build_app.sh`、`install.sh` 的 brew 和 Ollama 部分。
- Swift 代码 `swift/apple_translate.swift` 没有编译和运行过，`install.sh` 里的 `swiftc` 编译和 `--check` 也没有在 Mac 上运行。
- Apple Intelligence 的日译中质量，以及安全护栏会不会拒绝某些内容。
- 触控板真实手势：两指滑动发出的键、步长和手感。捏合没有实现。
- 上面触控板表格里 mpv 的默认绑定，是从 Linux 版 mpv 0.37 的内嵌默认配置读出的，macOS 版没有核对。
- 测试素材是 espeak-ng 合成的日语，不是真人录音。

复现测试：

```bash
# 生成测试素材（macOS 用 say，Linux 用 espeak-ng）
scripts/make_samples.sh samples

# 单元测试（不需要 mpv 窗口）
SUBPLAYER_SAMPLES=samples python -m unittest discover -s tests -v

# 端到端（Linux，需要 Xvfb 和 mpv；输出截图和结果到 out/）
Xvfb :99 -screen 0 1280x800x24 &
DISPLAY=:99 python tests/e2e_xvfb.py samples out
```

## 已知限制

- 第一次打开视频时，转写要跟上播放。`base` 在 Apple Silicon 上应该够用，但没有实测速度。
- 翻译是逐批进行的，播放位置附近的字幕优先。批次之间有模型推理时间，字幕不会立刻全部译完。
- 字幕样式只有字号可调，颜色、位置和字体是固定的。
- 只有一个转写进程。切换音轨或模型会停掉当前转写，从缓存的进度继续。
- 时间戳精度取决于 Whisper，字幕可能有几百毫秒的偏差。
- 设置菜单里的翻译模型只能从服务列出的模型里选（`openai` 引擎）。服务没开时，这一行只显示当前值。Apple 引擎下这一行显示“系统自带”，不能切换。

## 文件结构

```
install.sh                  一键安装（brew + venv + pip + 预下载模型 + 编译翻译组件，可选 Ollama）
run.sh                      启动脚本，设置 PATH 和 libmpv 路径后运行 python -m subplayer
build_app.sh                生成 Subplayer.app（只能在 Mac 上运行）
requirements.txt            默认依赖（mlx-whisper、python-mpv、numpy）
requirements-fallback.txt   faster-whisper，mlx 不可用时安装
subplayer/
  cli.py                    命令行参数，单实例检查
  player.py                 mpv 窗口、按键、字幕和菜单叠加层
  transcriber.py            分段、调度、缓存、后台转写线程
  translate.py              翻译引擎（Apple 和 OpenAI 兼容）、术语表、批量翻译和重试、翻译线程
  filters.py                幻觉过滤、重复和语气词合并、人声检测
  settings.py               设置文件和优先级
  positions.py              记住播放位置
  ipc.py                    单实例：把文件交给已在运行的窗口
  srt.py                    .srt 读写、缓存文件命名、清理
  media.py                  ffprobe / ffmpeg 封装
  asr/                      识别后端：mlx_backend、faster_backend、fake_backend（测试用）
swift/apple_translate.swift  Apple Intelligence 翻译小工具源码，install.sh 编译成 bin/apple-translate
scripts/make_samples.sh     生成测试素材
tests/test_units.py         单元测试
tests/mock_llm.py           假的 OpenAI 兼容翻译服务（测试用）
tests/fake_apple_helper.py  假的翻译小工具，冒充 bin/apple-translate（测试用）
tests/e2e_xvfb.py           Linux 端到端测试
```

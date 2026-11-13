#!/usr/bin/env bash
# 生成测试素材：
#   ja_180s.mp4      日语语音，3 分钟，用来测边播边出字幕、拖动后优先转写
#   multi_audio.ts   .ts 文件，两条音轨（第 1 条日语，第 2 条英语），起始时间偏移 1.4 秒
#
# 语音用系统自带 TTS 生成：macOS 用 say（Kyoko 声音），Linux 用 espeak-ng。
# 用法：scripts/make_samples.sh [输出目录]
set -euo pipefail

OUT="${1:-samples}"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/ja.txt" <<'EOF'
今日はとても良い天気ですね。
明日は雨が降るかもしれません。
駅まで一緒に歩きましょう。
この映画はとても面白かったです。
日本語の字幕を自動で作ります。
音声認識には Whisper を使っています。
次のシーンに進みましょう。
ご飯を食べてから出かけます。
電車の時間に間に合うでしょうか。
もう一度ゆっくり話してください。
EOF

cat > "$WORK/en.txt" <<'EOF'
This is the English audio track of the test file.
The player should transcribe the first track by default.
Press the t key to switch the track while playing.
EOF

tts() {  # tts <lang: ja|en> <textfile> <out.wav>
  local lang="$1" text="$2" wav="$3"
  if command -v say >/dev/null 2>&1; then
    local voice="Kyoko"; [ "$lang" = "en" ] && voice="Samantha"
    say -v "$voice" -f "$text" -o "$WORK/tmp.aiff"
    ffmpeg -nostdin -v error -y -i "$WORK/tmp.aiff" -ar 48000 -ac 1 "$wav"
  else
    espeak-ng -v "$lang" -s 150 -f "$text" -w "$wav"
  fi
}

# 日语 180 秒：把 10 句重复 3 轮，句间靠 TTS 自带的停顿
for i in 1 2 3; do cat "$WORK/ja.txt"; done > "$WORK/ja_long.txt"
tts ja "$WORK/ja_long.txt" "$WORK/ja_long.wav"
ffmpeg -nostdin -v error -y -f lavfi -i "testsrc2=size=640x360:rate=25" \
  -i "$WORK/ja_long.wav" -t 180 -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -c:a aac -b:a 128k -shortest "$OUT/ja_180s.mp4"

# 双音轨 .ts：音轨 1 日语，音轨 2 英语；output_ts_offset 让起始时间不是 0
tts en "$WORK/en.txt" "$WORK/en.wav"
ffmpeg -nostdin -v error -y -f lavfi -i "testsrc2=size=640x360:rate=25" \
  -i "$WORK/ja_long.wav" -i "$WORK/en.wav" -t 60 \
  -map 0:v -map 1:a -map 2:a \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -b:a 128k \
  -metadata:s:a:0 language=jpn -metadata:s:a:1 language=eng \
  -output_ts_offset 1.4 -f mpegts "$OUT/multi_audio.ts"

echo "已生成："
ls -lh "$OUT"/ja_180s.mp4 "$OUT"/multi_audio.ts

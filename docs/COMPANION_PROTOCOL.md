# Companion protocol

The native app (Swift) and the subtitle companion (Python) talk through the
shared libmpv core. This file is the contract between them. Version 1.

## Companion → app: `user-data/vidac-state`

A JSON object, set as a string property whenever it changes (at most about
twice a second). The app never parses human-readable text; everything it shows
is built from these fields. All `message` / `reason` strings are English.

```json
{
  "v": 1,
  "phase": "transcribing",
  "progress": 0.42,
  "ahead": false,
  "download": null,
  "model": "base",
  "language": "ja",
  "source": "generated",
  "resumed_from": null,
  "delay": 0.0,
  "translation": {
    "state": "working", "done": 12, "total": 25,
    "target": "en", "engine": "apple", "reason": null
  },
  "error": null,
  "files": ["/path/Movie.vidac.ja.srt"],
  "settings": { "display_mode": "bilingual", "translate": true, "...": "..." }
}
```

| Field | Meaning |
| --- | --- |
| `phase` | `idle` (no file), `disabled` (automatic subtitles turned off), `model-download`, `model-load`, `transcribing`, `ready` (whole file transcribed), `error` |
| `progress` | Fraction 0–1 of the file transcribed, or `null` when unknown |
| `ahead` | `true` while the playhead is in a region that has not been transcribed yet |
| `download` | During `model-download`: `{"received": bytes, "total": bytes or null}`; otherwise `null` |
| `model`, `language` | Model in use; detected or chosen spoken language (`null` until known) |
| `source` | `generated`, `cache` (Vidac's own earlier output), or `sidecar` (a subtitle file the user already had) |
| `resumed_from` | Seconds, set once when playback was resumed from a saved position, else `null` |
| `delay` | Subtitle timing offset in seconds (positive = later) |
| `translation.state` | `off`, `working`, `ready`, `unavailable` (engine cannot be used), `error` |
| `translation.reason` | English sentence explaining `unavailable` / `error`, with what the user can do |
| `error` | `null` or `{"code": "offline" \| "model-download" \| "audio" \| "internal", "message": "<English sentence>"}` |
| `files` | Subtitle files written for this video (absolute paths) |
| `settings` | The companion's effective settings, so the app's controls reflect reality |

The legacy free-text `user-data/vidac-status` is still published for the
command-line mode but the app ignores it.

## App → companion

- `script-message vidac-ui setting <key> <value>` — change one setting
  (existing). Keys: `display_mode` (`bilingual`/`orig`/`trans`/`off`),
  `translate` (`true`/`false`), `target_lang`, `language`, `model`,
  `enabled` (`true`/`false`: automatic subtitles on or off entirely),
  `font_scale` (number, 1.0 = default), `delay` (seconds),
  `subtitle_location` (`beside` the video / `library` =
  `~/Library/Application Support/vidac/subtitles`).
  The change is acknowledged by the next `vidac-state` carrying it in `settings`.
- `script-message vidac-ui action <name>` — `regenerate` (discard this video's
  generated subtitles and transcribe again with the current settings), `retry`
  (after an error), `stop` (stop transcribing this video).
- `user-data/vidac-subtitle-bottom` — bottom margin for subtitles in 720-unit
  overlay coordinates (existing). The app lowers it when the control bar is
  hidden and raises it when the bar is visible.

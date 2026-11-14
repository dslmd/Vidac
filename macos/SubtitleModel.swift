import Foundation

/// The companion's `user-data/vidac-state` object (docs/COMPANION_PROTOCOL.md)
/// as a Swift value, and the wording the app builds from it. Nothing here
/// parses human-readable text: the only strings taken from the companion are
/// the English `error.message` and `translation.reason` sentences, shown as
/// they are. Missing or unexpected fields are tolerated.
struct SubtitleState {
    enum Phase: String {
        case idle, disabled, modelDownload = "model-download", modelLoad = "model-load", transcribing, ready, error, unknown
    }
    enum Source: String { case generated, cache, sidecar }
    struct Download {
        var received: Int64
        var total: Int64?
    }
    struct Translation {
        enum State: String { case off, working, ready, unavailable, error }
        var state = State.off
        var done = 0
        var total = 0
        var target: String?
        var engine: String?
        var reason: String?
    }
    struct Failure {
        var code: String
        var message: String?
    }
    /// The companion's effective settings. Defaults match vidac/settings.py and
    /// only stand in until a state arrives.
    struct Settings {
        var displayMode = "bilingual"
        var translate = true
        var enabled = true
        var targetLanguage = "en"
        var language = "auto"
        var model = "base"
        var fontScale = 1.0
        var delay = 0.0
        var location = "beside"
    }

    var phase = Phase.unknown
    var progress: Double?
    var ahead = false
    var download: Download?
    var model: String?
    var language: String?
    var source: Source?
    var resumedFrom: Double?
    var delay = 0.0
    var translation = Translation()
    var error: Failure?
    var files: [String] = []
    var settings = Settings()

    /// Nil when the object carries nothing usable (empty, or no `phase`).
    init?(_ object: [String: Any]) {
        guard let phaseName = object["phase"] as? String else { return nil }
        phase = Phase(rawValue: phaseName) ?? .unknown
        progress = Self.number(object["progress"]).map { min(1, max(0, $0)) }
        ahead = object["ahead"] as? Bool ?? false
        if let raw = object["download"] as? [String: Any], let received = Self.number(raw["received"]) {
            download = Download(received: Int64(max(0, received)), total: Self.number(raw["total"]).flatMap { $0 > 0 ? Int64($0) : nil })
        }
        model = Self.text(object["model"])
        language = Self.text(object["language"])
        source = (object["source"] as? String).flatMap(Source.init(rawValue:))
        resumedFrom = Self.number(object["resumed_from"])
        if let raw = object["translation"] as? [String: Any] {
            translation.state = (raw["state"] as? String).flatMap(Translation.State.init(rawValue:)) ?? .off
            translation.done = Int(Self.number(raw["done"]) ?? 0)
            translation.total = Int(Self.number(raw["total"]) ?? 0)
            translation.target = Self.text(raw["target"])
            translation.engine = Self.text(raw["engine"])
            translation.reason = Self.text(raw["reason"])
        }
        if let raw = object["error"] as? [String: Any] {
            error = Failure(code: Self.text(raw["code"]) ?? "internal", message: Self.text(raw["message"]))
        }
        files = (object["files"] as? [Any])?.compactMap { Self.text($0) } ?? []
        if let raw = object["settings"] as? [String: Any] {
            if let value = Self.text(raw["display_mode"]) { settings.displayMode = value }
            settings.translate = raw["translate"] as? Bool ?? settings.translate
            settings.enabled = raw["enabled"] as? Bool ?? settings.enabled
            if let value = Self.text(raw["target_lang"]) { settings.targetLanguage = value.lowercased() }
            if let value = Self.text(raw["language"]) { settings.language = value.lowercased() }
            if let value = Self.text(raw["model"]) { settings.model = value }
            if let value = Self.number(raw["font_scale"]) { settings.fontScale = value }
            if let value = Self.number(raw["delay"]) { settings.delay = value }
            if let value = Self.text(raw["subtitle_location"]) { settings.location = value }
        }
        // The top-level delay is the current video's; `settings.delay` says the same.
        delay = Self.number(object["delay"]) ?? settings.delay
        settings.delay = delay
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The companion is working on subtitles for this video.
    var isGenerating: Bool { [.modelDownload, .modelLoad, .transcribing].contains(phase) }
    /// Subtitles that Vidac wrote and a Regenerate would throw away.
    var hasGeneratedSubtitles: Bool { source == .generated || source == .cache || phase == .ready }
    var showsSubtitles: Bool { settings.displayMode != "off" }
}

// MARK: Wording

enum SubtitleFormat {
    /// "Japanese", "Simplified Chinese"; the code itself when the system has no name for it.
    static func language(_ code: String?) -> String {
        guard let code, !code.isEmpty, code != "auto" else { return "Detect Automatically" }
        return code.lowercased() == "zh-tw" ? targetLanguage("zh-tw") : (Locale.current.localizedString(forLanguageCode: code) ?? code)
    }
    /// "Chinese, Simplified" for the translation target `zh`, whereas the spoken `zh` is plain "Chinese".
    static func targetLanguage(_ code: String) -> String {
        let locale = Locale.current
        switch code {
        case "zh": return locale.localizedString(forIdentifier: "zh-Hans") ?? "Chinese (Simplified)"
        case "zh-tw": return locale.localizedString(forIdentifier: "zh-Hant") ?? "Chinese (Traditional)"
        default: return locale.localizedString(forLanguageCode: code) ?? code
        }
    }
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
    static func percent(_ fraction: Double) -> String { "\(Int((min(1, max(0, fraction)) * 100).rounded()))%" }
    static func delay(_ seconds: Double) -> String {
        abs(seconds) < 0.05 ? "0.0 s" : String(format: "%+.1f s", seconds)
    }
    static func scale(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    static func displayMode(_ mode: String) -> String {
        switch mode {
        case "bilingual": return "Bilingual"
        case "orig": return "Original"
        case "trans": return "Translation"
        default: return "Off"
        }
    }
}

enum TargetLanguages {
    /// vidac/settings.py TARGET_LANGUAGES.
    static let codes = [
        "zh", "zh-tw", "en", "ja", "ko", "fr", "de", "es", "ru", "pt", "it", "th", "vi", "nl", "pl", "tr", "uk", "id", "hi", "ar",
    ]
}

enum SpokenLanguages {
    /// vidac/settings.py WHISPER_LANGUAGES.
    static let codes = """
        en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr
        bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn
        yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su
        yue
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
}

enum SubtitleModels {
    struct Preset {
        let code: String
        let name: String
        let size: String
        let summary: String
    }
    /// Sizes are approximate downloads; the real size is shown while downloading.
    static let presets = [
        Preset(code: "tiny", name: "Tiny", size: "75 MB", summary: "Fastest and least accurate. For clear speech in a quiet recording."),
        Preset(code: "base", name: "Base", size: "140 MB", summary: "Fast and good for clear speech. The default choice."),
        Preset(code: "small", name: "Small", size: "470 MB", summary: "More accurate than Base, and about twice as slow."),
        Preset(
            code: "medium", name: "Medium", size: "1.5 GB",
            summary: "Better with accents and background noise. Several times slower than Base."),
        Preset(
            code: "large-v3-turbo", name: "Large v3 Turbo", size: "1.6 GB",
            summary: "Close to the best accuracy at a speed between Medium and Large."),
        Preset(
            code: "large-v3", name: "Large v3", size: "3 GB",
            summary: "The most accurate and the slowest. For difficult audio and rare languages."),
    ]
    static func preset(_ code: String) -> Preset? { presets.first { $0.code == code } }
}

// MARK: Notices

/// What the badge and the control bar's status line say about the subtitles
/// right now, built from the state alone.
struct SubtitleNotice {
    enum Tone { case progress, success, info, warning, error }
    enum Lifetime {
        /// Shown for as long as the condition holds.
        case whileActive
        /// Shown for a few seconds, then only in the control bar.
        case fading
        /// Stays until dismissed or resolved.
        case sticky
    }
    enum Action { case retry, restartSubtitles, openSystemSettings, generate, stop }
    enum Availability { case running, restarting, gaveUp, stopped }

    var key: String
    var tone: Tone
    var lifetime: Lifetime
    var symbol: String
    var title: String
    var detail: String?
    /// 0–1 for a determinate bar; nil with `indeterminate` for a busy bar.
    var fraction: Double?
    var indeterminate = false
    /// Short text for the control bar.
    var label: String
    var action: Action?
    var actionTitle: String?

    static func mentionsAppleIntelligence(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason.localizedCaseInsensitiveContains("Apple Intelligence") || reason.localizedCaseInsensitiveContains("Siri")
    }

    /// Notices in priority order; the first is shown. Empty means nothing to say.
    static func build(state: SubtitleState?, availability: Availability, fresh: Bool) -> [SubtitleNotice] {
        switch availability {
        case .gaveUp:
            return [
                SubtitleNotice(
                    key: "unavailable", tone: .error, lifetime: .sticky, symbol: "exclamationmark.triangle.fill",
                    title: "Subtitles unavailable",
                    detail: "The subtitle component isn’t running. Playback isn’t affected.", label: "Subtitles unavailable",
                    action: .restartSubtitles, actionTitle: "Restart Subtitles")
            ]
        case .restarting:
            return [
                SubtitleNotice(
                    key: "restoring", tone: .progress, lifetime: .whileActive, symbol: "captions.bubble", title: "Restoring subtitles…",
                    detail: "The subtitle component stopped and is starting again.", indeterminate: true, label: "Restoring subtitles…")
            ]
        case .stopped, .running:
            break
        }
        guard availability == .running else { return [] }
        // Once the state is current and still says nothing is going on, there is nothing to report.
        if fresh, let state, state.phase == .idle || state.phase == .unknown { return [] }
        guard fresh, let state else {
            return [
                SubtitleNotice(
                    key: "preparing", tone: .progress, lifetime: .fading, symbol: "captions.bubble", title: "Preparing subtitles…",
                    indeterminate: true, label: "Preparing subtitles…")
            ]
        }
        var notices: [SubtitleNotice] = []
        let translation = state.translation

        if state.phase == .error {
            notices.append(errorNotice(state))
        }
        if state.phase == .modelDownload {
            notices.append(downloadNotice(state))
        }
        if state.phase == .modelLoad {
            notices.append(
                SubtitleNotice(
                    key: "model-load", tone: .progress, lifetime: .whileActive, symbol: "captions.bubble",
                    title: "Preparing the speech model…", detail: "Loading it into memory. This takes a few seconds.", indeterminate: true,
                    label: "Loading speech model…"))
        }
        if translation.state == .unavailable || translation.state == .error {
            let reason = translation.reason
            let appleIntelligence = mentionsAppleIntelligence(reason)
            notices.append(
                SubtitleNotice(
                    key: "translation-\(translation.state)-\(reason ?? "")", tone: .warning, lifetime: .sticky,
                    symbol: "exclamationmark.triangle.fill",
                    title: translation.state == .error ? "Translation stopped" : "Translation unavailable",
                    detail: reason ?? "Subtitles are shown in the original language.", label: "Translation unavailable",
                    action: appleIntelligence ? .openSystemSettings : nil, actionTitle: appleIntelligence ? "Open System Settings" : nil))
        }
        if state.phase == .transcribing, state.source != .sidecar, (state.progress ?? 0) < 0.999 {
            var parts: [String] = []
            if let progress = state.progress { parts.append(SubtitleFormat.percent(progress) + " of the video") }
            if let language = state.language { parts.append(SubtitleFormat.language(language)) }
            notices.append(
                SubtitleNotice(
                    key: "transcribing", tone: .progress, lifetime: .fading, symbol: "captions.bubble", title: "Generating subtitles",
                    detail: parts.isEmpty ? nil : parts.joined(separator: " · "), fraction: state.progress,
                    indeterminate: state.progress == nil,
                    label: state.progress.map { "Generating subtitles · " + SubtitleFormat.percent($0) } ?? "Generating subtitles…"))
        }
        if translation.state == .working {
            let counts = translation.total > 0 ? "\(translation.done) of \(translation.total) lines" : "Checking the translation service"
            notices.append(
                SubtitleNotice(
                    key: "translating", tone: .progress, lifetime: .fading, symbol: "captions.bubble", title: "Translating subtitles",
                    detail: counts + (translation.target.map { " · " + SubtitleFormat.targetLanguage($0) } ?? "")
                        + (translation.reason.map { "\n" + $0 } ?? ""),
                    fraction: translation.total > 0 ? Double(translation.done) / Double(translation.total) : nil,
                    indeterminate: translation.total == 0,
                    label: translation.total > 0 ? "Translating · \(translation.done) of \(translation.total)" : "Translating…"))
        }
        if state.phase == .disabled {
            notices.append(disabledNotice(state))
        }
        if state.phase == .ready {
            notices.append(readyNotice(state))
        }
        // The line in the control bar keeps its place when translation is the only problem.
        if notices.count > 1, notices[0].tone == .warning { notices[1].label += " · original only" }
        return notices
    }

    /// The label the control bar shows: the first notice that is not about translation being unavailable,
    /// with a note when translation is.
    static func label(for notices: [SubtitleNotice]) -> String {
        guard let first = notices.first else { return "" }
        if first.tone == .warning, notices.count > 1 { return notices[1].label }
        return first.label
    }

    private static func errorNotice(_ state: SubtitleState) -> SubtitleNotice {
        let code = state.error?.code ?? "internal"
        let message = state.error?.message
        var notice = SubtitleNotice(
            key: "error-\(code)-\(message ?? "")", tone: .error, lifetime: .sticky, symbol: "exclamationmark.triangle.fill",
            title: "Subtitles stopped", detail: message, label: "Subtitle error", action: .retry, actionTitle: "Retry")
        switch code {
        case "offline":
            notice.title = "You’re offline"
            notice.detail = message ?? "Vidac needs an internet connection once to download the speech model."
            notice.label = "Offline"
        case "model-download":
            notice.title = "Couldn’t download the speech model"
            notice.detail = message ?? "Check your internet connection and try again."
            notice.label = "Model download failed"
        case "audio":
            notice.title = "Can’t create subtitles"
            notice.detail = message ?? "This file has no audio that can be transcribed."
            notice.label = "No audio to transcribe"
        default:
            notice.detail = message ?? "Something went wrong while creating subtitles. Choose Retry to try again."
        }
        return notice
    }

    private static func downloadNotice(_ state: SubtitleState) -> SubtitleNotice {
        let download = state.download
        let preset = SubtitleModels.preset(state.model ?? state.settings.model)
        var size = download?.total.map { SubtitleFormat.bytes($0) }
        if size == nil, let preset { size = "about " + preset.size }
        var fraction: Double?
        var counts = ""
        if let download {
            if let total = download.total, total > 0 {
                fraction = min(1, Double(download.received) / Double(total))
                counts =
                    "\(SubtitleFormat.bytes(download.received)) of \(SubtitleFormat.bytes(total)) · \(SubtitleFormat.percent(fraction ?? 0))"
            } else if download.received > 0 {
                counts = "\(SubtitleFormat.bytes(download.received)) downloaded"
            }
        }
        let why = "Vidac needs it once to create subtitles on this Mac. Playback isn’t affected."
        return SubtitleNotice(
            key: "download", tone: .progress, lifetime: .whileActive, symbol: "arrow.down.circle",
            title: "Downloading the speech model" + (size.map { " (one time, \($0))" } ?? "") + "…",
            detail: counts.isEmpty ? why : counts + "\n" + why, fraction: fraction, indeterminate: fraction == nil,
            label: fraction.map { "Downloading model · " + SubtitleFormat.percent($0) } ?? "Downloading model…",
            action: .stop, actionTitle: "Cancel")
    }

    private static func disabledNotice(_ state: SubtitleState) -> SubtitleNotice {
        let off = !state.settings.enabled
        var detail =
            off
            ? "Automatic subtitles are turned off, so only existing subtitles are shown."
            : "Subtitle generation was stopped for this video."
        if let progress = state.progress, progress > 0, progress < 1 {
            detail += " \(SubtitleFormat.percent(progress)) of the video has subtitles."
        } else if state.progress == nil {
            detail += " This video has no subtitles yet."
        }
        return SubtitleNotice(
            key: off ? "disabled-off" : "disabled-stopped", tone: .info, lifetime: .fading, symbol: "captions.bubble",
            title: off ? "Automatic subtitles are off" : "Subtitles stopped",
            detail: detail, label: off ? "Automatic subtitles off" : "Subtitle generation stopped", action: .generate,
            actionTitle: off ? "Turn On" : "Generate Subtitles")
    }

    private static func readyNotice(_ state: SubtitleState) -> SubtitleNotice {
        let translation = state.translation
        var detail: String?
        switch state.source {
        case .sidecar: detail = "Using the subtitle file that came with the video."
        case .cache: detail = "Restored from an earlier run."
        default: break
        }
        if let reason = translation.reason, translation.state == .ready || translation.state == .off {
            detail = [detail, reason].compactMap { $0 }.joined(separator: "\n")
        } else if translation.state == .ready, translation.total > 0, let target = translation.target {
            detail = [detail, "Translated to \(SubtitleFormat.targetLanguage(target))."].compactMap { $0 }.joined(separator: "\n")
        }
        return SubtitleNotice(
            key: "ready", tone: .success, lifetime: .fading, symbol: "checkmark.circle.fill", title: "Subtitles ready", detail: detail,
            label: "Subtitles ready")
    }
}

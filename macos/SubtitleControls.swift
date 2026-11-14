import AppKit

extension SubtitleState.Settings {
    /// The value as the companion's `setting` message spells it.
    func value(for key: String) -> String {
        switch key {
        case "display_mode": return displayMode
        case "translate": return translate ? "true" : "false"
        case "enabled": return enabled ? "true" : "false"
        case "target_lang": return targetLanguage
        case "language": return language
        case "model": return model
        case "font_scale": return String(format: "%g", fontScale)
        case "delay": return String(format: "%.1f", delay)
        case "subtitle_location": return location
        default: return ""
        }
    }
}

/// Changing subtitles from the keyboard, the menus, the control bar's popover
/// and the settings window. Every change is a `setting` message to the
/// companion; the controls follow the state that comes back, and until it does
/// repeated presses add up from the value just sent.
extension PlayerController {
    static let subtitleScales: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.5, 1.75, 2.0, 2.5, 3.0]
    static let visibleDisplayModes = ["bilingual", "orig", "trans"]

    // MARK: Values

    /// The setting as the user last asked for it, or as the companion reports it.
    func subtitleValue(_ key: String) -> String {
        if let pending = subtitlePending[key], ProcessInfo.processInfo.systemUptime - pending.at < 1.5 { return pending.value }
        return (subtitleState?.settings ?? SubtitleState.Settings()).value(for: key)
    }
    var subtitleScale: Double { Double(subtitleValue("font_scale")) ?? 1 }
    var subtitleDelay: Double { Double(subtitleValue("delay")) ?? 0 }
    var subtitlesShown: Bool { subtitleValue("display_mode") != "off" }
    var translationOn: Bool { subtitleValue("translate") == "true" }

    func sendSubtitleSetting(_ key: String, _ value: String) {
        engine.setting(key, value)
        subtitlePending[key] = (value, ProcessInfo.processInfo.systemUptime)
        // If the companion never confirms (it rejected or dropped the change), go back to what it reports.
        pendingExpiryTimer?.invalidate()
        let timer = Timer(timeInterval: 1.6, repeats: false) { [weak self] _ in self?.refreshSubtitleUI() }
        pendingExpiryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    /// Phase `disabled` while generation is allowed or was stopped: one action starts it again.
    var subtitleCanResume: Bool { subtitleState?.phase == .disabled }
    var subtitleCanRetry: Bool { subtitleState?.phase == .error || subtitleCanResume }
    var subtitleRetryTitle: String { subtitleCanResume ? "Generate Subtitles" : "Retry Subtitles" }
    func sendSubtitleAction(_ name: String) {
        engine.command(["script-message", "vidac-ui", "action", name])
    }
    /// False, with a pill, when the companion cannot take the change.
    private func requireSubtitles() -> Bool {
        guard hasVideo else { return false }
        guard subtitlesControllable else {
            showGestureFeedback("Subtitles Unavailable", symbol: "exclamationmark.triangle.fill")
            return false
        }
        return true
    }
    private var lastVisibleMode: String {
        let saved = UserDefaults.standard.string(forKey: "SubtitleLastDisplayMode") ?? "bilingual"
        return Self.visibleDisplayModes.contains(saved) ? saved : "bilingual"
    }
    func displayModeAvailable(_ mode: String) -> Bool { mode == "orig" || mode == "off" || translationOn }

    // MARK: Display

    func setDisplayMode(_ mode: String) {
        guard requireSubtitles() else { return }
        if mode != "off" { UserDefaults.standard.set(mode, forKey: "SubtitleLastDisplayMode") }
        sendSubtitleSetting("display_mode", mode)
        showGestureFeedback(
            mode == "off" ? "Subtitles Off" : "Subtitles: " + SubtitleFormat.displayMode(mode),
            symbol: mode == "off" ? "captions.bubble" : "captions.bubble.fill")
    }
    @objc func toggleSubtitleVisibility() {
        guard requireSubtitles() else { return }
        if subtitlesShown {
            setDisplayMode("off")
        } else {
            let mode = lastVisibleMode
            setDisplayMode(displayModeAvailable(mode) ? mode : "orig")
        }
    }
    @objc func cycleDisplayMode() {
        guard requireSubtitles() else { return }
        let modes = Self.visibleDisplayModes.filter(displayModeAvailable)
        let current = subtitleValue("display_mode")
        if current == "off" {
            let mode = lastVisibleMode
            setDisplayMode(displayModeAvailable(mode) ? mode : "orig")
        } else if modes.count < 2 {
            if current != "orig" {
                setDisplayMode("orig")
            } else {
                showGestureFeedback("Original Only · Translation Is Off", symbol: "captions.bubble.fill")
            }
        } else {
            let next = modes.firstIndex(of: current).map { modes[($0 + 1) % modes.count] } ?? modes[0]
            setDisplayMode(next)
        }
    }
    @objc func menuDisplayMode(_ sender: NSMenuItem) { if let mode = sender.representedObject as? String { setDisplayMode(mode) } }

    // MARK: Size

    func setSubtitleScale(_ value: Double, announce: Bool = true) {
        guard requireSubtitles() else { return }
        let clamped = min(3, max(0.5, (value * 100).rounded() / 100))
        sendSubtitleSetting("font_scale", String(format: "%g", clamped))
        if announce { showGestureFeedback("Subtitle Size \(SubtitleFormat.scale(clamped))", symbol: "textformat.size") }
    }
    func stepSubtitleScale(_ direction: Int) {
        let current = subtitleScale
        let next =
            direction > 0
            ? Self.subtitleScales.first { $0 > current + 0.004 } : Self.subtitleScales.last { $0 < current - 0.004 }
        guard let next else {
            if requireSubtitles() {
                showGestureFeedback("Subtitle Size \(SubtitleFormat.scale(current))", symbol: "textformat.size")
            }
            return
        }
        setSubtitleScale(next)
    }
    @objc func smallerSubtitles() { stepSubtitleScale(-1) }
    @objc func largerSubtitles() { stepSubtitleScale(1) }
    @objc func resetSubtitleSize() { setSubtitleScale(1) }

    // MARK: Delay

    func setSubtitleDelay(_ seconds: Double) {
        guard requireSubtitles() else { return }
        let value = min(60, max(-60, (seconds * 10).rounded() / 10))
        sendSubtitleSetting("delay", String(format: "%.1f", value))
        showGestureFeedback("Subtitle Delay \(SubtitleFormat.delay(value))", symbol: "clock")
    }
    /// Delay is the offset of the subtitles: positive shows them later.
    func nudgeSubtitleDelay(_ delta: Double) { setSubtitleDelay(subtitleDelay + delta) }
    @objc func subtitlesEarlier() { nudgeSubtitleDelay(-0.1) }
    @objc func subtitlesLater() { nudgeSubtitleDelay(0.1) }
    @objc func subtitlesMuchEarlier() { nudgeSubtitleDelay(-0.5) }
    @objc func subtitlesMuchLater() { nudgeSubtitleDelay(0.5) }
    @objc func resetSubtitleDelay() { setSubtitleDelay(0) }
    /// Used by the menu's title line; not an action.
    @objc func subtitleDelayInfo() {}

    // MARK: Generation

    @objc func retrySubtitles() {
        guard requireSubtitles() else { return }
        sendSubtitleAction("retry")
    }
    @objc func stopSubtitles() {
        guard requireSubtitles() else { return }
        sendSubtitleAction("stop")
        showGestureFeedback("Subtitle Generation Stopped", symbol: "stop.circle")
    }
    @objc func restartSubtitles() {
        restartCompanion()
        showGestureFeedback("Restarting Subtitles", symbol: "arrow.triangle.2.circlepath")
    }
    /// Regenerating needs a running or finished generation; a file that could not be opened has nothing to redo.
    var subtitleCanRegenerate: Bool {
        guard let state = subtitleState, state.phase != .idle else { return false }
        if state.phase == .error, ["audio", "internal"].contains(state.error?.code ?? "internal"), !state.hasGeneratedSubtitles {
            return false
        }
        return true
    }

    @objc func regenerateSubtitles() {
        guard hasVideo, window.attachedSheet == nil else { return }
        guard requireSubtitles(), subtitleCanRegenerate else { return }
        guard let state = subtitleState, state.hasGeneratedSubtitles else {
            runRegenerate()
            return
        }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Regenerate subtitles for “\(currentURL?.lastPathComponent ?? "this video")”?"
        let model = SubtitleModels.preset(subtitleValue("model")).map(\.name) ?? subtitleValue("model")
        var settings = "\(model) model, spoken language: \(SubtitleFormat.language(subtitleValue("language")))"
        if translationOn { settings += ", translated to \(SubtitleFormat.targetLanguage(subtitleValue("target_lang")))" }
        let kept = state.source == .sidecar ? " The subtitle file that came with the video is never changed." : ""
        alert.informativeText =
            "The subtitles Vidac made for this video, including their translation, are discarded and created again with the current settings (\(settings)). This can take a while.\(kept)"
        let regenerate = alert.addButton(withTitle: "Regenerate")
        regenerate.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.runRegenerate() }
        }
    }
    private func runRegenerate() {
        sendSubtitleAction("regenerate")
        showGestureFeedback("Regenerating Subtitles", symbol: "arrow.triangle.2.circlepath")
    }

    // MARK: Files

    var existingSubtitleFiles: [URL] {
        (subtitleState?.files ?? []).map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    @objc func showSubtitleFiles() {
        let files = existingSubtitleFiles
        guard !files.isEmpty else {
            showGestureFeedback("No Subtitle Files Yet", symbol: "doc.text")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    // MARK: Menus

    /// The items shared by the Subtitles menu (with its keys) and the picture's context menu (without).
    func addSubtitleItems(to menu: NSMenu, keys: Bool) {
        func add(_ title: String, _ action: Selector, key: String = "", alternate: Bool = false) -> NSMenuItem {
            let item = menu.add(title, action, key: keys ? key : "", modifiers: alternate ? [.option] : [], target: self)
            item.isAlternate = alternate
            return item
        }
        _ = add("Show Subtitles", #selector(toggleSubtitleVisibility), key: "c")
        menu.addItem(.separator())
        for mode in Self.visibleDisplayModes {
            let title = mode == "bilingual" ? "Bilingual" : (mode == "orig" ? "Original Only" : "Translation Only")
            add(title, #selector(menuDisplayMode(_:))).representedObject = mode
        }
        if keys { _ = add("Cycle Display Mode", #selector(cycleDisplayMode), key: "v") }
        menu.addItem(.separator())
        _ = add("Smaller", #selector(smallerSubtitles), key: "-")
        _ = add("Larger", #selector(largerSubtitles), key: "=")
        _ = add("Reset Size", #selector(resetSubtitleSize))
        menu.addItem(.separator())
        _ = add("Delay", #selector(subtitleDelayInfo))
        _ = add("Show Subtitles Earlier", #selector(subtitlesEarlier), key: "z")
        if keys { _ = add("Show Subtitles Earlier by 0.5 s", #selector(subtitlesMuchEarlier), key: "z", alternate: true) }
        _ = add("Show Subtitles Later", #selector(subtitlesLater), key: "x")
        if keys { _ = add("Show Subtitles Later by 0.5 s", #selector(subtitlesMuchLater), key: "x", alternate: true) }
        _ = add("Reset Delay", #selector(resetSubtitleDelay))
        menu.addItem(.separator())
        _ = add("Regenerate Subtitles…", #selector(regenerateSubtitles))
        if keys {
            _ = add("Retry Subtitles", #selector(retrySubtitles))
            _ = add("Stop Generating Subtitles", #selector(stopSubtitles))
        }
        _ = add("Show Subtitle Files in Finder", #selector(showSubtitleFiles))
    }

    func buildSubtitlesMenu(_ menu: NSMenu) {
        addSubtitleItems(to: menu, keys: true)
        menu.addItem(.separator())
        menu.add("Restart Subtitles", #selector(restartSubtitles), target: self)
    }

    func contextMenuSubtitleItems() -> [NSMenuItem] {
        let submenu = NSMenu(title: "Subtitles")
        addSubtitleItems(to: submenu, keys: false)
        submenu.addItem(.separator())
        submenu.add("Subtitle Settings…", #selector(showSubtitleSettings), target: self)
        let item = NSMenuItem(title: "Subtitles", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return [item]
    }

    /// Enabled state and checkmarks for the subtitle items; nil for any other action.
    func validateSubtitleItem(_ item: NSMenuItem, action: Selector, playable: Bool) -> Bool? {
        guard let result = subtitleItemState(item, action: action, playable: playable) else { return nil }
        // A bare key only means anything while the picture (or its popover) has the keyboard.
        if !item.keyEquivalent.isEmpty, item.keyEquivalentModifierMask.isDisjoint(with: [.command, .control]) {
            let key = NSApp.keyWindow
            if key !== window, key !== subtitlePopover?.contentViewController?.view.window { return false }
        }
        return result
    }

    private func subtitleItemState(_ item: NSMenuItem, action: Selector, playable: Bool) -> Bool? {
        let usable = playable && subtitlesControllable
        let state = subtitleState
        switch action {
        case #selector(toggleSubtitleVisibility):
            item.state = subtitlesShown ? .on : .off
            return usable
        case #selector(menuDisplayMode(_:)):
            let mode = item.representedObject as? String ?? ""
            item.state = subtitleValue("display_mode") == mode ? .on : .off
            return usable && displayModeAvailable(mode)
        case #selector(cycleDisplayMode): return usable
        case #selector(smallerSubtitles): return usable && subtitleScale > 0.5 + 0.004
        case #selector(largerSubtitles): return usable && subtitleScale < 3 - 0.004
        case #selector(resetSubtitleSize): return usable && abs(subtitleScale - 1) >= 0.004
        case #selector(subtitleDelayInfo):
            item.title = "Delay: " + SubtitleFormat.delay(subtitleDelay)
            return false
        case #selector(subtitlesEarlier), #selector(subtitlesMuchEarlier): return usable && subtitleDelay > -60 + 0.04
        case #selector(subtitlesLater), #selector(subtitlesMuchLater): return usable && subtitleDelay < 60 - 0.04
        case #selector(resetSubtitleDelay): return usable && abs(subtitleDelay) >= 0.05
        case #selector(regenerateSubtitles): return usable && subtitleCanRegenerate
        case #selector(retrySubtitles):
            item.title = subtitleRetryTitle
            return usable && subtitleCanRetry
        case #selector(stopSubtitles): return usable && state?.isGenerating == true
        case #selector(showSubtitleFiles): return !existingSubtitleFiles.isEmpty
        case #selector(restartSubtitles): return window.attachedSheet == nil && !subtitlesControllable
        case #selector(showSubtitleSettings), #selector(showSettings): return true
        default: return nil
        }
    }

    // MARK: Popover

    @objc func toggleSubtitlePopover(_ sender: Any?) {
        if let popover = subtitlePopover, popover.isShown {
            popover.close()
        } else {
            showSubtitlePopover()
        }
    }
    func showSubtitlePopover() {
        guard hasVideo, captionButton != nil else { return }
        if subtitlePopover?.isShown == true { return }
        video.cancelTrackpadGestures()
        // The control bar must be on screen for the popover to point at it.
        showControls()
        window.contentView?.layoutSubtreeIfNeeded()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !reducedMotion
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = SubtitlePopoverController(player: self)
        popover.delegate = self
        subtitlePopover = popover
        popover.show(relativeTo: captionButton.bounds, of: captionButton, preferredEdge: .maxY)
    }
}

extension PlayerController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === subtitlePopover { subtitlePopover = nil }
        showControls()
    }
}

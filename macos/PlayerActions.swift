import AppKit

/// Everything the keyboard, the menu bar, the context menu and the control
/// bar can ask the player to do. Each action shows the same feedback pill
/// wherever it was triggered from.
extension PlayerController {
    static let speedSteps: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3]

    // MARK: Keyboard

    /// The keyboard map for the picture. Returns false for keys it does not
    /// own, including everything with ⌘ or ⌃, which belongs to the menu bar.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isDisjoint(with: [.command, .control]) else { return false }
        let fullScreen = window.styleMask.contains(.fullScreen)
        // Full screen can be left (or entered) even while nothing is playing.
        if modifiers.isEmpty, event.keyCode == 53 {
            if upNextTimer != nil {
                cancelUpNext()
                return true
            }
            if fullScreen && !event.isARepeat { toggleFullscreen() }
            return true
        }
        guard hasVideo else { return false }
        let plain = modifiers.isEmpty, repeated = event.isARepeat
        let shift = modifiers == [.shift], option = modifiers == [.option]
        switch event.keyCode {
        case 49 where plain:
            if !repeated { togglePause() }
        case 123 where plain || shift || option: seekBy(shift ? -1 : (option ? -30 : -5))
        case 124 where plain || shift || option: seekBy(shift ? 1 : (option ? 30 : 5))
        case 125 where plain: adjustVolume(by: -5)
        case 126 where plain: adjustVolume(by: 5)
        case 51 where plain:
            if !repeated { setSpeed(1) }
        case 115 where plain:
            if !repeated { jump(to: 0) }
        default:
            // Shift is part of the character here ("+", "<"); Option never is.
            guard !modifiers.contains(.option), let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else {
                return false
            }
            switch key {
            case "k" where plain:
                if !repeated { togglePause() }
            case "j" where plain: seekBy(-10)
            case "l" where plain: seekBy(10)
            case "m" where plain:
                if !repeated { toggleMute() }
            case "f" where plain:
                if !repeated { toggleFullscreen() }
            case "s" where plain:
                if !repeated { takeScreenshot() }
            case "," where plain: stepFrame(forward: false)
            case "." where plain: stepFrame(forward: true)
            case "[" where plain: stepSpeed(-1)
            case "]" where plain: stepSpeed(1)
            case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                guard plain else { return false }
                if !repeated, duration > 0, let tenth = Double(key) { jump(to: duration * tenth / 10) }
            case "v" where plain:
                if !repeated { cycleDisplayMode() }
            case "c" where plain:
                if !repeated { toggleSubtitleVisibility() }
            case "-" where plain: smallerSubtitles()
            case "=" where plain || shift, "+" where plain || shift: largerSubtitles()
            case "z" where plain: subtitlesEarlier()
            case "x" where plain: subtitlesLater()
            case "t" where plain:
                // The audio track is still the companion's binding.
                engine.command(["keypress", key])
            default: return false
            }
        }
        showControls()
        return true
    }

    // MARK: Seeking

    /// Moves by a number of seconds. Presses in quick succession add up from
    /// the last target, since the reported position trails a seek.
    func seekBy(_ delta: Double) {
        guard hasVideo else { return }
        video.cancelTrackpadGestures()
        let now = ProcessInfo.processInfo.systemUptime
        let base = keySeek.flatMap { now - $0.time < 1 ? $0.target : nil } ?? playbackPosition
        let target = max(0, duration > 0 ? min(duration, base + delta) : base + delta)
        keySeek = (target, now)
        engine.command(["seek", String(target), "absolute+exact"])
        let amount = String(format: "%g", abs(delta))
        showGestureFeedback(
            "\(delta < 0 ? "−" : "+")\(amount) s  ·  \(positionText(target))", symbol: delta < 0 ? "gobackward" : "goforward")
        showControls()
    }
    func jump(to seconds: Double) {
        guard hasVideo else { return }
        video.cancelTrackpadGestures()
        let target = max(0, duration > 0 ? min(duration, seconds) : seconds)
        keySeek = (target, ProcessInfo.processInfo.systemUptime)
        engine.command(["seek", String(target), "absolute+exact"])
        showGestureFeedback(positionText(target), symbol: target < playbackPosition ? "backward.fill" : "forward.fill")
        showControls()
    }
    private func positionText(_ seconds: Double) -> String {
        duration > 0 ? "\(timestamp(seconds)) / \(timestamp(duration))" : timestamp(seconds)
    }
    func stepFrame(forward: Bool) {
        guard hasVideo else { return }
        video.cancelTrackpadGestures()
        keySeek = nil
        engine.command([forward ? "frame-step" : "frame-back-step"])
        showGestureFeedback(forward ? "Next Frame" : "Previous Frame", symbol: forward ? "forward.frame.fill" : "backward.frame.fill")
    }
    @objc func menuSeek(_ sender: NSMenuItem) { if let seconds = sender.representedObject as? Double { seekBy(seconds) } }
    @objc func previousFrame() { stepFrame(forward: false) }
    @objc func nextFrame() { stepFrame(forward: true) }
    @objc func goToBeginning() { jump(to: 0) }
    @objc func goToTime() {
        guard hasVideo else { return }
        video.cancelTrackpadGestures()
        let alert = NSAlert()
        alert.messageText = "Go to Time"
        alert.informativeText = "Enter a time such as 1:23:45, 12:30, or a number of seconds."
        let field = NSTextField(string: timestamp(playbackPosition))
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, self.hasVideo else { return }
            guard let seconds = Self.seconds(fromTime: field.stringValue) else {
                NSSound.beep()
                return
            }
            self.jump(to: seconds)
        }
    }
    /// "1:23:45", "12:30" or "90" (also "90.5") → seconds.
    static func seconds(fromTime text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    // MARK: Play state

    func updatePlayButton() {
        let (symbol, label) = atEnd ? ("arrow.counterclockwise", "Replay") : (isPaused ? ("play.fill", "Play") : ("pause.fill", "Pause"))
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        playButton.toolTip = label
        playButton.setAccessibilityLabel(label)
    }

    // MARK: Volume

    func volumeSymbol(_ volume: Double, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        return volume < 34 ? "speaker.wave.1.fill" : (volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }
    func updateSpeakerIcon() {
        let label = playbackMuted ? "Unmute" : "Mute"
        speakerButton.image = NSImage(systemSymbolName: volumeSymbol(playbackVolume, muted: playbackMuted), accessibilityDescription: label)
        speakerButton.toolTip = label
        speakerButton.setAccessibilityLabel(label)
        volumeSlider.alphaValue = playbackMuted ? 0.4 : 1
    }
    /// Raising the volume also ends mute, as the trackpad gesture does.
    func adjustVolume(by delta: Double) {
        guard hasVideo else { return }
        video.cancelTrackpadGestures()
        applyGestureVolume(playbackVolume + delta)
    }
    @objc func volumeUp() { adjustVolume(by: 5) }
    @objc func volumeDown() { adjustVolume(by: -5) }
    @objc func toggleMute() {
        guard hasVideo else { return }
        video.cancelTrackpadGestures()
        playbackMuted.toggle()
        engine.command(["set", "mute", playbackMuted ? "yes" : "no"])
        updateSpeakerIcon()
        showGestureFeedback(
            playbackMuted ? "Muted" : "Volume \(Int(playbackVolume.rounded()))%", symbol: volumeSymbol(playbackVolume, muted: playbackMuted)
        )
    }

    // MARK: Speed

    static func speedLabel(_ speed: Double) -> String { String(format: "%g×", (speed * 100).rounded() / 100) }
    func updateSpeedIndicator() {
        let label = Self.speedLabel(playbackSpeed)
        speedButton.attributedTitle = NSAttributedString(
            string: label,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: accent])
        speedButton.setAccessibilityLabel("Playback speed \(label)")
        let normal = abs(playbackSpeed - 1) < 0.005
        if speedButton.isHidden != normal { speedButton.isHidden = normal }
    }
    func setSpeed(_ speed: Double) {
        guard hasVideo else { return }
        playbackSpeed = speed
        engine.command(["set", "speed", String(speed)])
        updateSpeedIndicator()
        showGestureFeedback("Speed \(Self.speedLabel(speed))", symbol: "speedometer")
    }
    /// Walks the fixed list of speeds; at either end the pill simply repeats.
    func stepSpeed(_ direction: Int) {
        let next =
            direction > 0
            ? Self.speedSteps.first { $0 > playbackSpeed + 0.005 } : Self.speedSteps.last { $0 < playbackSpeed - 0.005 }
        setSpeed(next ?? playbackSpeed)
    }
    @objc func menuSpeed(_ sender: NSMenuItem) { if let speed = sender.representedObject as? Double { setSpeed(speed) } }
    @objc func speedUp() { stepSpeed(1) }
    @objc func speedDown() { stepSpeed(-1) }
    @objc func resetSpeed() { setSpeed(1) }
    /// The list of speeds, shared by the menu bar, the context menu and the control bar.
    func addSpeedItems(to menu: NSMenu) {
        for speed in Self.speedSteps {
            let title = speed == 1 ? "Normal" : Self.speedLabel(speed)
            menu.add(title, #selector(menuSpeed(_:)), target: self).representedObject = speed
        }
    }
    @objc func showSpeedMenu(_ sender: NSButton) {
        video.cancelTrackpadGestures()
        let menu = NSMenu()
        addSpeedItems(to: menu)
        // The bar sits at the bottom of the window, so the list opens upwards.
        menu.popUp(
            positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? -menu.size.height - 6 : sender.bounds.maxY + menu.size.height + 6),
            in: sender)
    }

    // MARK: Picture

    @objc func takeScreenshot() {
        guard hasVideo, let url = currentURL else { return }
        let files = FileManager.default
        var destination: (folder: URL, name: String)?
        let candidates: [(FileManager.SearchPathDirectory, String, String?)] = [
            (.picturesDirectory, "Pictures", "Vidac"), (.desktopDirectory, "Desktop", nil),
        ]
        for (directory, name, subfolder) in candidates {
            guard var folder = files.urls(for: directory, in: .userDomainMask).first else { continue }
            if let subfolder { folder.appendPathComponent(subfolder, isDirectory: true) }
            try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            if files.isWritableFile(atPath: folder.path) {
                destination = (folder, name)
                break
            }
        }
        guard let destination else {
            showGestureFeedback("Couldn’t Save Screenshot", symbol: "exclamationmark.triangle.fill")
            return
        }
        let base =
            "\(url.deletingPathExtension().lastPathComponent) \(timestamp(playbackPosition).replacingOccurrences(of: ":", with: "."))"
        var file = destination.folder.appendingPathComponent(base + ".png")
        var copy = 2
        while files.fileExists(atPath: file.path) {
            file = destination.folder.appendingPathComponent("\(base) \(copy).png")
            copy += 1
        }
        // "video" saves the frame itself at full resolution, without the window's overlays.
        engine.command(["screenshot-to-file", file.path, "video"]) { [weak self] error, _ in
            guard let self, !self.quitting else { return }
            if error < 0 {
                nativeLog("Screenshot failed: \(mpvError(error))")
                self.showGestureFeedback("Couldn’t Save Screenshot", symbol: "exclamationmark.triangle.fill")
            } else {
                nativeLog("Screenshot saved to \(file.path)")
                self.showGestureFeedback("Screenshot Saved to \(destination.name)", symbol: "camera.fill")
            }
        }
    }
    @objc func toggleFloatOnTop() {
        floatOnTop.toggle()
        UserDefaults.standard.set(floatOnTop, forKey: "FloatOnTop")
        window.level = floatOnTop ? .floating : .normal
        // Panels raised while the player floated go back to the normal level with it.
        if !floatOnTop {
            for other in NSApp.windows where other !== window && other.level == .floating && !other.isSheet { other.level = .normal }
        }
        showGestureFeedback(floatOnTop ? "Float on Top: On" : "Float on Top: Off", symbol: floatOnTop ? "pin.fill" : "pin.slash.fill")
    }
    /// While the player floats, its own panels (settings, About) must not open underneath it.
    @objc func auxiliaryWindowBecameKey(_ notification: Notification) {
        guard floatOnTop, let other = notification.object as? NSWindow, other !== window, !other.isSheet, other.level == .normal
        else { return }
        other.level = .floating
    }
    @objc func revealInFinder() { if let url = currentURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc func showLog() {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/vidac-native.log")
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }

    // MARK: Context menu

    func makeContextMenu() -> NSMenu? {
        guard hasVideo else { return nil }
        video.cancelTrackpadGestures()
        let menu = NSMenu()
        menu.add("Play", #selector(togglePause), target: self)
        let speed = NSMenu()
        addSpeedItems(to: speed)
        menu.add("Speed", nil, target: nil).submenu = speed
        menu.add("Mute", #selector(toggleMute), target: self)
        let subtitleItems = contextMenuSubtitleItems()
        if !subtitleItems.isEmpty {
            menu.addItem(.separator())
            for item in subtitleItems { menu.addItem(item) }
        }
        menu.addItem(.separator())
        menu.add("Take Screenshot", #selector(takeScreenshot), target: self)
        menu.add("Float on Top", #selector(toggleFloatOnTop), target: self)
        menu.add("Enter Full Screen", #selector(toggleFullscreen), target: self)
        menu.addItem(.separator())
        menu.add("Show in Finder", #selector(revealInFinder), target: self)
        return menu
    }
}

// MARK: Menu state

extension PlayerController: NSMenuItemValidation, NSMenuDelegate {
    /// Menu actions on a bare key that must fire once per key press, not on every auto-repeat.
    static let oneShotActions: [Selector] = [
        #selector(togglePause), #selector(toggleMute), #selector(takeScreenshot), #selector(goToBeginning), #selector(resetSpeed),
        #selector(toggleSubtitleVisibility), #selector(cycleDisplayMode),
    ]

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        // A shortcut without ⌘ must never fire while the user is typing in a field.
        if !item.keyEquivalent.isEmpty, item.keyEquivalentModifierMask.isDisjoint(with: [.command, .control]) {
            if NSApp.keyWindow?.firstResponder is NSText { return false }
            // Settings, Shortcuts and About keep their own Space and arrow keys.
            let key = NSApp.keyWindow
            if key !== window, key !== subtitlePopover?.contentViewController?.view.window { return false }
            // The menu sees auto-repeat before handleKey does: one-shot actions must not repeat while a key is held.
            if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat, Self.oneShotActions.contains(action) {
                return false
            }
        }
        let playable = hasVideo && window.attachedSheet == nil
        if let handled = validateSubtitleItem(item, action: action, playable: playable) { return handled }
        switch action {
        case #selector(togglePause):
            item.title = atEnd ? "Replay" : (isPaused ? "Play" : "Pause")
            return playable
        case #selector(toggleMute):
            item.state = playbackMuted ? .on : .off
            return playable
        case #selector(menuSpeed(_:)):
            let speed = item.representedObject as? Double ?? 1
            item.state = abs(speed - playbackSpeed) < 0.005 ? .on : .off
            return playable
        case #selector(speedUp): return playable && playbackSpeed < (Self.speedSteps.last ?? 1) - 0.005
        case #selector(speedDown): return playable && playbackSpeed > (Self.speedSteps.first ?? 1) + 0.005
        case #selector(resetSpeed): return playable && abs(playbackSpeed - 1) >= 0.005
        case #selector(menuSeek(_:)), #selector(previousFrame), #selector(nextFrame), #selector(goToBeginning), #selector(goToTime),
            #selector(volumeUp), #selector(volumeDown), #selector(takeScreenshot), #selector(revealInFinder), #selector(zoomIn),
            #selector(zoomOut), #selector(resetZoom):
            return playable
        case #selector(toggleFloatOnTop):
            item.state = floatOnTop ? .on : .off
            return true
        case #selector(toggleFullscreen):
            item.title = window.styleMask.contains(.fullScreen) ? "Exit Full Screen" : "Enter Full Screen"
            return true
        case #selector(playNext): return playable && hasNextItem
        case #selector(playPrevious): return playable && hasPreviousItem
        case #selector(toggleAutoAdvance):
            item.state = autoAdvanceEnabled ? .on : .off
            return true
        case #selector(chooseFile), #selector(openRecent(_:)): return window.attachedSheet == nil
        case #selector(clearRecents): return !recentURLs().isEmpty
        default: return true
        }
    }

    /// File ▸ Open Recent is rebuilt from the stored list each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = recentURLs()
        for url in urls {
            let item = menu.add(url.lastPathComponent, #selector(openRecent(_:)), target: self)
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        menu.add("Clear Menu", #selector(clearRecents), target: self)
    }
}

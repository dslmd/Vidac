import AppKit

/// The popover from the control bar's captions button: the quick controls for
/// the subtitles of the video that is playing. It follows the state live.
final class SubtitlePopoverController: NSViewController {
    private unowned let player: PlayerController
    private let showSwitch = NSSwitch()
    private let statusLine = NSTextField(wrappingLabelWithString: "")
    private let modeControl = NSSegmentedControl(
        labels: ["Bilingual", "Original", "Translation"], trackingMode: .selectOne, target: nil, action: nil)
    private let modeNote = NSTextField(wrappingLabelWithString: "")
    private let sizeValue = NSTextField(labelWithString: "100%")
    private let delayValue = NSTextField(labelWithString: "0.0 s")
    private let sizeMinus = SubtitlePopoverController.stepButton("minus", "Smaller Subtitles")
    private let sizePlus = SubtitlePopoverController.stepButton("plus", "Larger Subtitles")
    private let delayMinus = SubtitlePopoverController.stepButton("minus", "Show Subtitles Earlier")
    private let delayPlus = SubtitlePopoverController.stepButton("plus", "Show Subtitles Later")
    private let delayReset = NSButton(title: "Reset", target: nil, action: nil)
    private let regenerate = NSButton(title: "Regenerate Subtitles…", target: nil, action: nil)
    private let stopOrRetry = NSButton(title: "Stop Generating", target: nil, action: nil)
    private let files = NSButton(title: "Show Subtitle Files in Finder", target: nil, action: nil)
    private let restart = NSButton(title: "Restart Subtitles", target: nil, action: nil)
    private let settings = NSButton(title: "Subtitle Settings…", target: nil, action: nil)
    private var controlsStack: NSStackView!

    init(player: PlayerController) {
        self.player = player
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func stepButton(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }
    private func small(_ label: NSTextField, secondary: Bool = true) {
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Subtitles")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        showSwitch.target = self
        showSwitch.action = #selector(toggleShown)
        showSwitch.controlSize = .small
        showSwitch.setAccessibilityLabel("Show subtitles")
        let spacer = NSView()
        let header = NSStackView(views: [title, spacer, showSwitch])
        header.alignment = .centerY

        small(statusLine)
        statusLine.maximumNumberOfLines = 4
        small(modeNote)
        modeNote.textColor = .tertiaryLabelColor
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.controlSize = .small
        modeControl.segmentStyle = .rounded
        modeControl.setAccessibilityLabel("Display mode")

        for value in [sizeValue, delayValue] {
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.alignment = .center
            value.widthAnchor.constraint(equalToConstant: 58).isActive = true
        }
        sizeMinus.target = self
        sizeMinus.action = #selector(sizeDown)
        sizePlus.target = self
        sizePlus.action = #selector(sizeUp)
        delayMinus.target = self
        delayMinus.action = #selector(delayDown)
        delayPlus.target = self
        delayPlus.action = #selector(delayUp)
        delayReset.target = self
        delayReset.action = #selector(delayZero)
        delayReset.bezelStyle = .rounded
        delayReset.controlSize = .small
        delayReset.toolTip = "Back to no delay"

        func row(_ name: String, _ views: [NSView]) -> NSStackView {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let stack = NSStackView(views: [label] + views)
            stack.spacing = 6
            stack.alignment = .centerY
            return stack
        }
        let sizeRow = row("Size", [sizeMinus, sizeValue, sizePlus])
        let delayRow = row("Delay", [delayMinus, delayValue, delayPlus, delayReset])

        for (button, action) in [
            (regenerate, #selector(regenerateTapped)), (stopOrRetry, #selector(stopOrRetryTapped)), (files, #selector(filesTapped)),
            (restart, #selector(restartTapped)), (settings, #selector(settingsTapped)),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let tight = NSStackView(views: [regenerate, stopOrRetry, files])
        tight.orientation = .vertical
        tight.alignment = .leading
        tight.spacing = 6
        let footer = NSStackView(views: [settings])
        footer.alignment = .centerY

        controlsStack = NSStackView(views: [modeControl, modeNote, sizeRow, delayRow, tight])
        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 10
        controlsStack.setCustomSpacing(14, after: modeNote)
        controlsStack.setCustomSpacing(14, after: delayRow)
        controlsStack.detachesHiddenViews = true

        let root = NSStackView(views: [header, statusLine, controlsStack, restart, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.setCustomSpacing(14, after: statusLine)
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.detachesHiddenViews = true
        for stretched in [header, modeControl, statusLine, modeNote] {
            stretched.widthAnchor.constraint(equalToConstant: 288).isActive = true
        }
        view = root
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        let state = player.subtitleState
        let usable = player.subtitlesControllable
        controlsStack.isHidden = !usable
        restart.isHidden = usable
        showSwitch.isEnabled = usable
        showSwitch.state = player.subtitlesShown ? .on : .off
        if usable {
            statusLine.stringValue = Self.summary(player: player)
        } else {
            switch player.subtitleAvailability {
            case .restarting: statusLine.stringValue = "The subtitle component stopped and is starting again."
            case .running: statusLine.stringValue = "Starting subtitles…"
            default: statusLine.stringValue = "Subtitles aren’t running. Playback isn’t affected."
            }
        }
        statusLine.isHidden = statusLine.stringValue.isEmpty
        restart.isEnabled = player.subtitleAvailability != .running && player.subtitleAvailability != .restarting
        // Segments follow the mode in effect; none is selected while subtitles are off.
        let modes = PlayerController.visibleDisplayModes
        let mode = player.subtitleValue("display_mode")
        modeControl.selectedSegment = modes.firstIndex(of: mode) ?? -1
        for (index, name) in modes.enumerated() { modeControl.setEnabled(player.displayModeAvailable(name), forSegment: index) }
        modeNote.stringValue = player.translationOn ? "" : "Translation is off. Turn it on in Subtitle Settings."
        modeNote.isHidden = player.translationOn
        sizeValue.stringValue = SubtitleFormat.scale(player.subtitleScale)
        sizeMinus.isEnabled = player.subtitleScale > 0.5 + 0.004
        sizePlus.isEnabled = player.subtitleScale < 3 - 0.004
        delayValue.stringValue = SubtitleFormat.delay(player.subtitleDelay)
        delayMinus.isEnabled = player.subtitleDelay > -60 + 0.04
        delayPlus.isEnabled = player.subtitleDelay < 60 - 0.04
        delayReset.isEnabled = abs(player.subtitleDelay) >= 0.05
        regenerate.isEnabled = player.subtitleCanRegenerate
        if player.subtitleCanRetry {
            stopOrRetry.title = player.subtitleCanResume ? "Generate Subtitles" : "Retry"
            stopOrRetry.isHidden = false
        } else if state?.isGenerating == true {
            stopOrRetry.title = "Stop Generating"
            stopOrRetry.isHidden = false
        } else {
            stopOrRetry.isHidden = true
        }
        files.isEnabled = !player.existingSubtitleFiles.isEmpty
        // The popover sizes itself to its content as that changes.
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        if abs(size.width - preferredContentSize.width) > 0.5 || abs(size.height - preferredContentSize.height) > 0.5 {
            preferredContentSize = size
        }
    }

    /// One or two plain sentences about this video's subtitles, from the notices.
    private static func summary(player: PlayerController) -> String {
        var lines: [String] = []
        if let notice = player.subtitleNotices.first {
            lines.append(notice.title + (notice.detail.map { ": " + $0.replacingOccurrences(of: "\n", with: " ") } ?? ""))
        }
        if let state = player.subtitleState {
            // Informative translation text that is not a problem stays secondary.
            if let reason = state.translation.reason, [.off, .ready, .working].contains(state.translation.state),
                !lines.contains(where: { $0.contains(reason) })
            {
                lines.append(reason)
            }
            if state.phase == .ready || state.phase == .transcribing || state.phase == .disabled, let language = state.language {
                lines.append("Spoken language: " + SubtitleFormat.language(language) + ".")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    private var coarse: Bool { NSApp.currentEvent?.modifierFlags.contains(.option) == true }
    @objc private func toggleShown() { player.toggleSubtitleVisibility() }
    @objc private func modeChanged() {
        let modes = PlayerController.visibleDisplayModes
        if modeControl.selectedSegment >= 0 { player.setDisplayMode(modes[modeControl.selectedSegment]) }
    }
    @objc private func sizeDown() { player.stepSubtitleScale(-1) }
    @objc private func sizeUp() { player.stepSubtitleScale(1) }
    @objc private func delayDown() { player.nudgeSubtitleDelay(coarse ? -0.5 : -0.1) }
    @objc private func delayUp() { player.nudgeSubtitleDelay(coarse ? 0.5 : 0.1) }
    @objc private func delayZero() { player.resetSubtitleDelay() }
    @objc private func regenerateTapped() {
        player.subtitlePopover?.close()
        player.regenerateSubtitles()
    }
    @objc private func stopOrRetryTapped() {
        if player.subtitleCanRetry { player.retrySubtitles() } else { player.stopSubtitles() }
    }
    @objc private func filesTapped() { player.showSubtitleFiles() }
    @objc private func restartTapped() { player.restartSubtitles() }
    @objc private func settingsTapped() {
        player.subtitlePopover?.close()
        player.showSubtitleSettings()
    }
}

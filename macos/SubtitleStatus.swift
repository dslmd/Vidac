import AppKit

/// What the subtitles are doing, shown to the user: the status line in the
/// control bar, the badge, the "catching up" note, the resume card and the
/// subtitle margin that follows the control bar. Everything is built from
/// `subtitleState` (the companion's `user-data/vidac-state`).
extension PlayerController {
    /// Where subtitles sit, in the overlay's 720-unit coordinates, while the control bar is hidden.
    static let hiddenSubtitleBottom = 36.0
    static let subtitleBottomRange = 20.0...420.0

    var subtitleAvailability: SubtitleNotice.Availability {
        if companionRunning { return .running }
        if companionGaveUp { return .gaveUp }
        if companionRestartWork != nil { return .restarting }
        return .stopped
    }
    /// A running companion that has reported its state: its controls can be used.
    var subtitlesControllable: Bool { companionRunning && subtitleState != nil }

    // MARK: Setup

    func configureStatus(in content: NSView) {
        content.addSubview(statusBadge)
        content.addSubview(aheadIndicator)
        content.addSubview(resumeCard)
        let aheadBottom = aheadIndicator.bottomAnchor.constraint(
            equalTo: content.bottomAnchor, constant: aheadRestingBottom(visible: false))
        aheadBottomConstraint = aheadBottom
        NSLayoutConstraint.activate([
            statusBadge.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            statusBadge.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            statusBadge.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.7),
            aheadIndicator.centerXAnchor.constraint(equalTo: content.centerXAnchor), aheadBottom,
            // Above the control bar at its tallest, at the leading edge (Up Next is at the trailing edge).
            resumeCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            resumeCard.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -128),
        ])
        statusBadge.onClick = { [weak self] in self?.showSubtitlePopover() }
        statusBadge.onDismiss = { [weak self] in self?.dismissBadge() }
        statusBadge.onAction = { [weak self] in
            if let action = self?.subtitleNotices.first?.action { self?.perform(action) }
        }
        resumeCard.onPrimary = { [weak self] in
            self?.dismissResumeCard()
            self?.jump(to: 0)
        }
        resumeCard.onSecondary = { [weak self] in self?.dismissResumeCard() }
        statusLabel.isSelectable = false
    }

    // MARK: Companion events

    func companionStateChanged() {
        subtitleState = SubtitleState(companionState)
        if pendingLoad == nil { subtitleStateFresh = true }
        let now = ProcessInfo.processInfo.systemUptime
        subtitlePending = subtitlePending.filter { now - $0.value.at < 1.5 && !stateMatches($0.key, $0.value.value) }
        if let mode = subtitleState?.settings.displayMode, mode != "off",
            mode != UserDefaults.standard.string(forKey: "SubtitleLastDisplayMode")
        {
            UserDefaults.standard.set(mode, forKey: "SubtitleLastDisplayMode")
        }
        announceResumeIfNeeded()
        refreshSubtitleUI()
    }

    func companionAvailabilityChanged() {
        if companionState.isEmpty {
            subtitleState = nil
            subtitlePending = [:]
        }
        refreshSubtitleUI()
    }

    private func stateMatches(_ key: String, _ value: String) -> Bool {
        guard let settings = subtitleState?.settings else { return false }
        let current = settings.value(for: key)
        if let a = Double(current), let b = Double(value) { return abs(a - b) < 0.001 }
        return current == value
    }

    // MARK: File lifecycle

    /// A different file is about to load; the old state still describes the old one.
    func subtitleFileWillChange() {
        resumeIgnored = subtitleState?.resumedFrom
        subtitleChangeAnnounced = true
        // Until the new file reports, the state on hand is the old file's.
        subtitleStateFresh = false
        freshTimer?.invalidate()
        dismissResumeCard()
        subtitlePending = [:]
    }
    func subtitleFileDidLoad() {
        // A file opened from outside (a command, a playlist step) never announced itself.
        if !subtitleChangeAnnounced { resumeIgnored = subtitleState?.resumedFrom }
        subtitleChangeAnnounced = false
        subtitleStateFresh = false
        dismissedBadgeKeys = []
        badgeKey = nil
        freshTimer?.invalidate()
        // A state published for the new file may have arrived before the file was reported as loaded.
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.subtitleStateFresh = true
            self?.announceResumeIfNeeded()
            self?.refreshSubtitleUI()
        }
        freshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        announceResumeIfNeeded()
        refreshSubtitleUI()
    }
    func subtitleFileDidClose() {
        subtitleStateFresh = false
        subtitleChangeAnnounced = false
        freshTimer?.invalidate()
        resumeIgnored = subtitleState?.resumedFrom
        dismissResumeCard()
        subtitlePopover?.close()
        refreshSubtitleUI()
    }

    // MARK: Refresh

    func refreshSubtitleUI() {
        guard !quitting else { return }
        let notices =
            hasVideo ? SubtitleNotice.build(state: subtitleState, availability: subtitleAvailability, fresh: subtitleStateFresh) : []
        subtitleNotices = notices
        dismissedBadgeKeys.formIntersection(notices.map(\.key))
        statusLabel.stringValue = SubtitleNotice.label(for: notices)
        statusLabel.toolTip = notices.first?.detail
        applyBadge(notices.first)
        updateAheadIndicator()
        updateCaptionButton()
        (subtitlePopover?.contentViewController as? SubtitlePopoverController)?.refresh()
        // A hidden Settings window is refreshed when it is shown again.
        if settingsController?.isVisible == true { settingsController?.refresh() }
    }

    func updateCaptionButton() {
        guard captionButton != nil else { return }
        let on = subtitleState?.showsSubtitles ?? true
        let problem = subtitleNotices.first.map { $0.tone == .error || $0.tone == .warning } ?? false
        captionButton.image = NSImage(
            systemSymbolName: on ? "captions.bubble.fill" : "captions.bubble", accessibilityDescription: "Subtitles")
        captionButton.contentTintColor = problem ? .systemOrange : .white.withAlphaComponent(on ? 0.92 : 0.6)
    }

    // MARK: Badge

    private func applyBadge(_ top: SubtitleNotice?) {
        guard let top else {
            badgeKey = nil
            statusBadgeTimer?.invalidate()
            statusBadgeEligible = false
            updateStatusBadgeVisibility()
            return
        }
        if top.key != badgeKey {
            badgeKey = top.key
            statusBadgeTimer?.invalidate()
            statusBadgeEligible = !dismissedBadgeKeys.contains(top.key)
            if top.lifetime == .fading {
                let timer = Timer(timeInterval: top.tone == .success ? 4 : 6, repeats: false) { [weak self] _ in self?.fadeOutBadge() }
                statusBadgeTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        statusBadge.configure(top)
        updateStatusBadgeVisibility()
    }
    func updateStatusBadgeVisibility() {
        let show = statusBadgeEligible && badgeKey != nil && hasVideo && gestureFeedback.isHidden
        if show, !statusBadge.isHidden, badgeFadingOut {
            // A notice arrived while the last one was fading out: bring the card back.
            badgeFadingOut = false
            badgeFadeID += 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reducedMotion ? 0 : 0.15
                self.statusBadge.animator().alphaValue = 1
            }
            statusBadge.alphaValue = 1
        } else if show, statusBadge.isHidden {
            badgeFadingOut = false
            badgeFadeID += 1
            statusBadge.isHidden = false
            if reducedMotion {
                statusBadge.alphaValue = 1
            } else {
                statusBadge.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = glide
                    self.statusBadge.animator().alphaValue = 1
                }
            }
        } else if !show, !statusBadge.isHidden {
            statusBadge.isHidden = true
        }
    }
    private func fadeOutBadge() {
        statusBadgeEligible = false
        guard !reducedMotion, !statusBadge.isHidden else {
            updateStatusBadgeVisibility()
            return
        }
        badgeFadeID += 1
        let fade = badgeFadeID
        badgeFadingOut = true
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.4
                context.timingFunction = glide
                self.statusBadge.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard let self, self.badgeFadeID == fade else { return }
                self.badgeFadingOut = false
                self.updateStatusBadgeVisibility()
            })
    }
    private func dismissBadge() {
        if let key = badgeKey { dismissedBadgeKeys.insert(key) }
        statusBadgeEligible = false
        updateStatusBadgeVisibility()
    }

    /// Runs the button on a notice (Retry, Restart Subtitles, Open System Settings, Generate Subtitles).
    func perform(_ action: SubtitleNotice.Action) {
        switch action {
        case .retry: retrySubtitles()
        case .restartSubtitles: restartSubtitles()
        case .generate:
            if subtitleState?.settings.enabled == false { sendSubtitleSetting("enabled", "true") } else { retrySubtitles() }
        case .openSystemSettings: Self.openAppleIntelligenceSettings()
        case .stop: stopSubtitles()
        }
    }
    static func openAppleIntelligenceSettings() {
        for address in ["x-apple.systempreferences:com.apple.Siri-Settings.extension", "x-apple.systempreferences:"] {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Ahead of the transcription

    var subtitleAheadWanted: Bool {
        guard hasVideo, companionRunning, let state = subtitleState else { return false }
        return state.ahead && state.isGenerating && state.showsSubtitles
    }
    func updateAheadIndicator() {
        if subtitleAheadWanted {
            guard aheadTimer == nil, !aheadShown else { return }
            // Seeking a little ahead is common; the note only appears if the wait lasts.
            let timer = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.aheadTimer = nil
                if self.subtitleAheadWanted {
                    self.aheadShown = true
                    self.aheadIndicator.setPresented(true)
                }
            }
            aheadTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            aheadTimer?.invalidate()
            aheadTimer = nil
            if aheadShown {
                aheadShown = false
                aheadIndicator.setPresented(false)
            }
        }
    }
    /// Distance from the window's bottom edge: just above the control bar when it shows, near the edge when it does not.
    func aheadRestingBottom(visible: Bool) -> CGFloat {
        guard visible else { return -28 }
        return compactPresentation ? -(80 + 14 + 12) : -(88 + 22 + 12)
    }

    // MARK: Resume

    func announceResumeIfNeeded() {
        guard let resumed = subtitleState?.resumedFrom else {
            resumeIgnored = nil
            return
        }
        guard hasVideo, pendingLoad == nil, subtitleStateFresh, resumed != resumeIgnored, resumeAnnouncedEntry != currentEntry, resumed >= 1
        else { return }
        resumeAnnouncedEntry = currentEntry
        resumeCard.setText(title: "Resumed from \(timestamp(resumed))", detail: "Where you stopped last time.")
        resumeCard.present()
        resumeCardTimer?.invalidate()
        let timer = Timer(timeInterval: 8, repeats: false) { [weak self] _ in self?.dismissResumeCard() }
        resumeCardTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func dismissResumeCard() {
        resumeCardTimer?.invalidate()
        resumeCardTimer = nil
        resumeCard.dismiss()
    }

    // MARK: Subtitle margin

    /// 20–420 in the overlay's 720-unit coordinates. With the control bar showing, the subtitles clear it;
    /// without it they sit low.
    func subtitleBottomUnits() -> Double {
        let height = max(Double(window.contentView?.bounds.height ?? 1), 1)
        let reserve: Double = compactPresentation ? 110 : 155
        let raw = controlsVisible && hasVideo ? ceil(reserve * 720.0 / height) : Self.hiddenSubtitleBottom
        return min(Self.subtitleBottomRange.upperBound, max(Self.subtitleBottomRange.lowerBound, raw))
    }
    private func setSubtitleBottom(_ value: Int) {
        let clamped = Int(min(Self.subtitleBottomRange.upperBound, max(Self.subtitleBottomRange.lowerBound, Double(value))))
        guard clamped != lastSubtitleBottom else { return }
        lastSubtitleBottom = clamped
        lastSubtitlePublish = ProcessInfo.processInfo.systemUptime
        engine.command(["set", "user-data/vidac-subtitle-bottom", String(clamped)])
    }
    /// Publishes the margin for the current window size and control bar state.
    /// Frequent calls (live resizing) are throttled. While the margin is gliding
    /// to a new value the glide itself follows the window.
    func publishSubtitleMargin(immediate: Bool = false) {
        guard subtitleBottomTween == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !immediate && now - lastSubtitlePublish < 0.08 {
            if subtitleMarginTimer?.isValid != true {
                let timer = Timer(timeInterval: 0.08 - (now - lastSubtitlePublish), repeats: false) { [weak self] _ in
                    self?.publishSubtitleMargin(immediate: true)
                }
                subtitleMarginTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            return
        }
        subtitleMarginTimer?.invalidate()
        subtitleMarginTimer = nil
        let value = subtitleBottomUnits()
        subtitleBottomValue = value
        setSubtitleBottom(Int(value))
    }
    /// The control bar appeared or left: raise or lower the subtitles with it, smoothly
    /// (at once with Reduce Motion).
    func glideSubtitleMargin() {
        subtitleMarginTimer?.invalidate()
        subtitleMarginTimer = nil
        let from = subtitleBottomValue ?? Double(lastSubtitleBottom ?? Int(Self.hiddenSubtitleBottom))
        subtitleBottomTween?.invalidate()
        subtitleBottomTween = nil
        guard !reducedMotion, abs(subtitleBottomUnits() - from) >= 1 else {
            publishSubtitleMargin(immediate: true)
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let duration: TimeInterval = controlsVisible ? 0.3 : 0.45
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / duration)
            let eased = 1 - pow(1 - progress, 3)
            let value = from + (self.subtitleBottomUnits() - from) * eased
            self.subtitleBottomValue = value
            self.setSubtitleBottom(Int(value.rounded()))
            if progress >= 1 {
                timer.invalidate()
                self.subtitleBottomTween = nil
                self.publishSubtitleMargin(immediate: true)
            }
        }
        subtitleBottomTween = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

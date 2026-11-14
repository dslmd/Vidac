import AppKit

/// What sits over the picture besides the control bar: the title strip, the
/// seek bar's time bubble, and the Up Next and update cards.
extension PlayerController {
    func configureOverlays(in content: NSView) {
        titleStrip.translatesAutoresizingMaskIntoConstraints = false
        titleStrip.alphaValue = 0
        content.addSubview(titleStrip)
        content.addSubview(scrubBubble)
        content.addSubview(upNextCard)
        content.addSubview(updateCard)
        NSLayoutConstraint.activate([
            titleStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titleStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            titleStrip.topAnchor.constraint(equalTo: content.topAnchor),
            titleStrip.heightAnchor.constraint(equalToConstant: TitleStrip.height),
            // Above the control bar at its tallest, at the trailing edge.
            upNextCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            upNextCard.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -128),
            // Top trailing: the status badge is top leading and the feedback pill top centre.
            updateCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            updateCard.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
        ])
        upNextCard.onPrimary = { [weak self] in self?.advanceFromUpNext() }
        upNextCard.onSecondary = { [weak self] in self?.cancelUpNext() }
        updateCard.onPrimary = { [weak self] in
            if let page = self?.updateCardRelease?.page { NSWorkspace.shared.open(page) }
            self?.dismissUpdateNotice()
        }
        updateCard.onSecondary = { [weak self] in self?.dismissUpdateNotice() }
    }

    // MARK: Duration label

    /// "12:34" for the full length, or "−12:34" left to play when the user has chosen that.
    func updateDurationLabel(position: Double) {
        let text = showsRemainingTime && duration > 0 ? "−" + timestamp(max(0, duration - position)) : timestamp(duration)
        if durationLabel.stringValue != text {
            durationLabel.stringValue = text
            durationLabel.setAccessibilityValue(text)
        }
        let hint = showsRemainingTime ? "Click to show total time" : "Click to show time remaining"
        if durationLabel.toolTip != hint { durationLabel.toolTip = hint }
    }
    func toggleRemainingTime() {
        showsRemainingTime.toggle()
        UserDefaults.standard.set(showsRemainingTime, forKey: "ShowRemainingTime")
        updateDurationLabel(position: progress.scrubbing ? progress.doubleValue * duration : playbackPosition)
        showControls()
    }

    // MARK: Seek bar

    func hoverSeekBar(_ fraction: Double?, x: CGFloat) {
        guard let fraction, duration > 0, !progress.scrubbing else {
            if !progress.scrubbing { scrubBubble.hide() }
            return
        }
        showScrubBubble(fraction: fraction, atSliderX: x)
    }
    /// The time under the knob (while dragging) or the pointer (while hovering).
    func showScrubBubble(fraction: Double, atSliderX x: CGFloat? = nil) {
        guard duration > 0, let content = window.contentView else { return }
        if scrubBubble.superview == nil { content.addSubview(scrubBubble) }
        let sliderX = x ?? progress.x(forFraction: fraction)
        let centre = progress.convert(NSPoint(x: sliderX, y: 0), to: content).x
        scrubBubble.show(timestamp(fraction * duration), centerX: centre, bottom: hud.frame.maxY + 6)
    }
    /// The mouse went up on the bar: one exact seek to where the knob ended.
    func commitScrub() {
        scrubBubble.hide()
        guard duration > 0, hasVideo else { return }
        keySeek = nil
        engine.command(["seek", String(progress.doubleValue * duration), "absolute+exact"])
        updateDurationLabel(position: progress.doubleValue * duration)
        showControls()
    }

    // MARK: Auto-hide

    /// True while the pointer is on the control bar or the traffic lights, which then stay put.
    var pointerRestsOnControls: Bool {
        let pointer = window.mouseLocationOutsideOfEventStream
        if controlsVisible, hud.bounds.contains(hud.convert(pointer, from: nil)) { return true }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        let area = buttons.map { $0.convert($0.bounds, to: nil) }.reduce(NSRect.null) { $0.union($1) }
        return !area.isNull && area.insetBy(dx: -10, dy: -10).contains(pointer)
    }

    // MARK: Update notice

    func showUpdateNotice(_ release: UpdateChecker.Release) {
        guard !quitting else { return }
        updateCardRelease = release
        updateCard.setText(
            title: "Vidac \(release.version) is available", detail: "You have \(UpdateChecker.runningVersion ?? "an older version").")
        updateCard.present()
        updateCardTimer?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: false) { [weak self] _ in self?.dismissUpdateNotice() }
        updateCardTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func dismissUpdateNotice() {
        updateCardTimer?.invalidate()
        updateCardTimer = nil
        updateCard.dismiss()
    }
}

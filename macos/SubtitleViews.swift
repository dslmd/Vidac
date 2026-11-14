import AppKit

/// The card at the top left that tells what the subtitles are doing: a
/// symbol, a title, a detail, an optional progress bar and one action. A
/// click anywhere else on it opens the subtitle popover.
final class SubtitleBadge: NSVisualEffectView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let dismissButton = NSButton(title: "", target: nil, action: nil)
    private var barWidth: NSLayoutConstraint?
    var onClick: (() -> Void)?
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.wraps = true
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 5
        for label in [titleLabel, detailLabel] {
            label.preferredMaxLayoutWidth = 280
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        dismissButton.bezelStyle = .inline
        dismissButton.isBordered = false
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismissButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.toolTip = "Dismiss"
        dismissButton.setAccessibilityLabel("Dismiss")
        dismissButton.target = self
        dismissButton.action = #selector(dismissPressed)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [titleLabel, detailLabel, bar, actionButton])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(8, after: bar)
        text.detachesHiddenViews = true
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(text)
        addSubview(dismissButton)
        let width = bar.widthAnchor.constraint(equalToConstant: 280)
        width.priority = NSLayoutConstraint.Priority(700)
        barWidth = width
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            icon.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -34),
            dismissButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissButton.widthAnchor.constraint(equalToConstant: 18),
            dismissButton.heightAnchor.constraint(equalToConstant: 18),
            width,
            widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue > 0.05 && !isHidden ? super.hitTest(point) : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    // A swipe or pinch over the card must not also change playback.
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    @objc private func actionPressed() { onAction?() }
    @objc private func dismissPressed() { onDismiss?() }

    func configure(_ notice: SubtitleNotice) {
        let tint: NSColor
        switch notice.tone {
        case .error: tint = .systemRed
        case .warning: tint = .systemOrange
        case .success: tint = .systemGreen
        case .progress, .info: tint = accent
        }
        icon.image = NSImage(systemSymbolName: notice.symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        titleLabel.stringValue = notice.title
        detailLabel.stringValue = notice.detail ?? ""
        detailLabel.isHidden = notice.detail == nil
        // A busy bar only moves with motion allowed; otherwise the title's ellipsis says enough.
        if let fraction = notice.fraction {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
            bar.isHidden = false
        } else if notice.indeterminate, notice.tone == .progress, !reducedMotion, notice.detail != nil || notice.key != "preparing" {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            bar.isHidden = false
        } else {
            bar.stopAnimation(nil)
            bar.isHidden = true
        }
        actionButton.title = notice.actionTitle ?? ""
        actionButton.isHidden = notice.action == nil
        dismissButton.isHidden = notice.lifetime != .sticky
        setAccessibilityLabel(notice.title)
        setAccessibilityValue(notice.detail ?? "")
        // A group, so the Retry and Dismiss buttons inside stay reachable; the card itself is pressed by an action.
        setAccessibilityRole(.group)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Show Subtitle Options") { [weak self] in
                self?.onClick?()
                return true
            }
        ])
        toolTip = "Click for subtitle options"
    }
}

/// A small, quiet note near the subtitles while the playhead is ahead of
/// the transcription. It never takes the mouse.
final class AheadIndicator: NSVisualEffectView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Subtitles catching up…")

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = 0
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var generation = 0
    func setPresented(_ presented: Bool) {
        generation += 1
        let mine = generation
        if presented {
            spinner.isHidden = reducedMotion
            if !reducedMotion { spinner.startAnimation(nil) }
            isHidden = false
            guard !reducedMotion else {
                alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = glide
                self.animator().alphaValue = 1
            }
        } else {
            guard !isHidden else { return }
            guard !reducedMotion else {
                alphaValue = 0
                isHidden = true
                spinner.stopAnimation(nil)
                return
            }
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.25
                    context.timingFunction = glide
                    self.animator().alphaValue = 0
                },
                completionHandler: { [weak self] in
                    guard let self, self.generation == mine else { return }
                    self.isHidden = true
                    self.spinner.stopAnimation(nil)
                })
        }
    }
}

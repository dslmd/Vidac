import AppKit

/// Small views that sit over the picture: the title strip, the seek bar's
/// time bubble, the clickable duration label and the notice card.

/// The tagline shared by the welcome page and the About panel.
enum Branding {
    static let tagline = "Local playback, automatic bilingual subtitles"
}

/// A darkening gradient across the top of the window with the file name in
/// it. It fades together with the control bar and never takes the mouse.
final class TitleStrip: NSView {
    static let height: CGFloat = 64
    private let label = NSTextField(labelWithString: "")

    override func makeBackingLayer() -> CALayer { CAGradientLayer() }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        if let gradient = layer as? CAGradientLayer {
            gradient.colors = [NSColor.black.withAlphaComponent(0.6).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        }
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white.withAlphaComponent(0.85)
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Level with the traffic lights, and clear of them on both sides.
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 84),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -84),
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `detail` is the position in a queue ("3 of 12"), shown in a lighter tone.
    func setTitle(_ title: String, detail: String?) {
        let text = NSMutableAttributedString(string: title)
        if let detail {
            text.append(
                NSAttributedString(
                    string: "  ·  " + detail,
                    attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.55), .font: NSFont.systemFont(ofSize: 13)]))
        }
        label.attributedStringValue = text
    }
}

/// The time shown above the seek bar while the pointer is on it or the knob
/// is being dragged. Positioned by frame, over the control bar.
final class ScrubBubble: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "0:00")
    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        addSubview(label)
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `centerX` is in the coordinates of the bubble's superview.
    func show(_ text: String, centerX: CGFloat, bottom: CGFloat) {
        guard let container = superview else { return }
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 20, height: 24)
        label.frame.origin = NSPoint(x: 10, y: (size.height - label.frame.height) / 2)
        let x = min(container.bounds.width - size.width - 8, max(8, centerX - size.width / 2))
        frame = NSRect(origin: NSPoint(x: x.rounded(), y: bottom.rounded()), size: size)
        isHidden = false
    }
    func hide() { isHidden = true }
}

/// A text label that can be clicked, such as the duration beside the seek bar.
final class ClickableLabel: NSTextField {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// A small floating card with a title, a detail line and up to two buttons.
/// Used for "Up Next" and for the update notice.
final class NoticeCard: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let primary: NSButton
    private let secondary: NSButton
    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?
    private var generation = 0
    var isPresented: Bool { !isHidden && alphaValue > 0.05 }

    init(primary primaryTitle: String, secondary secondaryTitle: String) {
        primary = NSButton(title: primaryTitle, target: nil, action: nil)
        secondary = NSButton(title: secondaryTitle, target: nil, action: nil)
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = 0
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        primary.target = self
        primary.action = #selector(primaryPressed)
        primary.keyEquivalent = ""
        secondary.target = self
        secondary.action = #selector(secondaryPressed)
        for button in [primary, secondary] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let buttons = NSStackView(views: [primary, secondary])
        buttons.spacing = 8
        let stack = NSStackView(views: [titleLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(10, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue > 0.05 && !isHidden ? super.hitTest(point) : nil }
    // A swipe or pinch over the card must not also change playback.
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}

    @objc private func primaryPressed() { onPrimary?() }
    @objc private func secondaryPressed() { onSecondary?() }

    func setText(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        setAccessibilityLabel(title)
        setAccessibilityValue(detail)
    }
    func present() {
        generation += 1
        let entering = isHidden || alphaValue < 0.05
        isHidden = false
        guard entering, !reducedMotion else {
            alphaValue = 1
            return
        }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = glide
            self.animator().alphaValue = 1
        }
    }
    func dismiss() {
        guard !isHidden else { return }
        generation += 1
        let mine = generation
        guard !reducedMotion else {
            alphaValue = 0
            isHidden = true
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
            })
    }
}

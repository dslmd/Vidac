import AppKit

/// A still image that never takes part in hit testing.
final class PassiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A slim track with a filled elapsed part and a small solid knob.
final class SleekSliderCell: NSSliderCell {
    private let trackHeight: CGFloat = 4
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - trackHeight / 2, width: rect.width, height: trackHeight)
        NSColor.white.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
        var elapsed = track
        elapsed.size.width = min(track.width, max(trackHeight, knobRect(flipped: flipped).midX - track.minX))
        NSColor.white.withAlphaComponent(isEnabled ? 0.92 : 0.4).setFill()
        NSBezierPath(roundedRect: elapsed, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        let diameter: CGFloat = isHighlighted ? 14 : 12
        let knob = NSRect(x: knobRect.midX - diameter / 2, y: knobRect.midY - diameter / 2, width: diameter, height: diameter)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A generous native hit target with a restrained rollover highlight.
final class PlaybackButton: NSButton {
    private var rollover: NSTrackingArea?
    private var pointerInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let rollover { removeTrackingArea(rollover) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        rollover = area
    }
    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        if pointerInside || isHighlighted {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.16 : 0.085).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
}

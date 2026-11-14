import AppKit

/// Native event adapter. Playback, window geometry and feedback belong to the
/// controller; this view only normalizes input and reports bounded intentions.
final class TrackpadVideoSurface: VideoSurface {
    var allowsTrackpadGestures: (() -> Bool)?
    var onScrollUpdate: ((TrackpadScrollUpdate) -> Void)?
    var onPinchBegan: (() -> Void)?
    var onPinchDelta: ((Double) -> Void)?
    var onPinchEnded: ((Bool) -> Void)?
    var onSmartZoom: (() -> Void)?
    var onGestureSummary: ((String) -> Void)?

    private struct ScrollStatistics {
        let precise: Bool
        var events = 0
        var callbacks = 0
        var inertiaEvents = 0
        var axis = "undecided"
        var total = 0.0
        var reason: String?
        var hasPhases = false
        var inversionMask = 0
        var rawX = 0.0
        var rawY = 0.0
        var normalizedX = 0.0
        var normalizedY = 0.0

        mutating func record(_ event: NSEvent, movement: Bool) {
            events += 1
            hasPhases = hasPhases || !event.phase.isEmpty
            let inverted = event.isDirectionInvertedFromDevice
            inversionMask |= inverted ? 2 : 1
            guard movement else { return }
            let x = Double(event.scrollingDeltaX)
            let y = Double(event.scrollingDeltaY)
            // Diagnostics stay finite and bounded even for malformed drivers.
            // Momentum contributes no movement to either these sums or playback.
            func adding(_ total: Double, _ delta: Double) -> Double {
                let finiteDelta = delta.isFinite ? min(1_000_000, max(-1_000_000, delta)) : 0
                return min(1_000_000, max(-1_000_000, total + finiteDelta))
            }
            rawX = adding(rawX, x)
            rawY = adding(rawY, y)
            normalizedX = adding(normalizedX, x * (inverted ? 1 : -1))
            normalizedY = adding(normalizedY, y * (inverted ? -1 : 1))
        }
    }
    private struct PinchStatistics {
        var events = 0
        var callbacks = 0
        var hasPhases = false
    }

    private var scroll = TrackpadScrollReducer()
    private var scrollStatistics: ScrollStatistics?
    private var pinchStatistics: PinchStatistics?
    private var lastScrollTimestamp: TimeInterval?
    private var scrollIdleTimer: Timer?
    private var scrollSummaryTimer: Timer?
    private var pinchIdleTimer: Timer?
    private var pinchActive = false

    /// The first recognized update lets the controller anchor actual media
    /// position/volume and apply their dynamic edges to the reducer.
    func constrainScrollTotal(minimum: Double, maximum: Double) {
        scroll.constrainTotal(minimum: minimum, maximum: maximum)
    }

    /// Safe for file changes, sheets, deactivation and full-screen transitions.
    /// Cancellation never commits pending movement from the previous context.
    func cancelTrackpadGestures() {
        scrollIdleTimer?.invalidate(); scrollIdleTimer = nil
        scrollSummaryTimer?.invalidate(); scrollSummaryTimer = nil
        pinchIdleTimer?.invalidate(); pinchIdleTimer = nil
        finishScroll(cancelled: true, reason: "cancelled")
        finishScrollSummary(fallbackReason: "cancelled")
        finishPinch(cancelled: true, reason: "cancelled")
    }

    override func scrollWheel(with event: NSEvent) {
        guard allowsTrackpadGestures?() ?? true else {
            cancelTrackpadGestures()
            return
        }
        guard !pinchActive else { return }

        // Momentum also has phase=.none. Filter it before classifying legacy
        // wheel events, and never let its deltas alter playback or volume.
        if !event.momentumPhase.isEmpty {
            if scrollStatistics != nil {
                scrollStatistics?.record(event, movement: false)
                scrollStatistics?.inertiaEvents += 1
            }
            if scroll.isActive { finishScroll(cancelled: false, reason: "momentum") }
            scrollIdleTimer?.invalidate(); scrollIdleTimer = nil
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                finishScrollSummary(fallbackReason: "momentum-ended")
            } else {
                scheduleScrollSummary()
            }
            return
        }

        let phase = scrollPhase(event.phase)
        // The corresponding first event may have landed on a control instead
        // of the video. Do not manufacture an action from a terminal event.
        if !scroll.isActive && (phase == .ended || phase == .cancelled) {
            scrollStatistics?.record(event, movement: true)
            scheduleScrollSummary()
            return
        }
        if event.phase.contains(.mayBegin), !scroll.isActive,
           event.scrollingDeltaX == 0, event.scrollingDeltaY == 0 { return }

        // A blocked run loop can deliver the next event before the idle timer
        // gets a turn. Finish the old context before the reducer resets itself.
        let gapExpired = phase == .none && (lastScrollTimestamp.map { event.timestamp - $0 >= scroll.unphasedGap } ?? false)
        let precisionChanged = scrollStatistics.map { $0.precise != event.hasPreciseScrollingDeltas } ?? false
        if scroll.isActive && (phase == .began || gapExpired || precisionChanged) {
            finishScroll(cancelled: false, reason: phase == .began ? "next-began" : "idle-gap")
            finishScrollSummary(fallbackReason: "next-input")
        } else if !scroll.isActive, scrollStatistics != nil {
            finishScrollSummary(fallbackReason: "next-input")
        }

        if scrollStatistics == nil { scrollStatistics = ScrollStatistics(precise: event.hasPreciseScrollingDeltas) }
        scrollStatistics?.record(event, movement: true)
        lastScrollTimestamp = event.timestamp
        let inverted = event.isDirectionInvertedFromDevice
        // Fixed physical finger direction, independently of Natural Scrolling:
        // right => positive seek; up => positive volume. Axes differ in AppKit.
        let x = Double(event.scrollingDeltaX) * (inverted ? 1 : -1)
        let y = Double(event.scrollingDeltaY) * (inverted ? -1 : 1)
        if let update = scroll.consume(deltaX: x, deltaY: y,
                                       precise: event.hasPreciseScrollingDeltas,
                                       timestamp: event.timestamp, phase: phase) {
            deliver(update)
        }
        if phase == .ended || phase == .cancelled {
            scrollStatistics?.reason = phase == .cancelled ? "cancelled" : "ended"
            scrollIdleTimer?.invalidate(); scrollIdleTimer = nil
            lastScrollTimestamp = nil
            scheduleScrollSummary()
        } else if scroll.isActive {
            scheduleScrollIdle(phased: scrollStatistics?.hasPhases ?? !event.phase.isEmpty)
        }
    }

    override func magnify(with event: NSEvent) {
        guard allowsTrackpadGestures?() ?? true else {
            cancelTrackpadGestures()
            return
        }
        let cancelled = event.phase.contains(.cancelled)
        let ended = event.phase.contains(.ended)
        if cancelled {
            if pinchActive { pinchStatistics?.events += 1 }
            finishPinch(cancelled: true, reason: "cancelled")
            return
        }
        guard pinchActive || !ended else { return }
        if event.phase.contains(.began), pinchActive {
            finishPinch(cancelled: true, reason: "next-began")
        }
        if !pinchActive {
            finishScroll(cancelled: true, reason: "pinch")
            finishScrollSummary(fallbackReason: "pinch")
            pinchActive = true
            pinchStatistics = PinchStatistics()
            onPinchBegan?()
        }
        // A controller callback may have cancelled because its context changed.
        guard pinchActive else { return }
        pinchStatistics?.events += 1
        if !event.phase.isEmpty { pinchStatistics?.hasPhases = true }
        let delta = Double(event.magnification)
        if delta.isFinite && delta != 0 {
            pinchStatistics?.callbacks += 1
            onPinchDelta?(delta)
        }
        guard pinchActive else { return }
        if ended { finishPinch(cancelled: false, reason: "ended") }
        else { schedulePinchIdle(phased: pinchStatistics?.hasPhases ?? !event.phase.isEmpty) }
    }

    override func smartMagnify(with event: NSEvent) {
        guard allowsTrackpadGestures?() ?? true else {
            cancelTrackpadGestures()
            return
        }
        cancelTrackpadGestures()
        onSmartZoom?()
        onGestureSummary?("trackpad smart-zoom events=1 callbacks=1")
    }

    override func keyDown(with event: NSEvent) {
        cancelTrackpadGestures()
        super.keyDown(with: event)
    }

    override func endGesture(with event: NSEvent) {
        guard allowsTrackpadGestures?() ?? true else {
            cancelTrackpadGestures()
            return
        }
        let cancelled = event.phase.contains(.cancelled)
        if pinchActive { finishPinch(cancelled: cancelled, reason: cancelled ? "cancelled" : "gesture-ended") }
        if scroll.isActive { finishScroll(cancelled: cancelled, reason: cancelled ? "cancelled" : "gesture-ended") }
    }

    private func scrollPhase(_ phase: NSEvent.Phase) -> TrackpadScrollPhase {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        return .none
    }
    private func deliver(_ update: TrackpadScrollUpdate) {
        scrollStatistics?.callbacks += 1
        scrollStatistics?.axis = update.axis == .horizontal ? "seek" : "volume"
        scrollStatistics?.total = update.total
        onScrollUpdate?(update)
    }
    private func finishScroll(cancelled: Bool, reason: String) {
        scrollIdleTimer?.invalidate(); scrollIdleTimer = nil
        lastScrollTimestamp = nil
        if let update = scroll.finish(timestamp: ProcessInfo.processInfo.systemUptime, cancelled: cancelled) { deliver(update) }
        if scrollStatistics?.reason == nil { scrollStatistics?.reason = reason }
        scheduleScrollSummary()
    }
    private func scheduleScrollIdle(phased: Bool) {
        // Keep a real finger gesture alive across brief stationary holds.
        // A legacy wheel has no finger-end phase and needs a shorter timeout.
        // Updating one deadline avoids allocating and re-registering a timer
        // for every high-frequency input event on the UI thread.
        let interval: TimeInterval = phased ? 5 : 0.18
        if let timer = scrollIdleTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: interval)
            return
        }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.allowsTrackpadGestures?() ?? true { self.finishScroll(cancelled: false, reason: "idle") }
            else { self.cancelTrackpadGestures() }
        }
        scrollIdleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func scheduleScrollSummary() {
        guard scrollStatistics != nil else { return }
        if let timer = scrollSummaryTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: 0.18)
            return
        }
        let timer = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            self?.finishScrollSummary(fallbackReason: "idle")
        }
        scrollSummaryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func finishScrollSummary(fallbackReason: String) {
        scrollSummaryTimer?.invalidate(); scrollSummaryTimer = nil
        guard let statistics = scrollStatistics else { return }
        scrollStatistics = nil
        guard statistics.events > 0 else { return }
        let mode = statistics.precise ? "points" : "wheel"
        let total = String(format: "%.3f", statistics.total)
        let inverted = statistics.inversionMask == 1 ? "false" : (statistics.inversionMask == 2 ? "true" : (statistics.inversionMask == 3 ? "mixed" : "unknown"))
        let movement = String(format: "raw-x=%.3f raw-y=%.3f normalized-x=%.3f normalized-y=%.3f", statistics.rawX, statistics.rawY, statistics.normalizedX, statistics.normalizedY)
        onGestureSummary?("trackpad scroll reason=\(statistics.reason ?? fallbackReason) axis=\(statistics.axis) events=\(statistics.events) callbacks=\(statistics.callbacks) inertia=\(statistics.inertiaEvents) mode=\(mode) reducer-total=\(total) inverted=\(inverted) \(movement) deltas=finger-only")
    }
    private func schedulePinchIdle(phased: Bool) {
        let interval: TimeInterval = phased ? 5 : 0.25
        if let timer = pinchIdleTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: interval)
            return
        }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.finishPinch(cancelled: !(self.allowsTrackpadGestures?() ?? true), reason: "idle")
        }
        pinchIdleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func finishPinch(cancelled: Bool, reason: String) {
        pinchIdleTimer?.invalidate(); pinchIdleTimer = nil
        guard pinchActive else { return }
        pinchActive = false
        let statistics = pinchStatistics
        pinchStatistics = nil
        onPinchEnded?(cancelled)
        if let statistics {
            onGestureSummary?("trackpad pinch reason=\(reason) cancelled=\(cancelled) events=\(statistics.events) callbacks=\(statistics.callbacks)")
        }
    }
    deinit {
        scrollIdleTimer?.invalidate()
        scrollSummaryTimer?.invalidate()
        pinchIdleTimer?.invalidate()
    }
}

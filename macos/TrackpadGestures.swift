import Foundation

enum TrackpadScrollPhase { case none, began, changed, ended, cancelled }
enum TrackpadScrollAxis { case horizontal, vertical }

struct TrackpadScrollUpdate {
    let axis: TrackpadScrollAxis
    /// Horizontal: seconds. Vertical: volume percentage points.
    let delta: Double
    let total: Double
    let isFirst: Bool
    let isFinal: Bool
    let cancelled: Bool
}

/// Converts a stream of device-normalized finger deltas into bounded actions.
/// AppKit direction/natural-scroll normalization deliberately belongs to the view.
struct TrackpadScrollReducer {
    var secondsPerPoint = 0.06
    var volumePerPoint = 0.25
    var intentThreshold = 8.0
    var dominanceRatio = 1.25
    var maximumSeekPerGesture = 60.0
    var maximumVolumePerGesture = 100.0
    var emissionInterval = 1.0 / 30.0
    var unphasedGap = 0.18
    private(set) var axis: TrackpadScrollAxis?
    private(set) var isActive = false
    private var precise = true
    private var undecidedX = 0.0
    private var undecidedY = 0.0
    private var total = 0.0
    private var emittedTotal = 0.0
    private var hasEmitted = false
    private var permittedTotal: ClosedRange<Double>?
    private var lastEventTime: TimeInterval?
    private var lastEmissionTime: TimeInterval?

    mutating func reset() {
        axis = nil
        isActive = false
        undecidedX = 0
        undecidedY = 0
        total = 0
        emittedTotal = 0
        hasEmitted = false
        permittedTotal = nil
        lastEventTime = nil
        lastEmissionTime = nil
    }

    mutating func consume(
        deltaX: Double, deltaY: Double, precise: Bool,
        timestamp: TimeInterval, phase: TrackpadScrollPhase,
        momentum: Bool = false
    ) -> TrackpadScrollUpdate? {
        guard timestamp.isFinite else { return nil }
        // Inertia never contributes movement. Its first event can finish the
        // real finger's pending tail if a driver omitted phase=.ended.
        if momentum { return finish() }
        if phase == .cancelled { return finish(cancelled: true) }
        if phase == .began { reset() }
        if phase == .none, let lastEventTime, timestamp - lastEventTime > unphasedGap { reset() }
        if isActive && self.precise != precise { reset() }
        if !isActive {
            isActive = true
            self.precise = precise
        }
        self.lastEventTime = timestamp

        let x = deltaX.isFinite ? deltaX : 0
        let y = deltaY.isFinite ? deltaY : 0
        if axis == nil {
            undecidedX += x
            undecidedY += y
            let minimum = precise ? intentThreshold : 0.001
            if abs(undecidedX) >= minimum && abs(undecidedX) >= abs(undecidedY) * dominanceRatio {
                axis = .horizontal
            } else if abs(undecidedY) >= minimum && abs(undecidedY) >= abs(undecidedX) * dominanceRatio {
                axis = .vertical
            }
            if let axis {
                let movement = axis == .horizontal ? undecidedX : undecidedY
                // Spend the initial threshold on identifying intent, not on a
                // sudden jump when the gesture first becomes recognized.
                let adjusted = precise ? movement - (movement < 0 ? -intentThreshold : intentThreshold) : movement
                accumulate(adjusted)
                undecidedX = 0
                undecidedY = 0
            }
        } else {
            accumulate(axis == .horizontal ? x : y)
        }
        if phase == .ended { return finish() }
        guard axis != nil, abs(total - emittedTotal) > 0.000_001 else { return nil }
        if let lastEmissionTime, timestamp - lastEmissionTime < emissionInterval { return nil }
        self.lastEmissionTime = timestamp
        return emit(final: false, cancelled: false)
    }

    /// Also usable by the view's idle timer for legacy events without phases.
    /// A terminal flush may follow a regular update sooner than one frame; it
    /// preserves the final finger movement rather than losing it to throttling.
    mutating func finish(timestamp: TimeInterval, cancelled: Bool = false) -> TrackpadScrollUpdate? {
        // Terminal flushes intentionally bypass the normal update interval.
        // Accept the caller's timestamp so idle-timer and event paths share an
        // API without making them manufacture a final zero-delta input event.
        finish(cancelled: cancelled)
    }
    mutating func finish(cancelled: Bool = false) -> TrackpadScrollUpdate? {
        guard isActive else { return nil }
        let result: TrackpadScrollUpdate?
        if let axis {
            if cancelled {
                result = TrackpadScrollUpdate(
                    axis: axis, delta: 0, total: emittedTotal,
                    isFirst: !hasEmitted,
                    isFinal: true, cancelled: true)
            } else {
                result = emit(final: true, cancelled: false)
            }
        } else {
            result = nil
        }
        reset()
        return result
    }

    /// Call after the first update supplies an axis and the view anchors the
    /// actual playback position/volume. Clamping both accumulators prevents
    /// hidden overshoot from producing a dead zone when reversing at an edge.
    mutating func constrainTotal(minimum: Double, maximum: Double) {
        guard let axis, minimum.isFinite, maximum.isFinite,
            minimum <= 0, maximum >= 0
        else { return }
        let cap = axis == .horizontal ? maximumSeekPerGesture : maximumVolumePerGesture
        let lower = max(-cap, minimum), upper = min(cap, maximum)
        guard lower <= upper else { return }
        permittedTotal = lower...upper
        total = min(upper, max(lower, total))
        emittedTotal = min(upper, max(lower, emittedTotal))
    }

    private mutating func accumulate(_ movement: Double) {
        guard let axis else { return }
        let addition: Double
        if precise {
            addition = movement * (axis == .horizontal ? secondsPerPoint : volumePerPoint)
        } else {
            // Non-precise wheels report driver-dependent line counts. One
            // event is one step; system "lines per notch" must not multiply it.
            addition = min(1, max(-1, movement)) * (axis == .horizontal ? 5 : 2)
        }
        let limit = axis == .horizontal ? maximumSeekPerGesture : maximumVolumePerGesture
        // Clamp the accumulator itself so reversing at the limit responds
        // immediately instead of spending time cancelling invisible overshoot.
        total = min(
            permittedTotal?.upperBound ?? limit,
            max(permittedTotal?.lowerBound ?? -limit, total + addition))
    }
    private mutating func emit(final: Bool, cancelled: Bool) -> TrackpadScrollUpdate? {
        guard let axis else { return nil }
        let update = TrackpadScrollUpdate(
            axis: axis, delta: total - emittedTotal,
            total: total, isFirst: !hasEmitted,
            isFinal: final, cancelled: cancelled)
        emittedTotal = total
        hasEmitted = true
        return update
    }
}

/// A bounded incremental pinch scale. The view maps this scale to video-zoom
/// and separately decides whether a windowed pinch should resize its window.
struct PinchZoomReducer {
    var minimumScale = 0.5
    var maximumScale = 3.0
    // AppKit has already recognized the pinch before delivering this stream.
    // A second 1.2% dead zone made the window lag behind the fingers; a 2.5%
    // end snap then moved it again after release. Preserve the exact input by
    // default. Explicit reset remains available through smart zoom / Cmd-0.
    var intentThreshold = 0.0
    var resetSnapTolerance = 0.0
    private(set) var isActive = false
    private(set) var scale = 1.0
    private var initialScale = 1.0
    private var pendingMagnification = 0.0
    private var recognized = false

    mutating func begin(scale: Double, min minimum: Double? = nil, max maximum: Double? = nil) {
        let lower = minimum ?? minimumScale
        let upper = maximum ?? maximumScale
        if lower.isFinite && upper.isFinite && lower > 0 && upper >= lower {
            minimumScale = lower
            maximumScale = upper
        } else {
            minimumScale = 0.5
            maximumScale = 3
        }
        self.scale = bounded(scale.isFinite ? scale : 1)
        initialScale = self.scale
        pendingMagnification = 0
        recognized = false
        isActive = true
    }
    mutating func consume(magnification: Double) -> Double? {
        guard isActive, magnification.isFinite else { return nil }
        var movement = min(2, max(-0.95, magnification))
        guard movement != 0 else { return nil }
        if !recognized {
            pendingMagnification += movement
            guard abs(pendingMagnification) >= intentThreshold else { return nil }
            recognized = true
            movement = pendingMagnification - (pendingMagnification < 0 ? -intentThreshold : intentThreshold)
            pendingMagnification = 0
        }
        let next = bounded(scale * (1 + movement))
        guard abs(next - scale) > 0.000_001 else { return nil }
        scale = next
        return scale
    }
    mutating func change(magnification: Double) -> Double? { consume(magnification: magnification) }
    mutating func end(cancelled: Bool = false) -> Double? {
        guard isActive else { return nil }
        isActive = false
        if cancelled {
            scale = initialScale
            return scale
        }
        guard recognized else { return nil }
        if minimumScale <= 1 && maximumScale >= 1 && abs(scale - 1) <= resetSnapTolerance { scale = 1 }
        return scale
    }
    mutating func reset(scale: Double = 1) {
        self.scale = bounded(scale.isFinite ? scale : 1)
        initialScale = self.scale
        pendingMagnification = 0
        recognized = false
        isActive = false
    }
    private func bounded(_ value: Double) -> Double { min(maximumScale, max(minimumScale, value)) }
}

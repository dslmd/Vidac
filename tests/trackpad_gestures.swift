import Foundation

@main
struct GestureReducerTests {
    static var assertions = 0
    static func expect(_ test: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !test() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.000_001) -> Bool { abs(a - b) < tolerance }
    static func main() {
        var scroll = TrackpadScrollReducer()
        // 1,000 precise events are one smooth gesture, not 1,000 keypresses.
        var updates: [TrackpadScrollUpdate] = []
        for i in 0..<1000 {
            if let u = scroll.consume(
                deltaX: 0.5, deltaY: 0.01, precise: true,
                timestamp: Double(i) / 1000, phase: i == 0 ? .began : .changed)
            {
                updates.append(u)
            }
        }
        if let u = scroll.finish() { updates.append(u) }
        expect(updates.count <= 32, "high-frequency stream stays bounded to frame-rate plus terminal flush")
        expect(
            near(updates.reduce(0) { $0 + $1.delta }, (500 - 8) * 0.06),
            "accumulation preserves all intended finger movement after dead zone")
        expect(updates.last?.isFinal == true, "end flush is marked final")
        expect(
            updates.first?.isFirst == true && updates.dropFirst().allSatisfy { !$0.isFirst }, "only the initial output anchors a gesture")
        expect(!scroll.isActive, "end clears gesture state")
        _ = scroll.consume(deltaX: 20, deltaY: 0, precise: true, timestamp: 1.1, phase: .began)
        let zeroTail = scroll.finish(timestamp: 1.2)
        expect(zeroTail?.isFinal == true && zeroTail?.delta == 0, "zero tail still ends a recognized gesture")

        // A mostly horizontal start cannot also alter volume as the hand drifts.
        var locked: [TrackpadScrollUpdate] = []
        for (i, point) in [(12.0, 2.0), (0.0, 60.0), (0.0, 80.0)].enumerated() {
            if let u = scroll.consume(
                deltaX: point.0, deltaY: point.1, precise: true,
                timestamp: 2 + Double(i) * 0.05, phase: i == 0 ? .began : .changed)
            {
                locked.append(u)
            }
        }
        if let u = scroll.finish() { locked.append(u) }
        expect(locked.allSatisfy { $0.axis == .horizontal }, "axis remains locked throughout a gesture")
        expect(near(locked.reduce(0) { $0 + $1.delta }, 0.24), "cross-axis motion cannot turn into movement")

        // Equal diagonal / tiny touches have no sufficiently clear intent.
        for i in 0..<10 {
            expect(
                scroll.consume(
                    deltaX: 0.3, deltaY: 0.3, precise: true,
                    timestamp: 3 + Double(i) * 0.01, phase: i == 0 ? .began : .changed) == nil,
                "tiny diagonal touch is ignored")
        }
        expect(scroll.finish() == nil, "unrecognized gesture has no final action")
        expect(
            scroll.consume(deltaX: 200, deltaY: 200, precise: true, timestamp: 4, phase: .began) == nil,
            "ambiguous strong diagonal is not arbitrarily assigned to an axis")
        _ = scroll.finish()

        // Momentum may flush the pending finger tail but contributes no delta.
        var sum = 0.0
        if let u = scroll.consume(deltaX: 10, deltaY: 0, precise: true, timestamp: 5, phase: .began) { sum += u.delta }
        if let u = scroll.consume(deltaX: 5, deltaY: 0, precise: true, timestamp: 5.001, phase: .changed) { sum += u.delta }
        if let u = scroll.consume(deltaX: 10000, deltaY: 0, precise: true, timestamp: 5.01, phase: .none, momentum: true) { sum += u.delta }
        expect(near(sum, 7 * 0.06), "inertia does not contribute 10,000-point delta")
        expect(!scroll.isActive, "momentum finishes the physical gesture")
        expect(
            scroll.consume(deltaX: 10000, deltaY: 0, precise: true, timestamp: 5.02, phase: .none, momentum: true) == nil,
            "later momentum is entirely ignored")

        _ = scroll.consume(deltaX: 20, deltaY: 0, precise: true, timestamp: 6, phase: .began)
        _ = scroll.consume(deltaX: 30, deltaY: 0, precise: true, timestamp: 6.001, phase: .changed)
        let cancellation = scroll.finish(cancelled: true)
        expect(cancellation?.cancelled == true && cancellation?.delta == 0, "cancel drops uncommitted tail")
        expect(!scroll.isActive, "cancel resets axis lock and activity")

        _ = scroll.consume(deltaX: 20000, deltaY: 0, precise: true, timestamp: 7, phase: .began)
        let reverse = scroll.consume(deltaX: -10, deltaY: 0, precise: true, timestamp: 7.05, phase: .changed)
        expect(near(reverse!.total, 59.4) && near(reverse!.delta, -0.6), "seek cap is 60s and reversal is immediately responsive")
        _ = scroll.finish()
        _ = scroll.consume(deltaX: 500, deltaY: 0, precise: true, timestamp: 7.2, phase: .began)
        scroll.constrainTotal(minimum: -100, maximum: 2)
        let reverseAtMovieEnd = scroll.consume(deltaX: -10, deltaY: 0, precise: true, timestamp: 7.25, phase: .changed)
        expect(
            near(reverseAtMovieEnd!.total, 1.4) && near(reverseAtMovieEnd!.delta, -0.6),
            "movie-end range removes invisible overshoot immediately")
        _ = scroll.consume(deltaX: -20000, deltaY: 0, precise: true, timestamp: 7.3, phase: .changed)
        expect(scroll.finish()!.total == -60, "external range cannot bypass the per-gesture safety cap")
        let volume = scroll.consume(deltaX: 0, deltaY: 2000, precise: true, timestamp: 8, phase: .began)
        expect(volume?.axis == .vertical && volume?.total == 100, "volume gesture total is bounded")
        _ = scroll.finish()

        let firstWheel = scroll.consume(deltaX: 0, deltaY: 3, precise: false, timestamp: 9, phase: .none)
        expect(firstWheel?.delta == 2, "mouse line-count preference does not triple a volume notch")
        let secondWheel = scroll.consume(deltaX: 1, deltaY: 0, precise: false, timestamp: 9.3, phase: .none)
        expect(secondWheel?.axis == .horizontal && secondWheel?.delta == 5, "unphased idle gap starts a fresh axis")
        _ = scroll.finish()
        expect(
            scroll.consume(deltaX: .nan, deltaY: .infinity, precise: true, timestamp: 10, phase: .began) == nil,
            "nonfinite deltas are ignored")
        _ = scroll.finish()

        var pinch = PinchZoomReducer()
        pinch.begin(scale: 1)
        expect(
            near(pinch.change(magnification: 0.005)!, 1.005), "first recognized pinch event moves immediately without a second dead zone")
        let spread = pinch.change(magnification: 0.1)
        expect(spread != nil && spread! > 1, "spreading fingers increases zoom")
        _ = pinch.change(magnification: 2)
        expect(pinch.scale == 3, "spread cannot exceed 300 percent")
        let reversed = pinch.change(magnification: -0.1)
        expect(reversed != nil && reversed! < 3, "pinch reverses immediately at upper clamp")
        _ = pinch.change(magnification: -2)
        _ = pinch.change(magnification: -2)
        expect(pinch.scale == 0.5, "contraction cannot go below 50 percent")
        expect(pinch.end(cancelled: true) == 1, "cancelled pinch restores initial zoom")
        pinch.begin(scale: 1.01)
        _ = pinch.change(magnification: 0.013)
        let beforeRelease = pinch.scale
        expect(
            pinch.end() == beforeRelease && near(beforeRelease, 1.02313),
            "release preserves the last finger position without a 100-percent snap")
        pinch.begin(scale: .nan)
        expect(pinch.scale == 1, "invalid initial zoom recovers to original size")
        expect(pinch.change(magnification: .nan) == nil, "invalid magnification does not corrupt zoom")
        expect(pinch.end() == nil, "no-op pinch has no visual jump")
        pinch.begin(scale: 1, min: 0.8, max: 1.25)
        _ = pinch.consume(magnification: 2)
        expect(pinch.scale == 1.25, "window-specific upper bound is respected")
        let reverseAtWindowLimit = pinch.consume(magnification: -0.1)
        expect(near(reverseAtWindowLimit!, 1.125), "dynamic upper bound has no reverse dead zone")
        _ = pinch.consume(magnification: -0.9)
        expect(pinch.scale == 0.8, "window-specific lower bound is respected")
        _ = pinch.end()
        pinch.begin(scale: 0.99, min: 0.8, max: 0.995)
        _ = pinch.consume(magnification: 0.013)
        expect(pinch.end()! <= 0.995, "100-percent snap cannot exceed dynamic upper bound")
        pinch.reset(scale: 0.9)
        expect(!pinch.isActive && near(pinch.scale, 0.9), "reset clears gesture state and preserves requested bounded scale")
        pinch = PinchZoomReducer()
        pinch.begin(scale: 1)
        expect(pinch.consume(magnification: 0) == nil && pinch.end() == nil, "zero-movement gesture remains a no-op")
        pinch.begin(scale: 1)
        let tinyForward = pinch.consume(magnification: 0.0005)
        expect(tinyForward != nil && near(tinyForward!, 1.0005), "small deliberate pinch movement reaches the first frame intact")
        let tinyReverse = pinch.consume(magnification: -0.0005)
        expect(tinyReverse != nil && tinyReverse! < tinyForward!, "small reversal responds on the very next event")
        _ = pinch.end()
        pinch.begin(scale: 1)
        for _ in 0..<1000 { _ = pinch.consume(magnification: 0.0001) }
        expect(near(pinch.scale, pow(1.0001, 1000)), "high-frequency small input is accumulated without dropping its first frame")
        let accumulatedScale = pinch.scale
        expect(pinch.end() == accumulatedScale, "high-frequency gesture has no release tail or scale jump")
        pinch.begin(scale: 0.99)
        _ = pinch.consume(magnification: 0.005)
        expect(near(pinch.end()!, 0.99495), "near-original contraction does not jump to original size on release")
        print("PASS: \(assertions) gesture reducer assertions")
    }
}

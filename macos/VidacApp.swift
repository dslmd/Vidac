import AppKit
import OpenGL.GL3
import Darwin

// Native macOS host. Video remains in this process; the Python companion only
// controls the same libmpv core through its IPC client and generates subtitles.

let accent = NSColor(calibratedRed: 0.64, green: 0.55, blue: 0.98, alpha: 1)
let background = NSColor(calibratedWhite: 0.065, alpha: 1)
var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
/// Fast start, long soft landing: the curve used for every discrete transition.
let glide = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
private let logLock = NSLock()
func appendHandle(_ url: URL) -> FileHandle? {
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    return descriptor >= 0 ? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) : nil
}
func nativeLog(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    logLock.lock()
    defer { logLock.unlock() }
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/vidac-native.log")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let file = appendHandle(url) {
        file.write(Data(line.utf8))
        try? file.close()
    }
}
func mpvError(_ code: Int32) -> String { String(cString: mpv_error_string(code)) }

/// What the core reports about the file it is playing. `entry` is mpv's
/// playlist entry id, which ties an event to the `loadfile` that caused it.
enum PlaybackEvent {
    enum EndReason { case finished, stopped, failed, other }
    case fileLoaded(entry: Int64)
    case fileEnded(entry: Int64, reason: EndReason, error: Int32)
}

final class PlaybackEngine {
    var handle: OpaquePointer?
    let socketPath: String
    var onValue: ((String, Any) -> Void)?
    var onEvent: ((PlaybackEvent) -> Void)?
    private var eventWork: DispatchWorkItem?
    private let eventGroup = DispatchGroup()
    private let stateLock = NSLock()
    private var stopping = false
    private var replyHandlers: [UInt64: (Int32, Int64?) -> Void] = [:]
    private var nextReply: UInt64 = 0
    private let observations: [(name: String, format: mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG), ("volume", MPV_FORMAT_DOUBLE),
        ("mute", MPV_FORMAT_FLAG), ("speed", MPV_FORMAT_DOUBLE), ("path", MPV_FORMAT_STRING), ("eof-reached", MPV_FORMAT_FLAG),
        ("user-data/vidac-state", MPV_FORMAT_STRING),
        ("video-out-params/aspect", MPV_FORMAT_DOUBLE), ("video-out-params/rotate", MPV_FORMAT_DOUBLE),
    ]

    init(socketPath: String, volume: Double = 100) throws {
        self.socketPath = socketPath
        guard let core = mpv_create() else {
            throw NSError(domain: "Vidac", code: 1, userInfo: [NSLocalizedDescriptionKey: "The playback engine could not start."])
        }
        handle = core
        for (key, value) in [
            ("vo", "libmpv"), ("terminal", "no"), ("osc", "no"),
            ("idle", "yes"), ("keep-open", "yes"), ("hwdec", "auto-safe"),
            ("input-default-bindings", "yes"), ("input-vo-keyboard", "yes"),
            ("input-ipc-server", socketPath), ("config", "no"),
            ("sub-auto", "no"), ("ytdl", "no"), ("osd-bar", "no"),
            // Vidac draws its own subtitles; an embedded track must not appear under them.
            ("sid", "no"),
            // Keys, slider and trackpad all share one 0–100 range.
            ("volume-max", "100"), ("volume", String(min(100, max(0, volume)))),
        ] {
            let result = mpv_set_option_string(core, key, value)
            if result < 0 { nativeLog("mpv option \(key): \(mpvError(result))") }
        }
        let result = mpv_initialize(core)
        guard result >= 0 else {
            mpv_terminate_destroy(core)
            handle = nil
            throw NSError(domain: "Vidac", code: Int(result), userInfo: [NSLocalizedDescriptionKey: mpvError(result)])
        }
        mpv_request_log_messages(core, "warn")
        for (index, observation) in observations.enumerated() {
            mpv_observe_property(core, UInt64(index + 1), observation.name, observation.format)
        }
        eventGroup.enter()
        let work = DispatchWorkItem { [weak self] in
            defer { self?.eventGroup.leave() }
            guard let self else { return }
            var startedEntry: Int64 = 0
            while true {
                self.stateLock.lock()
                let stop = self.stopping
                self.stateLock.unlock()
                if stop { break }
                guard let event = mpv_wait_event(core, 0.1) else { continue }
                let id = event.pointee.event_id
                if id == MPV_EVENT_SHUTDOWN { break }
                if id == MPV_EVENT_PROPERTY_CHANGE, let data = event.pointee.data {
                    let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                    guard let namePointer = property.name, let raw = property.data else { continue }
                    let name = String(cString: namePointer)
                    var value: Any?
                    if property.format == MPV_FORMAT_DOUBLE { value = raw.assumingMemoryBound(to: Double.self).pointee }
                    if property.format == MPV_FORMAT_FLAG { value = raw.assumingMemoryBound(to: Int32.self).pointee != 0 }
                    if property.format == MPV_FORMAT_STRING, let pointer = raw.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                        value = String(cString: pointer)
                    }
                    if let value { DispatchQueue.main.async { [weak self] in self?.onValue?(name, value) } }
                } else if id == MPV_EVENT_START_FILE, let data = event.pointee.data {
                    startedEntry = data.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id
                } else if id == MPV_EVENT_FILE_LOADED {
                    let entry = startedEntry
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(.fileLoaded(entry: entry)) }
                } else if id == MPV_EVENT_END_FILE, let data = event.pointee.data {
                    let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    let reason: PlaybackEvent.EndReason
                    switch end.reason {
                    case MPV_END_FILE_REASON_EOF: reason = .finished
                    case MPV_END_FILE_REASON_STOP, MPV_END_FILE_REASON_QUIT: reason = .stopped
                    case MPV_END_FILE_REASON_ERROR: reason = .failed
                    default: reason = .other
                    }
                    let entry = end.playlist_entry_id, error = end.error
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(.fileEnded(entry: entry, reason: reason, error: error)) }
                } else if id == MPV_EVENT_COMMAND_REPLY, event.pointee.reply_userdata != 0 {
                    let token = event.pointee.reply_userdata, error = event.pointee.error
                    var entry: Int64?
                    if error >= 0, let data = event.pointee.data {
                        let node = data.assumingMemoryBound(to: mpv_event_command.self).pointee.result
                        if node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list?.pointee, list.num > 0 {
                            for index in 0..<Int(list.num) {
                                guard let key = list.keys[index], String(cString: key) == "playlist_entry_id" else { continue }
                                if list.values[index].format == MPV_FORMAT_INT64 { entry = list.values[index].u.int64 }
                            }
                        }
                    }
                    self.stateLock.lock()
                    let handler = self.replyHandlers.removeValue(forKey: token)
                    self.stateLock.unlock()
                    if let handler { DispatchQueue.main.async { handler(error, entry) } }
                } else if id == MPV_EVENT_LOG_MESSAGE, let data = event.pointee.data {
                    let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    if let text = message.text {
                        nativeLog("mpv: " + String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
        }
        eventWork = work
        DispatchQueue.global(qos: .userInteractive).async(execute: work)
        nativeLog("Native playback engine ready at \(socketPath)")
    }

    // All commands issued from the UI/render thread use the documented safe
    // asynchronous API. No synchronous playback call blocks OpenGL rendering.
    /// `completion`, when given, runs on the main thread with mpv's error code
    /// (negative on failure) and, for `loadfile`, the new playlist entry id.
    func command(_ words: [String], completion: ((_ error: Int32, _ entry: Int64?) -> Void)? = nil) {
        guard let handle else { return }
        var token: UInt64 = 0
        if let completion {
            stateLock.lock()
            nextReply += 1
            token = nextReply
            replyHandlers[token] = completion
            stateLock.unlock()
        }
        var arguments = words.map { strdup($0) }
        arguments.append(nil)
        let argumentCount = arguments.count
        defer { arguments.forEach { free($0) } }
        let result = arguments.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: argumentCount) {
                mpv_command_async(handle, token, $0)
            }
        }
        guard result < 0 else { return }
        nativeLog("mpv command \(words.first ?? ""): \(mpvError(result))")
        if let completion {
            stateLock.lock()
            replyHandlers.removeValue(forKey: token)
            stateLock.unlock()
            DispatchQueue.main.async { completion(result, nil) }
        }
    }
    func setting(_ key: String, _ value: String) { command(["script-message", "vidac-ui", "setting", key, value]) }
    func stop() {
        stateLock.lock()
        stopping = true
        stateLock.unlock()
        eventGroup.wait()
        if let handle {
            mpv_terminate_destroy(handle)
            self.handle = nil
        }
    }
}

class VideoSurface: NSOpenGLView {
    let engine: PlaybackEngine
    var renderContext: OpaquePointer?
    var onReady: (() -> Void)?
    var onPointer: (() -> Void)?
    var onOpen: (([URL]) -> Void)?
    var onFullscreen: (() -> Void)?
    /// A settled single click on the picture (not a drag, not the first half of a double click).
    var onClick: (() -> Void)?
    /// Returns true when the key was handled.
    var onKey: ((NSEvent) -> Bool)?
    var onContextMenu: (() -> NSMenu?)?
    /// True while fingers are scaling the window. A resize redraw must reach
    /// the screen in the same refresh as the new frame, so the renderer is
    /// told not to wait for the next video frame's presentation time.
    var isDirectlyManipulated = false
    private var tracking: NSTrackingArea?
    private var didPrepare = false
    private var drawQueued = false
    private var pressLocation: NSPoint?
    private var pressMoved = false
    private var pendingClick: DispatchWorkItem?
    private var clickDelivered = false
    private let glLibrary = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)

    init(engine: PlaybackEngine) {
        self.engine = engine
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAColorSize), 24, UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAccelerated), 0,
        ]
        super.init(frame: .zero, pixelFormat: NSOpenGLPixelFormat(attributes: attributes)!)!
        wantsBestResolutionOpenGLSurface = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard !didPrepare else { return }
        didPrepare = true
        openGLContext?.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
        var initialization = mpv_opengl_init_params(
            get_proc_address: { context, name in
                guard let context, let name else { return nil }
                let view = Unmanaged<VideoSurface>.fromOpaque(context).takeUnretainedValue()
                return dlsym(view.glLibrary, name)
            }, get_proc_address_ctx: Unmanaged.passUnretained(self).toOpaque())
        let result = "opengl".withCString { api in
            withUnsafeMutablePointer(to: &initialization) { initializationPointer in
                var parameters = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initializationPointer),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_create(&renderContext, engine.handle, &parameters)
            }
        }
        guard result >= 0, let renderContext else {
            nativeLog("OpenGL renderer: \(mpvError(result))")
            return
        }
        mpv_render_context_set_update_callback(
            renderContext,
            { context in
                guard let context else { return }
                let view = Unmanaged<VideoSurface>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { [weak view] in
                    guard let view, !view.drawQueued else { return }
                    view.drawQueued = true
                    view.needsDisplay = true
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        nativeLog("OpenGL video surface ready")
        onReady?()
    }
    override func draw(_ dirtyRect: NSRect) {
        openGLContext?.makeCurrentContext()
        drawQueued = false
        guard let renderContext else {
            glClearColor(0.03, 0.03, 0.03, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            openGLContext?.flushBuffer()
            return
        }
        _ = mpv_render_context_update(renderContext)
        let size = convertToBacking(bounds).size
        var framebuffer = mpv_opengl_fbo(fbo: 0, w: Int32(max(1, size.width)), h: Int32(max(1, size.height)), internal_format: 0)
        var flip: Int32 = 1
        var waitForFrameTime: Int32 = (isDirectlyManipulated || inLiveResize) ? 0 : 1
        withUnsafeMutablePointer(to: &framebuffer) { framePointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                withUnsafeMutablePointer(to: &waitForFrameTime) { waitPointer in
                    var parameters = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: framePointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: waitPointer),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    mpv_render_context_render(renderContext, &parameters)
                }
            }
        }
        openGLContext?.flushBuffer()
        mpv_render_context_report_swap(renderContext)
    }
    override func reshape() {
        super.reshape()
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseMoved(with event: NSEvent) { onPointer?() }
    // A single click waits briefly so a double click can claim it. Should the
    // second click arrive after the wait, the first one is taken back.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.control) {
            // Control-click is a secondary click; its mouse-up must not count as a click.
            pressMoved = true
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        pressLocation = NSEvent.mouseLocation
        pressMoved = false
        if event.clickCount >= 2 {
            if pendingClick != nil { cancelPendingClick() } else if clickDelivered { onClick?() }
            clickDelivered = false
            if event.clickCount == 2 { onFullscreen?() }
        } else {
            clickDelivered = false
            onPointer?()
        }
    }
    // The whole picture is a drag handle, as in other borderless players.
    override func mouseDragged(with event: NSEvent) {
        if !pressMoved {
            guard let start = pressLocation else { return }
            let now = NSEvent.mouseLocation
            guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
            pressMoved = true
            cancelPendingClick()
        }
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.performDrag(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        pressLocation = nil
        guard !pressMoved, event.clickCount == 1 else { return }
        cancelPendingClick()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClick = nil
            self.clickDelivered = true
            self.onClick?()
        }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(NSEvent.doubleClickInterval, 0.25), execute: work)
    }
    func cancelPendingClick() {
        pendingClick?.cancel()
        pendingClick = nil
        clickDelivered = false
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        cancelPendingClick()
        return onContextMenu?()
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        // Keys the controller does not know may still belong to a menu item.
        // Anything else typed over the picture is ignored quietly; only an
        // unknown shortcut gets the system's usual response.
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { super.keyDown(with: event) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        else { return false }
        onOpen?(urls)
        return true
    }
    func tearDown() {
        guard let renderContext else { return }
        openGLContext?.makeCurrentContext()
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
    }
}

final class BrandMark: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let square = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: square, xRadius: square.width * 0.24, yRadius: square.height * 0.24)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.62, green: 0.45, blue: 0.99, alpha: 1),
            NSColor(calibratedRed: 0.30, green: 0.31, blue: 0.75, alpha: 1),
        ])?.draw(in: path, angle: -60)
        let w = square.width
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: w * 0.40, y: w * 0.28))
        triangle.line(to: NSPoint(x: w * 0.40, y: w * 0.72))
        triangle.line(to: NSPoint(x: w * 0.75, y: w * 0.50))
        triangle.close()
        NSColor.white.withAlphaComponent(0.95).setFill()
        triangle.fill()
    }
}
final class PrimaryButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let color = isHighlighted ? accent.withAlphaComponent(0.78) : accent
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
class GestureSafeSlider: NSSlider {
    override class var cellClass: AnyClass? {
        get { SleekSliderCell.self }
        set {}
    }
    // A two-finger swipe over the controls must not also change playback.
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
}
final class GestureSafeEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue > 0.05 && !isHidden ? super.hitTest(point) : nil }
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
}
final class PassiveEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class SeekSlider: GestureSafeSlider {
    var scrubbing = false
    /// The pointer's place on the bar as a fraction, with its x in the slider's coordinates; nil when it leaves.
    var onHover: ((Double?, CGFloat) -> Void)?
    /// The mouse button went up after a drag or click on the bar.
    var onScrubEnd: (() -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    /// Where the knob's centre sits for the ends of the bar.
    private var travel: (start: CGFloat, length: CGFloat) {
        guard let cell = cell as? NSSliderCell else { return (0, max(1, bounds.width)) }
        let bar = cell.barRect(flipped: isFlipped), knob = cell.knobRect(flipped: isFlipped).width
        let start = bar.minX + knob / 2, length = max(1, bar.width - knob)
        // Trust where the knob really is over the arithmetic, should the two differ.
        let actual = cell.knobRect(flipped: isFlipped).midX
        let shift = actual - (start + CGFloat((doubleValue - minValue) / (maxValue - minValue)) * length)
        return (start + shift, length)
    }
    func fraction(atX x: CGFloat) -> Double {
        let line = travel
        return min(1, max(0, Double((x - line.start) / line.length)))
    }
    func x(forFraction fraction: Double) -> CGFloat {
        let line = travel
        return line.start + CGFloat(fraction) * line.length
    }
    override func mouseMoved(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        onHover?(fraction(atX: x), x)
    }
    override func mouseExited(with event: NSEvent) { onHover?(nil, 0) }
    override func mouseDown(with event: NSEvent) {
        scrubbing = true
        super.mouseDown(with: event)
        scrubbing = false
        onScrubEnd?()
    }
}

final class PlayerController: NSObject, NSWindowDelegate {
    let engine: PlaybackEngine
    let window: NSWindow
    let video: TrackpadVideoSurface
    let welcome = WelcomeView()
    let hud = GestureSafeEffectView()
    let progress = SeekSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let positionLabel = NSTextField(labelWithString: "0:00")
    let durationLabel = ClickableLabel(labelWithString: "0:00")
    let statusLabel = NSTextField(labelWithString: "")
    let statusBadge = SubtitleBadge()
    var statusBadgeEligible = true
    var statusBadgeTimer: Timer?
    var badgeKey: String?
    var dismissedBadgeKeys = Set<String>()
    /// The companion's state decoded (SubtitleModel.swift); nil until it has published one.
    var subtitleState: SubtitleState?
    /// A state has arrived since the current file loaded (until then the state may describe the previous file).
    var subtitleStateFresh = false
    var freshTimer: Timer?
    /// `subtitleFileWillChange` ran for the file now loading (a load from outside the app skips it).
    var subtitleChangeAnnounced = false
    var pendingExpiryTimer: Timer?
    var badgeFadingOut = false
    var badgeFadeID = 0
    /// Settings just sent and not yet confirmed by a state.
    var subtitlePending: [String: (value: String, at: TimeInterval)] = [:]
    var subtitleNotices: [SubtitleNotice] = []
    var captionButton: NSButton!
    var subtitlePopover: NSPopover?
    var settingsController: SettingsWindowController?
    let aheadIndicator = AheadIndicator()
    var aheadBottomConstraint: NSLayoutConstraint?
    var aheadTimer: Timer?
    var aheadShown = false
    var subtitleBottomTween: Timer?
    var subtitleBottomValue: Double?
    let resumeCard = NoticeCard(primary: "Start Over", secondary: "Dismiss")
    var resumeCardTimer: Timer?
    var resumeIgnored: Double?
    var resumeAnnouncedEntry: Int64?
    let titleStrip = TitleStrip()
    let scrubBubble = ScrubBubble()
    var previousButton: NSButton!
    var nextButton: NSButton!
    /// The videos behind Next and Previous, and the place of the one playing (PlayerQueue.swift).
    var queue: [URL] = []
    var queueIndex = 0
    /// Symbol for the pill shown once the next queued video has loaded.
    var queueAnnouncement: String?
    /// Which way the last Next or Previous went, so a file that cannot be played is skipped on in that direction.
    var queueDirection = 1
    let upNextCard = NoticeCard(primary: "Play Now", secondary: "Cancel")
    let updateCard = NoticeCard(primary: "View Release", secondary: "Dismiss")
    var upNextTimer: Timer?
    var upNextRemaining = 0
    var updateCardTimer: Timer?
    var updateCardRelease: UpdateChecker.Release?
    var showsRemainingTime = UserDefaults.standard.bool(forKey: "ShowRemainingTime")
    var shortcutsWindow: NSWindow?
    lazy var nowPlaying = NowPlayingBridge(player: self)
    var playButton: NSButton!
    var volumeSlider: NSSlider!
    var hideTimer: Timer?
    var controlsVisible = false
    var controlsGeneration = 0
    var companion: Process?
    var companionRetries = 0
    var quitting = false
    var isPaused = false
    var pendingURL: URL?
    var rendererReady = false
    var currentURL: URL?
    var duration = 0.0
    var lastSubtitleBottom: Int?
    var subtitleMarginTimer: Timer?
    var lastSubtitlePublish = 0.0
    var compactControls: [NSView] = []
    var hudHeightConstraint: NSLayoutConstraint?
    var hudBottomConstraint: NSLayoutConstraint?
    let gestureFeedback = PassiveEffectView()
    let gestureFeedbackText = NSTextField(labelWithString: "")
    let gestureFeedbackIcon = NSImageView()
    var gestureFeedbackTimer: Timer?
    var feedbackGeneration = 0
    var playbackPosition = 0.0
    var playbackVolume = 100.0
    var playbackMuted = false
    var scrollSession: (axis: TrackpadScrollAxis, base: Double, wasPaused: Bool, wasMuted: Bool, gain: Double)?
    var pinch = PinchZoomReducer()
    var pinchWindowFrame: NSRect?
    var windowZoomAspect: CGFloat?
    var applyingZoomFrame = false
    var pinchFullscreen = false
    var pinchAtLimit = false
    var videoAspect: Double?
    var videoRotation = 0.0
    var hudRestingBottom: CGFloat = -22
    var hudHiddenOffset: CGFloat { reducedMotion ? 0 : 12 }
    var fullscreenVideoScale = 1.0
    var fullscreenTransition = false
    var lastVolumeBoundary: Int?
    let referenceWindowSize = NSSize(width: 960, height: 600)
    var speakerButton: NSButton!
    var speedButton: NSButton!
    var playbackSpeed = 1.0
    /// Playback has reached the end and is resting on the last frame.
    var atEnd = false
    var sleepActivity: NSObjectProtocol?
    /// The file handed to the core that has not reported back yet.
    var pendingLoad: (token: Int, url: URL, entry: Int64?)?
    var loadToken = 0
    var currentEntry: Int64?
    var lastObservedPath: String?
    var adoptNextPath = false
    var keySeek: (target: Double, time: TimeInterval)?
    var floatOnTop = false
    let recentMenu = NSMenu(title: "Open Recent")
    var companionStartedAt: TimeInterval?
    var companionLaunches = 0
    var companionRestartWork: DispatchWorkItem?
    var companionRestartRequested = false
    /// True once automatic restarts are exhausted or the companion cannot be launched.
    var companionGaveUp = false
    /// The companion's latest `user-data/vidac-state` object (docs/COMPANION_PROTOCOL.md).
    var companionState: [String: Any] = [:]
    let runtimeDirectory: URL
    /// A video is loaded and on screen (not the welcome page, not a file still opening).
    var hasVideo: Bool { currentURL != nil && welcome.superview == nil }

    init(runtimeDirectory: URL) throws {
        self.runtimeDirectory = runtimeDirectory
        let socket = ProcessInfo.processInfo.environment["VIDAC_NATIVE_SOCKET"] ?? "/tmp/vidac-native-\(getuid()).sock"
        let savedVolume = (UserDefaults.standard.object(forKey: "Volume") as? Double) ?? 100
        engine = try PlaybackEngine(socketPath: socket, volume: savedVolume.isFinite ? savedVolume : 100)
        video = TrackpadVideoSurface(engine: engine)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Vidac"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = background
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        content.wantsLayer = true
        content.layer?.backgroundColor = background.cgColor
        window.contentView = content
        for view in [video, welcome] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor), view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        configureHUD(in: content)
        configureStatus(in: content)
        configureGestureFeedback(in: content)
        configureTrackpad()
        configureOverlays(in: content)
        welcome.onChoose = { [weak self] in self?.chooseFile() }
        welcome.onOpen = { [weak self] in self?.open($0) }
        welcome.onRemove = { [weak self] in self?.removeRecent($0) }
        welcome.onClear = { [weak self] in self?.clearRecents() }
        welcome.refresh(recentURLs())
        video.onOpen = { [weak self] in self?.open($0) }
        video.onPointer = { [weak self] in self?.showControls() }
        video.onFullscreen = { [weak self] in self?.toggleFullscreen() }
        video.onClick = { [weak self] in self?.togglePause() }
        video.onKey = { [weak self] in self?.handleKey($0) ?? false }
        video.onContextMenu = { [weak self] in self?.makeContextMenu() }
        video.onReady = { [weak self] in
            guard let self else { return }
            self.rendererReady = true
            self.publishSubtitleMargin()
            self.startCompanion()
            if let pending = self.pendingURL {
                self.pendingURL = nil
                self.load(pending)
            }
        }
        engine.onValue = { [weak self] name, value in self?.receive(name, value) }
        engine.onEvent = { [weak self] in self?.handle($0) }
        recentMenu.delegate = self
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.setContentSize(NSSize(width: 960, height: 600))
        restoreWindowPosition()
        playbackVolume = min(100, max(0, savedVolume.isFinite ? savedVolume : 100))
        volumeSlider.doubleValue = playbackVolume
        updateSpeakerIcon()
        nowPlaying.setUp()
        floatOnTop = UserDefaults.standard.bool(forKey: "FloatOnTop")
        window.level = floatOnTop ? .floating : .normal
        NotificationCenter.default.addObserver(
            self, selector: #selector(auxiliaryWindowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        nativeLog("Window frame=\(window.frame) content=\(content.bounds) screen=\(String(describing: window.screen?.visibleFrame))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            nativeLog("Window settled frame=\(self.window.frame) content=\(self.window.contentView?.bounds ?? .zero)")
        }
        // An NSOpenGLView fully covered by the welcome page may not draw yet.
        // Initialize its context explicitly on this main thread before opening.
        video.prepareOpenGL()
    }
    func symbolButton(_ symbol: String, label: String, selector: Selector) -> NSButton {
        let button = PlaybackButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: selector)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white.withAlphaComponent(0.92)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }
    func configureHUD(in content: NSView) {
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 20
        hud.layer?.cornerCurve = .continuous
        hud.layer?.borderWidth = 0.5
        hud.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        hud.layer?.masksToBounds = true
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.isHidden = true
        hud.alphaValue = 0
        content.addSubview(hud)
        progress.target = self
        progress.action = #selector(seek(_:))
        progress.isContinuous = true
        progress.controlSize = .small
        progress.setAccessibilityLabel("Playback position")
        progress.onHover = { [weak self] fraction, x in self?.hoverSeekBar(fraction, x: x) }
        progress.onScrubEnd = { [weak self] in self?.commitScrub() }
        playButton = symbolButton("play.fill", label: "Play", selector: #selector(togglePause))
        playButton.imageScaling = .scaleProportionallyUpOrDown
        playButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 23, weight: .semibold)
        let back = symbolButton("gobackward.10", label: "Back 10 Seconds", selector: #selector(backward))
        let forward = symbolButton("goforward.10", label: "Forward 10 Seconds", selector: #selector(forward))
        // Shown only when the queue has something to go to (updateQueueButtons).
        previousButton = symbolButton("backward.end.fill", label: "Previous Video", selector: #selector(playPrevious))
        nextButton = symbolButton("forward.end.fill", label: "Next Video", selector: #selector(playNext))
        previousButton.isHidden = true
        nextButton.isHidden = true
        let caption = symbolButton("captions.bubble", label: "Subtitles", selector: #selector(toggleSubtitlePopover(_:)))
        captionButton = caption
        let full = symbolButton("arrow.up.left.and.arrow.down.right", label: "Full Screen", selector: #selector(toggleFullscreen))
        let speaker = symbolButton("speaker.wave.2.fill", label: "Mute", selector: #selector(toggleMute))
        speakerButton = speaker
        // Shown only while the speed is not 1×, so the bar stays quiet normally.
        speedButton = PlaybackButton(title: "", target: self, action: #selector(showSpeedMenu(_:)))
        speedButton.isBordered = false
        speedButton.toolTip = "Playback Speed"
        speedButton.isHidden = true
        speedButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        speedButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        volumeSlider = GestureSafeSlider(value: 100, minValue: 0, maxValue: 100, target: self, action: #selector(volume(_:)))
        volumeSlider.isContinuous = true
        volumeSlider.controlSize = .small
        volumeSlider.setAccessibilityLabel("Volume")
        volumeSlider.widthAnchor.constraint(equalToConstant: 88).isActive = true
        for label in [positionLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        durationLabel.onClick = { [weak self] in self?.toggleRemainingTime() }
        durationLabel.setAccessibilityRole(.button)
        durationLabel.setAccessibilityLabel("Duration")
        updateDurationLabel(position: 0)
        let spacer1 = NSView()
        let spacer2 = NSView()
        let controls = NSStackView(views: [
            positionLabel, statusLabel, spacer1, previousButton, back, playButton, forward, nextButton, spacer2, speaker, volumeSlider,
            speedButton, caption, full, durationLabel,
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.detachesHiddenViews = true
        compactControls = [statusLabel, back, forward, speaker, volumeSlider, durationLabel]
        spacer1.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        spacer2.widthAnchor.constraint(equalTo: spacer1.widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        let stack = NSStackView(views: [progress, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        hud.addSubview(stack)
        stack.detachesHiddenViews = true
        let preferredHUDWidth = hud.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -72)
        // This preference must stay below window fitting priority. Otherwise
        // the 880 pt HUD cap pulls the window back to 952 pt while its height
        // keeps changing, distorting every programmatic pinch resize.
        preferredHUDWidth.priority = NSLayoutConstraint.Priority(rawValue: 49)
        preferredHUDWidth.isActive = true
        let bottom = hud.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        let height = hud.heightAnchor.constraint(equalToConstant: 88)
        hudBottomConstraint = bottom
        hudHeightConstraint = height
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: content.centerXAnchor), bottom,
            hud.widthAnchor.constraint(lessThanOrEqualToConstant: 880),
            hud.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 22),
            hud.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -22), height,
            stack.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: hud.topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -12),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor), controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    func receive(_ name: String, _ value: Any) {
        switch name {
        case "time-pos":
            if let position = value as? Double {
                playbackPosition = position
                if scrollSession?.axis != .horizontal, !progress.scrubbing {
                    progress.doubleValue = duration > 0 ? position / duration : 0
                    positionLabel.stringValue = timestamp(position)
                    updateDurationLabel(position: position)
                }
                nowPlaying.positionChanged()
            }
        case "duration":
            if let seconds = value as? Double {
                duration = seconds
                updateDurationLabel(position: playbackPosition)
                nowPlaying.refresh()
            }
        case "pause":
            if let paused = value as? Bool {
                isPaused = paused
                updatePlayButton()
                updateSleepAssertion()
                nowPlaying.refresh()
                showControls()
            }
        case "eof-reached":
            if let ended = value as? Bool {
                atEnd = ended
                updatePlayButton()
                updateSleepAssertion()
                nowPlaying.refresh()
                if ended {
                    showControls()
                    beginUpNext()
                } else {
                    cancelUpNext()
                }
            }
        case "volume":
            if let volume = value as? Double {
                playbackVolume = volume
                volumeSlider.doubleValue = volume
                UserDefaults.standard.set(volume, forKey: "Volume")
                updateSpeakerIcon()
            }
        case "mute":
            if let muted = value as? Bool {
                playbackMuted = muted
                updateSpeakerIcon()
            }
        case "speed":
            if let speed = value as? Double {
                playbackSpeed = speed
                updateSpeedIndicator()
                nowPlaying.refresh()
            }
        case "path":
            if let path = value as? String, !path.isEmpty {
                lastObservedPath = path
                if adoptNextPath, pendingLoad == nil, let entry = currentEntry {
                    adoptNextPath = false
                    didLoad(URL(fileURLWithPath: path), entry: entry)
                }
            }
        case "user-data/vidac-state":
            if let text = value as? String,
                var parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            {
                // Tolerate the object arriving wrapped in a JSON string.
                if let inner = parsed as? String, let unwrapped = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) {
                    parsed = unwrapped
                }
                if let state = parsed as? [String: Any] {
                    companionState = state
                    companionStateChanged()
                }
            }
        case "video-out-params/aspect":
            if let aspect = value as? Double {
                videoAspect = aspect
                fitWindowToVideo()
            }
        case "video-out-params/rotate":
            if let degrees = value as? Double {
                videoRotation = degrees
                fitWindowToVideo()
            }
        default: break
        }
    }
    func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
    /// The welcome page leaves as a fading still, so the first frame appears
    /// through it instead of replacing it in a single refresh.
    func dissolveWelcome() {
        guard !reducedMotion, let content = window.contentView, welcome.bounds.width > 0,
            let still = welcome.bitmapImageRepForCachingDisplay(in: welcome.bounds)
        else { return }
        welcome.cacheDisplay(in: welcome.bounds, to: still)
        let image = NSImage(size: welcome.bounds.size)
        image.addRepresentation(still)
        let veil = PassiveImageView(frame: content.bounds)
        veil.image = image
        veil.imageScaling = .scaleAxesIndependently
        veil.autoresizingMask = [.width, .height]
        content.addSubview(veil, positioned: .above, relativeTo: video)
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.42
                context.timingFunction = glide
                veil.animator().alphaValue = 0
            }, completionHandler: { veil.removeFromSuperview() })
    }
    func minimumWindowWidth(forAspect ratio: CGFloat) -> CGFloat { ratio >= 1 ? max(480, 300 * ratio) : 320 }
    /// Gives the window the picture's shape, as large as it was before, so no
    /// black bars remain and later pinches scale exactly the picture.
    func fitWindowToVideo() {
        guard var aspect = videoAspect, aspect.isFinite, aspect > 0.2, aspect < 6,
            currentURL != nil, welcome.superview == nil
        else { return }
        if Int(videoRotation.rounded()) % 180 != 0 { aspect = 1 / aspect }
        guard !window.styleMask.contains(.fullScreen), !fullscreenTransition else { return }
        video.cancelTrackpadGestures()
        let ratio = CGFloat(aspect), minimumWidth = minimumWindowWidth(forAspect: ratio)
        let minimum = NSSize(width: minimumWidth, height: minimumWidth / ratio)
        window.minSize = minimum
        window.contentMinSize = minimum
        window.contentAspectRatio = NSSize(width: ratio, height: 1)
        windowZoomAspect = ratio
        let origin = window.frame
        let available = (window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? origin).insetBy(dx: 8, dy: 8)
        // The picture keeps the area the user last gave it, whatever its shape.
        let area = savedPictureArea ?? origin.width * origin.height
        let width = min(available.width, available.height * ratio, max(minimumWidth, (area * ratio).squareRoot()))
        let size = NSSize(width: width, height: width / ratio)
        let frame = alignedToPixels(
            NSRect(
                x: min(available.maxX - size.width, max(available.minX, origin.midX - size.width / 2)),
                y: min(available.maxY - size.height, max(available.minY, origin.midY - size.height / 2)),
                width: size.width, height: size.height))
        nativeLog(String(format: "Window fits picture aspect=%.4f frame=%.0fx%.0f", aspect, frame.width, frame.height))
        commitWindowZoom(frame, animated: true)
    }
    func showWelcome() {
        video.cancelTrackpadGestures()
        if let content = window.contentView, welcome.superview == nil {
            welcome.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(welcome, positioned: .above, relativeTo: video)
            NSLayoutConstraint.activate([
                welcome.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                welcome.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                welcome.topAnchor.constraint(equalTo: content.topAnchor), welcome.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        videoAspect = nil
        windowZoomAspect = nil
        window.resizeIncrements = NSSize(width: 1, height: 1)  // releases the picture's aspect lock
        window.minSize = NSSize(width: 760, height: 480)
        window.contentMinSize = NSSize(width: 760, height: 480)
        if !window.styleMask.contains(.fullScreen),
            window.frame.width < 760 || window.frame.height < 480 || abs(window.frame.width / window.frame.height - 1.6) > 0.4
        {
            let available = (window.screen?.visibleFrame ?? window.frame).insetBy(dx: 8, dy: 8)
            let size = NSSize(
                width: min(referenceWindowSize.width, available.width), height: min(referenceWindowSize.height, available.height))
            commitWindowZoom(
                alignedToPixels(
                    NSRect(
                        x: min(available.maxX - size.width, max(available.minX, window.frame.midX - size.width / 2)),
                        y: min(available.maxY - size.height, max(available.minY, window.frame.midY - size.height / 2)),
                        width: size.width, height: size.height)))
        }
        welcome.refresh(recentURLs())
        welcome.isHidden = false
        hideTimer?.invalidate()
        hideTimer = nil
        controlsVisible = false
        controlsGeneration += 1
        hud.isHidden = true
        hud.alphaValue = 0
        titleStrip.alphaValue = 0
        scrubBubble.hide()
        statusBadge.isHidden = true
        gestureFeedback.isHidden = true
        setWindowButtons(alpha: 1)
        window.title = "Vidac"
        window.representedURL = nil
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func recentURLs() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: "RecentVideoPaths") ?? []).map { URL(fileURLWithPath: $0) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
    var scrollSensitivity: Double {
        let value = (UserDefaults.standard.object(forKey: "TrackpadSensitivity") as? Double) ?? 1
        return value.isFinite ? min(2, max(0.5, value)) : 1
    }
    func configureTrackpad() {
        video.allowsTrackpadGestures = { [weak self] in
            guard let self else { return false }
            let enabled = (UserDefaults.standard.object(forKey: "TrackpadGesturesEnabled") as? Bool) ?? true
            return enabled && self.currentURL != nil && self.welcome.superview == nil && self.window.isKeyWindow
                && !self.fullscreenTransition && self.window.attachedSheet == nil
                && self.settingsController?.isVisible != true && !self.quitting
        }
        video.onScrollUpdate = { [weak self] in self?.applyScroll($0) }
        video.onPinchBegan = { [weak self] in self?.beginPinch() }
        video.onPinchDelta = { [weak self] delta in
            guard let self, let scale = self.pinch.consume(magnification: delta) else { return }
            self.applyPinchScale(scale)
        }
        video.onPinchEnded = { [weak self] cancelled in
            guard let self else { return }
            if let scale = self.pinch.end(cancelled: cancelled) {
                if cancelled, let origin = self.pinchWindowFrame { self.commitWindowZoom(origin) } else { self.applyPinchScale(scale) }
            }
            self.video.isDirectlyManipulated = false
            self.pinchAtLimit = false
            self.publishSubtitleMargin(immediate: true)
            if let origin = self.pinchWindowFrame {
                self.logWindowZoom(origin: origin)
                if !cancelled { self.rememberWindowGeometry() }
            }
            self.pinchWindowFrame = nil
        }
        video.onSmartZoom = { [weak self] in self?.resetZoom() }
        video.onGestureSummary = { nativeLog("Trackpad " + $0) }
    }
    var scrollLastTotal = 0.0
    func applyScroll(_ update: TrackpadScrollUpdate) {
        if update.isFirst {
            if update.isFinal && abs(update.total) < 0.000_001 { return }
            let previousPause = scrollSession?.wasPaused ?? isPaused
            if scrollSession != nil { finishScroll(cancelled: false) }
            let gain = scrollSensitivity
            if update.axis == .horizontal {
                guard duration.isFinite, duration > 0 else { return }
                let base = min(duration, max(0, playbackPosition))
                scrollSession = (.horizontal, base, previousPause, playbackMuted, gain)
                video.constrainScrollTotal(minimum: max(-60 / gain, -base / gain), maximum: min(60 / gain, (duration - base) / gain))
                engine.command(["set", "pause", "yes"])
            } else {
                let base = min(100, max(0, playbackVolume))
                scrollSession = (.vertical, base, isPaused, playbackMuted, gain)
                video.constrainScrollTotal(minimum: -base / gain, maximum: (100 - base) / gain)
            }
            scrollLastTotal = 0
            keySeek = nil
        }
        guard let session = scrollSession, session.axis == update.axis else { return }
        let total = session.axis == .horizontal ? min(60 / session.gain, max(-60 / session.gain, update.total)) : update.total
        scrollLastTotal = total
        if update.isFinal {
            finishScroll(cancelled: update.cancelled)
            return
        }
        if session.axis == .horizontal {
            let target = min(duration, max(0, session.base + total * session.gain))
            // Lightweight previews while fingers move; one exact seek on release.
            engine.command(["seek", String(target), "absolute+keyframes"])
            drawSeekPreview(target, origin: session.base)
        } else {
            applyGestureVolume(session.base + total * session.gain)
        }
    }
    func finishScroll(cancelled: Bool) {
        guard let session = scrollSession else { return }
        scrollSession = nil
        if session.axis == .horizontal {
            let target = min(duration, max(0, session.base + (cancelled ? 0 : scrollLastTotal * session.gain)))
            engine.command(["seek", String(target), "absolute+exact"])
            engine.command(["set", "pause", session.wasPaused ? "yes" : "no"])
            playbackPosition = target
            drawSeekPreview(target, origin: session.base)
        } else if cancelled {
            playbackVolume = session.base
            volumeSlider.doubleValue = session.base
            playbackMuted = session.wasMuted
            engine.command(["set", "volume", String(session.base)])
            engine.command(["set", "mute", session.wasMuted ? "yes" : "no"])
            updateSpeakerIcon()
            showGestureFeedback(
                session.wasMuted ? "Muted" : "Volume \(Int(session.base.rounded()))%",
                symbol: volumeSymbol(session.base, muted: session.wasMuted))
        } else {
            applyGestureVolume(session.base + scrollLastTotal * session.gain)
        }
        scrollLastTotal = 0
        showControls()
    }
    func drawSeekPreview(_ target: Double, origin: Double) {
        progress.doubleValue = duration > 0 ? target / duration : 0
        positionLabel.stringValue = timestamp(target)
        let change = target - origin
        let prefix = change < 0 ? "−" : "+"
        showGestureFeedback(
            "\(prefix)\(String(format: "%.1f", abs(change))) s  ·  \(timestamp(target)) / \(timestamp(duration))",
            symbol: change < 0 ? "gobackward" : "goforward")
        showControls()
    }
    func applyGestureVolume(_ proposed: Double) {
        let value = min(100, max(0, proposed))
        playbackVolume = value
        volumeSlider.doubleValue = value
        engine.command(["set", "volume", String(value)])
        if playbackMuted && value > 0 {
            engine.command(["set", "mute", "no"])
            playbackMuted = false
        }
        let boundary = value <= 0 ? 0 : (value >= 100 ? 100 : nil)
        if let boundary, boundary != lastVolumeBoundary {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastVolumeBoundary = boundary
        updateSpeakerIcon()
        showGestureFeedback("Volume \(Int(value.rounded()))%", symbol: volumeSymbol(value, muted: false))
    }
    func beginPinch() {
        if scrollSession != nil { finishScroll(cancelled: true) }
        pinchAtLimit = false
        pinchFullscreen = window.styleMask.contains(.fullScreen)
        if pinchFullscreen {
            pinchWindowFrame = nil
            pinch.begin(scale: fullscreenVideoScale, min: 0.5, max: 3)
        } else {
            let origin = window.frame
            if windowZoomAspect == nil { windowZoomAspect = origin.width / max(1, origin.height) }
            let base = NSSize(width: origin.width, height: origin.width / (windowZoomAspect ?? 1.6))
            let available = (window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? origin).insetBy(dx: 8, dy: 8)
            let maximum = max(0.1, min(3, available.width / base.width, available.height / base.height))
            let minimum = min(maximum, minimumWindowWidth(forAspect: windowZoomAspect ?? 1.6) / base.width)
            pinchWindowFrame = origin
            pinch.begin(scale: 1, min: minimum, max: maximum)
        }
        video.isDirectlyManipulated = true
    }
    /// One light tap when the fingers reach the smallest or largest size, so
    /// the stop feels like an edge rather than an unresponsive gesture.
    func notePinchLimit(_ scale: Double) {
        let atLimit = scale <= pinch.minimumScale + 0.000_5 || scale >= pinch.maximumScale - 0.000_5
        if atLimit && !pinchAtLimit && video.isDirectlyManipulated {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        pinchAtLimit = atLimit
    }
    func alignedToPixels(_ rect: NSRect) -> NSRect {
        let scale = max(1, window.backingScaleFactor)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return NSRect(x: snap(rect.minX), y: snap(rect.minY), width: snap(rect.width), height: snap(rect.height))
    }
    func applyPinchScale(_ scale: Double) {
        if pinchFullscreen {
            fullscreenVideoScale = min(3, max(0.5, scale))
            // The player applies the newest value at its next rendered frame;
            // holding it back for a display-link tick only added latency.
            engine.command(["set", "video-zoom", String(log2(fullscreenVideoScale))])
            showGestureFeedback("Zoom \(Int((fullscreenVideoScale * 100).rounded()))%", symbol: "viewfinder")
            notePinchLimit(fullscreenVideoScale)
        } else if let origin = pinchWindowFrame {
            let frame = zoomedFrame(from: origin, scale: scale)
            // AppKit already delivers one magnify event per display refresh.
            // Moving the window inside that same event keeps it under the
            // fingers; deferring to a display link trailed by a whole frame.
            commitWindowZoom(frame)
            notePinchLimit(scale)
        }
    }
    /// Scales about the window's centre, keeps the picture's aspect and stays
    /// inside the visible screen.
    func zoomedFrame(from origin: NSRect, scale: Double) -> NSRect {
        let available = (window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? origin).insetBy(dx: 8, dy: 8)
        let ratio = windowZoomAspect ?? origin.width / max(1, origin.height)
        let width = min(available.width, available.height * ratio, max(minimumWindowWidth(forAspect: ratio), origin.width * scale))
        let size = NSSize(width: width, height: width / ratio)
        return alignedToPixels(
            NSRect(
                x: min(available.maxX - size.width, max(available.minX, origin.midX - size.width / 2)),
                y: min(available.maxY - size.height, max(available.minY, origin.midY - size.height / 2)),
                width: size.width, height: size.height))
    }
    func commitWindowZoom(_ frame: NSRect, animated: Bool = false) {
        guard frame != window.frame else { return }
        applyingZoomFrame = true
        if animated && !reducedMotion {
            // Discrete steps (menu, ⌘0) glide; finger-driven changes never do.
            updateCompactControls(for: frame.size)
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.22
                    context.timingFunction = glide
                    context.allowsImplicitAnimation = true
                    self.window.animator().setFrame(frame, display: true)
                },
                completionHandler: { [weak self] in
                    self?.applyingZoomFrame = false
                    self?.publishSubtitleMargin(immediate: true)
                })
            return
        }
        // Frame, layout and the picture are committed as one transaction so
        // the video never shows stretched for a refresh while it catches up.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateCompactControls(for: frame.size)
        window.setFrame(frame, display: true)
        CATransaction.commit()
        applyingZoomFrame = false
    }
    func resetFullscreenZoom() {
        fullscreenVideoScale = 1
        engine.command(["set", "video-zoom", "0"])
    }
    @objc func resetZoom() {
        guard currentURL != nil, welcome.superview == nil else { return }
        video.cancelTrackpadGestures()
        resetFullscreenZoom()
        if window.styleMask.contains(.fullScreen) {
            showGestureFeedback("Zoom 100%", symbol: "viewfinder")
        } else {
            let available = (window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame).insetBy(dx: 8, dy: 8)
            let ratio = windowZoomAspect ?? referenceWindowSize.width / referenceWindowSize.height
            let reference = NSSize(width: referenceWindowSize.width, height: referenceWindowSize.width / ratio)
            let factor = min(1, available.width / reference.width, available.height / reference.height)
            let size = NSSize(width: reference.width * factor, height: reference.height * factor)
            windowZoomAspect = ratio
            let frame = NSRect(
                x: min(available.maxX - size.width, max(available.minX, window.frame.midX - size.width / 2)),
                y: min(available.maxY - size.height, max(available.minY, window.frame.midY - size.height / 2)), width: size.width,
                height: size.height)
            commitWindowZoom(alignedToPixels(frame), animated: true)
            rememberWindowGeometry(size: size)
            publishSubtitleMargin(immediate: true)
            showGestureFeedback("Actual Size", symbol: "arrow.counterclockwise")
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    @objc func zoomIn() { stepZoom(1.1) }
    @objc func zoomOut() { stepZoom(1 / 1.1) }
    func stepZoom(_ factor: Double) {
        guard currentURL != nil, welcome.superview == nil, !fullscreenTransition else { return }
        video.cancelTrackpadGestures()
        beginPinch()
        let proposed = min(pinch.maximumScale, max(pinch.minimumScale, pinchFullscreen ? fullscreenVideoScale * factor : factor))
        if pinchFullscreen {
            applyPinchScale(proposed)
        } else if let origin = pinchWindowFrame {
            let frame = zoomedFrame(from: origin, scale: proposed)
            commitWindowZoom(frame, animated: true)
            rememberWindowGeometry(size: frame.size)
        }
        publishSubtitleMargin(immediate: true)
        pinch.reset()
        pinchWindowFrame = nil
        video.isDirectlyManipulated = false
    }
    func logWindowZoom(origin: NSRect) {
        let actual = window.frame
        nativeLog(
            String(
                format: "Window zoom from=%.3fx%.3f actual=%.3fx%.3f ratio-before=%.6f ratio-after=%.6f", origin.width, origin.height,
                actual.width, actual.height, origin.width / origin.height, actual.width / actual.height))
    }
    var compactPresentation: Bool {
        let size = window.contentView?.bounds.size ?? referenceWindowSize
        return size.width < 700 || size.height < 440
    }
    func updateCompactControls(for proposedSize: NSSize? = nil) {
        let compact = proposedSize.map { $0.width < 700 || $0.height < 440 } ?? compactPresentation
        for view in compactControls where view.isHidden != compact { view.isHidden = compact }
        updateQueueButtons(width: proposedSize?.width)
        let height: CGFloat = compact ? 80 : 88
        hudRestingBottom = compact ? -14 : -22
        let bottom = hudRestingBottom + (controlsVisible ? 0 : hudHiddenOffset)
        if hudHeightConstraint?.constant != height { hudHeightConstraint?.constant = height }
        if hudBottomConstraint?.constant != bottom { hudBottomConstraint?.constant = bottom }
        aheadBottomConstraint?.constant = aheadRestingBottom(visible: controlsVisible)
    }
    func configureGestureFeedback(in content: NSView) {
        gestureFeedback.material = .hudWindow
        gestureFeedback.blendingMode = .withinWindow
        gestureFeedback.state = .active
        gestureFeedback.wantsLayer = true
        gestureFeedback.layer?.cornerRadius = 14
        gestureFeedback.layer?.cornerCurve = .continuous
        gestureFeedback.layer?.borderWidth = 0.5
        gestureFeedback.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        gestureFeedback.layer?.masksToBounds = true
        gestureFeedback.translatesAutoresizingMaskIntoConstraints = false
        gestureFeedback.isHidden = true
        gestureFeedbackIcon.contentTintColor = .white
        gestureFeedbackIcon.translatesAutoresizingMaskIntoConstraints = false
        gestureFeedbackText.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        gestureFeedbackText.textColor = .white
        let line = NSStackView(views: [gestureFeedbackIcon, gestureFeedbackText])
        line.spacing = 12
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        gestureFeedback.addSubview(line)
        content.addSubview(gestureFeedback)
        NSLayoutConstraint.activate([
            gestureFeedback.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            gestureFeedback.topAnchor.constraint(equalTo: content.topAnchor, constant: 56),
            gestureFeedback.heightAnchor.constraint(equalToConstant: 58),
            gestureFeedback.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
            line.leadingAnchor.constraint(equalTo: gestureFeedback.leadingAnchor, constant: 20),
            line.trailingAnchor.constraint(equalTo: gestureFeedback.trailingAnchor, constant: -20),
            line.centerYAnchor.constraint(equalTo: gestureFeedback.centerYAnchor),
            gestureFeedbackIcon.widthAnchor.constraint(equalToConstant: 22),
            gestureFeedbackIcon.heightAnchor.constraint(equalToConstant: 22),
        ])
    }
    func showGestureFeedback(_ text: String, symbol: String) {
        feedbackGeneration += 1
        if gestureFeedbackText.stringValue != text { gestureFeedbackText.stringValue = text }
        if gestureFeedbackIcon.identifier?.rawValue != symbol {
            gestureFeedbackIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            gestureFeedbackIcon.identifier = NSUserInterfaceItemIdentifier(symbol)
        }
        let entering = gestureFeedback.isHidden
        gestureFeedback.isHidden = false
        if entering && !reducedMotion {
            gestureFeedback.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = glide
                self.gestureFeedback.animator().alphaValue = 1
            }
        } else {
            gestureFeedback.alphaValue = 1
        }
        statusBadge.isHidden = true
        if let timer = gestureFeedbackTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: 0.85)
        } else {
            let timer = Timer(timeInterval: 0.85, repeats: false) { [weak self] _ in self?.hideGestureFeedback() }
            gestureFeedbackTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func hideGestureFeedback() {
        let generation = feedbackGeneration
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = reducedMotion ? 0 : 0.3
                context.timingFunction = glide
                self.gestureFeedback.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard let self, generation == self.feedbackGeneration else { return }
                self.gestureFeedback.isHidden = true
                self.updateStatusBadgeVisibility()
            })
    }
    func showControls() {
        guard currentURL != nil, welcome.superview == nil else { return }
        setControlsVisible(true)
        // At the end of a video the Replay button stays in reach.
        if atEnd {
            hideTimer?.invalidate()
            hideTimer = nil
            return
        }
        // A paused picture is usually being studied: the controls leave later, but they do leave.
        let delay: TimeInterval = isPaused ? 6 : 3
        if let timer = hideTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: delay)
        } else {
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                // A one-shot timer is still valid inside its own block; drop it so showControls arms a new one.
                self.hideTimer = nil
                if self.progress.scrubbing || self.pointerRestsOnControls || self.window.attachedSheet != nil
                    || self.subtitlePopover?.isShown == true
                {
                    self.showControls()
                } else {
                    self.setControlsVisible(false)
                }
            }
            hideTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func setControlsVisible(_ visible: Bool) {
        guard visible != controlsVisible else { return }
        controlsVisible = visible
        controlsGeneration += 1
        let generation = controlsGeneration
        if visible, hud.isHidden {
            hud.isHidden = false
            hudBottomConstraint?.constant = hudRestingBottom + hudHiddenOffset
            window.contentView?.layoutSubtreeIfNeeded()
        }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = reducedMotion ? 0 : (visible ? 0.3 : 0.45)
                context.timingFunction = glide
                context.allowsImplicitAnimation = true
                self.hud.animator().alphaValue = visible ? 1 : 0
                self.titleStrip.animator().alphaValue = visible ? 1 : 0
                self.hudBottomConstraint?.animator().constant = self.hudRestingBottom + (visible ? 0 : self.hudHiddenOffset)
                self.aheadBottomConstraint?.animator().constant = self.aheadRestingBottom(visible: visible)
                self.setWindowButtons(alpha: visible ? 1 : 0, animated: true)
            },
            completionHandler: { [weak self] in
                guard let self, generation == self.controlsGeneration else { return }
                self.hud.isHidden = !visible
            })
        glideSubtitleMargin()
        if !visible { scrubBubble.hide() }
        if !visible, window.isKeyWindow, !isPaused, !atEnd {
            let pointer = video.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if video.bounds.contains(pointer) { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }
    /// The traffic lights belong to the controls: they fade with them while a
    /// video plays and are always present on the welcome page.
    func setWindowButtons(alpha: CGFloat, animated: Bool = false) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            if animated { button.animator().alphaValue = alpha } else { button.alphaValue = alpha }
        }
    }
    @objc func togglePause() {
        guard hasVideo else { return }
        video.cancelTrackpadGestures()
        if atEnd {
            engine.command(["seek", "0", "absolute"])
            engine.command(["set", "pause", "no"])
        } else {
            engine.command(["cycle", "pause"])
        }
        showControls()
    }
    @objc func backward() { seekBy(-10) }
    @objc func forward() { seekBy(10) }
    /// While the knob is held the picture follows on keyframes, which is cheap
    /// on long-GOP files; `commitScrub` makes the one exact seek on release.
    @objc func seek(_ sender: NSSlider) {
        guard duration > 0 else { return }
        video.cancelTrackpadGestures()
        keySeek = nil
        let target = sender.doubleValue * duration
        if progress.scrubbing {
            positionLabel.stringValue = timestamp(target)
            updateDurationLabel(position: target)
            showScrubBubble(fraction: sender.doubleValue)
            engine.command(["seek", String(target), "absolute+keyframes"])
        } else {
            engine.command(["seek", String(target), "absolute+exact"])
        }
    }
    @objc func volume(_ sender: NSSlider) {
        video.cancelTrackpadGestures()
        engine.command(["set", "volume", String(sender.doubleValue)])
    }
    @objc func toggleFullscreen() { window.toggleFullScreen(nil) }
    /// Closing a video returns to the welcome page; closing that quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasVideo else { return true }
        closeVideo()
        return false
    }
    /// Closing a video only returns to the welcome page. Closing the welcome
    /// page quits: Vidac has one window and nothing to do without it, and a
    /// lingering process would keep the subtitle companion alive for nothing.
    func windowWillClose(_ notification: Notification) {
        video.cancelTrackpadGestures()
        NSApp.terminate(nil)
    }
    func windowDidResize(_ notification: Notification) {
        publishSubtitleMargin()
        updateCompactControls()
    }
    func windowWillStartLiveResize(_ notification: Notification) {
        video.cancelTrackpadGestures()
        windowZoomAspect = nil
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if !applyingZoomFrame { windowZoomAspect = window.frame.width / max(1, window.frame.height) }
        publishSubtitleMargin(immediate: true)
        rememberWindowGeometry()
    }
    func windowDidMove(_ notification: Notification) { rememberWindowPosition() }
    func windowWillEnterFullScreen(_ notification: Notification) {
        video.cancelTrackpadGestures()
        fullscreenTransition = true
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        video.cancelTrackpadGestures()
        fullscreenTransition = true
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        fullscreenTransition = false
        resetFullscreenZoom()
        publishSubtitleMargin()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenTransition = false
        resetFullscreenZoom()
        publishSubtitleMargin()
        fitWindowToVideo()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullscreenTransition = false
        resetFullscreenZoom()
        publishSubtitleMargin()
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullscreenTransition = false
        resetFullscreenZoom()
        publishSubtitleMargin()
    }
    func windowDidResignKey(_ notification: Notification) {
        video.cancelTrackpadGestures()
        if currentURL != nil, welcome.superview == nil { setWindowButtons(alpha: 1, animated: true) }
    }
    func windowWillMiniaturize(_ notification: Notification) { video.cancelTrackpadGestures() }
    func shutdown() {
        quitting = true
        video.cancelTrackpadGestures()
        video.cancelPendingClick()
        companionRestartWork?.cancel()
        updateSleepAssertion()
        nowPlaying.clear()
        NotificationCenter.default.removeObserver(self)
        hideTimer?.invalidate()
        upNextTimer?.invalidate()
        updateCardTimer?.invalidate()
        gestureFeedbackTimer?.invalidate()
        subtitleMarginTimer?.invalidate()
        statusBadgeTimer?.invalidate()
        freshTimer?.invalidate()
        pendingExpiryTimer?.invalidate()
        aheadTimer?.invalidate()
        subtitleBottomTween?.invalidate()
        resumeCardTimer?.invalidate()
        if let companion, companion.isRunning { companion.interrupt() }
        video.tearDown()
        engine.stop()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var player: PlayerController?
    var pendingFiles: [URL] = []
    let updates = UpdateChecker()
    var updateMenuItem: NSMenuItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false  // keeps tab commands out of the menus
        let resource = Bundle.main.resourceURL?.appendingPathComponent("runtime-path.txt")
        let fromFile = resource.flatMap { try? String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
        let bundledRuntime = Bundle.main.resourceURL?.appendingPathComponent("runtime")
        let embeddedPath = bundledRuntime.flatMap {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("run.sh").path) ? $0.path : nil
        }
        let path =
            ProcessInfo.processInfo.environment["VIDAC_RUNTIME_DIR"] ?? embeddedPath ?? fromFile
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/vidac/Application").path
        do { player = try PlayerController(runtimeDirectory: URL(fileURLWithPath: path)) } catch {
            let alert = NSAlert()
            alert.messageText = "Vidac can’t start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        if let player { installMenus(for: player) }
        updates.onChange = { [weak self] release, isNew in self?.updateAvailabilityChanged(release, isNew: isNew) }
        updates.start()
        let launchFiles = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        if !pendingFiles.isEmpty {
            player?.open(pendingFiles)
            pendingFiles.removeAll()
        } else if !launchFiles.isEmpty {
            player?.open(launchFiles.map { URL(fileURLWithPath: $0) })
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let files = filenames.map { URL(fileURLWithPath: $0) }
        if let player, !files.isEmpty { player.open(files) } else { pendingFiles.append(contentsOf: files) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { player?.window.makeKeyAndOrderFront(nil) }  // brings a minimized player back as it was
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { player?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @objc func about() {
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let credits = NSMutableAttributedString(
            string: Branding.tagline + ".\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        credits.append(
            NSAttributedString(
                string:
                    "Privacy: no analytics. Your videos and audio never leave this Mac. The network is used only to download speech models, and about once a day to look for a new release of Vidac.\n\n",
                attributes: body))
        var links: [(String, URL)] = [("GitHub", ProjectLinks.home), ("Report an Issue", ProjectLinks.issues)]
        if let notices = Bundle.main.resourceURL?.appendingPathComponent("ThirdParty"),
            FileManager.default.fileExists(atPath: notices.path)
        {
            links.append(("Third-Party Licenses", notices))
        }
        for (index, link) in links.enumerated() {
            if index > 0 { credits.append(NSAttributedString(string: "  ·  ", attributes: body)) }
            credits.append(NSAttributedString(string: link.0, attributes: body.merging([.link: link.1]) { $1 }))
        }
        credits.append(
            NSAttributedString(
                string:
                    "\n\nVidac is free software under the GNU GPL, version 3 or later, and comes with no warranty. Playback is provided by mpv and FFmpeg. Third-party components and their licenses are listed in the ThirdParty folder inside the app.",
                attributes: body))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func makeDefaultPlayer() {
        let alert = NSAlert()
        alert.messageText = "Make Vidac the default video player?"
        alert.informativeText =
            "Videos you open from Finder will play in Vidac. “Common Formats” covers MP4, M4V, MOV, MKV, AVI, WebM, TS, M2TS, WMV and FLV; “All Formats” also includes every other format Vidac registers. For a format another player already handles, macOS may ask you to confirm; choose “Use Vidac”. You can change this later in Finder under Get Info → Open With."
        alert.addButton(withTitle: "Common Formats")
        alert.addButton(withTitle: "All Formats")
        alert.addButton(withTitle: "Cancel")
        present(alert) { [weak self] response in
            guard response != .alertThirdButtonReturn else { return }
            let common = response == .alertFirstButtonReturn
            VideoFormats.makeDefaultHandler(extensions: common ? VideoFormats.commonExtensions : nil) { changed, failed in
                nativeLog("Default handler set for \(changed) types, \(failed.count) failed: \(failed.joined(separator: ","))")
                let done = NSAlert()
                done.messageText = failed.isEmpty ? "Vidac is now the default video player" : "Some formats were left unchanged"
                done.informativeText =
                    failed.isEmpty
                    ? "\(changed) \(common ? "common " : "")video types will open in Vidac. Double-click a video in Finder to try it."
                    : "\(changed) of \(changed + failed.count) video types now open in Vidac. You can set the rest in Finder under Get Info → Open With."
                self?.present(done) { _ in }
            }
        }
    }
    /// Shows an alert as a sheet on the player window when it can, so it does not block the whole app.
    func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = player?.window, window.isVisible, !window.isMiniaturized {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

/// Builds before 0.5 stored preferences under a placeholder identifier.
private func migrateLegacyPreferences() {
    let defaults = UserDefaults.standard
    guard Bundle.main.bundleIdentifier != "local.vidac", !defaults.bool(forKey: "LegacyPreferencesMigrated") else { return }
    if let legacy = UserDefaults.standard.persistentDomain(forName: "local.vidac") {
        for key in ["RecentVideoPaths", "TrackpadGesturesEnabled", "TrackpadSensitivity"] where defaults.object(forKey: key) == nil {
            if let value = legacy[key] { defaults.set(value, forKey: key) }
        }
    }
    defaults.set(true, forKey: "LegacyPreferencesMigrated")
}

@main
struct VidacMain {
    static func main() {
        if CommandLine.arguments.contains("--ipc-smoke-test") {
            do {
                let path = ProcessInfo.processInfo.environment["VIDAC_NATIVE_SOCKET"] ?? "/tmp/vidac-native-smoke-\(getpid()).sock"
                let engine = try PlaybackEngine(socketPath: path)
                print("IPC_READY \(path)")
                fflush(stdout)
                RunLoop.current.run(until: Date().addingTimeInterval(8))
                engine.stop()
                return
            } catch {
                fputs("\(error)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--make-default-handler") {
            var outcome: (Int, [String])?
            VideoFormats.makeDefaultHandler { outcome = ($0, $1) }
            // macOS may ask the user to confirm each format another app already handles.
            let deadline = Date().addingTimeInterval(600)
            while outcome == nil && Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            guard let outcome else {
                fputs("timed out\n", stderr)
                exit(1)
            }
            print("default-handler changed=\(outcome.0) failed=\(outcome.1.joined(separator: ","))")
            exit(outcome.1.isEmpty ? 0 : 2)
        }
        migrateLegacyPreferences()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

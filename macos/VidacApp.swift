import AppKit
import OpenGL.GL3
import Darwin

// Native macOS host. Video remains in this process; the Python companion only
// controls the same libmpv core through its IPC client and generates subtitles.

private let accent = NSColor(calibratedRed: 0.64, green: 0.55, blue: 0.98, alpha: 1)
private let background = NSColor(calibratedWhite: 0.065, alpha: 1)
private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
/// Fast start, long soft landing: the curve used for every discrete transition.
private let glide = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
private let logLock = NSLock()
private func appendHandle(_ url: URL) -> FileHandle? {
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    return descriptor >= 0 ? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) : nil
}
private func nativeLog(_ message: String) {
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
private func mpvError(_ code: Int32) -> String { String(cString: mpv_error_string(code)) }

final class PlaybackEngine {
    var handle: OpaquePointer?
    let socketPath: String
    var onValue: ((String, Any) -> Void)?
    private var eventWork: DispatchWorkItem?
    private let eventGroup = DispatchGroup()
    private let stateLock = NSLock()
    private var stopping = false
    private let observationNames = [
        "time-pos", "duration", "pause", "volume", "mute", "path", "eof-reached", "user-data/vidac-status", "video-out-params/aspect",
        "video-out-params/rotate",
    ]

    init(socketPath: String) throws {
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
        for (index, name) in observationNames.enumerated() {
            let format =
                ["path", "user-data/vidac-status"].contains(name)
                ? MPV_FORMAT_STRING : (["pause", "mute", "eof-reached"].contains(name) ? MPV_FORMAT_FLAG : MPV_FORMAT_DOUBLE)
            mpv_observe_property(core, UInt64(index + 1), name, format)
        }
        eventGroup.enter()
        let work = DispatchWorkItem { [weak self] in
            defer { self?.eventGroup.leave() }
            guard let self else { return }
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
                        let text = String(cString: pointer)
                        if name == "user-data/vidac-status",
                            let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? String
                        {
                            value = decoded
                        } else {
                            value = text
                        }
                    }
                    if let value { DispatchQueue.main.async { [weak self] in self?.onValue?(name, value) } }
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
    func command(_ words: [String]) {
        guard let handle else { return }
        var arguments = words.map { strdup($0) }
        arguments.append(nil)
        let argumentCount = arguments.count
        defer { arguments.forEach { free($0) } }
        let result = arguments.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: argumentCount) {
                mpv_command_async(handle, 0, $0)
            }
        }
        if result < 0 { nativeLog("mpv command \(words.first ?? ""): \(mpvError(result))") }
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
    var onOpen: ((URL) -> Void)?
    var onFullscreen: (() -> Void)?
    /// True while fingers are scaling the window. A resize redraw must reach
    /// the screen in the same refresh as the new frame, so the renderer is
    /// told not to wait for the next video frame's presentation time.
    var isDirectlyManipulated = false
    private var tracking: NSTrackingArea?
    private var didPrepare = false
    private var drawQueued = false
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
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onFullscreen?() } else { onPointer?() }
    }
    // The whole picture is a drag handle, as in other borderless players.
    override func mouseDragged(with event: NSEvent) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.performDrag(with: event)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: engine.command(["cycle", "pause"])
        case 123: engine.command(["seek", "-5", "relative+exact"])
        case 124: engine.command(["seek", "5", "relative+exact"])
        case 125: engine.command(["add", "volume", "-2"])
        case 126: engine.command(["add", "volume", "2"])
        case 3: onFullscreen?()
        case 53: if window?.styleMask.contains(.fullScreen) == true { onFullscreen?() }
        default:
            if let character = event.charactersIgnoringModifiers, ["v", "t", "[", "]", "-", "=", "+"].contains(character) {
                engine.command(["keypress", character])
            } else {
                super.keyDown(with: event)
            }
        }
        onPointer?()
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?
                .first
        else { return false }
        onOpen?(url)
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
final class WelcomeView: NSView {
    var onOpen: ((URL) -> Void)?
    var onChoose: (() -> Void)?
    var recents: [URL] = []
    private var recentStack: NSStackView!
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        registerForDraggedTypes([.fileURL])
        let mark = BrandMark()
        mark.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Vidac")
        title.font = .systemFont(ofSize: 42, weight: .medium)
        title.textColor = .white
        let subtitle = NSTextField(labelWithString: "Local playback, automatic bilingual subtitles")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        let open = PrimaryButton(title: "Open Video…", target: self, action: #selector(choose))
        open.isBordered = false
        open.controlSize = .large
        open.keyEquivalent = "o"
        open.keyEquivalentModifierMask = .command
        let shortcut = NSTextField(labelWithString: "or drop a video here")
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.textColor = .tertiaryLabelColor
        let brand = NSStackView(views: [mark, title, subtitle, open, shortcut])
        brand.orientation = .vertical
        brand.spacing = 16
        brand.alignment = .centerX
        brand.translatesAutoresizingMaskIntoConstraints = false
        addSubview(brand)
        // NSBox.separator has a one-point intrinsic *height*; using it as a
        // vertical line would constrain the entire welcome page to 203 pt.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        let recentTitle = NSTextField(labelWithString: "Recent")
        recentTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        recentTitle.textColor = .secondaryLabelColor
        recentStack = NSStackView()
        recentStack.orientation = .vertical
        recentStack.spacing = 8
        recentStack.alignment = .leading
        let recentArea = NSStackView(views: [recentTitle, recentStack])
        recentArea.orientation = .vertical
        recentArea.spacing = 18
        recentArea.alignment = .leading
        recentArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recentArea)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 88), mark.heightAnchor.constraint(equalToConstant: 88),
            open.widthAnchor.constraint(equalToConstant: 184), open.heightAnchor.constraint(equalToConstant: 40),
            brand.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4),
            brand.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 236),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 450),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 112),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -90), divider.widthAnchor.constraint(equalToConstant: 1),
            recentArea.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 36),
            recentArea.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            recentArea.topAnchor.constraint(equalTo: topAnchor, constant: 125),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [
            NSColor(calibratedRed: 0.115, green: 0.105, blue: 0.15, alpha: 1), background, NSColor(calibratedWhite: 0.045, alpha: 1),
        ])?.draw(in: bounds, angle: -35)
    }
    @objc private func choose() { onChoose?() }
    func refresh(_ urls: [URL]) {
        recents = urls
        for child in recentStack.arrangedSubviews {
            recentStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        if urls.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "Videos you open will appear here.")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .tertiaryLabelColor
            recentStack.addArrangedSubview(empty)
        }
        for (index, url) in urls.prefix(6).enumerated() {
            let button = PlaybackButton(
                title: url.deletingPathExtension().lastPathComponent, target: self, action: #selector(openRecent(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 13)
            button.contentTintColor = .labelColor
            button.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = false
            button.lineBreakMode = .byTruncatingMiddle
            button.toolTip = url.lastPathComponent
            recentStack.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
    }
    @objc private func openRecent(_ sender: NSButton) { if sender.tag < recents.count { onOpen?(recents[sender.tag]) } }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let url = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?
                .first
        else { return false }
        onOpen?(url)
        return true
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
    override func mouseDown(with event: NSEvent) {
        scrubbing = true
        super.mouseDown(with: event)
        scrubbing = false
    }
}

final class PlayerController: NSObject, NSWindowDelegate {
    let engine: PlaybackEngine
    let window: NSWindow
    let video: TrackpadVideoSurface
    let welcome = WelcomeView()
    private let hud = GestureSafeEffectView()
    private let progress = SeekSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let positionLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusBadge = PassiveEffectView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private var statusBadgeEligible = true
    private var statusBadgeTimer: Timer?
    private let nameLabel = NSTextField(labelWithString: "")
    private var playButton: NSButton!
    private var volumeSlider: NSSlider!
    private var hideTimer: Timer?
    private var controlsVisible = false
    private var controlsGeneration = 0
    private var companion: Process?
    private var companionRetries = 0
    private var quitting = false
    private var isPaused = false
    private var pendingURL: URL?
    private var rendererReady = false
    private var currentURL: URL?
    private var duration = 0.0
    private var lastSubtitleBottom: Int?
    private var subtitleMarginTimer: Timer?
    private var lastSubtitlePublish = 0.0
    private var settingsPanel: NSPanel?
    private var trackpadPanel: NSPanel?
    private var compactControls: [NSView] = []
    private var hudHeightConstraint: NSLayoutConstraint?
    private var hudBottomConstraint: NSLayoutConstraint?
    private let gestureFeedback = PassiveEffectView()
    private let gestureFeedbackText = NSTextField(labelWithString: "")
    private let gestureFeedbackIcon = NSImageView()
    private var gestureFeedbackTimer: Timer?
    private var feedbackGeneration = 0
    private var playbackPosition = 0.0
    private var playbackVolume = 100.0
    private var playbackMuted = false
    private var scrollSession: (axis: TrackpadScrollAxis, base: Double, wasPaused: Bool, wasMuted: Bool, gain: Double)?
    private var pinch = PinchZoomReducer()
    private var pinchWindowFrame: NSRect?
    private var windowZoomAspect: CGFloat?
    private var applyingZoomFrame = false
    private var pinchFullscreen = false
    private var pinchAtLimit = false
    private var videoAspect: Double?
    private var videoRotation = 0.0
    private var hudRestingBottom: CGFloat = -22
    private var hudHiddenOffset: CGFloat { reducedMotion ? 0 : 12 }
    private var fullscreenVideoScale = 1.0
    private var fullscreenTransition = false
    private var lastVolumeBoundary: Int?
    private let referenceWindowSize = NSSize(width: 960, height: 600)
    private var sensitivityLabel: NSTextField?
    let runtimeDirectory: URL

    init(runtimeDirectory: URL) throws {
        self.runtimeDirectory = runtimeDirectory
        let socket = ProcessInfo.processInfo.environment["VIDAC_NATIVE_SOCKET"] ?? "/tmp/vidac-native-\(getuid()).sock"
        engine = try PlaybackEngine(socketPath: socket)
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
        welcome.onChoose = { [weak self] in self?.chooseFile() }
        welcome.onOpen = { [weak self] in self?.open($0) }
        welcome.refresh(recentURLs())
        video.onOpen = { [weak self] in self?.open($0) }
        video.onPointer = { [weak self] in self?.showControls() }
        video.onFullscreen = { [weak self] in self?.toggleFullscreen() }
        video.onReady = { [weak self] in
            guard let self else { return }
            self.rendererReady = true
            self.publishSubtitleMargin()
            self.startCompanion()
            if let pending = self.pendingURL {
                self.pendingURL = nil
                self.open(pending)
            }
        }
        engine.onValue = { [weak self] name, value in self?.receive(name, value) }
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.setContentSize(NSSize(width: 960, height: 600))
        window.center()
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
    private func symbolButton(_ symbol: String, label: String, selector: Selector) -> NSButton {
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
    private func configureHUD(in content: NSView) {
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
        playButton = symbolButton("play.fill", label: "Play or Pause", selector: #selector(togglePause))
        playButton.imageScaling = .scaleProportionallyUpOrDown
        playButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 23, weight: .semibold)
        let back = symbolButton("gobackward.10", label: "Back 10 Seconds", selector: #selector(backward))
        let forward = symbolButton("goforward.10", label: "Forward 10 Seconds", selector: #selector(forward))
        let caption = symbolButton("captions.bubble", label: "Subtitle Settings", selector: #selector(showSubtitleSettings))
        let full = symbolButton("arrow.up.left.and.arrow.down.right", label: "Full Screen", selector: #selector(toggleFullscreen))
        let speaker = symbolButton("speaker.wave.2.fill", label: "Mute", selector: #selector(mute))
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
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .white.withAlphaComponent(0.72)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        let spacer1 = NSView()
        let spacer2 = NSView()
        let controls = NSStackView(views: [
            positionLabel, statusLabel, spacer1, back, playButton, forward, spacer2, speaker, volumeSlider, caption, full, durationLabel,
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.detachesHiddenViews = true
        compactControls = [statusLabel, back, forward, speaker, volumeSlider, durationLabel]
        spacer1.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        spacer2.widthAnchor.constraint(equalTo: spacer1.widthAnchor).isActive = true
        statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        let stack = NSStackView(views: [nameLabel, progress, controls])
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
        let height = hud.heightAnchor.constraint(equalToConstant: 108)
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
    private func configureStatus(in content: NSView) {
        statusBadge.material = .hudWindow
        statusBadge.blendingMode = .withinWindow
        statusBadge.state = .active
        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = 9
        statusBadge.layer?.masksToBounds = true
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.isHidden = true
        badgeLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.lineBreakMode = .byTruncatingTail
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.addSubview(badgeLabel)
        content.addSubview(statusBadge)
        NSLayoutConstraint.activate([
            statusBadge.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            statusBadge.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            statusBadge.heightAnchor.constraint(equalToConstant: 30),
            statusBadge.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.7),
            badgeLabel.leadingAnchor.constraint(equalTo: statusBadge.leadingAnchor, constant: 12),
            badgeLabel.trailingAnchor.constraint(equalTo: statusBadge.trailingAnchor, constant: -12),
            badgeLabel.centerYAnchor.constraint(equalTo: statusBadge.centerYAnchor),
        ])
    }
    private func setStatus(_ raw: String) {
        var message = raw
        if raw.contains("翻译不可用") || raw.contains("翻译服务未连接") || raw.contains("翻译出错") {
            message = "Translation unavailable · showing original"
        } else if raw.contains("字幕不可用") {
            message = "Subtitles unavailable · playback continues"
        } else if raw.contains("翻译模型未下载") {
            message = "Translation model not downloaded · showing original"
        } else if raw.contains("正在加载识别模型") {
            message = "Preparing subtitles…"
        } else if let range = raw.range(of: #"\d+/\d+ 段"#, options: .regularExpression) {
            message = "Generating subtitles · " + raw[range].replacingOccurrences(of: " 段", with: "")
        } else if raw.contains("保留原文") {
            message = "Subtitles ready · some lines untranslated"
        } else if raw.contains("字幕"), raw.contains("已完成") {
            if translationIsComplete(raw) {
                message = "Subtitles and translation ready"
            } else {
                message = raw.contains("翻译") ? "Subtitles ready · translating" : "Subtitles ready"
            }
        }
        statusLabel.stringValue = message
        statusLabel.toolTip = raw
        badgeLabel.stringValue = message
        badgeLabel.toolTip = raw
        statusBadgeTimer?.invalidate()
        statusBadgeEligible = true
        updateStatusBadgeVisibility()
        if ["Subtitles ready", "Subtitles and translation ready", "Subtitles ready · some lines untranslated"].contains(message) {
            let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
                self?.statusBadgeEligible = false
                self?.updateStatusBadgeVisibility()
            }
            statusBadgeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func updateStatusBadgeVisibility() {
        statusBadge.isHidden =
            !statusBadgeEligible || statusLabel.stringValue.isEmpty || currentURL == nil || welcome.superview != nil
            || !gestureFeedback.isHidden
    }
    private func translationIsComplete(_ raw: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: #"翻译.*?(\d+)\s*/\s*(\d+)"#),
            let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
            let doneRange = Range(match.range(at: 1), in: raw), let totalRange = Range(match.range(at: 2), in: raw),
            let done = Int(raw[doneRange]), let total = Int(raw[totalRange])
        else { return false }
        return done == total
    }
    private func receive(_ name: String, _ value: Any) {
        switch name {
        case "time-pos":
            if let position = value as? Double {
                playbackPosition = position
                if scrollSession?.axis != .horizontal {
                    if !progress.scrubbing { progress.doubleValue = duration > 0 ? position / duration : 0 }
                    positionLabel.stringValue = timestamp(position)
                }
            }
        case "duration":
            if let seconds = value as? Double {
                duration = seconds
                durationLabel.stringValue = timestamp(seconds)
            }
        case "pause":
            if let paused = value as? Bool {
                isPaused = paused
                playButton.image = NSImage(
                    systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? "Play" : "Pause")
                showControls()
            }
        case "volume":
            if let volume = value as? Double {
                playbackVolume = volume
                volumeSlider.doubleValue = volume
            }
        case "mute": if let muted = value as? Bool { playbackMuted = muted }
        case "path":
            if let path = value as? String, !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                currentURL = url
                nameLabel.stringValue = url.deletingPathExtension().lastPathComponent
                window.title = url.lastPathComponent + " — Vidac"
                welcome.isHidden = true
                showControls()
            }
        case "user-data/vidac-status": if let text = value as? String { setStatus(text) }
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
    private func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
    @objc func chooseFile() {
        video.cancelTrackpadGestures()
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK, let url = panel.url { self?.open(url) } }
    }
    func open(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "This video can’t be found"
            alert.informativeText = "The file may have been moved, or its disk is not connected."
            alert.beginSheetModal(for: window)
            return
        }
        guard rendererReady else {
            pendingURL = url
            return
        }
        video.cancelTrackpadGestures()
        fullscreenVideoScale = 1
        engine.command(["set", "video-zoom", "0"])
        videoAspect = nil
        videoRotation = 0
        if welcome.superview != nil {
            window.minSize = NSSize(width: 480, height: 300)
            window.contentMinSize = NSSize(width: 480, height: 300)
            dissolveWelcome()
        }
        welcome.removeFromSuperview()
        currentURL = url
        welcome.isHidden = true
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(video)
        nameLabel.stringValue = url.deletingPathExtension().lastPathComponent
        setStatus("Preparing subtitles…")
        engine.command(["loadfile", url.path])
        engine.command(["set", "pause", "no"])
        var urls = recentURLs().filter { $0 != url }
        urls.insert(url, at: 0)
        UserDefaults.standard.set(urls.prefix(12).map(\.path), forKey: "RecentVideoPaths")
        welcome.refresh(Array(urls.prefix(6)))
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        showControls()
    }
    /// The welcome page leaves as a fading still, so the first frame appears
    /// through it instead of replacing it in a single refresh.
    private func dissolveWelcome() {
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
    private func minimumWindowWidth(forAspect ratio: CGFloat) -> CGFloat { ratio >= 1 ? max(480, 300 * ratio) : 320 }
    /// Gives the window the picture's shape, as large as it was before, so no
    /// black bars remain and later pinches scale exactly the picture.
    private func fitWindowToVideo() {
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
        let width = min(available.width, available.height * ratio, max(minimumWidth, (origin.width * origin.height * ratio).squareRoot()))
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
        controlsVisible = false
        controlsGeneration += 1
        hud.isHidden = true
        hud.alphaValue = 0
        statusBadge.isHidden = true
        gestureFeedback.isHidden = true
        setWindowButtons(alpha: 1)
        window.title = "Vidac"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func recentURLs() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: "RecentVideoPaths") ?? []).map { URL(fileURLWithPath: $0) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
    private var scrollSensitivity: Double {
        let value = (UserDefaults.standard.object(forKey: "TrackpadSensitivity") as? Double) ?? 1
        return value.isFinite ? min(2, max(0.5, value)) : 1
    }
    private func configureTrackpad() {
        video.allowsTrackpadGestures = { [weak self] in
            guard let self else { return false }
            let enabled = (UserDefaults.standard.object(forKey: "TrackpadGesturesEnabled") as? Bool) ?? true
            return enabled && self.currentURL != nil && self.welcome.superview == nil && self.window.isKeyWindow
                && !self.fullscreenTransition && self.window.attachedSheet == nil
                && self.settingsPanel?.isVisible != true && self.trackpadPanel?.isVisible != true && !self.quitting
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
            if let origin = self.pinchWindowFrame { self.logWindowZoom(origin: origin) }
            self.pinchWindowFrame = nil
        }
        video.onSmartZoom = { [weak self] in self?.resetZoom() }
        video.onGestureSummary = { nativeLog("Trackpad " + $0) }
    }
    private var scrollLastTotal = 0.0
    private func applyScroll(_ update: TrackpadScrollUpdate) {
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
    private func finishScroll(cancelled: Bool) {
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
            showGestureFeedback(
                session.wasMuted ? "Muted" : "Volume \(Int(session.base.rounded()))%",
                symbol: session.wasMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        } else {
            applyGestureVolume(session.base + scrollLastTotal * session.gain)
        }
        scrollLastTotal = 0
        showControls()
    }
    private func drawSeekPreview(_ target: Double, origin: Double) {
        progress.doubleValue = duration > 0 ? target / duration : 0
        positionLabel.stringValue = timestamp(target)
        let change = target - origin
        let prefix = change < 0 ? "−" : "+"
        showGestureFeedback(
            "\(prefix)\(String(format: "%.1f", abs(change))) s  ·  \(timestamp(target)) / \(timestamp(duration))",
            symbol: change < 0 ? "gobackward" : "goforward")
        showControls()
    }
    private func applyGestureVolume(_ proposed: Double) {
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
        showGestureFeedback("Volume \(Int(value.rounded()))%", symbol: value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }
    private func beginPinch() {
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
    private func notePinchLimit(_ scale: Double) {
        let atLimit = scale <= pinch.minimumScale + 0.000_5 || scale >= pinch.maximumScale - 0.000_5
        if atLimit && !pinchAtLimit && video.isDirectlyManipulated {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        pinchAtLimit = atLimit
    }
    private func alignedToPixels(_ rect: NSRect) -> NSRect {
        let scale = max(1, window.backingScaleFactor)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        return NSRect(x: snap(rect.minX), y: snap(rect.minY), width: snap(rect.width), height: snap(rect.height))
    }
    private func applyPinchScale(_ scale: Double) {
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
    private func zoomedFrame(from origin: NSRect, scale: Double) -> NSRect {
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
    private func commitWindowZoom(_ frame: NSRect, animated: Bool = false) {
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
    private func resetFullscreenZoom() {
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
            publishSubtitleMargin(immediate: true)
            showGestureFeedback("Actual Size", symbol: "arrow.counterclockwise")
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    @objc func zoomIn() { stepZoom(1.1) }
    @objc func zoomOut() { stepZoom(1 / 1.1) }
    private func stepZoom(_ factor: Double) {
        guard currentURL != nil, welcome.superview == nil, !fullscreenTransition else { return }
        video.cancelTrackpadGestures()
        beginPinch()
        let proposed = min(pinch.maximumScale, max(pinch.minimumScale, pinchFullscreen ? fullscreenVideoScale * factor : factor))
        if pinchFullscreen {
            applyPinchScale(proposed)
        } else if let origin = pinchWindowFrame {
            commitWindowZoom(zoomedFrame(from: origin, scale: proposed), animated: true)
        }
        publishSubtitleMargin(immediate: true)
        pinch.reset()
        pinchWindowFrame = nil
        video.isDirectlyManipulated = false
    }
    private func logWindowZoom(origin: NSRect) {
        let actual = window.frame
        nativeLog(
            String(
                format: "Window zoom from=%.3fx%.3f actual=%.3fx%.3f ratio-before=%.6f ratio-after=%.6f", origin.width, origin.height,
                actual.width, actual.height, origin.width / origin.height, actual.width / actual.height))
    }
    private var compactPresentation: Bool {
        let size = window.contentView?.bounds.size ?? referenceWindowSize
        return size.width < 700 || size.height < 440
    }
    private func updateCompactControls(for proposedSize: NSSize? = nil) {
        let compact = proposedSize.map { $0.width < 700 || $0.height < 440 } ?? compactPresentation
        for view in compactControls where view.isHidden != compact { view.isHidden = compact }
        if nameLabel.isHidden != compact { nameLabel.isHidden = compact }
        let height: CGFloat = compact ? 80 : 108
        hudRestingBottom = compact ? -14 : -22
        let bottom = hudRestingBottom + (controlsVisible ? 0 : hudHiddenOffset)
        if hudHeightConstraint?.constant != height { hudHeightConstraint?.constant = height }
        if hudBottomConstraint?.constant != bottom { hudBottomConstraint?.constant = bottom }
    }
    private func configureGestureFeedback(in content: NSView) {
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
    private func showGestureFeedback(_ text: String, symbol: String) {
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
    private func hideGestureFeedback() {
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
    @objc func showTrackpadSettings() {
        video.cancelTrackpadGestures()
        if let trackpadPanel {
            trackpadPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Trackpad"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        let enabled = NSButton(
            checkboxWithTitle: "Enable trackpad gestures over the video", target: self, action: #selector(changeTrackpadEnabled(_:)))
        enabled.state = ((UserDefaults.standard.object(forKey: "TrackpadGesturesEnabled") as? Bool) ?? true) ? .on : .off
        let instructions = NSTextField(
            wrappingLabelWithString:
                "Two-finger swipe left or right: seek\nTwo-finger swipe up or down: volume\nPinch: resize the window, or zoom the picture in full screen\n⌘0 or two-finger double-tap: actual size"
        )
        instructions.font = .systemFont(ofSize: 13)
        instructions.textColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "Swipe sensitivity")
        let slider = NSSlider(
            value: scrollSensitivity, minValue: 0.5, maxValue: 2, target: self, action: #selector(changeTrackpadSensitivity(_:)))
        slider.isContinuous = true
        slider.setAccessibilityLabel("Swipe sensitivity")
        let value = NSTextField(labelWithString: "\(Int((scrollSensitivity * 100).rounded()))%")
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sensitivityLabel = value
        let sensitivity = NSStackView(views: [title, slider, value])
        sensitivity.spacing = 12
        let note = NSTextField(
            wrappingLabelWithString:
                "Swipe right to go forward and up to raise the volume. Adjustment stops when you lift your fingers. Gestures over menus and the control bar are ignored."
        )
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [enabled, instructions, sensitivity, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 28),
            slider.widthAnchor.constraint(equalToConstant: 200),
        ])
        trackpadPanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }
    @objc private func changeTrackpadEnabled(_ sender: NSButton) {
        video.cancelTrackpadGestures()
        UserDefaults.standard.set(sender.state == .on, forKey: "TrackpadGesturesEnabled")
    }
    @objc private func changeTrackpadSensitivity(_ sender: NSSlider) {
        video.cancelTrackpadGestures()
        UserDefaults.standard.set(sender.doubleValue, forKey: "TrackpadSensitivity")
        sensitivityLabel?.stringValue = "\(Int((scrollSensitivity * 100).rounded()))%"
    }
    func showControls() {
        guard currentURL != nil, welcome.superview == nil else { return }
        setControlsVisible(true)
        if isPaused {
            hideTimer?.invalidate()
            hideTimer = nil
            return
        }
        if let timer = hideTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: 3)
        } else {
            let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
                guard let self else { return }
                let pointer = self.hud.convert(self.window.mouseLocationOutsideOfEventStream, from: nil)
                if self.progress.scrubbing || self.hud.bounds.contains(pointer) || self.window.attachedSheet != nil {
                    self.showControls()
                } else {
                    self.setControlsVisible(false)
                }
            }
            hideTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func setControlsVisible(_ visible: Bool) {
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
                self.hudBottomConstraint?.animator().constant = self.hudRestingBottom + (visible ? 0 : self.hudHiddenOffset)
                self.setWindowButtons(alpha: visible ? 1 : 0, animated: true)
            },
            completionHandler: { [weak self] in
                guard let self, generation == self.controlsGeneration else { return }
                self.hud.isHidden = !visible
            })
        if !visible, window.isKeyWindow, !isPaused {
            let pointer = video.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if video.bounds.contains(pointer) { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }
    /// The traffic lights belong to the controls: they fade with them while a
    /// video plays and are always present on the welcome page.
    private func setWindowButtons(alpha: CGFloat, animated: Bool = false) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            if animated { button.animator().alphaValue = alpha } else { button.alphaValue = alpha }
        }
    }
    @objc func togglePause() {
        video.cancelTrackpadGestures()
        engine.command(["cycle", "pause"])
        showControls()
    }
    @objc private func backward() {
        video.cancelTrackpadGestures()
        engine.command(["seek", "-10", "relative+exact"])
        showControls()
    }
    @objc private func forward() {
        video.cancelTrackpadGestures()
        engine.command(["seek", "10", "relative+exact"])
        showControls()
    }
    @objc private func mute() { engine.command(["cycle", "mute"]) }
    @objc private func seek(_ sender: NSSlider) {
        video.cancelTrackpadGestures()
        engine.command(["seek", String(sender.doubleValue * duration), "absolute+exact"])
    }
    @objc private func volume(_ sender: NSSlider) {
        video.cancelTrackpadGestures()
        engine.command(["set", "volume", String(sender.doubleValue)])
    }
    @objc func toggleFullscreen() { window.toggleFullScreen(nil) }
    @objc func showSubtitleSettings() {
        video.cancelTrackpadGestures()
        if let settingsPanel {
            settingsPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Subtitle Settings"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        let settingsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/vidac/settings.json")
        let settings =
            (try? Data(contentsOf: settingsFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let heading = NSTextField(labelWithString: "Subtitles & Translation")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(heading)
        func row(_ title: String, _ key: String, _ items: [(String, String)], _ current: String) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 72).isActive = true
            let popup = NSPopUpButton()
            popup.identifier = NSUserInterfaceItemIdentifier(key)
            popup.target = self
            popup.action = #selector(changeSetting(_:))
            popup.addItems(withTitles: items.map { $0.0 })
            for (i, item) in items.enumerated() { popup.item(at: i)?.representedObject = item.1 }
            if let index = items.firstIndex(where: { $0.1 == current }) { popup.selectItem(at: index) }
            popup.widthAnchor.constraint(equalToConstant: 240).isActive = true
            let line = NSStackView(views: [label, popup])
            line.spacing = 14
            stack.addArrangedSubview(line)
        }
        row(
            "Show", "display_mode", [("Bilingual", "bilingual"), ("Original only", "orig"), ("Translation only", "trans"), ("Off", "off")],
            settings["display_mode"] as? String ?? "bilingual")
        row("Translate", "translate", [("On", "true"), ("Off", "false")], (settings["translate"] as? Bool ?? true) ? "true" : "false")
        row(
            "Translate to", "target_lang", [("简体中文", "zh"), ("繁體中文", "zh-tw"), ("English", "en"), ("日本語", "ja"), ("한국어", "ko")],
            settings["target_lang"] as? String ?? "zh")
        row(
            "Spoken", "language", [("Detect automatically", "auto"), ("日本語", "ja"), ("English", "en"), ("中文", "zh")],
            settings["language"] as? String ?? "auto")
        row(
            "Model", "model", [("Base", "base"), ("Small", "small"), ("Large v3 Turbo", "large-v3-turbo")],
            settings["model"] as? String ?? "base")
        let note = NSTextField(wrappingLabelWithString: "Recognition and translation run on this Mac. Subtitles appear as the video plays.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 26),
        ])
        settingsPanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }
    @objc private func changeSetting(_ sender: NSPopUpButton) {
        if let key = sender.identifier?.rawValue, let value = sender.selectedItem?.representedObject as? String {
            engine.setting(key, value)
        }
    }
    private func startCompanion() {
        guard !quitting, companion == nil else { return }
        let executable = runtimeDirectory.appendingPathComponent("run.sh")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            setStatus("Subtitle component missing")
            nativeLog("Missing companion \(executable.path)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [executable.path, "-v"]
        process.currentDirectoryURL = runtimeDirectory
        var environment = ProcessInfo.processInfo.environment
        let runtimeBin = runtimeDirectory.appendingPathComponent("bin").path
        environment["VIDAC_ATTACH_SOCKET"] = engine.socketPath
        environment["VIDAC_SOCKET"] = engine.socketPath
        environment["VIDAC_NATIVE_UI"] = "1"
        environment["VIDAC_APPLE_HELPER"] = runtimeDirectory.appendingPathComponent("bin/apple-translate").path
        environment["PATH"] = runtimeBin + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        if companionRetries > 0 {
            environment["VIDAC_KEEP_CURRENT_POSITION"] = "1"
        } else {
            environment.removeValue(forKey: "VIDAC_KEEP_CURRENT_POSITION")
        }
        process.environment = environment
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/vidac-native.log")
        if let file = appendHandle(logURL) {
            process.standardOutput = file
            process.standardError = file
        }
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            nativeLog("Subtitle companion exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.companion = nil
                if !self.quitting, self.companionRetries < 1 {
                    self.companionRetries += 1
                    self.setStatus("Restoring subtitles…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startCompanion() }
                } else if !self.quitting {
                    self.setStatus("Subtitles unavailable · playback continues")
                }
            }
        }
        do {
            try process.run()
            companion = process
            nativeLog("Subtitle companion started pid=\(process.processIdentifier)")
        } catch {
            setStatus("Subtitles unavailable · playback continues")
            nativeLog("Subtitle companion start failed: \(error)")
        }
    }
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
    }
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
    func windowDidResignKey(_ notification: Notification) {
        video.cancelTrackpadGestures()
        if currentURL != nil, welcome.superview == nil { setWindowButtons(alpha: 1, animated: true) }
    }
    func windowWillMiniaturize(_ notification: Notification) { video.cancelTrackpadGestures() }
    private func publishSubtitleMargin(immediate: Bool = false) {
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
        let height = max(Double(window.contentView?.bounds.height ?? 1), 1)
        // Convert the 130 pt control panel + 25 pt gap to the subtitle
        // overlay's 720-unit coordinates, independent of Retina backing scale.
        let reserve: Double = compactPresentation ? 110 : 155
        let bottom = min(300, max(110, Int(ceil(reserve * 720.0 / height))))
        guard bottom != lastSubtitleBottom else { return }
        lastSubtitleBottom = bottom
        lastSubtitlePublish = now
        engine.command(["set", "user-data/vidac-subtitle-bottom", String(bottom)])
    }
    func shutdown() {
        quitting = true
        video.cancelTrackpadGestures()
        hideTimer?.invalidate()
        gestureFeedbackTimer?.invalidate()
        subtitleMarginTimer?.invalidate()
        statusBadgeTimer?.invalidate()
        if let companion, companion.isRunning { companion.interrupt() }
        video.tearDown()
        engine.stop()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var player: PlayerController?
    var pendingFiles: [URL] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
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
        if let first = pendingFiles.first {
            player?.open(first)
            pendingFiles.removeAll()
        } else if let first = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }),
            FileManager.default.fileExists(atPath: first)
        {
            player?.open(URL(fileURLWithPath: first))
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let files = filenames.map { URL(fileURLWithPath: $0) }
        if let player, let first = files.first { player.open(first) } else { pendingFiles.append(contentsOf: files) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { player?.showWelcome() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { player?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @objc func choose() { player?.chooseFile() }
    @objc func closeWindow() { player?.window.performClose(nil) }
    @objc func settings() { player?.showSubtitleSettings() }
    @objc func trackpadSettings() { player?.showTrackpadSettings() }
    @objc func resetZoom() { player?.resetZoom() }
    @objc func zoomIn() { player?.zoomIn() }
    @objc func zoomOut() { player?.zoomOut() }
    @objc func pause() { player?.togglePause() }
    @objc func fullscreen() { player?.toggleFullscreen() }
    @objc func welcome() { player?.showWelcome() }
    @objc func about() {
        let credits = NSMutableAttributedString(
            string: "Immersive playback with on-device subtitles.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        credits.append(
            NSAttributedString(
                string:
                    "Vidac is free software under the GNU GPL, version 3 or later, and comes with no warranty. Playback is provided by mpv and FFmpeg. Third-party components and their licenses are listed in the ThirdParty folder inside the app.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func makeDefaultPlayer() {
        let alert = NSAlert()
        alert.messageText = "Make Vidac the default video player?"
        alert.informativeText =
            "MP4, MKV, MOV, TS and the other \(VideoFormats.extensions.count) registered video formats will open in Vidac. For formats another player already handles, macOS asks you to confirm each one — choose “Use Vidac”. You can change this later in Finder under Get Info → Open With."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        VideoFormats.makeDefaultHandler { changed, failed in
            nativeLog("Default handler set for \(changed) types, \(failed.count) failed: \(failed.joined(separator: ","))")
            let done = NSAlert()
            done.messageText = failed.isEmpty ? "Vidac is now the default video player" : "\(changed) formats now open in Vidac"
            done.informativeText =
                failed.isEmpty
                ? "Double-click a video in Finder to play it in Vidac."
                : "\(failed.count) formats were left unchanged. You can set them in Finder under Get Info → Open With."
            done.runModal()
        }
    }
    private func installMenus() {
        let main = NSMenu()
        NSApp.mainMenu = main
        let app = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)
        func item(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target ?? self
            menu.addItem(i)
        }
        item(app, "About Vidac", #selector(about))
        app.addItem(.separator())
        item(app, "Subtitle Settings…", #selector(settings), ",")
        item(app, "Trackpad Settings…", #selector(trackpadSettings))
        item(app, "Make Default Video Player…", #selector(makeDefaultPlayer))
        app.addItem(.separator())
        item(app, "Hide Vidac", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        item(app, "Quit Vidac", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = NSMenu(title: "File")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)
        item(file, "Open Video…", #selector(choose), "o")
        item(file, "Welcome", #selector(welcome))
        file.addItem(.separator())
        item(file, "Close Window", #selector(closeWindow), "w")
        let play = NSMenu(title: "Playback")
        let playItem = NSMenuItem(title: "Playback", action: nil, keyEquivalent: "")
        playItem.submenu = play
        main.addItem(playItem)
        item(play, "Play / Pause", #selector(pause), " ")
        let window = NSMenu(title: "Window")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        item(window, "Zoom In", #selector(zoomIn), "=")
        item(window, "Zoom Out", #selector(zoomOut), "-")
        item(window, "Actual Size", #selector(resetZoom), "0")
        window.addItem(.separator())
        item(window, "Enter Full Screen", #selector(fullscreen), "f")
        NSApp.windowsMenu = window
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

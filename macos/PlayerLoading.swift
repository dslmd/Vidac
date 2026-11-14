import AppKit
import UniformTypeIdentifiers

/// Opening and closing files, the recents list, the sleep assertion, window
/// memory and the life of the subtitle companion.
extension PlayerController {
    // MARK: Opening

    @objc func chooseFile() {
        video.cancelTrackpadGestures()
        video.cancelPendingClick()
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        // Registered formats plus anything macOS itself classes as a movie or sound.
        panel.allowedContentTypes = VideoFormats.contentTypes + [.movie, .video, .audio]
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK, !panel.urls.isEmpty { self?.open(panel.urls) } }
    }

    /// Hands one file to the core; `open(_:)` in PlayerQueue.swift decides what
    /// to queue first. The window only changes once the core has reported the
    /// file as loaded (`didLoad`) or refused (`failLoad`).
    func load(_ url: URL) {
        guard rendererReady else {
            pendingURL = url
            return
        }
        video.cancelTrackpadGestures()
        video.cancelPendingClick()
        resetFullscreenZoom()
        videoAspect = nil
        videoRotation = 0
        adoptNextPath = false
        cancelUpNext()
        subtitleFileWillChange()
        loadToken += 1
        let token = loadToken
        pendingLoad = (token, url, nil)
        if companion == nil {
            companionRetries = 0
            startCompanion()
        }
        window.makeKeyAndOrderFront(nil)
        engine.command(["set", "speed", "1"])
        engine.command(["loadfile", url.path]) { [weak self] error, entry in
            guard let self, var pending = self.pendingLoad, pending.token == token else { return }
            if error < 0 {
                self.pendingLoad = nil
                self.failLoad(pending.url, error: error, wasPlaying: false)
            } else {
                pending.entry = entry
                self.pendingLoad = pending
            }
        }
        engine.command(["set", "pause", "no"])
    }

    func handle(_ event: PlaybackEvent) {
        guard !quitting else { return }
        switch event {
        case .fileLoaded(let entry):
            if let pending = pendingLoad {
                // A file from an earlier request may still report in; only the newest counts.
                guard pending.entry == nil || pending.entry == entry else { return }
                pendingLoad = nil
                didLoad(pending.url, entry: entry)
            } else if entry != currentEntry {
                // Loaded from outside the app, through the IPC socket.
                currentEntry = entry
                if let path = lastObservedPath, path != currentURL?.path {
                    didLoad(URL(fileURLWithPath: path), entry: entry)
                } else {
                    adoptNextPath = true
                }
            }
        case .fileEnded(let entry, let reason, let error):
            if let pending = pendingLoad {
                guard pending.entry == entry else { return }  // the file being replaced
                pendingLoad = nil
                if reason == .failed { failLoad(pending.url, error: error, wasPlaying: false) } else { closeVideo(stopCore: false) }
            } else if entry == currentEntry, let url = currentURL {
                if reason == .failed { failLoad(url, error: error, wasPlaying: true) } else { closeVideo(stopCore: false) }
            }
        }
    }

    func didLoad(_ url: URL, entry: Int64) {
        currentEntry = entry
        currentURL = url
        atEnd = false
        keySeek = nil
        if welcome.superview != nil {
            window.minSize = NSSize(width: 480, height: 300)
            window.contentMinSize = NSSize(width: 480, height: 300)
            dissolveWelcome()
            welcome.removeFromSuperview()
        }
        window.makeFirstResponder(video)
        window.title = url.lastPathComponent + " — Vidac"
        window.representedURL = url
        subtitleFileDidLoad()
        noteRecent(url)
        updatePlayButton()
        updateSleepAssertion()
        fitWindowToVideo()
        queueDidLoad(url)
        nowPlaying.refresh()
        showControls()
        nativeLog("Loaded \(url.lastPathComponent)")
    }

    func failLoad(_ url: URL, error: Int32, wasPlaying: Bool) {
        nativeLog("Playback failed for \(url.lastPathComponent): \(mpvError(error)) (\(error)) loaded=\(wasPlaying)")
        if !wasPlaying { removeRecent(url) }
        // A video reached by Next, Previous or auto-advance that cannot be
        // played is passed over rather than ending the queue.
        if !wasPlaying, queueAnnouncement != nil, queue.count > 1, queue.indices.contains(queueIndex), queue[queueIndex].path == url.path {
            queue.remove(at: queueIndex)
            let target = queueDirection > 0 ? queueIndex : queueIndex - 1
            if queue.indices.contains(target) {
                queueIndex = target
                load(queue[target])
                return
            }
        }
        closeVideo(stopCore: false)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if wasPlaying {
            alert.messageText = "“\(url.lastPathComponent)” stopped playing"
            alert.informativeText = "The file could no longer be read. Its disk may have been disconnected."
        } else {
            alert.messageText = "Vidac can’t play “\(url.lastPathComponent)”"
            if !FileManager.default.isReadableFile(atPath: url.path) {
                alert.informativeText = "Vidac doesn’t have permission to read this file."
            } else if error == MPV_ERROR_NOTHING_TO_PLAY.rawValue {
                alert.informativeText = "The file doesn’t contain any video or audio that Vidac can play."
            } else if error == MPV_ERROR_UNKNOWN_FORMAT.rawValue {
                alert.informativeText = "The file isn’t a video, or is in a format Vidac doesn’t recognize."
            } else {
                alert.informativeText = "The file may be damaged, or use an unsupported or protected format."
            }
        }
        alert.beginSheetModal(for: window)
    }

    /// Ends the current video (or a load in progress) and returns to the welcome page.
    func closeVideo(stopCore: Bool = true) {
        video.cancelTrackpadGestures()
        video.cancelPendingClick()
        let wasActive = currentURL != nil || pendingLoad != nil
        pendingLoad = nil
        currentEntry = nil
        currentURL = nil
        lastObservedPath = nil
        adoptNextPath = false
        atEnd = false
        keySeek = nil
        if wasActive && stopCore { engine.command(["stop"]) }
        duration = 0
        playbackPosition = 0
        progress.doubleValue = 0
        positionLabel.stringValue = timestamp(0)
        updateDurationLabel(position: 0)
        clearQueue()
        nowPlaying.refresh()
        subtitleFileDidClose()
        updatePlayButton()
        updateSleepAssertion()
        showWelcome()
    }

    // MARK: Recents

    func noteRecent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var urls = recentURLs().filter { $0 != url }
        urls.insert(url, at: 0)
        UserDefaults.standard.set(urls.prefix(12).map(\.path), forKey: "RecentVideoPaths")
        welcome.refresh(Array(urls.prefix(12)))
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
    func removeRecent(_ url: URL) {
        let urls = recentURLs().filter { $0 != url }
        UserDefaults.standard.set(urls.map(\.path), forKey: "RecentVideoPaths")
        welcome.refresh(urls)
    }
    @objc func clearRecents() {
        UserDefaults.standard.removeObject(forKey: "RecentVideoPaths")
        NSDocumentController.shared.clearRecentDocuments(nil)
        welcome.refresh([])
    }
    @objc func openRecent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { open(url) } }

    // MARK: Sleep

    /// With the render API the host, not mpv, must keep the display awake.
    func updateSleepAssertion() {
        let playing = currentURL != nil && !isPaused && !atEnd && !quitting
        if playing, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing video")
        } else if !playing, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    // MARK: Window memory

    var savedPictureArea: CGFloat? {
        let area = UserDefaults.standard.double(forKey: "PlayerPictureArea")
        return area.isFinite && area >= 480 * 270 ? CGFloat(area) : nil
    }
    private var windowGeometryIsUsers: Bool {
        window.isVisible && !window.styleMask.contains(.fullScreen) && !fullscreenTransition && !quitting
    }
    func rememberWindowPosition() {
        guard windowGeometryIsUsers else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: window.frame.midX, y: window.frame.midY)), forKey: "PlayerWindowCenter")
    }
    /// Called after the user (not a fit to a new picture) changes the size.
    /// The welcome page's size is not a picture size and is never recorded.
    func rememberWindowGeometry(size: NSSize? = nil) {
        guard windowGeometryIsUsers else { return }
        rememberWindowPosition()
        guard hasVideo else { return }
        let size = size ?? window.frame.size
        UserDefaults.standard.set(Double(size.width * size.height), forKey: "PlayerPictureArea")
    }
    func restoreWindowPosition() {
        guard let text = UserDefaults.standard.string(forKey: "PlayerWindowCenter") else {
            window.center()
            return
        }
        let centre = NSPointFromString(text)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(centre) }) else {
            window.center()  // the display it was on is gone
            return
        }
        let available = screen.visibleFrame.insetBy(dx: 8, dy: 8), size = window.frame.size
        window.setFrameOrigin(
            NSPoint(
                x: min(available.maxX - size.width, max(available.minX, centre.x - size.width / 2)),
                y: min(available.maxY - size.height, max(available.minY, centre.y - size.height / 2))))
    }

    // MARK: Subtitle companion

    /// Waits before each automatic restart. The count starts over once a
    /// companion has stayed up for `companionHealthyAfter` seconds.
    private static let companionBackoff: [TimeInterval] = [1, 3, 8]
    private static let companionHealthyAfter: TimeInterval = 30
    var companionRunning: Bool { companion?.isRunning == true }

    func startCompanion() {
        guard !quitting, companion == nil else { return }
        companionRestartWork?.cancel()
        companionRestartWork = nil
        let executable = runtimeDirectory.appendingPathComponent("run.sh")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            companionGaveUp = true
            nativeLog("Missing companion \(executable.path)")
            companionAvailabilityChanged()
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
        // A relaunched companion joins a video that is already playing and must not seek it.
        // The companion only honours this for the named file, so a video opened later still resumes.
        if companionLaunches > 0, let playing = currentURL, playing.isFileURL {
            environment["VIDAC_KEEP_CURRENT_POSITION"] = playing.path
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
        engine.command(["set", "user-data/vidac-state", ""])
        process.terminationHandler = { [weak self] process in
            nativeLog("Subtitle companion exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)")
            DispatchQueue.main.async { self?.companionExited(process) }
        }
        do {
            try process.run()
            companion = process
            companionLaunches += 1
            companionStartedAt = ProcessInfo.processInfo.systemUptime
            companionGaveUp = false
            nativeLog("Subtitle companion started pid=\(process.processIdentifier)")
        } catch {
            companionGaveUp = true
            nativeLog("Subtitle companion start failed: \(error)")
        }
        companionAvailabilityChanged()
    }

    private func companionExited(_ process: Process) {
        guard companion === process else { return }
        companion = nil
        companionState = [:]
        // mpv sends no change for an identical value, so a stale payload would hide the next companion's first publish.
        engine.command(["set", "user-data/vidac-state", ""])
        guard !quitting else { return }
        if companionRestartRequested {
            companionRestartRequested = false
            companionRetries = 0
            startCompanion()
            return
        }
        if let started = companionStartedAt, ProcessInfo.processInfo.systemUptime - started >= Self.companionHealthyAfter {
            companionRetries = 0
        }
        guard companionRetries < Self.companionBackoff.count else {
            companionGaveUp = true
            nativeLog("Subtitle companion kept exiting; automatic restarts stopped")
            companionAvailabilityChanged()
            return
        }
        let delay = Self.companionBackoff[companionRetries]
        companionRetries += 1
        let work = DispatchWorkItem { [weak self] in
            self?.companionRestartWork = nil
            self?.startCompanion()
        }
        companionRestartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        companionAvailabilityChanged()
    }

    /// Starts the companion afresh with a clean retry budget, replacing one
    /// that is still running. Safe to call at any time.
    func restartCompanion() {
        guard !quitting else { return }
        companionRetries = 0
        companionGaveUp = false
        companionRestartWork?.cancel()
        companionRestartWork = nil
        guard let running = companion, running.isRunning else {
            companion = nil
            startCompanion()
            return
        }
        companionRestartRequested = true
        running.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.companion === running, running.isRunning { running.terminate() }
        }
    }
}

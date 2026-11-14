import AppKit

/// The queue of videos behind Next and Previous: built when files are opened,
/// walked by the menu, the control bar and the media keys, and advanced when a
/// video ends.
extension PlayerController {
    static let upNextSeconds = 5

    var hasNextItem: Bool { queueIndex + 1 < queue.count }
    var hasPreviousItem: Bool { queueIndex > 0 && queueIndex < queue.count }
    var autoAdvanceEnabled: Bool { (UserDefaults.standard.object(forKey: "AutoAdvance") as? Bool) ?? true }

    // MARK: Building the queue

    /// Opens what the user chose, dropped or double-clicked. One file queues
    /// the other videos in its folder; several files (or folders) queue
    /// themselves.
    func open(_ requested: [URL]) {
        guard let plan = queuePlan(for: requested) else { return }
        queue = plan.queue
        queueIndex = plan.index
        queueAnnouncement = nil
        load(plan.queue[plan.index])
    }
    func open(_ requested: URL) { open([requested]) }

    private static var videoExtensions: Set<String> { Set(VideoFormats.extensions.map { $0.lowercased() }) }

    private func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    /// The videos directly inside a folder, in the order Finder lists "Episode 2" before "Episode 10".
    func videos(in folder: URL) -> [URL] {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) && !isFolder($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func queuePlan(for requested: [URL]) -> (queue: [URL], index: Int)? {
        let existing = requested.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = requested.count > 1 ? "These videos can’t be found" : "This video can’t be found"
            alert.informativeText = "The file may have been moved, or its disk is not connected."
            alert.beginSheetModal(for: window)
            return nil
        }
        // A single file brings its folder along, so Next works without a trip to Finder.
        if existing.count == 1, !isFolder(existing[0]) {
            let file = existing[0]
            guard Self.videoExtensions.contains(file.pathExtension.lowercased()) else { return ([file], 0) }
            var siblings = videos(in: file.deletingLastPathComponent())
            if !siblings.contains(where: { $0.path == file.path }) {
                siblings.append(file)
                siblings.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
            return (siblings, siblings.firstIndex { $0.path == file.path } ?? 0)
        }
        var items: [URL] = []
        for url in existing { items.append(contentsOf: isFolder(url) ? videos(in: url) : [url]) }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.path).inserted }
        // Files picked together from one folder are episodes more often than a deliberate order.
        if existing.allSatisfy({ !isFolder($0) }), Set(items.map { $0.deletingLastPathComponent().path }).count == 1 {
            items.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        guard !items.isEmpty else {
            let alert = NSAlert()
            alert.messageText =
                existing.count == 1 ? "There are no videos in “\(existing[0].lastPathComponent)”" : "There are no videos to open"
            alert.informativeText = "Choose video files, or a folder that contains some."
            alert.beginSheetModal(for: window)
            return nil
        }
        return (items, 0)
    }

    // MARK: Walking the queue

    @objc func playNext() { go(1, announcing: "forward.end.fill") }
    @objc func playPrevious() { go(-1, announcing: "backward.end.fill") }

    /// Moves one item along. Files that have disappeared since the queue was
    /// built are dropped on the way.
    private func go(_ direction: Int, announcing symbol: String) {
        guard hasVideo else { return }
        cancelUpNext()
        var target = queueIndex + direction
        while queue.indices.contains(target), !FileManager.default.fileExists(atPath: queue[target].path) {
            queue.remove(at: target)
            if direction < 0 {
                target -= 1
                queueIndex -= 1
            }
        }
        guard queue.indices.contains(target) else {
            updateQueueUI()
            return
        }
        queueIndex = target
        queueAnnouncement = symbol
        queueDirection = direction
        updateQueueUI()
        load(queue[target])
    }

    @objc func toggleAutoAdvance() {
        UserDefaults.standard.set(!autoAdvanceEnabled, forKey: "AutoAdvance")
        if !autoAdvanceEnabled { cancelUpNext() }
        if settingsController?.isVisible == true { settingsController?.refresh() }
        showGestureFeedback(
            autoAdvanceEnabled ? "Play Next Automatically: On" : "Play Next Automatically: Off", symbol: "forward.end.alt.fill")
    }

    /// Called when a file has loaded: makes the queue agree with what is
    /// playing and says where we are after a Next, Previous or auto-advance.
    func queueDidLoad(_ url: URL) {
        if !(queue.indices.contains(queueIndex) && queue[queueIndex].path == url.path) {
            // Started from outside (IPC); whatever was queued no longer applies.
            queue = [url]
            queueIndex = 0
        }
        cancelUpNext()
        updateQueueUI()
        if let symbol = queueAnnouncement {
            queueAnnouncement = nil
            if queue.count > 1 { showGestureFeedback("\(queueIndex + 1) of \(queue.count)", symbol: symbol) }
        }
    }

    func clearQueue() {
        queue = []
        queueIndex = 0
        queueAnnouncement = nil
        cancelUpNext()
        updateQueueUI()
    }

    /// The control bar's buttons, the title strip's position and the media keys.
    func updateQueueUI() {
        updateQueueButtons()
        let name = currentURL?.deletingPathExtension().lastPathComponent ?? ""
        titleStrip.setTitle(name, detail: queue.count > 1 && hasVideo ? "\(queueIndex + 1) of \(queue.count)" : nil)
        nowPlaying.refresh()
    }
    /// The compact layout only has room for them when the window is wide enough.
    func updateQueueButtons(width proposedWidth: CGFloat? = nil) {
        let width = proposedWidth ?? window.contentView?.bounds.width ?? referenceWindowSize.width
        let room = width >= 420
        let previous = hasVideo && hasPreviousItem && room, next = hasVideo && hasNextItem && room
        if previousButton.isHidden == previous { previousButton.isHidden = !previous }
        if nextButton.isHidden == next { nextButton.isHidden = !next }
    }

    // MARK: Up Next

    /// The video ended: unless there is nothing to go to, offer the next one
    /// after a few seconds, with a way to stop it.
    func beginUpNext() {
        guard hasVideo, pendingLoad == nil, hasNextItem, autoAdvanceEnabled, !upNextCard.isPresented else { return }
        upNextRemaining = Self.upNextSeconds
        updateUpNextText()
        upNextCard.present()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.upNextRemaining -= 1
            if self.upNextRemaining <= 0 { self.advanceFromUpNext() } else { self.updateUpNextText() }
        }
        upNextTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func updateUpNextText() {
        let next = queue.indices.contains(queueIndex + 1) ? queue[queueIndex + 1] : nil
        upNextCard.setText(
            title: "Up Next in \(upNextRemaining)", detail: next?.deletingPathExtension().lastPathComponent ?? "")
    }
    func advanceFromUpNext() {
        guard atEnd, hasNextItem else {
            cancelUpNext()
            return
        }
        playNext()
    }
    /// Stops the countdown and hides the card; safe when none is showing.
    @discardableResult
    func cancelUpNext() -> Bool {
        let wasShowing = upNextTimer != nil
        upNextTimer?.invalidate()
        upNextTimer = nil
        upNextCard.dismiss()
        return wasShowing
    }
}

import AppKit

/// Where each video was left, as the companion records it (positions.json),
/// so a recent can say "Resume at 12:34". Only entries whose file is
/// unchanged count, as in the companion itself.
enum ResumePoints {
    private static var file: URL {
        if let home = ProcessInfo.processInfo.environment["VIDAC_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath).appendingPathComponent("positions.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/vidac/positions.json")
    }
    /// Resume points for these videos only, so a disk that is slow or gone is not asked about the other 500.
    static func load(for urls: [URL]) -> [String: Double] {
        guard let data = try? Data(contentsOf: file), let records = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        var points: [String: Double] = [:]
        for path in urls.map(\.path) {
            guard let record = records[path] as? [String: Any], let position = record["pos"] as? Double, position >= 5,
                let size = record["size"] as? Double, let modified = record["mtime"] as? Double,
                let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                (attributes[.size] as? NSNumber)?.doubleValue == size,
                let date = attributes[.modificationDate] as? Date, abs(date.timeIntervalSince1970 - modified) <= 1
            else { continue }
            points[path] = position
        }
        return points
    }
}

/// One recent video: icon, name, and a quieter line with its folder and
/// resume point. Shows a remove button and a highlight under the pointer.
final class RecentRow: NSView {
    let url: URL
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    private let removeButton = NSButton()
    private var hover = false

    init(url: URL, detail: String) {
        self.url = url
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: url.deletingPathExtension().lastPathComponent)
        name.font = .systemFont(ofSize: 13)
        name.textColor = .labelColor
        let line = NSTextField(labelWithString: detail)
        line.font = .systemFont(ofSize: 11)
        line.textColor = .tertiaryLabelColor
        for label in [name, line] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [name, line])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        removeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove from Recents")
        removeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        removeButton.isBordered = false
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.toolTip = "Remove from Recents"
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.alphaValue = 0
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(text)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -8),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        toolTip = url.path
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(url.deletingPathExtension().lastPathComponent)
        setAccessibilityHelp(detail)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Remove from Recents") { [weak self] in
                self?.onRemove?()
                return true
            }
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func remove() { onRemove?() }
    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    private func setHover(_ inside: Bool) {
        hover = inside
        needsDisplay = true
        removeButton.alphaValue = inside ? 1 : 0
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHover(false) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard hover else { return }
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.add("Show in Finder", #selector(reveal), target: self)
        menu.add("Remove from Recents", #selector(remove), target: self)
        return menu
    }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

final class WelcomeView: NSView {
    static let visibleRecents = 6
    var onOpen: (([URL]) -> Void)?
    var onChoose: (() -> Void)?
    var onRemove: ((URL) -> Void)?
    var onClear: (() -> Void)?
    private var recentStack: NSStackView!
    private var clearButton: NSButton!
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
        let subtitle = NSTextField(labelWithString: Branding.tagline)
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        let open = PrimaryButton(title: "Open Video…", target: self, action: #selector(choose))
        open.isBordered = false
        open.controlSize = .large
        open.keyEquivalent = "o"
        open.keyEquivalentModifierMask = .command
        let shortcut = NSTextField(labelWithString: "or drop videos or a folder here")
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.textColor = .tertiaryLabelColor
        let brand = NSStackView(views: [mark, title, subtitle, open, shortcut])
        brand.orientation = .vertical
        brand.spacing = 16
        brand.alignment = .centerX
        brand.translatesAutoresizingMaskIntoConstraints = false
        addSubview(brand)
        // What opening a video does, in two calm lines: the facts that decide whether to trust it.
        let notes = NSStackView(views: [
            Self.note("Subtitles are generated on this Mac. Your video never leaves it."),
            Self.note("A speech model is downloaded once, the first time you open a video."),
        ])
        notes.orientation = .vertical
        notes.alignment = .centerX
        notes.spacing = 3
        notes.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notes)
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
        clearButton = NSButton(title: "Clear", target: self, action: #selector(clear))
        clearButton.isBordered = false
        clearButton.font = .systemFont(ofSize: 12)
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.toolTip = "Clear the list of recent videos. The videos themselves are not touched."
        let header = NSStackView(views: [recentTitle, NSView(), clearButton])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        recentStack = NSStackView()
        recentStack.orientation = .vertical
        recentStack.spacing = 4
        recentStack.alignment = .leading
        let recentArea = NSStackView(views: [header, recentStack])
        recentArea.orientation = .vertical
        recentArea.spacing = 14
        recentArea.alignment = .leading
        recentArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recentArea)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 88), mark.heightAnchor.constraint(equalToConstant: 88),
            open.widthAnchor.constraint(equalToConstant: 184), open.heightAnchor.constraint(equalToConstant: 40),
            brand.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -22),
            brand.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 236),
            notes.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 236),
            notes.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -30),
            notes.widthAnchor.constraint(lessThanOrEqualToConstant: 390),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 450),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 112),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -90), divider.widthAnchor.constraint(equalToConstant: 1),
            recentArea.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 28),
            recentArea.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            recentArea.topAnchor.constraint(equalTo: topAnchor, constant: 112),
            header.leadingAnchor.constraint(equalTo: recentArea.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: recentArea.trailingAnchor, constant: -8),
            recentStack.leadingAnchor.constraint(equalTo: recentArea.leadingAnchor),
            recentStack.trailingAnchor.constraint(equalTo: recentArea.trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    private static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        return label
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [
            NSColor(calibratedRed: 0.115, green: 0.105, blue: 0.15, alpha: 1), background, NSColor(calibratedWhite: 0.045, alpha: 1),
        ])?.draw(in: bounds, angle: -35)
    }
    @objc private func choose() { onChoose?() }
    @objc private func clear() { onClear?() }
    func refresh(_ urls: [URL]) {
        for child in recentStack.arrangedSubviews {
            recentStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        clearButton.isHidden = urls.isEmpty
        if urls.isEmpty {
            let title = NSTextField(labelWithString: "No recent videos")
            title.font = .systemFont(ofSize: 13)
            title.textColor = .secondaryLabelColor
            let hint = NSTextField(wrappingLabelWithString: "Videos you open will appear here.")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = .tertiaryLabelColor
            let empty = NSStackView(views: [title, hint])
            empty.orientation = .vertical
            empty.alignment = .leading
            empty.spacing = 4
            empty.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 0, right: 0)
            recentStack.addArrangedSubview(empty)
            return
        }
        let shown = Array(urls.prefix(Self.visibleRecents))
        let resume = ResumePoints.load(for: shown)
        for url in shown {
            var parts = [url.deletingLastPathComponent().lastPathComponent]
            if let position = resume[url.path] { parts.append("Resume at " + Self.timestamp(position)) }
            let row = RecentRow(url: url, detail: parts.joined(separator: " · "))
            row.onOpen = { [weak self] in self?.onOpen?([url]) }
            row.onRemove = { [weak self] in self?.onRemove?(url) }
            recentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
        }
    }
    private static func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
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
}

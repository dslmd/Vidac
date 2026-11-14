import AppKit

/// Every key and gesture the player answers to, in one table. The Help
/// window is generated from it, so a binding is added here and nowhere else
/// in the documentation. The bindings themselves live in
/// `PlayerController.handleKey` (PlayerActions.swift), the menus
/// (AppMenus.swift) and `TrackpadVideoSurface`; keep this list in step when
/// one of those changes.
struct ShortcutItem {
    /// Alternatives or a pair, each drawn as its own key cap and joined by "/".
    let keys: [String]
    let action: String
}
struct ShortcutGroup {
    let title: String
    let items: [ShortcutItem]
}

enum ShortcutTable {
    /// `keys` lists the alternatives separated by "|".
    private static func item(_ keys: String, _ action: String) -> ShortcutItem {
        ShortcutItem(keys: keys.components(separatedBy: "|"), action: action)
    }

    static let groups: [ShortcutGroup] = [
        ShortcutGroup(
            title: "Playback",
            items: [
                item("Space|K", "Play or pause (Replay at the end)"),
                item("←|→", "Skip back or forward 5 seconds"),
                item("⇧←|⇧→", "Skip back or forward 1 second"),
                item("⌥←|⌥→", "Skip back or forward 30 seconds"),
                item("J|L", "Skip back or forward 10 seconds"),
                item("0 – 9", "Jump to 0% – 90% of the video"),
                item("Home", "Go to the beginning"),
                item("⌘J", "Go to a time"),
                item(",|.", "Previous or next frame"),
                item("[|]", "Slower or faster"),
                item("⌫", "Normal speed"),
            ]),
        ShortcutGroup(
            title: "Playlist",
            items: [
                item("⌘→|⌘←", "Next or previous video in the folder or selection"),
                item("Esc", "Cancel “Up Next”"),
            ]),
        ShortcutGroup(
            title: "Sound",
            items: [
                item("↑|↓", "Volume up or down"),
                item("M", "Mute"),
            ]),
        ShortcutGroup(
            title: "Picture and Window",
            items: [
                item("F|⌃⌘F", "Enter or leave full screen"),
                item("Esc", "Leave full screen"),
                item("⌘=|⌘-", "Zoom in or out"),
                item("⌘0", "Actual size"),
                item("⌃⌘T", "Float on top"),
                item("S", "Take a screenshot"),
                item("⌘O", "Open a video…"),
                item("⌘W", "Close the video (or the window)"),
            ]),
        ShortcutGroup(
            title: "Subtitles",
            items: [
                item("C", "Show or hide subtitles"),
                item("V", "Cycle bilingual, original and translation"),
                item("-|=", "Smaller or larger subtitles"),
                item("Z|X", "Show subtitles earlier or later by 0.1 seconds (⌥ for 0.5)"),
                item("T", "Next audio track"),
                item("⌘,", "Settings…"),
            ]),
        ShortcutGroup(
            title: "Mouse and Trackpad",
            items: [
                item("Click", "Play or pause"),
                item("Double-click", "Enter or leave full screen"),
                item("Right-click", "Menu for the picture"),
                item("Drag the picture", "Move the window"),
                item("Swipe left or right", "Seek (two fingers)"),
                item("Swipe up or down", "Volume (two fingers)"),
                item("Pinch", "Resize the window, or zoom in full screen"),
                item("Double-tap", "Actual size (two fingers)"),
                item("Drop videos or a folder", "Open them as a queue"),
            ]),
    ]
}

enum ProjectLinks {
    static let home = URL(string: "https://github.com/dslmd/Vidac")!
    static let issues = URL(string: "https://github.com/dslmd/Vidac/issues")!
}

/// The window behind Help ▸ Keyboard Shortcuts and Gestures, and the Help menu's links.
extension PlayerController {
    @objc func openProjectPage() { NSWorkspace.shared.open(ProjectLinks.home) }
    @objc func reportIssue() { NSWorkspace.shared.open(ProjectLinks.issues) }

    @objc func showShortcuts() {
        video.cancelTrackpadGestures()
        if let shortcutsWindow {
            shortcutsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered,
            defer: false)
        window.title = "Keyboard Shortcuts and Gestures"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 440, height: 320)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        for (index, group) in ShortcutTable.groups.enumerated() {
            let heading = NSTextField(labelWithString: group.title)
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            list.addArrangedSubview(heading)
            if index > 0 { list.setCustomSpacing(18, after: list.arrangedSubviews[list.arrangedSubviews.count - 2]) }
            for item in group.items {
                let row = Self.shortcutRow(item)
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        window.contentView = scroll
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        shortcutsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private static func shortcutRow(_ item: ShortcutItem) -> NSView {
        let keys = NSStackView()
        keys.orientation = .horizontal
        keys.spacing = 4
        for (index, key) in item.keys.enumerated() {
            if index > 0 {
                let slash = NSTextField(labelWithString: "/")
                slash.textColor = .tertiaryLabelColor
                keys.addArrangedSubview(slash)
            }
            let cap = NSTextField(labelWithString: key)
            cap.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            cap.textColor = .labelColor
            cap.wantsLayer = true
            cap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
            cap.layer?.cornerRadius = 5
            keys.addArrangedSubview(cap)
        }
        keys.translatesAutoresizingMaskIntoConstraints = false
        let action = NSTextField(wrappingLabelWithString: item.action)
        action.font = .systemFont(ofSize: 13)
        action.textColor = .labelColor
        action.translatesAutoresizingMaskIntoConstraints = false
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(keys)
        row.addSubview(action)
        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            keys.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            keys.widthAnchor.constraint(lessThanOrEqualToConstant: 190),
            action.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 200),
            action.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            action.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            action.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
            keys.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
        ])
        return row
    }
}

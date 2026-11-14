import AppKit

/// Seams for the parts of the player that are built separately. The subtitle
/// ones (`companionStateChanged`, `companionAvailabilityChanged`,
/// `buildSubtitlesMenu`, `contextMenuSubtitleItems`) live in
/// SubtitleStatus.swift and SubtitleControls.swift.
extension PlayerController {
    /// Fills the Help menu. macOS adds the search field by itself.
    func buildHelpMenu(_ menu: NSMenu) {
        menu.add("Keyboard Shortcuts and Gestures", #selector(showShortcuts), target: self)
        menu.addItem(.separator())
        menu.add("Vidac on GitHub", #selector(openProjectPage), target: self)
        menu.add("Report an Issue", #selector(reportIssue), target: self)
        menu.addItem(.separator())
        menu.add("Show Log in Finder", #selector(showLog), target: self)
    }
}

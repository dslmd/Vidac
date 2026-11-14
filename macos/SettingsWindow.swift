import AppKit

enum SettingsPane: String, CaseIterable {
    case general = "General"
    case subtitles = "Subtitles"
    case trackpad = "Trackpad"

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .subtitles: return "captions.bubble"
        case .trackpad: return "trackpad"
        }
    }
}

extension PlayerController {
    /// ⌘, in the Vidac menu.
    @objc func showSettings() { presentSettings(pane: nil) }
    /// The Subtitles pane, from the popover and the picture's menu.
    @objc func showSubtitleSettings() { presentSettings(pane: .subtitles) }
    func presentSettings(pane: SettingsPane?) {
        video.cancelTrackpadGestures()
        let controller = settingsController ?? SettingsWindowController(player: self)
        settingsController = controller
        controller.show(pane)
    }
}

/// The one Settings window: General, Subtitles and Trackpad, chosen from the
/// toolbar. The subtitle controls show the companion's settings and change
/// them with `setting` messages; the next state confirms. Without a running
/// companion they are disabled and say why.
final class SettingsWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {
    private unowned let player: PlayerController
    let window: NSWindow
    private var current = SettingsPane.general
    private var panes: [SettingsPane: SettingsPaneView] = [:]
    private static let width: CGFloat = 560

    var isVisible: Bool { window.isVisible }

    init(player: PlayerController) {
        self.player = player
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300), styleMask: [.titled, .closable], backing: .buffered,
            defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "VidacSettings")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        panes[.general] = GeneralPane(player: player)
        panes[.subtitles] = SubtitlesPane(player: player)
        panes[.trackpad] = TrackpadPane(player: player)
        let saved = UserDefaults.standard.string(forKey: "SettingsPane").flatMap(SettingsPane.init(rawValue:)) ?? .general
        select(saved, animated: false)
        window.center()
    }

    func show(_ pane: SettingsPane?) {
        if let pane { select(pane, animated: window.isVisible) }
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        panes[current]?.refresh()
        fitWindow(animated: false)
    }

    func windowWillClose(_ notification: Notification) { player.video.cancelTrackpadGestures() }

    private func select(_ pane: SettingsPane, animated: Bool) {
        current = pane
        UserDefaults.standard.set(pane.rawValue, forKey: "SettingsPane")
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        window.title = pane.rawValue
        guard let view = panes[pane] else { return }
        view.refresh()
        window.contentView = view
        fitWindow(animated: animated && !reducedMotion)
    }

    private func fitWindow(animated: Bool) {
        guard let view = panes[current] else { return }
        view.layoutSubtreeIfNeeded()
        let height = max(120, ceil(view.fittingSize.height))
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: height))
        var frame = window.frame
        guard abs(frame.height - target.height) > 0.5 || abs(frame.width - target.width) > 0.5 else { return }
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: animated)
    }

    @objc private func toolbarSelect(_ sender: NSToolbarItem) {
        if let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) { select(pane, animated: !reducedMotion) }
    }

    // MARK: NSToolbarDelegate

    private var identifiers: [NSToolbarItem.Identifier] { SettingsPane.allCases.map { NSToolbarItem.Identifier($0.rawValue) } }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.rawValue
        item.paletteLabel = pane.rawValue
        item.image =
            NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.rawValue)
            ?? NSImage(systemSymbolName: "hand.tap", accessibilityDescription: pane.rawValue)
        item.target = self
        item.action = #selector(toolbarSelect(_:))
        return item
    }
}

// MARK: Panes

/// A pane: a two-column grid of label and control, with captions under controls.
class SettingsPaneView: NSView {
    unowned let player: PlayerController
    let grid = NSGridView()
    static let contentWidth: CGFloat = 330

    init(player: PlayerController) {
        self.player = player
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 200))
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            widthAnchor.constraint(equalToConstant: 560),
        ])
        build()
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).width = Self.contentWidth
    }
    required init?(coder: NSCoder) { fatalError() }

    func build() {}
    func refresh() {}

    // MARK: Building blocks

    func caption(_ text: String = "") -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.contentWidth
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        return label
    }
    func titleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        return label
    }
    func stack(_ views: [NSView], spacing: CGFloat = 5) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        return stack
    }
    func line(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = spacing
        stack.alignment = .centerY
        return stack
    }
    @discardableResult
    func addRow(_ title: String?, _ content: NSView) -> NSGridRow {
        grid.addRow(with: [title.map(titleLabel) ?? NSGridCell.emptyContentView, content])
    }
    func addSeparator() {
        let box = NSBox()
        box.boxType = .separator
        let row = grid.addRow(with: [box])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        box.widthAnchor.constraint(equalToConstant: 150 + 14 + Self.contentWidth).isActive = true
    }
    func popup(_ action: Selector, width: CGFloat = 250) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = action
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
        return popup
    }
    func checkbox(_ title: String, _ action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        return box
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
}

private final class GeneralPane: SettingsPaneView {
    override func build() {
        let advanceBox = checkbox("Play next video automatically", #selector(toggleAdvance(_:)))
        advanceBox.setAccessibilityLabel("Play next video automatically")
        let advanceCaption = caption(
            "When a video ends and others were opened with it from the same folder or selection, the next one starts after a short countdown you can cancel."
        )
        addRow("Playback", stack([advanceBox, advanceCaption]))
        let updateBox = checkbox("Check for updates automatically", #selector(toggleUpdates(_:)))
        let check = button("Check Now", #selector(checkNow))
        check.controlSize = .small
        let updateCaption = caption("Contacts github.com once a day; nothing about you or your videos is sent.")
        addRow("Updates", stack([updateBox, updateCaption, check], spacing: 8))
        advanceControl = advanceBox
        updatesControl = updateBox
    }
    private var advanceControl: NSButton?
    private var updatesControl: NSButton?

    override func refresh() {
        advanceControl?.state = player.autoAdvanceEnabled ? .on : .off
        updatesControl?.state = ((UserDefaults.standard.object(forKey: "AutomaticUpdateCheck") as? Bool) ?? true) ? .on : .off
    }
    @objc private func toggleAdvance(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "AutoAdvance")
        if sender.state != .on { player.cancelUpNext() }
    }
    @objc private func toggleUpdates(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "AutomaticUpdateCheck")
    }
    @objc private func checkNow() { NSApp.sendAction(Selector(("checkForUpdates")), to: NSApp.delegate, from: nil) }
}

private final class TrackpadPane: SettingsPaneView {
    private var enabled: NSButton?
    private let slider = NSSlider(value: 1, minValue: 0.5, maxValue: 2, target: nil, action: nil)
    private let value = NSTextField(labelWithString: "100%")

    override func build() {
        let box = checkbox("Enable trackpad gestures over the video", #selector(toggleEnabled(_:)))
        enabled = box
        let list = caption(
            "Two-finger swipe left or right: seek\nTwo-finger swipe up or down: volume\nPinch: resize the window, or zoom the picture in full screen\n⌘0 or two-finger double-tap: actual size"
        )
        list.font = .systemFont(ofSize: 12)
        addRow("Gestures", stack([box, list], spacing: 8))
        slider.target = self
        slider.action = #selector(changeSensitivity(_:))
        slider.isContinuous = true
        slider.setAccessibilityLabel("Swipe sensitivity")
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let note = caption(
            "Swipe right to go forward and up to raise the volume. Adjustment stops when you lift your fingers. Gestures over menus and the control bar are ignored."
        )
        addRow("Swipe sensitivity", stack([line([slider, value]), note], spacing: 8))
    }
    override func refresh() {
        let on = (UserDefaults.standard.object(forKey: "TrackpadGesturesEnabled") as? Bool) ?? true
        enabled?.state = on ? .on : .off
        slider.isEnabled = on
        slider.doubleValue = player.scrollSensitivity
        value.stringValue = "\(Int((player.scrollSensitivity * 100).rounded()))%"
    }
    @objc private func toggleEnabled(_ sender: NSButton) {
        player.video.cancelTrackpadGestures()
        UserDefaults.standard.set(sender.state == .on, forKey: "TrackpadGesturesEnabled")
        refresh()
    }
    @objc private func changeSensitivity(_ sender: NSSlider) {
        player.video.cancelTrackpadGestures()
        UserDefaults.standard.set(sender.doubleValue, forKey: "TrackpadSensitivity")
        value.stringValue = "\(Int((player.scrollSensitivity * 100).rounded()))%"
    }
}

private final class SubtitlesPane: SettingsPaneView {
    private let banner = NSTextField(wrappingLabelWithString: "")
    private let restart = NSButton()
    private var bannerStack: NSStackView!
    private var auto: NSButton!
    private let model = NSPopUpButton()
    private let modelCaption = NSTextField()
    private let language = NSPopUpButton()
    private var translate: NSButton!
    private let target = NSPopUpButton()
    private let translationCaption = NSTextField()
    private let translationButton = NSButton()
    private let mode = NSPopUpButton()
    private let size = NSSlider(value: 1, minValue: 0.5, maxValue: 3, target: nil, action: nil)
    private let sizeValue = NSTextField(labelWithString: "100%")
    private var draggingSize = false
    private let delayValue = NSTextField(labelWithString: "0.0 s")
    private let delayMinus = NSButton()
    private let delayPlus = NSButton()
    private let delayReset = NSButton()
    private let delayCaption = NSTextField()
    private let location = NSPopUpButton()
    private let locationCaption = NSTextField()
    private let regenerate = NSButton()
    private let files = NSButton()
    private var controlsForState: [NSControl] = []

    private static let modes = [("Bilingual", "bilingual"), ("Original Only", "orig"), ("Translation Only", "trans"), ("Off", "off")]

    /// Names in the user's language, ordered by those names.
    private static let spokenItems: [(String, String)] = {
        let items = SpokenLanguages.codes.map { (SubtitleFormat.language($0), $0) }
        return items.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }()
    private static let targetItems: [(String, String)] = {
        let items = TargetLanguages.codes.map { (SubtitleFormat.targetLanguage($0), $0) }
        return items.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }()

    override func build() {
        // Why the controls are disabled, when they are.
        banner.font = .systemFont(ofSize: 12)
        banner.preferredMaxLayoutWidth = Self.contentWidth
        banner.maximumNumberOfLines = 0
        restart.title = "Restart Subtitles"
        restart.bezelStyle = .rounded
        restart.target = self
        restart.action = #selector(restartTapped)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemOrange
        bannerStack = stack([line([icon, banner], spacing: 8), restart], spacing: 8)
        addRow(nil, bannerStack)

        auto = checkbox("Create subtitles automatically", #selector(toggleAuto(_:)))
        addRow("Subtitles", stack([auto, caption("When off, Vidac only shows subtitle files that already exist.")]))

        configure(model, #selector(changeModel(_:)), width: 250)
        for preset in SubtitleModels.presets {
            model.addItem(withTitle: "\(preset.name) (\(preset.size))")
            model.lastItem?.representedObject = preset.code
        }
        configureCaption(modelCaption)
        addRow("Speech model", stack([model, modelCaption]))

        configure(language, #selector(changeLanguage(_:)), width: 250)
        language.addItem(withTitle: "Detect Automatically")
        language.lastItem?.representedObject = "auto"
        language.menu?.addItem(.separator())
        for (name, code) in Self.spokenItems {
            language.addItem(withTitle: name)
            language.lastItem?.representedObject = code
        }
        addRow(
            "Spoken language",
            stack([
                language,
                caption("Detecting works for most videos. Choose a language if it guesses wrong, or for videos in more than one."),
            ]))
        addSeparator()

        translate = checkbox("Translate subtitles", #selector(toggleTranslate(_:)))
        configure(target, #selector(changeTarget(_:)), width: 250)
        for (name, code) in Self.targetItems {
            target.addItem(withTitle: name)
            target.lastItem?.representedObject = code
        }
        configureCaption(translationCaption)
        translationButton.title = "Open System Settings"
        translationButton.bezelStyle = .rounded
        translationButton.controlSize = .small
        translationButton.target = self
        translationButton.action = #selector(openSystemSettings)
        addRow(
            "Translation",
            stack([translate, line([titleLabelPlain("Translate to"), target]), translationCaption, translationButton], spacing: 8))
        addSeparator()

        configure(mode, #selector(changeMode(_:)), width: 250)
        for (name, code) in Self.modes {
            mode.addItem(withTitle: name)
            mode.lastItem?.representedObject = code
        }
        addRow("Show", mode)

        size.target = self
        size.action = #selector(changeSize(_:))
        size.isContinuous = true
        size.setAccessibilityLabel("Subtitle size")
        size.widthAnchor.constraint(equalToConstant: 200).isActive = true
        sizeValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeValue.widthAnchor.constraint(equalToConstant: 48).isActive = true
        addRow("Size", line([size, sizeValue]))

        for (button, symbol, label, action) in [
            (delayMinus, "minus", "Show Subtitles Earlier", #selector(delayDown)),
            (delayPlus, "plus", "Show Subtitles Later", #selector(delayUp)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = action
        }
        delayReset.title = "Reset"
        delayReset.bezelStyle = .rounded
        delayReset.controlSize = .small
        delayReset.target = self
        delayReset.action = #selector(delayZero)
        delayValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        delayValue.alignment = .center
        delayValue.widthAnchor.constraint(equalToConstant: 58).isActive = true
        configureCaption(delayCaption)
        addRow("Delay", stack([line([delayMinus, delayValue, delayPlus, delayReset], spacing: 6), delayCaption], spacing: 6))
        addSeparator()

        configure(location, #selector(changeLocation(_:)), width: 250)
        for (name, code) in [("Next to the video", "beside"), ("In the Vidac library folder", "library")] {
            location.addItem(withTitle: name)
            location.lastItem?.representedObject = code
        }
        configureCaption(locationCaption)
        addRow("Subtitle files", stack([location, locationCaption]))

        regenerate.title = "Regenerate Subtitles…"
        regenerate.bezelStyle = .rounded
        regenerate.target = self
        regenerate.action = #selector(regenerateTapped)
        files.title = "Show Subtitle Files in Finder"
        files.bezelStyle = .rounded
        files.target = self
        files.action = #selector(filesTapped)
        addRow(
            "Current video",
            stack(
                [
                    line([regenerate, files]),
                    caption(
                        "Changing the speech model, the spoken language or the translation language makes Vidac create this video’s subtitles again."
                    ),
                ], spacing: 8))

        controlsForState = [
            auto, model, language, translate, target, mode, size, delayMinus, delayPlus, delayReset, location,
        ]
    }

    private func configure(_ popup: NSPopUpButton, _ action: Selector, width: CGFloat) {
        popup.target = self
        popup.action = action
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    private func configureCaption(_ label: NSTextField) {
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.contentWidth
        label.maximumNumberOfLines = 0
    }
    private func titleLabelPlain(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: Refresh

    /// Selects the item for `code`, adding one for a value the list does not know.
    private func select(_ popup: NSPopUpButton, _ code: String, custom: (String) -> String) {
        if let index = popup.itemArray.firstIndex(where: { Self.stripped($0.representedObject) == code }) {
            popup.selectItem(at: index)
            return
        }
        // Drop an earlier stand-in before adding the new one.
        if let old = popup.itemArray.first(where: { ($0.representedObject as? String)?.hasPrefix("\u{1}") == true }) {
            popup.menu?.removeItem(old)
        }
        popup.addItem(withTitle: custom(code))
        popup.lastItem?.representedObject = "\u{1}" + code
        popup.selectItem(at: popup.numberOfItems - 1)
    }

    override func refresh() {
        let usable = player.subtitlesControllable
        let state = player.subtitleState
        bannerStack.isHidden = usable
        if !usable {
            switch player.subtitleAvailability {
            case .running: banner.stringValue = "Starting subtitles… These settings can be changed in a moment."
            case .restarting:
                banner.stringValue = "The subtitle component stopped and is starting again. These settings can be changed once it is back."
            default:
                banner.stringValue =
                    "The subtitle component isn’t running, so these settings can’t be changed right now. Playback isn’t affected."
            }
            restart.isHidden = player.subtitleAvailability == .running || player.subtitleAvailability == .restarting
        }
        for control in controlsForState { control.isEnabled = usable }
        auto.state = player.subtitleValue("enabled") == "true" ? .on : .off

        let modelCode = player.subtitleValue("model")
        select(model, modelCode) { "\($0) (custom)" }
        if let preset = SubtitleModels.preset(modelCode) {
            modelCaption.stringValue = preset.summary + " Downloads once, about \(preset.size), the first time it is used."
        } else {
            modelCaption.stringValue = "A custom speech model chosen outside the app."
        }
        select(language, player.subtitleValue("language")) { SubtitleFormat.language($0) }
        translate.state = player.translationOn ? .on : .off
        select(target, player.subtitleValue("target_lang")) { SubtitleFormat.targetLanguage($0) }
        target.isEnabled = usable && player.translationOn

        var translationNote: [String] = []
        let engine = state?.translation.engine
        if engine == "apple" {
            translationNote.append("Translation runs on this Mac with Apple Intelligence.")
        } else if engine == "openai" {
            translationNote.append("Translation uses the language-model server you set up.")
        }
        var showSettingsButton = false
        if let translation = state?.translation, let reason = translation.reason, player.translationOn {
            translationNote.append(reason)
            showSettingsButton =
                SubtitleNotice.mentionsAppleIntelligence(reason) && (translation.state == .unavailable || translation.state == .error)
        }
        translationCaption.stringValue = translationNote.joined(separator: "\n")
        translationCaption.isHidden = translationNote.isEmpty
        translationButton.isHidden = !showSettingsButton

        select(mode, player.subtitleValue("display_mode")) { $0 }
        // The same modes as the menu and the popover offer: translated ones need translation on.
        mode.autoenablesItems = false
        for item in mode.itemArray { item.isEnabled = player.displayModeAvailable(code(item) ?? "off") }
        if !draggingSize {
            size.doubleValue = player.subtitleScale
            sizeValue.stringValue = SubtitleFormat.scale(player.subtitleScale)
        }
        delayValue.stringValue = SubtitleFormat.delay(player.subtitleDelay)
        let canDelay = usable && player.hasVideo
        delayMinus.isEnabled = canDelay && player.subtitleDelay > -60 + 0.04
        delayPlus.isEnabled = canDelay && player.subtitleDelay < 60 - 0.04
        delayReset.isEnabled = canDelay && abs(player.subtitleDelay) >= 0.05
        delayCaption.stringValue =
            player.hasVideo
            ? "Positive values show subtitles later. Each video remembers its own delay. Hold Option for 0.5 s steps."
            : "Open a video to adjust its delay. Each video remembers its own."
        select(location, player.subtitleValue("subtitle_location")) { $0 }
        locationCaption.stringValue =
            player.subtitleValue("subtitle_location") == "library"
            ? "Subtitle files are kept in ~/Library/Application Support/vidac/subtitles. Existing files for this video are moved there."
            : "Subtitle files are saved next to the video, such as Movie.vidac.ja.srt. Existing files for this video are moved there."
        regenerate.isEnabled = usable && player.hasVideo && player.subtitleCanRegenerate
        files.isEnabled = !player.existingSubtitleFiles.isEmpty
    }

    // MARK: Actions

    private static func stripped(_ object: Any?) -> String? {
        guard let value = object as? String else { return nil }
        return value.hasPrefix("\u{1}") ? String(value.dropFirst()) : value
    }
    private func code(_ popup: NSPopUpButton) -> String? { Self.stripped(popup.selectedItem?.representedObject) }
    private func code(_ item: NSMenuItem) -> String? { Self.stripped(item.representedObject) }
    @objc private func toggleAuto(_ sender: NSButton) { player.sendSubtitleSetting("enabled", sender.state == .on ? "true" : "false") }
    /// These settings make the companion discard and redo what it generated for the video, so ask first
    /// when there is something to lose (a subtitle file that came with the video is not touched by
    /// the speech settings). Cancelling puts the control back to what the companion reports.
    private func changeWithConfirmation(_ what: String, key: String, value: String, speechOnly: Bool) {
        guard player.hasVideo, let state = player.subtitleState, state.hasGeneratedSubtitles,
            !(speechOnly && state.source == .sidecar), let window = window
        else {
            player.sendSubtitleSetting(key, value)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Change the \(what) and redo the subtitles?"
        alert.informativeText =
            "The subtitles Vidac made for “\(player.currentURL?.lastPathComponent ?? "this video")” are discarded and created again with the new choice. This can take a while."
        alert.addButton(withTitle: "Change and Redo")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.player.sendSubtitleSetting(key, value)
            } else {
                self?.refresh()
            }
        }
    }
    @objc private func changeModel(_ sender: NSPopUpButton) {
        if let value = code(sender) { changeWithConfirmation("speech model", key: "model", value: value, speechOnly: true) }
    }
    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        if let value = code(sender) { changeWithConfirmation("spoken language", key: "language", value: value, speechOnly: true) }
    }
    @objc private func toggleTranslate(_ sender: NSButton) {
        player.sendSubtitleSetting("translate", sender.state == .on ? "true" : "false")
        target.isEnabled = player.subtitlesControllable && sender.state == .on
    }
    @objc private func changeTarget(_ sender: NSPopUpButton) {
        if let value = code(sender) { changeWithConfirmation("translation language", key: "target_lang", value: value, speechOnly: false) }
    }
    @objc private func changeMode(_ sender: NSPopUpButton) {
        guard let value = code(sender) else { return }
        if value != "off" { UserDefaults.standard.set(value, forKey: "SubtitleLastDisplayMode") }
        player.sendSubtitleSetting("display_mode", value)
    }
    @objc private func changeSize(_ sender: NSSlider) {
        let value = min(3, max(0.5, (sender.doubleValue * 20).rounded() / 20))
        sizeValue.stringValue = SubtitleFormat.scale(value)
        // While the knob is held the label follows; the setting is sent once it is let go.
        let type = NSApp.currentEvent?.type
        draggingSize = type == .leftMouseDragged || type == .leftMouseDown
        if !draggingSize { player.sendSubtitleSetting("font_scale", String(format: "%g", value)) }
    }
    private var coarse: Bool { NSApp.currentEvent?.modifierFlags.contains(.option) == true }
    @objc private func delayDown() { player.nudgeSubtitleDelay(coarse ? -0.5 : -0.1) }
    @objc private func delayUp() { player.nudgeSubtitleDelay(coarse ? 0.5 : 0.1) }
    @objc private func delayZero() { player.resetSubtitleDelay() }
    @objc private func changeLocation(_ sender: NSPopUpButton) {
        if let value = code(sender) { player.sendSubtitleSetting("subtitle_location", value) }
    }
    @objc private func restartTapped() { player.restartSubtitles() }
    @objc private func regenerateTapped() { player.regenerateSubtitles() }
    @objc private func filesTapped() { player.showSubtitleFiles() }
    @objc private func openSystemSettings() { PlayerController.openAppleIntelligenceSettings() }
}

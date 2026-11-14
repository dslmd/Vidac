import AppKit

extension NSMenu {
    /// Appends an item. `modifiers` only matters when `key` is given; pass `[]`
    /// for a bare key such as Space.
    @discardableResult
    func add(_ title: String, _ action: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject?)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = target
        addItem(item)
        return item
    }
    /// Appends an empty submenu and returns it.
    func addSubmenu(_ title: String) -> NSMenu {
        let submenu = NSMenu(title: title)
        add(title, nil, target: nil).submenu = submenu
        return submenu
    }
}

private func functionKey(_ code: Int) -> String { String(UnicodeScalar(UInt16(code)).map(Character.init) ?? " ") }

extension AppDelegate {
    /// The menu bar. Playback items carry the same bare keys the picture
    /// handles itself, so the menus double as the list of shortcuts.
    func installMenus(for player: PlayerController) {
        let main = NSMenu()
        let left = functionKey(NSLeftArrowFunctionKey), right = functionKey(NSRightArrowFunctionKey)
        let up = functionKey(NSUpArrowFunctionKey), down = functionKey(NSDownArrowFunctionKey)

        let app = main.addSubmenu("Vidac")
        app.add("About Vidac", #selector(about), target: self)
        // Appears only once a newer release is known (UpdateChecker).
        let update = app.add("Update Available…", #selector(showAvailableUpdate), target: self)
        update.isHidden = updates.available == nil
        updateMenuItem = update
        app.add("Check for Updates…", #selector(checkForUpdates), target: self)
        app.addItem(.separator())
        app.add("Settings…", #selector(PlayerController.showSettings), key: ",", target: player)
        app.add("Make Default Video Player…", #selector(makeDefaultPlayer), target: self)
        app.addItem(.separator())
        NSApp.servicesMenu = app.addSubmenu("Services")
        app.addItem(.separator())
        app.add("Hide Vidac", #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        app.add("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], target: NSApp)
        app.add("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        app.add("Quit Vidac", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)

        let file = main.addSubmenu("File")
        file.add("Open…", #selector(PlayerController.chooseFile), key: "o", target: player)
        file.add("Open Recent", nil, target: nil).submenu = player.recentMenu
        file.addItem(.separator())
        file.add("Show in Finder", #selector(PlayerController.revealInFinder), target: player)
        file.addItem(.separator())
        // Goes to the key window: a panel closes, a video returns to the welcome page.
        file.add("Close", #selector(NSWindow.performClose(_:)), key: "w", target: nil)

        let edit = main.addSubmenu("Edit")
        edit.add("Undo", Selector(("undo:")), key: "z", target: nil)
        edit.add("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift], target: nil)
        edit.addItem(.separator())
        edit.add("Cut", #selector(NSText.cut(_:)), key: "x", target: nil)
        edit.add("Copy", #selector(NSText.copy(_:)), key: "c", target: nil)
        edit.add("Paste", #selector(NSText.paste(_:)), key: "v", target: nil)
        edit.add("Select All", #selector(NSText.selectAll(_:)), key: "a", target: nil)

        let playback = main.addSubmenu("Playback")
        playback.add("Play", #selector(PlayerController.togglePause), key: " ", modifiers: [], target: player)
        playback.addItem(.separator())
        for (title, seconds, key, modifiers) in [
            ("Skip Back 5 Seconds", -5.0, left, NSEvent.ModifierFlags()), ("Skip Forward 5 Seconds", 5.0, right, []),
            ("Skip Back 30 Seconds", -30.0, left, .option), ("Skip Forward 30 Seconds", 30.0, right, .option),
        ] {
            playback.add(title, #selector(PlayerController.menuSeek(_:)), key: key, modifiers: modifiers, target: player)
                .representedObject = seconds
        }
        playback.add("Previous Frame", #selector(PlayerController.previousFrame), key: ",", modifiers: [], target: player)
        playback.add("Next Frame", #selector(PlayerController.nextFrame), key: ".", modifiers: [], target: player)
        playback.addItem(.separator())
        playback.add(
            "Go to Beginning", #selector(PlayerController.goToBeginning), key: functionKey(NSHomeFunctionKey), modifiers: [], target: player
        )
        playback.add("Go to Time…", #selector(PlayerController.goToTime), key: "j", target: player)
        playback.addItem(.separator())
        playback.add("Next Video", #selector(PlayerController.playNext), key: right, target: player)
        playback.add("Previous Video", #selector(PlayerController.playPrevious), key: left, target: player)
        playback.add("Play Next Automatically", #selector(PlayerController.toggleAutoAdvance), target: player)
        playback.addItem(.separator())
        let speed = playback.addSubmenu("Speed")
        player.addSpeedItems(to: speed)
        speed.addItem(.separator())
        speed.add("Faster", #selector(PlayerController.speedUp), key: "]", modifiers: [], target: player)
        speed.add("Slower", #selector(PlayerController.speedDown), key: "[", modifiers: [], target: player)
        speed.add("Reset Speed", #selector(PlayerController.resetSpeed), key: "\u{8}", modifiers: [], target: player)
        playback.addItem(.separator())
        playback.add("Volume Up", #selector(PlayerController.volumeUp), key: up, modifiers: [], target: player)
        playback.add("Volume Down", #selector(PlayerController.volumeDown), key: down, modifiers: [], target: player)
        playback.add("Mute", #selector(PlayerController.toggleMute), key: "m", modifiers: [], target: player)

        let video = main.addSubmenu("Video")
        video.add("Zoom In", #selector(PlayerController.zoomIn), key: "=", target: player)
        video.add("Zoom Out", #selector(PlayerController.zoomOut), key: "-", target: player)
        video.add("Actual Size", #selector(PlayerController.resetZoom), key: "0", target: player)
        video.addItem(.separator())
        // Sent to the player window itself, which retitles the item to Exit Full Screen.
        video.add(
            "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control], target: player.window)
        video.add("Float on Top", #selector(PlayerController.toggleFloatOnTop), key: "t", modifiers: [.command, .control], target: player)
        video.addItem(.separator())
        video.add("Take Screenshot", #selector(PlayerController.takeScreenshot), key: "s", modifiers: [], target: player)

        // The Subtitles menu is filled by PlayerController.buildSubtitlesMenu (SubtitleControls.swift).
        player.buildSubtitlesMenu(main.addSubmenu("Subtitles"))

        let window = main.addSubmenu("Window")
        window.add("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", target: nil)
        window.add("Zoom", #selector(NSWindow.performZoom(_:)), target: nil)
        window.addItem(.separator())
        window.add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = window

        // STAGE 2: the Help menu is filled by PlayerController.buildHelpMenu (PlayerHooks.swift).
        let help = main.addSubmenu("Help")
        player.buildHelpMenu(help)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }
}

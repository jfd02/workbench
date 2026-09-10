import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        // Carry over anything the old UserDefaults build stored.
        PinnedSites.migrateFromUserDefaultsIfNeeded()

        if let error = AppDatabase.shared.openError {
            Ghostty.logger.warning("database unavailable: \(error, privacy: .public)")
        }

        // Agent status. The self-test runs against the user's real home
        // directory, so it must not rewrite their Claude settings — it checks
        // the merge against fixtures instead.
        AgentActivityStore.shared.start()
        if !SelfTest.isEnabled {
            ClaudeHooks.install()
        }

        if let error = GhosttyApp.shared.startupError {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Ghostty failed to start"
            alert.informativeText = error
            alert.runModal()
        }

        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)

        if SelfTest.isEnabled {
            // Deliberately skip activation: the harness must not take focus
            // away from whatever the user is doing.
            SelfTest.start(controller)
        } else {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // libghostty needs to know when the keyboard layout changes so it can
        // retranslate keys.
        NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            GhosttyApp.shared.keyboardChanged()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        GhosttyApp.shared.setFocus(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        GhosttyApp.shared.setFocus(false)
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About TabTerm",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide TabTerm",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit TabTerm",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "New Tab…",
            action: #selector(newTab(_:)),
            keyEquivalent: "t"
        )
        fileMenu.addItem(
            withTitle: "Close Tab",
            action: #selector(closeTab(_:)),
            keyEquivalent: "w"
        )
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu — these route into the terminal/web view via the responder chain.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        // nil target: this routes down the responder chain to the split view.
        let sidebarItem = viewMenu.addItem(
            withTitle: "Toggle Sidebar",
            action: #selector(NSSplitViewController.toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebarItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "Split Right",
            action: #selector(splitRight(_:)),
            keyEquivalent: "d"
        )
        let splitDownItem = viewMenu.addItem(
            withTitle: "Split Down",
            action: #selector(splitDown(_:)),
            keyEquivalent: "d"
        )
        splitDownItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(
            withTitle: "Equalize Splits",
            action: #selector(equalizeSplits(_:)),
            keyEquivalent: ""
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "Show Next Tab",
            action: #selector(nextTab(_:)),
            keyEquivalent: "]"
        )
        viewMenu.addItem(
            withTitle: "Show Previous Tab",
            action: #selector(previousTab(_:)),
            keyEquivalent: "["
        )
        viewMenu.addItem(.separator())
        for index in 1...9 {
            let item = NSMenuItem(
                title: "Tab \(index)",
                action: #selector(selectTabByIndex(_:)),
                keyEquivalent: "\(index)"
            )
            item.tag = index - 1
            // Not hidden: AppKit skips hidden items when matching key
            // equivalents, so hiding these made ⌘2…⌘9 do nothing at all.
            // validateMenuItem greys out the ones with no tab behind them.
            viewMenu.addItem(item)
        }
        viewMenu.addItem(.separator())
        for index in 1...9 {
            let item = NSMenuItem(
                title: "Workspace \(index)",
                action: #selector(selectWorkspaceByIndex(_:)),
                keyEquivalent: "\(index)"
            )
            item.keyEquivalentModifierMask = [.command, .shift]
            item.tag = index - 1
            viewMenu.addItem(item)
        }
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    /// The numbered tab items, for the self-test.
    var tabShortcutItems: [NSMenuItem] {
        NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter { $0.action == #selector(selectTabByIndex(_:)) } ?? []
    }

    /// The numbered workspace items, for the self-test.
    var workspaceShortcutItems: [NSMenuItem] {
        NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter { $0.action == #selector(selectWorkspaceByIndex(_:)) } ?? []
    }

    // MARK: - Menu actions

    @objc private func newTab(_ sender: Any?) {
        MainWindowController.current?.presentNewTabDialog()
    }

    @objc private func closeTab(_ sender: Any?) {
        MainWindowController.current?.closeSelectedTab()
    }

    @objc private func nextTab(_ sender: Any?) {
        MainWindowController.current?.selectNextTab()
    }

    @objc private func previousTab(_ sender: Any?) {
        MainWindowController.current?.selectPreviousTab()
    }

    @objc private func selectTabByIndex(_ sender: NSMenuItem) {
        MainWindowController.current?.selectTab(at: sender.tag)
    }

    @objc private func selectWorkspaceByIndex(_ sender: NSMenuItem) {
        MainWindowController.current?.selectWorkspace(at: sender.tag)
    }

    @objc private func splitRight(_ sender: Any?) {
        MainWindowController.current?.splitFocusedPane(.right)
    }

    @objc private func splitDown(_ sender: Any?) {
        MainWindowController.current?.splitFocusedPane(.down)
    }

    @objc private func equalizeSplits(_ sender: Any?) {
        MainWindowController.current?.selectedTab?.equalizeSplits()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Grey out tab shortcuts past the number of open tabs.
        if menuItem.action == #selector(selectTabByIndex(_:)) {
            return menuItem.tag < (MainWindowController.current?.tabSnapshot.count ?? 0)
        }
        if menuItem.action == #selector(selectWorkspaceByIndex(_:)) {
            return menuItem.tag
                < (MainWindowController.current?.orderedWorkspaceKeys.count ?? 0)
        }

        guard let tab = MainWindowController.current?.selectedTab else { return true }

        switch menuItem.action {
        case #selector(closeTab(_:)):
            // ⌘W closes the focused split first, so say which one it means.
            menuItem.title = tab.paneCount > 1 ? "Close Split" : "Close Tab"
        case #selector(equalizeSplits(_:)):
            return tab.paneCount > 1
        default:
            break
        }
        return true
    }
}

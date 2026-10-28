import AppKit
import TabTermKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        if let error = AppDatabase.shared.openError {
            Ghostty.logger.warning("database unavailable: \(error, privacy: .public)")
        }

        // Agent status. The self-test runs against the user's real home
        // directory, so it must not rewrite their Claude settings — it checks
        // the merge against fixtures instead.
        AgentActivityStore.shared.start()
        if !SelfTest.isEnabled, !AppSupport.isOverridden {
            AgentHooks.install()
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

        // Phones. Not for the self-test, which starts its own on the loopback.
        if !SelfTest.isEnabled {
            AgentCompletionSound.shared.start()
            RemoteServer.shared.start()
            AgentNotifier.shared.start()
            for name in [RemoteServer.didChange, PairingStore.didChange] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Self.updateSleepGuard()
                }
            }
            Self.updateSleepGuard()

            // `--pairing-link` prints a fresh one-time link, for pairing a
            // simulator or a phone without scanning the screen.
            if CommandLine.arguments.contains("--pairing-link") {
                Self.printPairingLink()
            }
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

    private static func printPairingLink() {
        guard case .listening(let address, let port) = RemoteServer.shared.status else {
            print("Workbench isn't accepting phones: \(RemoteServer.shared.status)")
            return
        }
        let link = PairingLink(
            name: Host.current().localizedName ?? "Mac",
            hosts: [address.ip] + (address.dnsName.map { [$0] } ?? []),
            port: port,
            code: PairingStore.makeCode()
        )
        print(link.url.absoluteString)
        fflush(stdout)
    }

    /// Stay awake while a paired phone may want this Mac.
    private static func updateSleepGuard() {
        let listening: Bool
        if case .listening = RemoteServer.shared.status { listening = true } else { listening = false }
        SleepGuard.update(active: listening && !PairingStore.devices.isEmpty)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The sessions' shells get their hangup when the process exits and the
        // ptys close with it; only the socket file would be left behind.
        SessionManager.shared.shutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        GhosttyApp.shared.setFocus(true)
        windowController?.acknowledgeVisibleAgents()
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
            withTitle: "About Workbench",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Pair iPhone…",
            action: #selector(pairIPhone(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let soundItem = appMenu.addItem(withTitle: "Agent Completion Sound", action: nil, keyEquivalent: "")
        soundItem.submenu = makeSoundMenu()
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Workbench",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Workbench",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "New Tab",
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

        // Edit menu — these route into the terminal via the responder chain.
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
        let changesItem = viewMenu.addItem(withTitle: "Show Changes", action: #selector(showChanges(_:)), keyEquivalent: "g")
        changesItem.keyEquivalentModifierMask = [.command, .shift]
        let ciItem = viewMenu.addItem(withTitle: "Show CI Checks", action: #selector(showCIChecks(_:)), keyEquivalent: "i")
        ciItem.keyEquivalentModifierMask = [.command, .shift]
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
        let moveSplitItem = viewMenu.addItem(
            withTitle: "Move Split to New Tab",
            action: #selector(moveSplitToNewTab(_:)),
            keyEquivalent: "t"
        )
        moveSplitItem.keyEquivalentModifierMask = [.command, .shift]
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

    @objc private func pairIPhone(_ sender: Any?) {
        PairingWindowController.shared.present()
    }

    @objc private func newTab(_ sender: Any?) {
        MainWindowController.current?.addTab()
    }

    @objc private func closeTab(_ sender: Any?) {
        MainWindowController.current?.closeSelectedTab()
    }

    @objc private func showChanges(_ sender: Any?) {
        MainWindowController.current?.toggleChangesPanel()
    }

    @objc private func showCIChecks(_ sender: Any?) {
        MainWindowController.current?.toggleCIPanel()
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

    @objc private func moveSplitToNewTab(_ sender: Any?) {
        MainWindowController.current?.moveFocusedPaneToNewTab()
    }

    private func makeSoundMenu() -> NSMenu {
        let menu = NSMenu(title: "Agent Completion Sound")
        let none = menu.addItem(withTitle: "None", action: #selector(selectAgentSound(_:)), keyEquivalent: "")
        none.representedObject = "none"
        menu.addItem(.separator())
        for name in AgentCompletionSound.presets {
            let item = menu.addItem(withTitle: name, action: #selector(selectAgentSound(_:)), keyEquivalent: "")
            item.representedObject = name
        }
        menu.addItem(.separator())
        let custom = menu.addItem(withTitle: "Custom Sound", action: #selector(selectAgentSound(_:)), keyEquivalent: "")
        custom.representedObject = "custom"
        menu.addItem(withTitle: "Choose Custom Sound…", action: #selector(chooseAgentSound(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preview Sound", action: #selector(previewAgentSound(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func selectAgentSound(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if name == "none" {
            AgentCompletionSound.isEnabled = false
        } else {
            AgentCompletionSound.select(name)
            AgentCompletionSound.playSelectedSound()
        }
    }

    @objc private func chooseAgentSound(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose Agent Completion Sound"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AgentCompletionSound.importCustomSound(from: url)
            AgentCompletionSound.playSelectedSound()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t use this sound"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func previewAgentSound(_ sender: Any?) {
        AgentCompletionSound.playSelectedSound()
    }

    @objc private func equalizeSplits(_ sender: Any?) {
        MainWindowController.current?.selectedTab?.equalizeSplits()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showChanges(_:)) || menuItem.action == #selector(showCIChecks(_:)) {
            return MainWindowController.current?.currentWorkspaceKey.worktreeId != nil
        }
        if menuItem.action == #selector(selectAgentSound(_:)), let name = menuItem.representedObject as? String {
            let selected = AgentCompletionSound.isEnabled ? AgentCompletionSound.selectedSound : "none"
            menuItem.state = selected == name ? .on : .off
            if name == "custom" {
                menuItem.title = AgentCompletionSound.customName.map { "Custom: \($0)" } ?? "Custom Sound"
                return AgentCompletionSound.customName != nil
            }
            return true
        }
        if menuItem.action == #selector(previewAgentSound(_:)) { return AgentCompletionSound.isEnabled }
        // Grey out tab shortcuts past the number of open tabs.
        if menuItem.action == #selector(selectTabByIndex(_:)) {
            return menuItem.tag < (MainWindowController.current?.tabSnapshot.count ?? 0)
        }
        if menuItem.action == #selector(selectWorkspaceByIndex(_:)) {
            return menuItem.tag
                < (MainWindowController.current?.orderedWorkspaceKeys.count ?? 0)
        }

        if menuItem.action == #selector(moveSplitToNewTab(_:)) {
            return (MainWindowController.current?.selectedTab?.paneCount ?? 0) > 1
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

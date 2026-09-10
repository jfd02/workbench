import AppKit

/// The app's window. It reports first-responder changes so the selected tab can
/// tell which pane is focused, whatever kind of view holds it.
final class MainWindow: NSWindow {
    var onFirstResponderChange: ((NSResponder?) -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { onFirstResponderChange?(responder) }
        return accepted
    }
}

/// The main window: a tab strip on top, the selected tab's panes below.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// The frontmost controller, so libghostty actions can route to it.
    static weak var current: MainWindowController?

    /// One tab set per workspace: Home, plus one for every worktree.
    private var workspaces: [WorkspaceKey: Workspace] = [:]
    private(set) var currentWorkspaceKey: WorkspaceKey = .home

    private let tabBar = TabBarView(frame: .zero)
    private let contentContainer = NSView()
    private let sidebar = SidebarViewController()
    private let emptyStateLabel = NSTextField(labelWithString: "No tabs — press ⌘T to open one")
    private var currentContentView: NSView?
    private var pendingFrameSave: DispatchWorkItem?
    private var pendingTabSave: DispatchWorkItem?

    /// The workspace on screen.
    var currentWorkspace: Workspace { workspace(for: currentWorkspaceKey) }

    /// The current workspace's tabs. Reads and writes go through the workspace
    /// so the rest of this controller can stay written in terms of tabs.
    private var tabs: [Tab] {
        get { currentWorkspace.tabs }
        set { currentWorkspace.tabs = newValue }
    }

    private var selectedID: UUID? {
        get { currentWorkspace.selectedID }
        set { currentWorkspace.selectedID = newValue }
    }

    var selectedTab: Tab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    /// Read-only view of the tab list, used by the self-test harness.
    var tabSnapshot: [(id: UUID, title: String, kind: TabKind)] {
        tabs.map { ($0.id, $0.title, $0.kind) }
    }

    var selectedTabID: UUID? { selectedID }

    /// The focused pane's content: what menu actions and the self-test act on.
    var selectedTabContent: TabContent? { selectedTab?.focusedPane?.content }

    convenience init() {
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TabTerm"
        // The tab strip already says what's open; the titlebar repeating "~"
        // adds nothing. The title is still set, so the Window menu and the app
        // switcher have something to show.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 480, height: 320)
        window.tabbingMode = .disallowed

        self.init(window: window)
        window.delegate = self
        window.onFirstResponderChange = { [weak self] responder in
            self?.selectedTab?.firstResponderDidChange(responder)
        }
        MainWindowController.current = self

        buildLayout()

        // Only now: assigning contentViewController resizes the window to the
        // split view's fitting size, which would undo a restored frame.
        restoreWindowFrame()

        // Re-open whatever was showing last time, falling back to Home. The
        // workspace materializes its own tabs, so this also restores them.
        let restored = AppState.string(forKey: Self.workspaceStateKey)
            .flatMap(WorkspaceKey.init(stateValue:))
        selectWorkspace(restored.flatMap(validWorkspaceKey) ?? .home)
    }

    /// Drop a remembered worktree that no longer exists.
    private func validWorkspaceKey(_ key: WorkspaceKey) -> WorkspaceKey? {
        guard case .worktree(let id) = key else { return key }
        return RepositoryStore.worktree(id: id) == nil ? nil : key
    }

    private func buildLayout() {
        guard let window else { return }

        // Right-hand side: the tab strip over the selected tab's panes.
        let main = NSView()
        main.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        main.addSubview(tabBar)
        main.addSubview(contentContainer)
        contentContainer.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: main.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: main.trailingAnchor),

            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: main.bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
        ])

        let mainController = NSViewController()
        mainController.view = main

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: mainController))
        window.contentViewController = split

        let width = AppState.string(forKey: Self.sidebarWidthKey).flatMap(Double.init) ?? 220
        split.splitView.setPosition(width, ofDividerAt: 0)

        sidebar.onSelect = { [weak self] node in
            guard let key = node.workspaceKey else { return }
            self?.selectWorkspace(key)
        }
        sidebar.onStructureChange = { [weak self] in
            self?.pruneWorkspaces()
        }
        sidebar.agentState = { [weak self] key in
            self?.agentState(for: key) ?? .idle
        }
        AgentActivityStore.shared.onChange = { [weak self] in
            self?.agentsDidChange()
        }

        tabBar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        tabBar.onNewTab = { [weak self] in self?.presentNewTabDialog() }
        tabBar.onSelectTab = { [weak self] id in self?.selectTab(id) }
        tabBar.onCloseTab = { [weak self] id in self?.requestCloseTab(id) }
    }

    /// The left panel, so the self-test can exercise its menus.
    var sidebarPanel: SidebarViewController { sidebar }

    /// Rebuild the sidebar from the database, keeping the current selection.
    func reloadSidebar() {
        sidebar.reload(selecting: currentWorkspaceKey)
    }

    /// Show or hide the sidebar. Driven by the tab bar's button and ⌃⌘S.
    @objc func toggleSidebar() {
        (window?.contentViewController as? NSSplitViewController)?.toggleSidebar(nil)
    }

    /// True when the sidebar is hidden, so the button can reflect it.
    var isSidebarCollapsed: Bool {
        (window?.contentViewController as? NSSplitViewController)?
            .splitViewItems.first?.isCollapsed ?? false
    }

    // MARK: - Workspaces

    private func workspace(for key: WorkspaceKey) -> Workspace {
        if let existing = workspaces[key] { return existing }
        let created = makeWorkspace(for: key)
        workspaces[key] = created
        return created
    }

    private func makeWorkspace(for key: WorkspaceKey) -> Workspace {
        switch key {
        case .home:
            return Workspace(key: .home, name: "Home", directory: nil)

        case .worktree(let id):
            guard let worktree = RepositoryStore.worktree(id: id) else {
                return Workspace(key: key, name: "Worktree", directory: nil)
            }
            let repository = RepositoryStore.repository(id: worktree.repositoryId)
            let name = repository.map { "\($0.name) — \(worktree.displayName)" }
                ?? worktree.displayName
            return Workspace(key: key, name: name, directory: worktree.path)
        }
    }

    /// Every workspace in sidebar order: Home, then each repository's
    /// worktrees. This is what ⌘⇧1…⌘⇧9 count through.
    var orderedWorkspaceKeys: [WorkspaceKey] {
        var keys: [WorkspaceKey] = [.home]
        for repository in RepositoryStore.all {
            for worktree in RepositoryStore.worktrees(ofRepository: repository.id ?? -1) {
                if let id = worktree.id { keys.append(.worktree(id)) }
            }
        }
        return keys
    }

    /// ⌘⇧N: jump to the Nth workspace.
    func selectWorkspace(at index: Int) {
        let keys = orderedWorkspaceKeys
        guard index >= 0, index < keys.count else { return }
        selectWorkspace(keys[index])
    }

    /// Show a workspace, building its tabs the first time it's visited.
    func selectWorkspace(_ key: WorkspaceKey) {
        if key != currentWorkspaceKey {
            // Park the outgoing workspace: its tabs stay alive, just hidden.
            currentWorkspace.selectedTab?.setVisible(false)
            currentWorkspace.persist()
            currentContentView?.removeFromSuperview()
            currentContentView = nil
        }

        currentWorkspaceKey = key
        AppState.set(key.stateValue, forKey: Self.workspaceStateKey)
        if let worktreeId = key.worktreeId {
            WorktreeActivity.markUsed(worktreeId)
        }

        let workspace = currentWorkspace
        workspace.materialize { layout in
            self.makeTab(from: layout, directory: workspace.directory)
        }

        if let selected = workspace.selectedID ?? workspace.tabs.first?.id {
            selectTab(selected)
        } else {
            refreshTabBar()
            updateWindowTitle()
            updateEmptyState()
        }
        // Opening a worktree is how the user answers its dot.
        acknowledgeVisibleAgents()
        sidebar.select(key)
        sidebar.refreshAgentStates()
    }

    /// Forget workspaces whose worktree is gone, closing anything open in them.
    private func pruneWorkspaces() {
        var live: Set<Int64> = []
        for repository in RepositoryStore.all {
            for worktree in RepositoryStore.worktrees(ofRepository: repository.id ?? -1) {
                if let id = worktree.id { live.insert(id) }
            }
        }

        var currentWasRemoved = false
        for (key, workspace) in workspaces {
            guard case .worktree(let id) = key, !live.contains(id) else { continue }
            for tab in workspace.tabs { tab.closeAll() }
            workspaces.removeValue(forKey: key)
            if key == currentWorkspaceKey { currentWasRemoved = true }
        }

        if currentWasRemoved {
            currentContentView?.removeFromSuperview()
            currentContentView = nil
            selectWorkspace(.home)
        }
    }

    private func updateEmptyState() {
        emptyStateLabel.isHidden = !tabs.isEmpty
    }

    // MARK: - Agents

    /// Every terminal in a workspace that could have an agent running in it.
    ///
    /// Read straight out of the dictionary rather than through `workspace(for:)`
    /// so drawing the sidebar never materializes a workspace — a worktree
    /// nobody has opened has no terminals, and so nothing to report.
    private func agentIDs(in key: WorkspaceKey) -> [String] {
        guard let workspace = workspaces[key], workspace.isMaterialized else { return [] }
        return workspace.tabs
            .flatMap(\.panes)
            .compactMap { ($0.content as? TerminalTabContent)?.agentID }
    }

    /// What the sidebar shows beside a workspace: the most demanding state
    /// among its terminals.
    private func agentState(for key: WorkspaceKey) -> AgentState {
        AgentActivityStore.shared.state(ofAgents: agentIDs(in: key))
    }

    /// The visible workspace's terminals, so the self-test can report an event
    /// against a real one and watch the sidebar answer.
    var visibleAgentIDsForTesting: [String] { agentIDs(in: currentWorkspaceKey) }

    /// Mark the visible workspace's finished turns as seen.
    ///
    /// Its terminals are on screen in front of the user, so lighting the row
    /// they are already looking at would only be telling them what they can
    /// see. A blocked agent is not covered — that stays lit until it's answered.
    private func acknowledgeVisibleAgents() {
        AgentActivityStore.shared.acknowledge(agentIDs(in: currentWorkspaceKey))
    }

    private func agentsDidChange() {
        if window?.isKeyWindow == true { acknowledgeVisibleAgents() }
        sidebar.refreshAgentStates()
    }

    /// Throw away the live workspaces so the next selection rebuilds from the
    /// database. Only the self-test needs this; the app keeps them for the
    /// lifetime of the window.
    func discardWorkspacesForTesting() {
        for workspace in workspaces.values {
            for tab in workspace.tabs { tab.closeAll() }
            workspace.tabs.removeAll()
        }
        workspaces.removeAll()
        currentContentView?.removeFromSuperview()
        currentContentView = nil
    }

    // MARK: - Tab management

    /// Show the picker sheet, then create whatever the user chose.
    func presentNewTabDialog() {
        guard let window else { return }

        let dialog = NewTabDialog { [weak self] choice in
            guard let self, let choice else { return }
            switch choice {
            case .terminal:
                self.addTab(.terminal)
            case .browser(let url):
                self.addTab(.browser, url: url)
            }
        }

        let sheet = NSWindow(contentViewController: dialog)
        sheet.styleMask = [.titled]
        window.beginSheet(sheet)
    }

    @discardableResult
    func addTab(_ kind: TabKind, url: URL? = nil) -> Tab {
        let tab = makeTab(kind, url: url, directory: currentWorkingDirectory())
        tabs.append(tab)
        selectTab(tab.id)
        scheduleTabSave()
        return tab
    }

    /// Build a tab and wire it to this window. Used for new tabs and for tabs
    /// restored from the database.
    private func makeTab(_ kind: TabKind, url: URL?, directory: String?) -> Tab {
        let tab = Tab(content: makeContent(kind, url: url, directory: directory))
        adopt(tab)
        return tab
    }

    private func makeContent(_ kind: TabKind, url: URL?, directory: String?) -> TabContent {
        switch kind {
        case .terminal: return TerminalTabContent(workingDirectory: directory)
        case .browser: return BrowserTabContent(initialURL: url)
        }
    }

    /// Rebuild a saved tab, splits and all.
    ///
    /// The tab starts as the tree's leftmost pane, then each split is recreated
    /// by dividing the pane that occupies the space it used to fill.
    private func makeTab(from layout: SavedLayout, directory: String?) -> Tab {
        let leaves = layout.leaves
        let first = leaves.first ?? .pane(kind: "terminal", url: nil, directory: nil, focused: true)

        let tab = makeTab(
            first.tabKind,
            url: first.url,
            directory: first.directory ?? directory
        )
        if let paneID = tab.focusedPaneID {
            restore(layout, in: tab, paneID: paneID, directory: directory)
        }

        // Panes come out in tree order, so the leaves line up with them.
        if let index = leaves.firstIndex(where: \.isFocused), index < tab.panes.count {
            tab.focusPane(tab.panes[index].id, moveResponder: false)
        }
        return tab
    }

    private func restore(
        _ layout: SavedLayout,
        in tab: Tab,
        paneID: UUID,
        directory: String?
    ) {
        guard case .split(let stacked, let ratio, let first, let second) = layout else { return }

        // Splitting right/down keeps the existing pane in the first slot, which
        // is where the saved tree expects it.
        let leaf = second.leaves.first
            ?? .pane(kind: "terminal", url: nil, directory: nil, focused: false)
        let content = makeContent(
            leaf.tabKind,
            url: leaf.url,
            directory: leaf.directory ?? directory
        )

        guard let created = tab.split(paneID, stacked ? .down : .right, content: content) else {
            return
        }
        tab.setRatio(CGFloat(ratio), ofSplitAbove: paneID)

        restore(first, in: tab, paneID: paneID, directory: directory)
        restore(second, in: tab, paneID: created.id, directory: directory)
    }

    /// Wire a tab's callbacks to this window.
    private func adopt(_ tab: Tab) {
        tab.onTitleChange = { [weak self] in
            self?.refreshTabBar()
            self?.updateWindowTitle()
        }
        tab.onFocusChange = { [weak self] in
            self?.refreshTabBar()
            self?.updateWindowTitle()
        }
        tab.onPaneCloseRequest = { [weak self] paneID, confirm in
            guard let self else { return }
            if confirm {
                self.requestClosePane(tabID: tab.id, paneID: paneID)
            } else {
                self.closePane(tabID: tab.id, paneID: paneID)
            }
        }
        tab.onSplitRequest = { [weak self] paneID, direction in
            self?.splitPane(tabID: tab.id, paneID: paneID, direction: direction)
        }
        // A tab can't be dropped into itself: it is already where it is.
        tab.canAcceptTab = { [weak self] draggedID in
            guard let self else { return false }
            return draggedID != tab.id && self.tabs.contains { $0.id == draggedID }
        }
        tab.onDropTab = { [weak self] draggedID, target in
            self?.moveTab(draggedID, into: tab.id, target: target)
        }
    }

    /// Where a new terminal in this workspace should start.
    ///
    /// It inherits the focused terminal's directory the way a real terminal
    /// does, but never wanders outside the worktree the workspace is for.
    private func currentWorkingDirectory() -> String? {
        let root = currentWorkspace.directory
        guard let pwd = (selectedTabContent as? TerminalTabContent)?.pwd else { return root }
        guard let root else { return pwd }
        return pwd == root || pwd.hasPrefix(root + "/") ? pwd : root
    }

    func selectTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }

        if let previous = selectedTab, previous.id != id {
            previous.setVisible(false)
        }

        selectedID = id

        if currentContentView !== tab.view {
            currentContentView?.removeFromSuperview()
            let contentView = tab.view
            contentView.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                contentView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                contentView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
            currentContentView = contentView
        }

        tab.setVisible(true)
        refreshTabBar()
        updateWindowTitle()
        updateEmptyState()
        scheduleTabSave()

        // Tab.focusPane defers the responder change so the surface has its real
        // size first.
        tab.takeFocus()
    }

    /// Close a tab the user asked to close, after confirming.
    ///
    /// Closes triggered by the content itself finishing (a shell that exited)
    /// go straight to `closeTab` instead — there is nothing to discard.
    func requestCloseTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }

        // Only ask when there's something to lose. A tab of idle shells and web
        // pages just closes.
        guard !tab.isDisposable else {
            closeTab(id)
            return
        }

        confirm(
            message: "Close “\(tab.title)”?",
            detail: tab.closeConfirmationDetail,
            button: "Close Tab"
        ) { [weak self] in
            self?.closeTab(id)
        }
    }

    /// Close a tab immediately, no questions asked.
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]

        tab.closeAll()
        if tab.id == selectedID {
            currentContentView?.removeFromSuperview()
            currentContentView = nil
        }
        tabs.remove(at: index)

        // An empty workspace is fine now — the window belongs to the sidebar,
        // not to any one tab set.
        if tabs.isEmpty {
            selectedID = nil
            refreshTabBar()
            updateWindowTitle()
            updateEmptyState()
            scheduleTabSave()
            return
        }

        if id == selectedID {
            selectTab(tabs[min(index, tabs.count - 1)].id)
        } else {
            refreshTabBar()
            scheduleTabSave()
        }
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        selectTab(tabs[index].id)
    }

    func selectNextTab() {
        guard let selectedID,
              let index = tabs.firstIndex(where: { $0.id == selectedID }),
              !tabs.isEmpty
        else { return }
        selectTab(tabs[(index + 1) % tabs.count].id)
    }

    func selectPreviousTab() {
        guard let selectedID,
              let index = tabs.firstIndex(where: { $0.id == selectedID }),
              !tabs.isEmpty
        else { return }
        selectTab(tabs[(index - 1 + tabs.count) % tabs.count].id)
    }

    /// ⌘W: close the focused split, or the whole tab when it is the only one.
    func closeSelectedTab() {
        guard let tab = selectedTab else { return }
        if tab.paneCount > 1, let pane = tab.focusedPane {
            requestClosePane(tabID: tab.id, paneID: pane.id)
        } else {
            requestCloseTab(tab.id)
        }
    }

    // MARK: - Splits

    /// ⌘D / ⌘⇧D: split the focused pane.
    func splitFocusedPane(_ direction: SplitDirection) {
        guard let tab = selectedTab, let pane = tab.focusedPane else { return }
        splitPane(tabID: tab.id, paneID: pane.id, direction: direction)
    }

    /// Divide the space one pane occupies, putting fresh content beside it.
    ///
    /// A terminal splits into another terminal in the same directory; a browser
    /// splits into another view of the same page.
    func splitPane(tabID: UUID, paneID: UUID, direction: SplitDirection) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let pane = tab.pane(for: paneID)
        else { return }

        let content: TabContent
        switch pane.content {
        case let terminal as TerminalTabContent:
            content = TerminalTabContent(workingDirectory: terminal.pwd)
        case let browser as BrowserTabContent:
            content = BrowserTabContent(initialURL: browser.currentURL)
        default:
            content = TerminalTabContent(workingDirectory: currentWorkingDirectory())
        }

        tab.split(paneID, direction, content: content)
        refreshTabBar()
        updateWindowTitle()
    }

    /// Close one split, after confirming.
    func requestClosePane(tabID: UUID, paneID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              let pane = tab.pane(for: paneID)
        else { return }

        guard tab.paneCount > 1 else {
            requestCloseTab(tabID)
            return
        }

        guard !pane.content.isDisposable else {
            closePane(tabID: tabID, paneID: paneID)
            return
        }

        confirm(
            message: "Close “\(pane.content.title)”?",
            detail: pane.content.closeConfirmationDetail,
            button: "Close Split"
        ) { [weak self] in
            self?.closePane(tabID: tabID, paneID: paneID)
        }
    }

    /// Close one split immediately. Closing the last one closes the tab.
    func closePane(tabID: UUID, paneID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }

        if !tab.removePane(paneID) {
            closeTab(tabID)
            return
        }
        refreshTabBar()
        updateWindowTitle()
    }

    /// Move a whole tab into another tab as a split — what dropping a tab onto
    /// a pane does. The dragged tab brings its own splits with it.
    func moveTab(_ draggedID: UUID, into targetID: UUID, target: SplitDropTarget) {
        guard draggedID != targetID,
              let sourceIndex = tabs.firstIndex(where: { $0.id == draggedID }),
              let destination = tabs.first(where: { $0.id == targetID }),
              destination.pane(for: target.paneID) != nil
        else { return }

        let source = tabs.remove(at: sourceIndex)
        destination.insert(source.detachRoot(), target.direction, of: target.paneID)

        if selectedID == draggedID {
            selectedID = destination.id
        }
        selectTab(destination.id)
        refreshTabBar()
        updateWindowTitle()
    }

    // MARK: - Helpers

    private func confirm(
        message: String,
        detail: String,
        button: String,
        then action: @escaping () -> Void
    ) {
        guard let window else {
            action()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = "\u{1b}"

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            action()
        }
    }

    private func refreshTabBar() {
        tabBar.reload(tabs: tabs, selectedID: selectedID)
    }

    private func updateWindowTitle() {
        let workspace = currentWorkspace.name
        guard let tab = selectedTab?.title else {
            window?.title = workspace
            return
        }
        window?.title = currentWorkspaceKey == .home ? tab : "\(tab) — \(workspace)"
    }

    /// Tab changes come in bursts (open, focus, close), so coalesce the writes.
    private func scheduleTabSave() {
        pendingTabSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingTabSave = nil
            self?.currentWorkspace.persist()
        }
        pendingTabSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persistAllWorkspaces() {
        pendingTabSave?.cancel()
        pendingTabSave = nil
        for workspace in workspaces.values {
            workspace.persist()
        }
    }

    // MARK: - NSWindowDelegate

    private static let frameStateKey = "mainWindowFrame"
    private static let workspaceStateKey = "selectedWorkspace"
    private static let sidebarWidthKey = "sidebarWidth"

    /// Resize and move fire continuously while dragging, so coalesce them
    /// instead of opening a write transaction per event.
    private func scheduleWindowFrameSave() {
        pendingFrameSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveWindowFrame() }
        pendingFrameSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Frame lives in SQLite rather than NSWindow's UserDefaults autosave.
    ///
    /// A stored frame is only trusted if it still makes sense: a display that
    /// went away, or a bad value written by an earlier version, shouldn't leave
    /// the window stuck offscreen or shrunk to nothing.
    private func restoreWindowFrame() {
        guard let window else { return }

        if let descriptor = AppState.string(forKey: Self.frameStateKey) {
            window.setFrame(from: descriptor)
            let frame = window.frame
            let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
            if visible, frame.width > window.minSize.width, frame.height > window.minSize.height {
                return
            }
        }

        window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 720), display: false)
        window.center()
    }

    private func saveWindowFrame() {
        pendingFrameSave?.cancel()
        pendingFrameSave = nil
        guard let window else { return }
        AppState.set(window.frameDescriptor, forKey: Self.frameStateKey)
    }

    func windowDidResize(_ notification: Notification) {
        scheduleWindowFrameSave()
    }

    func windowDidMove(_ notification: Notification) {
        scheduleWindowFrameSave()
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
        saveSidebarWidth()
        persistAllWorkspaces()
        AgentActivityStore.shared.onChange = nil

        for workspace in workspaces.values {
            for tab in workspace.tabs { tab.closeAll() }
            workspace.tabs.removeAll()
        }
        workspaces.removeAll()

        if MainWindowController.current === self {
            MainWindowController.current = nil
        }
    }

    private func saveSidebarWidth() {
        guard let split = window?.contentViewController as? NSSplitViewController,
              let sidebarView = split.splitViewItems.first?.viewController.view,
              sidebarView.frame.width > 0
        else { return }
        AppState.set("\(Double(sidebarView.frame.width))", forKey: Self.sidebarWidthKey)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        MainWindowController.current = self
        GhosttyApp.shared.setFocus(true)
        selectedTab?.takeFocus()
        // Coming back to the window counts as looking at what is on screen.
        acknowledgeVisibleAgents()
        sidebar.refreshAgentStates()
    }

    func windowDidResignKey(_ notification: Notification) {
        GhosttyApp.shared.setFocus(false)
    }
}


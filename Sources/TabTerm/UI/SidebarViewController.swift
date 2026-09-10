import AppKit

/// A row in the sidebar outline.
final class SidebarNode: NSObject {
    enum Kind {
        case home
        case repository(Repository)
        case worktree(Worktree)
        /// The "New Worktree" row under a repository's worktrees.
        case newWorktree(Repository)
    }

    let kind: Kind
    var children: [SidebarNode] = []

    init(_ kind: Kind) {
        self.kind = kind
    }

    var title: String {
        switch kind {
        case .home: return "Home"
        case .repository(let repository): return repository.name
        case .worktree(let worktree): return worktree.displayName
        case .newWorktree: return "New Worktree"
        }
    }

    /// The dimmer second line: which folder it is, and when it was last opened.
    var subtitle: String? {
        guard case .worktree(let worktree) = kind else { return nil }
        let folder = URL(fileURLWithPath: worktree.path).lastPathComponent
        guard let when = WorktreeActivity.relativeDescription(
            WorktreeActivity.lastActivity(for: worktree)
        ) else { return folder }
        return "\(folder) · \(when)"
    }

    var symbolName: String? {
        switch kind {
        case .home: return "house"
        // Repositories read as section headers, so they carry no icon.
        case .repository: return nil
        case .worktree(let worktree):
            return worktree.isMain ? "book.closed" : "arrow.triangle.branch"
        case .newWorktree: return "plus"
        }
    }

    var workspaceKey: WorkspaceKey? {
        switch kind {
        case .home: return .home
        case .repository, .newWorktree: return nil
        case .worktree(let worktree): return worktree.id.map { .worktree($0) }
        }
    }

    /// Rows that highlight and act when clicked. Repositories only expand.
    var isSelectable: Bool {
        switch kind {
        case .home, .worktree, .newWorktree: return true
        case .repository: return false
        }
    }

    var isHeader: Bool {
        if case .repository = kind { return true }
        return false
    }

    /// Two-line rows are taller than the plain ones.
    var rowHeight: CGFloat {
        switch kind {
        case .worktree: return 44
        case .repository: return 30
        case .home, .newWorktree: return 30
        }
    }
}

/// A sidebar row.
///
/// Worktrees are two lines — the branch, then which folder it is and when it
/// was last opened. Everything else is a single line.
final class SidebarCellView: NSTableCellView {
    var onAdd: (() -> Void)?

    let addButton = NSButton()
    /// Collapsed to zero when the button is hidden, so rows that don't have one
    /// get the full width for their text.
    private var addButtonWidth: NSLayoutConstraint!
    private let statusDot = AgentStatusDotView()
    /// Same trick as the button: no dot, no reserved space.
    private var statusDotWidth: NSLayoutConstraint!
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")

    /// 1…9 for the workspaces ⌘⇧1…⌘⇧9 can reach, nil beyond that.
    var shortcutNumber: Int? {
        didSet {
            guard shortcutNumber != oldValue else { return }
            shortcutLabel.stringValue = shortcutNumber.map { "⇧⌘\($0)" } ?? ""
            shortcutLabel.isHidden = shortcutNumber == nil
        }
    }

    /// What the badge reads, for the self-test.
    var shortcutTextForTesting: String { shortcutLabel.stringValue }
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { updateAddButton() }
    }

    /// Only repositories can take a new worktree.
    var showsAddButton = false {
        didSet { updateAddButton() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "New worktree"
        )
        addButton.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        addButton.isBordered = false
        addButton.bezelStyle = .inline
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.toolTip = "New worktree from this repository"
        addButton.setAccessibilityIdentifier("newWorktreeButton")
        addButton.isHidden = true
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setContentHuggingPriority(.required, for: .horizontal)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSStackView(views: [label, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        shortcutLabel.font = .systemFont(ofSize: 10, weight: .medium)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.isHidden = true
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(icon)
        addSubview(text)
        addSubview(shortcutLabel)
        addSubview(statusDot)
        addSubview(addButton)
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(
                lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -6),

            shortcutLabel.trailingAnchor.constraint(
                equalTo: statusDot.leadingAnchor, constant: -4),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // A row never has both, but chaining them means neither has to know
            // that.
            statusDot.trailingAnchor.constraint(equalTo: addButton.leadingAnchor),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.heightAnchor.constraint(equalToConstant: AgentStatusDotView.diameter),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        addButtonWidth = addButton.widthAnchor.constraint(equalToConstant: 0)
        addButtonWidth.isActive = true
        statusDotWidth = statusDot.widthAnchor.constraint(equalToConstant: 0)
        statusDotWidth.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Lay the row out for one node: header, two-line worktree, or plain row.
    func configure(for node: SidebarNode) {
        textField?.stringValue = node.title
        subtitleLabel.stringValue = node.subtitle ?? ""
        subtitleLabel.isHidden = node.subtitle == nil

        if let symbolName = node.symbolName {
            imageView?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            imageView?.isHidden = false
        } else {
            imageView?.image = nil
            imageView?.isHidden = true
        }

        // Headers sit above their worktrees in quieter, heavier type.
        if node.isHeader {
            textField?.font = .systemFont(ofSize: 12, weight: .semibold)
            textField?.textColor = .secondaryLabelColor
        } else {
            textField?.font = .systemFont(ofSize: 13)
            textField?.textColor = .labelColor
        }

        setAccessibilityIdentifier("sidebarRow")
        setAccessibilityLabel(node.title)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func updateAddButton() {
        addButton.isHidden = !showsAddButton
        addButtonWidth.constant = showsAddButton ? 18 : 0
        // Present but quiet until the row is under the pointer.
        addButton.alphaValue = isHovered ? 1 : 0.45
    }

    @objc private func addClicked() {
        onAdd?()
    }

    private(set) var pullRequestInfo: PullRequestInfo?

    /// Colour the row's icon by where its pull request has got to. Nil leaves
    /// the icon in the normal accent tint, which is most branches.
    func setPullRequest(_ info: PullRequestInfo?) {
        pullRequestInfo = info
        imageView?.contentTintColor = info?.state.color ?? .controlAccentColor
    }

    /// Show what the agents in this worktree are up to, on the row's right edge.
    func setAgentState(_ state: AgentState) {
        statusDot.setState(state)
        statusDotWidth.constant = state == .idle ? 0 : AgentStatusDotView.diameter
    }

    /// What the icon is actually tinted, for the self-test.
    var iconTintForTesting: NSColor? { imageView?.contentTintColor }

    /// The dot's state, for the self-test.
    var agentStateForTesting: AgentState { statusDot.state }
}

/// The left panel: repositories and their worktrees.
final class SidebarViewController: NSViewController {
    /// Called when the user picks a worktree (or Home).
    var onSelect: ((SidebarNode) -> Void)?

    /// Called after repositories or worktrees change on disk.
    var onStructureChange: (() -> Void)?

    /// Asked what the agents in a workspace are doing, so the row can show a
    /// dot. The window owns the tabs, so only it can answer.
    var agentState: ((WorkspaceKey) -> AgentState)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private var nodes: [SidebarNode] = []
    private var selectingProgrammatically = false
    /// Where to put the highlight back after an action row is clicked.
    private var lastSelectedKey: WorkspaceKey?
    /// Which ⌘⇧-number reaches each workspace, worked out once per reload.
    private var shortcutByKey: [WorkspaceKey: Int] = [:]

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        outlineView.headerView = nil
        // The modern source-list look: inset rounded selection, system row
        // height and indentation. Don't override those metrics by hand.
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        // Deliberately taller than the source-list default, to match the
        // larger row text above.
        outlineView.rowHeight = 30
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = makeContextMenu()

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(
            title: " Add Repository",
            target: self,
            action: #selector(addRepository)
        )
        // Borderless with a leading glyph, the way sidebar footers look now.
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.contentTintColor = .secondaryLabelColor
        addButton.alignment = .left
        addButton.setAccessibilityIdentifier("addRepositoryButton")
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(separator)
        root.addSubview(addButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -6),

            addButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            addButton.trailingAnchor.constraint(
                lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            addButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        view = root
        reload()
    }

    // MARK: - Data

    /// Rebuild the tree from the database.
    func reload(selecting key: WorkspaceKey? = nil) {
        let expandedPaths = expandedRepositoryPaths()

        nodes = [SidebarNode(.home)]
        for repository in RepositoryStore.all {
            let node = SidebarNode(.repository(repository))
            node.children = RepositoryStore
                .worktrees(ofRepository: repository.id ?? -1)
                .map { SidebarNode(.worktree($0)) }
            node.children.append(SidebarNode(.newWorktree(repository)))
            nodes.append(node)
        }

        shortcutByKey = [:]
        for (index, key) in (MainWindowController.current?.orderedWorkspaceKeys ?? [])
            .prefix(9).enumerated() {
            shortcutByKey[key] = index + 1
        }

        outlineView.reloadData()

        for node in nodes where node.isHeader {
            if case .repository(let repository) = node.kind,
               expandedPaths.isEmpty || expandedPaths.contains(repository.path) {
                outlineView.expandItem(node)
            }
        }

        if let key {
            select(key)
        }

        refreshPullRequests()
    }

    private func expandedRepositoryPaths() -> Set<String> {
        var paths: Set<String> = []
        for node in nodes {
            guard case .repository(let repository) = node.kind else { continue }
            if outlineView.isItemExpanded(node) { paths.insert(repository.path) }
        }
        return paths
    }

    /// Highlight a workspace without firing `onSelect`.
    func select(_ key: WorkspaceKey) {
        guard let node = node(for: key) else { return }
        if case .worktree = node.kind {
            // Make sure the parent repository is open so the row is visible.
            for parent in nodes where parent.children.contains(node) {
                outlineView.expandItem(parent)
            }
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        selectingProgrammatically = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectingProgrammatically = false
        lastSelectedKey = key
    }

    private func node(for key: WorkspaceKey) -> SidebarNode? {
        for node in nodes {
            if node.workspaceKey == key { return node }
            for child in node.children where child.workspaceKey == key { return child }
        }
        return nil
    }

    /// The pull request for a worktree's branch, if `gh` reported one.
    private func pullRequest(for node: SidebarNode) -> PullRequestInfo? {
        guard case .worktree(let worktree) = node.kind,
              let branch = worktree.branch,
              let repository = RepositoryStore.repository(id: worktree.repositoryId)
        else { return nil }
        return PullRequestService.cached(for: repository.path)[branch]
    }

    /// Ask `gh` about each repository, and redraw when an answer differs from
    /// what's on screen. Cached results mean this is usually a no-op.
    private func refreshPullRequests(force: Bool = false) {
        guard PullRequestService.isAvailable else { return }
        for repository in RepositoryStore.all {
            PullRequestService.refresh(
                repositoryPath: repository.path,
                force: force
            ) { [weak self] _ in
                guard let self else { return }
                // Only the rows change, so don't disturb selection or expansion.
                self.outlineView.reloadData()
            }
        }
    }

    /// Redraw the rows because an agent changed state. Only the dots move, so
    /// this leaves selection and expansion alone.
    func refreshAgentStates() {
        outlineView.reloadData()
    }

    /// The dot a row should show.
    ///
    /// A collapsed repository stands in for the worktrees it is hiding —
    /// otherwise folding one away would silently take its agents with it. An
    /// open one shows nothing, since every worktree under it is saying so
    /// itself.
    private func agentState(showing node: SidebarNode) -> AgentState {
        guard let agentState else { return .idle }
        if let key = node.workspaceKey { return agentState(key) }
        guard node.isHeader, !outlineView.isItemExpanded(node) else { return .idle }
        return node.children.compactMap(\.workspaceKey).map(agentState).max() ?? .idle
    }

    private var clickedNode: SidebarNode? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? SidebarNode
    }

    // MARK: - Actions

    @objc private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a git repository"

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let repository = try RepositoryStore.add(path: url.path)
                self.reload()
                // Land the user on the repo's main checkout.
                if let main = RepositoryStore
                    .worktrees(ofRepository: repository.id ?? -1)
                    .first(where: { $0.isMain }) ?? RepositoryStore
                    .worktrees(ofRepository: repository.id ?? -1).first,
                   let id = main.id
                {
                    self.select(.worktree(id))
                    if let node = self.node(for: .worktree(id)) { self.onSelect?(node) }
                }
                self.onStructureChange?()
            } catch {
                self.presentError(error, title: "Couldn't add repository")
            }
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    @objc private func addWorktreeFromMenu() {
        guard let node = clickedNode else { return }
        addWorktree(for: node)
    }

    /// Create a worktree in whichever repository `node` belongs to.
    func addWorktree(for node: SidebarNode) {
        let repository: Repository
        switch node.kind {
        case .repository(let value):
            repository = value
        case .worktree(let worktree):
            guard let owner = RepositoryStore.repository(id: worktree.repositoryId) else { return }
            repository = owner
        case .newWorktree(let value):
            repository = value
        case .home:
            return
        }

        guard let window = view.window else { return }
        let dialog = NewWorktreeDialog(repository: repository) { [weak self] result in
            guard let self, let result else { return }
            do {
                try GitService.addWorktree(
                    repositoryPath: repository.path,
                    path: result.path,
                    branch: result.branch,
                    createBranch: result.createBranch,
                    startPoint: result.startPoint
                )
                try RepositoryStore.refreshWorktrees(of: repository)
                self.reload()

                if let created = RepositoryStore
                    .worktrees(ofRepository: repository.id ?? -1)
                    .first(where: { $0.path == result.path }),
                   let id = created.id
                {
                    self.select(.worktree(id))
                    if let node = self.node(for: .worktree(id)) { self.onSelect?(node) }
                }
                self.onStructureChange?()
            } catch {
                self.presentError(error, title: "Couldn't create worktree")
            }
        }

        let sheet = NSWindow(contentViewController: dialog)
        sheet.styleMask = [.titled]
        window.beginSheet(sheet)
    }

    @objc func removeWorktree() {
        guard let node = clickedNode,
              case .worktree(let worktree) = node.kind,
              let repository = RepositoryStore.repository(id: worktree.repositoryId),
              let window = view.window
        else { return }

        guard !worktree.isMain else {
            let alert = NSAlert()
            alert.messageText = "That's the main checkout"
            alert.informativeText =
                "Remove the repository from the sidebar instead — the main working tree isn't a removable worktree."
            alert.beginSheetModal(for: window)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove worktree “\(worktree.displayName)”?"
        alert.informativeText =
            "This runs git worktree remove and deletes \(worktree.path) from disk. The branch itself is kept."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = "\u{1b}"

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if let error = self.performRemoveWorktree(worktree, in: repository) {
                // Usually an unclean worktree; offer the forced path.
                self.confirmForceRemove(worktree: worktree, repository: repository, error: error)
            }
        }
    }

    /// Run `git worktree remove` and reconcile the sidebar.
    ///
    /// Returns the error when git refuses, so the caller can offer `--force`.
    @discardableResult
    func performRemoveWorktree(
        _ worktree: Worktree,
        in repository: Repository,
        force: Bool = false
    ) -> Error? {
        do {
            try GitService.removeWorktree(
                repositoryPath: repository.path,
                path: worktree.path,
                force: force
            )
        } catch {
            return error
        }
        try? RepositoryStore.refreshWorktrees(of: repository)
        reload()
        onStructureChange?()
        return nil
    }

    private func confirmForceRemove(
        worktree: Worktree,
        repository: Repository,
        error: Error
    ) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "git wouldn't remove that worktree"
        alert.informativeText = "\(error.localizedDescription)\n\nRemove it anyway? Uncommitted changes there will be lost."
        alert.addButton(withTitle: "Remove Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[1].keyEquivalent = "\u{1b}"

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if let error = self.performRemoveWorktree(worktree, in: repository, force: true) {
                self.presentError(error, title: "Couldn't remove worktree")
            }
        }
    }

    @objc private func removeRepository() {
        guard let node = clickedNode,
              case .repository(let repository) = node.kind,
              let window = view.window
        else { return }

        let alert = NSAlert()
        alert.messageText = "Remove “\(repository.name)” from the sidebar?"
        alert.informativeText = "Nothing on disk is deleted. You can add it again later."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\u{1b}"

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            RepositoryStore.remove(repository)
            self.reload()
            self.onStructureChange?()
        }
    }

    @objc private func refreshPullRequestsFromMenu() {
        refreshPullRequests(force: true)
    }

    @objc private func refreshRepository() {
        guard let node = clickedNode else { return }
        let repository: Repository?
        switch node.kind {
        case .repository(let value): repository = value
        case .newWorktree(let value): repository = value
        case .worktree(let worktree): repository = RepositoryStore.repository(id: worktree.repositoryId)
        case .home: repository = nil
        }
        guard let repository else { return }

        do {
            try RepositoryStore.refreshWorktrees(of: repository)
            reload()
            onStructureChange?()
        } catch {
            presentError(error, title: "Couldn't refresh")
        }
    }

    @objc private func revealInFinder() {
        guard let node = clickedNode else { return }
        let path: String?
        switch node.kind {
        case .home: path = NSHomeDirectory()
        case .repository(let repository), .newWorktree(let repository): path = repository.path
        case .worktree(let worktree): path = worktree.path
        }
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }
}

// MARK: - NSMenuDelegate

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode else { return }

        switch node.kind {
        case .home, .newWorktree:
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "")

        case .repository:
            menu.addItem(withTitle: "New Worktree…", action: #selector(addWorktreeFromMenu), keyEquivalent: "")
            menu.addItem(withTitle: "Refresh Worktrees", action: #selector(refreshRepository), keyEquivalent: "")
            if PullRequestService.isAvailable {
                menu.addItem(
                    withTitle: "Refresh Pull Requests",
                    action: #selector(refreshPullRequestsFromMenu),
                    keyEquivalent: ""
                )
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Remove from Sidebar", action: #selector(removeRepository), keyEquivalent: "")

        case .worktree(let worktree):
            menu.addItem(withTitle: "New Worktree…", action: #selector(addWorktreeFromMenu), keyEquivalent: "")
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "")
            menu.addItem(.separator())
            let remove = menu.addItem(
                withTitle: "Remove Worktree…",
                action: #selector(removeWorktree),
                keyEquivalent: ""
            )
            // git can't remove the main working tree, but hiding the item just
            // looks like the feature is missing. Show why instead.
            remove.isEnabled = !worktree.isMain
            if worktree.isMain {
                remove.toolTip =
                    "This is the repository's main checkout. Remove the repository from the sidebar instead."
            }
        }

        for item in menu.items { item.target = self }
    }
}

// MARK: - Outline view

extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SidebarNode else { return nodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else { return nodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode).map { !$0.children.isEmpty } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? SidebarNode)?.rowHeight ?? 30
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Repositories only expand; their rows aren't workspaces.
        (item as? SidebarNode)?.isSelectable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView
            ?? {
                let created = SidebarCellView()
                created.identifier = identifier
                return created
            }()

        // Cells are reused, so re-point the button at this row every time.
        if case .repository = node.kind {
            cell.showsAddButton = true
            cell.onAdd = { [weak self] in self?.addWorktree(for: node) }
        } else {
            cell.showsAddButton = false
            cell.onAdd = nil
        }

        cell.configure(for: node)
        cell.shortcutNumber = node.workspaceKey.flatMap { shortcutByKey[$0] }

        // Icons take the accent tint like Finder and Mail, except a branch with
        // a pull request, whose icon takes that pull request's colour.
        let pullRequest = pullRequest(for: node)
        cell.setPullRequest(pullRequest)

        // Home has terminals too, so it gets a dot on the same terms.
        let agents = agentState(showing: node)
        cell.setAgentState(agents)

        cell.toolTip = {
            switch node.kind {
            case .home: return NSHomeDirectory()
            case .newWorktree: return "Create a worktree in this repository"
            case .repository(let repository): return repository.path
            case .worktree(let worktree):
                let lines = [
                    worktree.path,
                    pullRequest?.summary,
                    AgentStatusDotView.tooltip(for: agents),
                ]
                return lines.compactMap { $0 }.joined(separator: "\n")
            }
        }()
        return cell
    }

    /// Folding a repository moves its worktrees' dots onto its own row, and
    /// unfolding hands them back. Deferred, because reloading the outline from
    /// inside its own expansion callback re-enters it.
    func outlineViewItemDidExpand(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.refreshAgentStates() }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.refreshAgentStates() }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !selectingProgrammatically,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode
        else { return }

        // "New Worktree" is an action, not a place: run it and put the
        // selection back where it was.
        if case .newWorktree = node.kind {
            let previous = lastSelectedKey
            addWorktree(for: node)
            if let previous { select(previous) } else {
                outlineView.deselectAll(nil)
            }
            return
        }

        guard node.workspaceKey != nil else { return }
        lastSelectedKey = node.workspaceKey
        onSelect?(node)
    }
}

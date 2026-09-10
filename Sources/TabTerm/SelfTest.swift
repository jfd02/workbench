import AppKit

/// An in-process smoke test, run with `TabTerm --self-test`.
///
/// It calls the same methods the buttons and menu items call, so behavior can
/// be verified without synthesizing mouse or keyboard events. That means it
/// never moves the cursor and never steals focus from whatever you're doing.
/// A tab being dragged over a pane, without a real mouse involved.
///
/// AppKit hands the destination an `NSDraggingInfo`; this is the smallest one
/// that carries a tab id and a location.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard

    init(tabID: UUID, location: NSPoint) {
        draggingLocation = location
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("tabterm-selftest"))
        draggingPasteboard.clearContents()
        draggingPasteboard.setString(
            tabID.uuidString,
            forType: SplitContainerView.tabPasteboardType
        )
        super.init()
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var draggingFormation: NSDraggingFormation = .default
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        nil
    }
    func resetSpringLoading() {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

/// Pane content that holds nothing, so the icon and title plumbing can be
/// driven without a real terminal or web view behind it.
private final class StubContent: TabContent {
    /// Stands in for content with something at stake, which a real terminal
    /// can't be made into deterministically.
    var isDisposable: Bool

    init(disposable: Bool = true) {
        isDisposable = disposable
    }

    let view = NSView()
    let kind: TabKind = .terminal
    var title = "Stub"
    var icon: NSImage?

    var onTitleChange: ((String) -> Void)?
    var onIconChange: ((NSImage?) -> Void)?
    var onRequestClose: ((Bool) -> Void)?

    var closeConfirmationDetail: String { "Nothing will be lost." }

    func takeFocus() {}
    func setFocused(_ focused: Bool) {}
    func setVisible(_ visible: Bool) {}
    func close() {}

    /// Change the icon the way real content does when it learns about one.
    func emit(_ image: NSImage?) {
        icon = image
        onIconChange?(image)
    }
}

enum SelfTest {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--self-test")
    }

    /// A small solid-colour PNG, standing in for a downloaded favicon.
    static func swatchPNG(size: Int = 64) -> Data {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }

    private static var checks = 0
    private static var failures: [String] = []

    private enum Step {
        /// Do something, then continue on the next runloop turn.
        case act(String, () -> Void)
        /// Poll until the condition holds. Fails the run if it never does.
        case waitUntil(String, () -> Bool)
    }

    private static func expect(_ condition: Bool, _ description: String) {
        checks += 1
        if condition {
            print("  ok    \(description)")
        } else {
            failures.append(description)
            print("  FAIL  \(description)")
        }
    }

    private static func expectEqual<T: Equatable>(_ a: T, _ b: T, _ description: String) {
        expect(a == b, "\(description) (got \(a), want \(b))")
    }

    /// Depth-first search of a view tree, for finding a control by identifier.
    private static func findView(
        in root: NSView?,
        where matches: (NSView) -> Bool
    ) -> NSView? {
        guard let root else { return nil }
        if matches(root) { return root }
        for subview in root.subviews {
            if let found = findView(in: subview, where: matches) { return found }
        }
        return nil
    }

    /// Gather every view of a kind in a tree, for checking what's on screen.
    private static func collectViews<T: NSView>(in root: NSView?, into found: inout [T]) {
        guard let root else { return }
        if let match = root as? T { found.append(match) }
        for subview in root.subviews { collectViews(in: subview, into: &found) }
    }

    private static func run(steps: [Step], then finish: @escaping () -> Void) {
        var remaining = steps

        func next() {
            guard !remaining.isEmpty else { return finish() }

            switch remaining.removeFirst() {
            case .act(let name, let body):
                print("\n▸ \(name)")
                body()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: next)

            case .waitUntil(let name, let condition):
                // AppKit attaches and detaches sheets asynchronously, so poll
                // rather than guessing a sleep duration.
                let deadline = Date().addingTimeInterval(5)
                func poll() {
                    if condition() {
                        expect(true, name)
                        return next()
                    }
                    guard Date() < deadline else {
                        expect(false, "\(name) — timed out")
                        return next()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
                }
                poll()
            }
        }

        next()
    }

    static func start(_ controller: MainWindowController) {
        print("TabTerm self-test")

        let example = URL(string: "https://example.com/docs")!
        var localPage: URL?
        var temporaryRepo: String?
        var scratchRepository: Repository?
        var featureWorktree: Worktree?
        var mainWorktreeID: Int64?

        // Agent status runs against a throwaway directory, never the one the
        // running app watches.
        let agentDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "tabterm-agents-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        let agents = AgentActivityStore(directory: agentDirectory)
        var envTerminal: TerminalTabContent?
        var envProbe: URL?
        var litAgent: String?

        /// Leave an event the way the hook does: written elsewhere, then moved
        /// into place, so the watcher sees the same thing it sees in the wild.
        func report(_ event: String, from agentID: String) {
            let json = "{\"event\":\"\(event)\",\"at\":\(Date().timeIntervalSince1970)}"
            try? json.write(
                to: agentDirectory.appendingPathComponent("\(agentID).json"),
                atomically: true,
                encoding: .utf8
            )
        }

        func dialog() -> NewTabDialog? {
            controller.window?.attachedSheet?.contentViewController as? NewTabDialog
        }

        // The add-site sheet hangs off the new-tab sheet, not the window.
        func addSiteSheet() -> AddSiteDialog? {
            dialog()?.view.window?.attachedSheet?.contentViewController as? AddSiteDialog
        }

        run(steps: [
            .act("storage", {
                // main.swift redirected us to a temp file for this run.
                expect(AppDatabase.shared.openError == nil, "database opened cleanly")
                expectEqual(PinnedSites.all.count, 0, "temp database starts empty")

                AppState.set("hello", forKey: "selftest")
                expectEqual(AppState.string(forKey: "selftest"), "hello", "app state round-trips")
                AppState.set("world", forKey: "selftest")
                expectEqual(AppState.string(forKey: "selftest"), "world", "app state overwrites")
                AppState.set(nil, forKey: "selftest")
                expect(AppState.string(forKey: "selftest") == nil, "app state deletes")

                expect(
                    UserDefaults.standard.data(forKey: "pinnedSites") == nil,
                    "nothing of ours left in UserDefaults"
                )
            }),

            .act("startup state", {
                expectEqual(controller.tabSnapshot.count, 1, "one tab at launch")
                expectEqual(controller.tabSnapshot.first?.kind, .terminal, "it is a terminal")
                expect(GhosttyApp.shared.app != nil, "libghostty app created")
                expect(GhosttyApp.shared.startupError == nil, "no libghostty startup error")
            }),

            // The Claude mark depends on libghostty naming the pty's
            // foreground process, so check that it does before trusting it.
            .waitUntil("the terminal reports a foreground process", {
                (controller.selectedTabContent as? TerminalTabContent)
                    .map { $0.foregroundPID > 0 } ?? false
            }),

            .act("and its command line can be read", {
                guard let terminal = controller.selectedTabContent as? TerminalTabContent else {
                    return expect(false, "the first tab is a terminal")
                }
                let command = ForegroundProcess.commandLine(of: terminal.foregroundPID)
                print("  · foreground=\(command.prefix(3).joined(separator: " "))")

                expect(!command.isEmpty, "the foreground process has a command line")
                expect(
                    !ForegroundProcess.isClaude(commandLine: command),
                    "a freshly opened shell is not running Claude"
                )
                expect(terminal.icon == nil, "so the tab shows no Claude mark")
            }),

            .act("tabs draw the icon their content reports", {
                let icon = FaviconStore.decode(swatchPNG())
                expect(icon != nil, "a stand-in favicon to hand around")

                let stub = StubContent()
                let tab = Tab(content: stub)
                var refreshes = 0
                tab.onTitleChange = { refreshes += 1 }

                expect(tab.icon == nil, "a tab with no icon falls back to its kind")
                stub.emit(icon)
                expect(tab.icon === icon, "the tab takes the icon from its focused pane")
                expectEqual(refreshes, 1, "and asks the tab bar to redraw once")

                let button = TabButtonView(tabID: tab.id, kind: .browser, title: "Example")
                let symbol = button.iconImageForTesting
                expect(symbol != nil, "a tab button starts with its kind's symbol")
                button.icon = icon
                expect(button.iconImageForTesting === icon, "an icon replaces the symbol")
                button.icon = nil
                expect(button.iconImageForTesting !== icon, "and clearing it puts the symbol back")

                tab.closeAll()
            }),

            .act("url normalization", {
                expectEqual(
                    BrowserTabContent.normalizeURL("example.com")?.absoluteString,
                    "https://example.com",
                    "bare host gets https"
                )
                expectEqual(
                    BrowserTabContent.normalizeURL("https://a.dev/x")?.absoluteString,
                    "https://a.dev/x",
                    "full url passes through"
                )
                expectEqual(
                    BrowserTabContent.normalizeURL("localhost:3000")?.absoluteString,
                    "https://localhost:3000",
                    "localhost with port"
                )
                expect(
                    BrowserTabContent.normalizeURL("how tall is everest")?
                        .host?.contains("duckduckgo") == true,
                    "plain text becomes a search"
                )

                // Saving a site takes the stricter reading: no searches.
                expectEqual(
                    BrowserTabContent.address("figma.com")?.absoluteString,
                    "https://figma.com",
                    "an address is still an address"
                )
                expect(
                    BrowserTabContent.address("how tall is everest") == nil,
                    "but plain text is refused rather than searched"
                )
                expectEqual(
                    PinnedSite.suggestedTitle(for: URL(string: "https://www.figma.com/files")!),
                    "Figma",
                    "an unnamed site is named after its host"
                )
            }),

            .act("site icons are cached", {
                FaviconStore.resetForTesting()
                let site = URL(string: "https://icons.example/page")!
                expect(FaviconStore.cached(for: site) == nil, "nothing cached to begin with")

                expect(
                    FaviconStore.storeForTesting(swatchPNG(), for: site),
                    "an icon normalizes and stores"
                )
                guard let icon = FaviconStore.cached(for: site) else {
                    return expect(false, "and comes back out of the database")
                }
                expect(true, "and comes back out of the database")
                expectEqual(icon.size, NSSize(width: 16, height: 16), "sized in points to draw at")
                expect(!icon.isTemplate, "and not a template, so its colors survive")

                // Same host, different page: one icon covers the site.
                expect(
                    FaviconStore.cached(for: URL(string: "https://icons.example/other")!) != nil,
                    "another page on the host uses it too"
                )
                expect(
                    FaviconStore.cached(for: URL(string: "https://other.example/")!) == nil,
                    "a different host does not"
                )

                // With the network off this must answer rather than hang.
                var answered = false
                FaviconStore.icon(for: URL(string: "https://nowhere.example/")!) { image in
                    answered = true
                    expect(image == nil, "an unknown host with no network resolves to nothing")
                }
                expect(answered, "and answers straight away")
            }),

            .act("icons declared by a page are found", {
                let html = Data("""
                <html><head>
                <link rel="stylesheet" href="/style.css">
                <link rel="shortcut icon" href="/small.ico">
                <link rel="apple-touch-icon" href="https://cdn.example/touch.png">
                </head><body></body></html>
                """.utf8)
                let links = FaviconStore.iconLinks(
                    inHTML: html, base: URL(string: "https://site.example/page")!)

                expectEqual(links.map(\.absoluteString), [
                    "https://site.example/small.ico",
                    "https://cdn.example/touch.png",
                ], "icon links are read, relative ones resolved, stylesheets ignored")
            }),

            .act("what a terminal is running", {
                expect(ClaudeIcon.image != nil, "there is a Claude mark to show")

                expect(
                    ForegroundProcess.isClaude(commandLine: ["/Users/x/.local/bin/claude"]),
                    "the claude binary is recognized"
                )
                expect(
                    ForegroundProcess.isClaude(commandLine: [
                        "/opt/homebrew/bin/node", "node",
                        "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                    ]),
                    "so is an npm install running under node"
                )
                expect(
                    !ForegroundProcess.isClaude(commandLine: ["/bin/zsh", "-zsh"]),
                    "a shell prompt is not Claude"
                )
                expect(
                    !ForegroundProcess.isClaude(commandLine: ["/usr/bin/vim", "vim", "claude.md"]),
                    "and neither is an editor holding a file named after it"
                )
            }),

            .act("pinned sites store", {
                expect(!PinnedSites.isPinned(example), "not pinned initially")
                PinnedSites.add(title: "Example Docs", url: example)
                expectEqual(PinnedSites.all.count, 1, "one pin after add")
                expect(PinnedSites.isPinned(example), "isPinned true after add")

                // Same page with tracking junk should not create a second pin.
                let tracked = URL(string: "https://example.com/docs/?utm_source=x")!
                expect(PinnedSites.isPinned(tracked), "matches ignoring query and trailing slash")
                PinnedSites.add(title: "Renamed", url: example)
                expectEqual(PinnedSites.all.count, 1, "re-adding updates instead of duplicating")
                expectEqual(PinnedSites.all.first?.title, "Renamed", "title updated")

                PinnedSites.remove(example)
                expect(!PinnedSites.isPinned(example), "unpinned after remove")
                expectEqual(PinnedSites.all.count, 0, "store empty again")
            }),

            .act("pin ordering survives a round trip", {
                let a = URL(string: "https://a.example/1")!
                let b = URL(string: "https://b.example/2")!
                let c = URL(string: "https://c.example/3")!
                PinnedSites.add(title: "A", url: a)
                PinnedSites.add(title: "B", url: b)
                PinnedSites.add(title: "C", url: c)
                expectEqual(PinnedSites.all.map(\.title), ["A", "B", "C"], "insertion order kept")

                PinnedSites.remove(b)
                expectEqual(PinnedSites.all.map(\.title), ["A", "C"], "order kept after a removal")
                PinnedSites.replaceAll(with: [])
                expectEqual(PinnedSites.all.count, 0, "cleared")
            }),

            .act("browser tab creation", {
                controller.addTab(.browser, url: example)
                expectEqual(controller.tabSnapshot.count, 2, "two tabs after adding browser")
                expectEqual(controller.tabSnapshot.last?.kind, .browser, "second tab is a browser")
                expectEqual(
                    controller.selectedTabID,
                    controller.tabSnapshot.last?.id,
                    "new tab is selected"
                )
                controller.closeTab(controller.tabSnapshot.last!.id)
            }),

            .act("pin button on a real loaded page", {
                // A local file, so this doesn't depend on the network.
                let path = NSTemporaryDirectory() + "tabterm-selftest.html"
                try? "<title>Pin Me</title><h1>hi</h1>".write(
                    toFile: path, atomically: true, encoding: .utf8)
                localPage = URL(fileURLWithPath: path)
                controller.addTab(.browser, url: localPage)
            }),

            .waitUntil("local page finishes loading", {
                (controller.selectedTabContent as? BrowserTabContent)?.currentURL != nil
            }),

            .act("toggling the pin button pins the live page", {
                guard let browser = controller.selectedTabContent as? BrowserTabContent,
                      let url = browser.currentURL
                else { return expect(false, "browser tab has a loaded URL") }

                expect(!PinnedSites.isPinned(url), "page starts unpinned")
                browser.togglePin()
                expect(PinnedSites.isPinned(url), "pin button pinned the page")
                browser.togglePin()
                expect(!PinnedSites.isPinned(url), "pin button unpinned it again")

                controller.closeTab(controller.tabSnapshot.last!.id)
            }),

            .act("workspaces are per worktree", {
                // Build a real throwaway repo so this exercises git itself
                // rather than skipping when the app isn't inside a checkout.
                let pid = ProcessInfo.processInfo.processIdentifier
                let repoPath = NSTemporaryDirectory() + "tabterm-selftest-repo-\(pid)"
                temporaryRepo = repoPath
                try? FileManager.default.removeItem(atPath: repoPath)
                try? FileManager.default.removeItem(atPath: repoPath + "-worktrees")
                try? FileManager.default.createDirectory(
                    atPath: repoPath, withIntermediateDirectories: true)

                do {
                    try GitService.run(["init", "-b", "main"], in: repoPath)
                    FileManager.default.createFile(
                        atPath: repoPath + "/README.md",
                        contents: Data("hello".utf8)
                    )
                    try GitService.run(["add", "."], in: repoPath)
                    // A worktree needs a commit to branch from, and the sandbox
                    // may have no git identity configured.
                    try GitService.run([
                        "-c", "user.email=selftest@tabterm.local",
                        "-c", "user.name=TabTerm Self Test",
                        "commit", "-m", "initial",
                    ], in: repoPath)
                } catch {
                    return expect(false, "building a scratch repo: \(error.localizedDescription)")
                }
                expect(true, "built a scratch git repository")

                guard let repository = try? RepositoryStore.add(path: repoPath) else {
                    return expect(false, "adding a repository succeeds")
                }
                expect(true, "adding a repository succeeds")

                var worktrees = RepositoryStore.worktrees(ofRepository: repository.id ?? -1)
                expectEqual(worktrees.count, 1, "a fresh repo has just its main checkout")
                expect(worktrees.first?.isMain == true, "and it is marked as the main one")
                expectEqual(worktrees.first?.branch, "main", "on the branch git reports")

                // Now create a second worktree the way the sidebar does.
                let branch = "feature/self-test"
                let path = GitService.defaultWorktreePath(
                    repositoryPath: repoPath, branch: branch)
                expect(
                    path.hasPrefix(repoPath + "-worktrees/"),
                    "new worktrees go in a sibling folder"
                )
                expect(!path.contains("feature/self-test"), "slashes in the branch are flattened")

                do {
                    try GitService.addWorktree(
                        repositoryPath: repoPath,
                        path: path,
                        branch: branch,
                        createBranch: true
                    )
                    try RepositoryStore.refreshWorktrees(of: repository)
                } catch {
                    return expect(false, "git worktree add: \(error.localizedDescription)")
                }

                worktrees = RepositoryStore.worktrees(ofRepository: repository.id ?? -1)
                expectEqual(worktrees.count, 2, "the new worktree was picked up")
                expect(
                    worktrees.contains { $0.branch == branch },
                    "and it is on the branch we asked for"
                )
                expect(
                    FileManager.default.fileExists(atPath: path + "/README.md"),
                    "the working tree was checked out on disk"
                )

                guard let main = worktrees.first(where: { $0.isMain }), let id = main.id else {
                    return expect(false, "main worktree has an id")
                }

                // The repository row carries its own + for adding a worktree.
                controller.reloadSidebar()
                let plus = findView(in: controller.window?.contentView) { view in
                    view.accessibilityIdentifier() == "newWorktreeButton"
                        && !view.isHidden
                }
                expect(plus != nil, "the repository row shows a + for new worktrees")

                // Home has whatever tabs the earlier steps left it.
                let homeTabs = controller.tabSnapshot.count
                controller.selectWorkspace(.worktree(id))
                expectEqual(controller.currentWorkspaceKey, .worktree(id), "switched workspace")
                expectEqual(controller.tabSnapshot.count, 1, "new workspace opens one terminal")

                controller.addTab(.terminal)
                expectEqual(controller.tabSnapshot.count, 2, "added a tab in the worktree")

                controller.selectWorkspace(.home)
                expectEqual(controller.tabSnapshot.count, homeTabs, "home's tabs are untouched")

                controller.selectWorkspace(.worktree(id))
                expectEqual(
                    controller.tabSnapshot.count, 2,
                    "the worktree's tabs are still there on return"
                )

                // The second worktree is its own workspace, not a view of the first.
                guard let other = worktrees.first(where: { !$0.isMain }), let otherID = other.id
                else { return expect(false, "the feature worktree has an id") }

                controller.selectWorkspace(.worktree(otherID))
                expectEqual(controller.tabSnapshot.count, 1, "the other worktree starts fresh")
                expectEqual(
                    controller.currentWorkspace.directory, other.path,
                    "its terminals are rooted at that worktree"
                )

                scratchRepository = repository
                featureWorktree = other
                mainWorktreeID = id
                controller.selectWorkspace(.home)
            }),

            .act("branch state shows in the sidebar", {
                guard let repository = scratchRepository, let feature = featureWorktree,
                      let branch = feature.branch
                else { return expect(false, "the scratch repo is still set up") }

                // Seed the cache rather than calling gh, so this doesn't depend
                // on the network or on the user's GitHub account.
                PullRequestService.resetForTesting()
                PullRequestService.seedForTesting(
                    repositoryPath: repository.path,
                    branches: [branch: PullRequestInfo(number: 42, state: .open)]
                )
                controller.reloadSidebar()

                var cells: [SidebarCellView] = []
                collectViews(in: controller.window?.contentView, into: &cells)
                let row = cells.first { $0.textField?.stringValue == feature.displayName }

                expect(row != nil, "the worktree has a row in the sidebar")
                expectEqual(row?.pullRequestInfo?.number, 42, "carrying its pull request")
                expectEqual(row?.pullRequestInfo?.state, .open, "in the open state")

                // The main checkout has no PR, so it stays undecorated.
                let mainRow = cells.first { $0.textField?.stringValue == "main" }
                expect(mainRow?.pullRequestInfo == nil, "a branch with no PR shows nothing")

                // The branch icon itself carries the colour, not a separate dot.
                expectEqual(
                    row?.iconTintForTesting, PullRequestState.open.color,
                    "the branch icon is tinted with the open colour"
                )
                expectEqual(
                    mainRow?.iconTintForTesting, NSColor.controlAccentColor,
                    "a branch with no PR keeps the normal accent tint"
                )
                expect(
                    PullRequestState.open.color != PullRequestState.merged.color,
                    "open and merged are told apart by colour"
                )

                PullRequestService.seedForTesting(
                    repositoryPath: repository.path,
                    branches: [branch: PullRequestInfo(number: 42, state: .merged)]
                )
                controller.reloadSidebar()
                cells.removeAll()
                collectViews(in: controller.window?.contentView, into: &cells)
                let merged = cells.first { $0.textField?.stringValue == feature.displayName }
                expectEqual(
                    merged?.pullRequestInfo?.state, .merged,
                    "and the row follows the pull request when it merges"
                )
                expectEqual(
                    merged?.iconTintForTesting, PullRequestState.merged.color,
                    "with the icon repainted purple"
                )
                PullRequestService.resetForTesting()
            }),

            .act("a worktree can be removed from its context menu", {
                guard let repository = scratchRepository,
                      let feature = featureWorktree,
                      let featureID = feature.id,
                      let main = RepositoryStore
                          .worktrees(ofRepository: repository.id ?? -1)
                          .first(where: { $0.isMain }),
                      let mainID = main.id
                else { return expect(false, "the scratch repo is still set up") }

                let sidebar = controller.sidebarPanel
                controller.reloadSidebar()

                func removeItem(for key: WorkspaceKey) -> NSMenuItem? {
                    sidebar.select(key)
                    let menu = NSMenu()
                    sidebar.menuNeedsUpdate(menu)
                    return menu.items.first { $0.title == "Remove Worktree…" }
                }

                let featureItem = removeItem(for: .worktree(featureID))
                expect(featureItem != nil, "right-clicking a worktree offers Remove Worktree…")
                expect(featureItem?.isEnabled == true, "and it is enabled")

                // The main checkout keeps the item but greys it out, so the
                // option doesn't just look missing.
                let mainItem = removeItem(for: .worktree(mainID))
                expect(mainItem != nil, "the main checkout shows the item too")
                expect(mainItem?.isEnabled == false, "but disabled, since git can't remove it")
                expect(mainItem?.toolTip?.isEmpty == false, "with a tooltip saying why")

                // Choosing it asks before deleting anything.
                sidebar.select(.worktree(featureID))
                sidebar.removeWorktree()
            }),

            .waitUntil("removing puts up a confirmation", {
                controller.window?.attachedSheet != nil
            }),

            .act("cancelling keeps the worktree on disk", {
                guard let feature = featureWorktree else { return }
                expect(
                    FileManager.default.fileExists(atPath: feature.path),
                    "nothing was deleted while the sheet was up"
                )
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
            }),

            .waitUntil("confirmation dismissed", { controller.window?.attachedSheet == nil }),

            .act("confirming removes it for real", {
                guard let repository = scratchRepository, let feature = featureWorktree else {
                    return expect(false, "the scratch repo is still set up")
                }
                expect(
                    FileManager.default.fileExists(atPath: feature.path),
                    "cancelling left the worktree alone"
                )

                let error = controller.sidebarPanel.performRemoveWorktree(feature, in: repository)
                expect(error == nil, "git worktree remove succeeded")
                expect(
                    !FileManager.default.fileExists(atPath: feature.path),
                    "the directory is gone from disk"
                )
                expectEqual(
                    RepositoryStore.worktrees(ofRepository: repository.id ?? -1).count, 1,
                    "and only the main checkout is left"
                )

                // Removing the repo takes its workspaces with it.
                RepositoryStore.remove(repository)
                expect(RepositoryStore.all.isEmpty, "repository removed again")
                expect(
                    RepositoryStore.worktrees(ofRepository: repository.id ?? -1).isEmpty,
                    "its worktree rows cascade away"
                )
                expectEqual(
                    SavedTabStore.tabs(forWorktree: mainWorktreeID).count, 0,
                    "and so do the tabs saved against them"
                )
                expect(
                    SavedTabStore.tabs(forWorktree: mainWorktreeID)
                        .allSatisfy { $0.worktreeId == mainWorktreeID },
                    "a worktree's tabs never include Home's"
                )
            }),

            .act("a split layout survives a restore", {
                // Build a tab with three panes: one split right, then that half
                // split down, with an off-centre divider.
                controller.selectWorkspace(.home)
                for tab in controller.tabSnapshot { controller.closeTab(tab.id) }
                controller.addTab(.terminal)

                guard let tab = controller.selectedTab, let root = tab.focusedPaneID else {
                    return expect(false, "a tab to split")
                }
                controller.splitPane(tabID: tab.id, paneID: root, direction: .right)
                guard let right = tab.focusedPaneID else {
                    return expect(false, "the split produced a pane")
                }
                controller.splitPane(tabID: tab.id, paneID: right, direction: .down)
                tab.setRatio(0.25, ofSplitAbove: root)
                expectEqual(tab.paneCount, 3, "three panes before saving")

                let saved = controller.currentWorkspace
                saved.persist()

                let rows = SavedTabStore.tabs(forWorktree: nil)
                expectEqual(rows.count, 1, "one tab was saved")
                guard let layout = SavedLayout(json: rows.first?.layout) else {
                    return expect(false, "the layout column holds a tree")
                }
                expect(true, "the layout column holds a tree")
                expectEqual(layout.leaves.count, 3, "the tree has three leaves")

                // Outer split is side by side at the ratio we set; its second
                // child is the stacked pair.
                guard case .split(let stacked, let ratio, _, let second) = layout else {
                    return expect(false, "the root is a split")
                }
                expect(!stacked, "the outer split is side by side")
                expect(abs(ratio - 0.25) < 0.001, "the divider position was kept")
                if case .split(let innerStacked, _, _, _) = second {
                    expect(innerStacked, "the inner split is stacked")
                } else {
                    expect(false, "the inner split is stacked")
                }
            }),

            .act("and comes back with the same shape", {
                // Drop the live workspace so it has to rebuild from the database.
                controller.discardWorkspacesForTesting()
                controller.selectWorkspace(.home)

                expectEqual(controller.tabSnapshot.count, 1, "the tab came back")
                guard let tab = controller.selectedTab else {
                    return expect(false, "the restored tab is selected")
                }
                expectEqual(tab.paneCount, 3, "with all three panes")

                let layout = SavedLayout(json: SavedTabStore.tabs(forWorktree: nil).first?.layout)
                guard case .split(let stacked, let ratio, _, let second)? = layout else {
                    return expect(false, "still a split after restoring")
                }
                expect(!stacked, "outer orientation survived the round trip")
                expect(abs(ratio - 0.25) < 0.001, "so did the divider position")
                if case .split(let innerStacked, _, _, _) = second {
                    expect(innerStacked, "and the nested stacked split")
                } else {
                    expect(false, "and the nested stacked split")
                }

                // Hand the later steps a plain single-pane tab again.
                for entry in controller.tabSnapshot { controller.closeTab(entry.id) }
                controller.addTab(.terminal)
                expectEqual(controller.tabSnapshot.count, 1, "workspace reset for later steps")
            }),

            .act("the sidebar has a visible way back", {
                guard let split = controller.window?.contentViewController
                        as? NSSplitViewController,
                      let sidebarItem = split.splitViewItems.first
                else { return expect(false, "the window hosts a split view with a sidebar") }

                expect(true, "the window hosts a split view with a sidebar")
                expect(sidebarItem.canCollapse, "the sidebar can be collapsed")
                expect(!sidebarItem.isCollapsed, "and starts open")

                // The button lives in the tab bar, so it stays on screen when
                // the sidebar itself is gone.
                let button = findView(in: controller.window?.contentView) { view in
                    view.accessibilityIdentifier() == "toggleSidebarButton"
                }
                expect(button != nil, "there is a visible sidebar toggle button")
                expect(
                    (button as? NSButton)?.isHidden == false,
                    "and it is not hidden"
                )

                // Click it the way AppKit would.
                if let button = button as? NSButton {
                    button.performClick(nil)
                } else {
                    split.toggleSidebar(nil)
                }
            }),

            .waitUntil("the toggle collapses it", {
                (controller.window?.contentViewController as? NSSplitViewController)?
                    .splitViewItems.first?.isCollapsed == true
            }),

            .act("toggle again", {
                (controller.window?.contentViewController as? NSSplitViewController)?
                    .toggleSidebar(nil)
            }),

            .waitUntil("and brings it back", {
                (controller.window?.contentViewController as? NSSplitViewController)?
                    .splitViewItems.first?.isCollapsed == false
            }),

            .act("⌘1…⌘9 really do jump between tabs", {
                guard let delegate = NSApp.delegate as? AppDelegate else {
                    return expect(false, "the app delegate is reachable")
                }

                let items = delegate.tabShortcutItems
                expectEqual(items.count, 9, "there are nine numbered tab items")
                expect(
                    items.allSatisfy { !$0.isHidden },
                    "none are hidden — AppKit ignores hidden items when matching keys"
                )
                expectEqual(
                    items.map(\.keyEquivalent), (1...9).map(String.init),
                    "bound to 1 through 9"
                )
                expect(
                    items.allSatisfy { $0.keyEquivalentModifierMask == .command },
                    "with command as the modifier"
                )

                // Three tabs, then jump to the third the way the menu does.
                controller.selectWorkspace(.home)
                for entry in controller.tabSnapshot { controller.closeTab(entry.id) }
                controller.addTab(.terminal)
                controller.addTab(.terminal)
                controller.addTab(.terminal)
                expectEqual(controller.tabSnapshot.count, 3, "three tabs open")

                let third = controller.tabSnapshot[2].id
                controller.selectTab(controller.tabSnapshot[0].id)
                expect(controller.selectedTabID != third, "starting on the first tab")

                _ = NSApp.sendAction(items[2].action!, to: items[2].target, from: items[2])
                expectEqual(controller.selectedTabID, third, "⌘3 selected the third tab")

                // Items past the open tabs are greyed rather than dead keys.
                expect(delegate.validateMenuItem(items[2]), "⌘3 is enabled with three tabs")
                expect(!delegate.validateMenuItem(items[5]), "⌘6 is disabled with three tabs")
            }),

            .act("selecting a tab doesn't tear the strip down", {
                // Selection happens on mouse down; rebuilding the strip there
                // detaches the button and kills the drag that click started.
                let bar = findView(in: controller.window?.contentView) { view in
                    view is TabBarView
                } as? TabBarView
                guard let bar else { return expect(false, "the tab bar is on screen") }

                let before = bar.rebuildCountForTesting
                controller.selectTab(controller.tabSnapshot[0].id)
                controller.selectTab(controller.tabSnapshot[1].id)
                expectEqual(
                    bar.rebuildCountForTesting, before,
                    "switching tabs leaves the buttons in place"
                )

                // Adding or closing a tab does change the order, so it rebuilds.
                controller.addTab(.terminal)
                expect(
                    bar.rebuildCountForTesting > before,
                    "but a new tab still rebuilds the strip"
                )

                for entry in controller.tabSnapshot.dropFirst() {
                    controller.closeTab(entry.id)
                }
                expectEqual(controller.tabSnapshot.count, 1, "workspace reset for later steps")
            }),

            .act("many tabs scroll instead of widening the window", {
                guard let window = controller.window else {
                    return expect(false, "there is a window")
                }
                controller.selectWorkspace(.home)
                for entry in controller.tabSnapshot { controller.closeTab(entry.id) }
                controller.addTab(.terminal)

                let widthBefore = window.frame.width
                for _ in 1...12 { controller.addTab(.terminal) }
                expectEqual(controller.tabSnapshot.count, 13, "thirteen tabs open")
                expectEqual(
                    window.frame.width, widthBefore,
                    "the window is the same width as before"
                )

                // The strip itself is scrollable and its content now overflows.
                let scroller = findView(in: controller.window?.contentView) { view in
                    (view as? NSScrollView)?.documentView is NSStackView
                } as? NSScrollView
                expect(scroller != nil, "the tab strip lives in a scroll view")
                if let scroller, let document = scroller.documentView {
                    window.layoutIfNeeded()
                    expect(
                        document.frame.width > scroller.contentView.bounds.width,
                        "with more tabs than fit, so it scrolls"
                    )
                }

                for entry in controller.tabSnapshot.dropFirst() {
                    controller.closeTab(entry.id)
                }
                expectEqual(controller.tabSnapshot.count, 1, "workspace reset for later steps")
            }),

            .act("tabs advertise their ⌘-number", {
                controller.selectWorkspace(.home)
                for entry in controller.tabSnapshot { controller.closeTab(entry.id) }
                controller.addTab(.terminal)
                for _ in 1...10 { controller.addTab(.terminal) }
                expectEqual(controller.tabSnapshot.count, 11, "eleven tabs open")

                var buttons: [TabButtonView] = []
                collectViews(in: controller.window?.contentView, into: &buttons)
                // In strip order, which is the order the shortcuts follow.
                let ordered = buttons.sorted { $0.frame.minX < $1.frame.minX }

                expectEqual(
                    ordered.prefix(9).map(\.shortcutNumber), Array(1...9),
                    "the first nine are numbered in order"
                )
                expectEqual(
                    ordered.first?.shortcutTextForTesting, "⌘1",
                    "and the badge reads the chord itself"
                )
                expect(
                    ordered.dropFirst(9).allSatisfy { $0.shortcutNumber == nil },
                    "tabs past the ninth have no shortcut to advertise"
                )

                for entry in controller.tabSnapshot.dropFirst() {
                    controller.closeTab(entry.id)
                }
                expectEqual(controller.tabSnapshot.count, 1, "workspace reset for later steps")
            }),

            .act("⌘⇧1…⌘⇧9 switch workspaces", {
                guard let delegate = NSApp.delegate as? AppDelegate else {
                    return expect(false, "the app delegate is reachable")
                }

                let items = delegate.workspaceShortcutItems
                expectEqual(items.count, 9, "there are nine numbered workspace items")
                expect(
                    items.allSatisfy { $0.keyEquivalentModifierMask == [.command, .shift] },
                    "bound with command and shift, clear of the tab shortcuts"
                )
                expect(
                    items.allSatisfy { !$0.isHidden },
                    "and none hidden, or the keys wouldn't fire"
                )

                // Home is always first, so ⌘⇧1 lands there.
                expectEqual(
                    controller.orderedWorkspaceKeys.first, .home,
                    "Home leads the workspace order"
                )
                controller.selectWorkspace(.home)
                _ = NSApp.sendAction(items[0].action!, to: items[0].target, from: items[0])
                expectEqual(controller.currentWorkspaceKey, .home, "⌘⇧1 selects Home")

                // The sidebar advertises the same chords. Make sure it's on
                // screen and laid out first — a collapsed sidebar builds no
                // rows, and then every check below would pass on nothing.
                if let split = controller.window?.contentViewController
                    as? NSSplitViewController {
                    split.splitViewItems.first?.isCollapsed = false
                }
                controller.reloadSidebar()
                controller.window?.layoutIfNeeded()

                var rows: [SidebarCellView] = []
                collectViews(in: controller.window?.contentView, into: &rows)
                expect(!rows.isEmpty, "the sidebar has rows to check")

                let home = rows.first { $0.textField?.stringValue == "Home" }
                expect(home != nil, "including the Home row")
                expectEqual(home?.shortcutNumber, 1, "the Home row is numbered 1")
                expectEqual(
                    home?.shortcutTextForTesting, "⇧⌘1",
                    "and shows the chord that reaches it"
                )
                expect(
                    rows.first { $0.textField?.stringValue == "New Worktree" }?
                        .shortcutNumber == nil,
                    "action rows aren't workspaces, so they carry no chord"
                )

                expect(delegate.validateMenuItem(items[0]), "⌘⇧1 is enabled")
                expect(
                    !delegate.validateMenuItem(items[8]),
                    "⌘⇧9 is disabled with only Home around"
                )
            }),

            .act("the strip makes room for a visible scroller", {
                // Overlay scrollers float above the tabs and cost nothing.
                expectEqual(
                    TabBarView.scrollerAllowance(overflowing: true, style: .overlay), 0,
                    "an overlay scroller needs no extra height"
                )
                expectEqual(
                    TabBarView.scrollerAllowance(overflowing: false, style: .legacy), 0,
                    "nor does a strip that fits"
                )
                expect(
                    TabBarView.scrollerAllowance(overflowing: true, style: .legacy) > 0,
                    "but an always-visible scroller does, or it eats the tabs"
                )
            }),

            .act("the titlebar doesn't repeat the tab name", {
                expectEqual(
                    controller.window?.titleVisibility, .hidden,
                    "the title is hidden"
                )
                expect(
                    controller.window?.title.isEmpty == false,
                    "but still set, for the Window menu and app switcher"
                )
            }),

            .act("the window frame is remembered", {
                guard let window = controller.window else {
                    return expect(false, "there is a window")
                }
                let frame = NSRect(x: 120, y: 140, width: 960, height: 640)
                window.setFrame(frame, display: false)
                // The delegate method the real resize goes through.
                controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
            }),

            .waitUntil("the size is written to the database", {
                // Poll for the new frame specifically: a stored value from an
                // earlier step would satisfy a plain non-nil check without ever
                // waiting for the debounced save.
                AppState.string(forKey: "mainWindowFrame")
                    == controller.window?.frameDescriptor
            }),

            .act("and matches what's on screen", {
                guard let window = controller.window else { return }
                expectEqual(
                    AppState.string(forKey: "mainWindowFrame"),
                    window.frameDescriptor,
                    "the stored frame is the window's own"
                )
                expect(
                    AppState.string(forKey: "mainWindowFrame")?.contains("960") == true,
                    "including the width it was resized to"
                )
            }),

            .act("open the new-tab dialog", {
                PinnedSites.add(title: "Example Docs", url: example)
                controller.presentNewTabDialog()
            }),

            .waitUntil("new-tab dialog presented as a sheet", { dialog() != nil }),

            .act("dialog contents", {
                guard let dialog = dialog() else { return }
                expectEqual(
                    dialog.rowTitles,
                    ["Terminal", "Web Browser", "Example Docs", "Add Site…"],
                    "rows are terminal, browser, pins, then the way to add one"
                )
                dialog.presentAddSiteForTesting()
            }),

            .waitUntil("add-site sheet opens on top", { addSiteSheet() != nil }),

            .act("adding a site", {
                guard let sheet = addSiteSheet() else { return }

                expect(
                    !sheet.addForTesting(address: "somewhere nice"),
                    "text that isn't an address is refused"
                )
                expect(addSiteSheet() != nil, "and the sheet stays open to fix it")

                expect(sheet.addForTesting(address: "figma.com"), "a bare host is accepted")
            }),

            .waitUntil("add-site sheet closes", { addSiteSheet() == nil }),

            .act("the added site is in the list", {
                expectEqual(
                    PinnedSites.all.map(\.title), ["Example Docs", "Figma"],
                    "it was saved, named after its host"
                )
                expectEqual(
                    PinnedSites.all.last?.url.absoluteString, "https://figma.com",
                    "with https filled in"
                )
                expectEqual(
                    dialog()?.rowTitles,
                    ["Terminal", "Web Browser", "Example Docs", "Figma", "Add Site…"],
                    "and the launcher lists it without being reopened"
                )
                dialog()?.cancelForTesting()
            }),

            .waitUntil("dialog dismissed", { controller.window?.attachedSheet == nil }),

            .act("tidy up the pins", {
                PinnedSites.replaceAll(with: [])
                expectEqual(PinnedSites.all.count, 0, "pins cleared")
            }),

            .act("open a tab to close", {
                controller.addTab(.terminal)
                expectEqual(controller.tabSnapshot.count, 2, "second tab open")
            }),

            // libghostty reports a child process while the shell is still
            // coming up, so a tab closed in that instant would still prompt.
            .waitUntil("the new shell reaches its prompt", {
                controller.selectedTab?.isDisposable == true
            }),

            .act("closing an idle terminal doesn't nag", {
                guard let tab = controller.selectedTab else {
                    return expect(false, "the new tab is selected")
                }
                expect(tab.isDisposable, "a shell at a prompt has nothing at stake")

                controller.requestCloseTab(tab.id)
                expect(
                    controller.window?.attachedSheet == nil,
                    "so ⌘W closes it without a confirmation"
                )
                expectEqual(controller.tabSnapshot.count, 1, "and it is gone")
            }),

            .act("but a tab with something running still asks", {
                // Split in a stub that reports work in progress — a real
                // terminal can't be made busy deterministically here.
                let tab = controller.addTab(.terminal)
                guard let paneID = tab.focusedPaneID else {
                    return expect(false, "the new tab has a pane")
                }
                _ = tab.split(paneID, .right, content: StubContent(disposable: false))

                expect(!tab.isDisposable, "the tab reports something at stake")
                controller.requestCloseTab(tab.id)
            }),

            .waitUntil("close puts up a confirmation", {
                controller.window?.attachedSheet != nil
            }),

            .act("cancelling keeps the tab", {
                expectEqual(controller.tabSnapshot.count, 2, "tab still open while asking")
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
            }),

            .waitUntil("confirmation dismissed", { controller.window?.attachedSheet == nil }),

            .act("cancel left the tab alone", {
                expectEqual(controller.tabSnapshot.count, 2, "cancel left the tab open")
            }),

            .act("process-exit close skips confirmation", {
                controller.closeTab(controller.tabSnapshot.last!.id)
                expectEqual(controller.tabSnapshot.count, 1, "closed without asking")
                expect(controller.window?.attachedSheet == nil, "no confirmation sheet")
            }),

            .act("splitting the focused pane", {
                guard let tab = controller.selectedTab else {
                    return expect(false, "a selected tab")
                }
                expectEqual(tab.paneCount, 1, "a tab starts as a single pane")

                controller.splitFocusedPane(.right)
                expectEqual(tab.paneCount, 2, "⌘D adds a pane")
                expectEqual(controller.tabSnapshot.count, 1, "and does not add a tab")
                expect(tab.focusedPaneID == tab.panes.last?.id, "focus moves to the new pane")

                controller.splitFocusedPane(.down)
                expectEqual(tab.paneCount, 3, "⌘⇧D splits the focused pane again")
            }),

            .act("drop zones follow the pointer", {
                let rect = NSRect(x: 0, y: 0, width: 100, height: 100)
                expectEqual(
                    SplitContainerView.dropDirection(for: NSPoint(x: 90, y: 50), in: rect),
                    .right, "near the right edge, split right")
                expectEqual(
                    SplitContainerView.dropDirection(for: NSPoint(x: 10, y: 50), in: rect),
                    .left, "near the left edge, split left")
                expectEqual(
                    SplitContainerView.dropDirection(for: NSPoint(x: 50, y: 90), in: rect),
                    .up, "near the top edge, split up")
                expectEqual(
                    SplitContainerView.dropDirection(for: NSPoint(x: 50, y: 10), in: rect),
                    .down, "near the bottom edge, split down")
                expectEqual(
                    SplitContainerView.highlightRect(.right, in: rect),
                    NSRect(x: 50, y: 0, width: 50, height: 100),
                    "the highlight covers the half the pane will take")
            }),

            .act("a drag over a pane offers to split it", {
                guard let dragged = controller.selectedTab else {
                    return expect(false, "a tab to drag")
                }

                // A fresh single-pane tab, so there is no doubt which pane a
                // point is over.
                let target = controller.addTab(.terminal)
                controller.window?.layoutIfNeeded()

                guard let container = target.view as? SplitContainerView,
                      container.bounds.width > 0
                else { return expect(false, "the tab is a laid-out split container") }

                expect(
                    container.registeredDraggedTypes.contains(
                        SplitContainerView.tabPasteboardType),
                    "the pane area accepts dragged tabs"
                )

                // Drive the destination the way AppKit does, without moving the
                // real mouse. Dragging info carries window coordinates.
                func hover(_ tabID: UUID, _ spot: NSPoint) -> NSDragOperation {
                    container.draggingUpdated(
                        FakeDrag(tabID: tabID, location: container.convert(spot, to: nil))
                    )
                }

                let bounds = container.bounds
                let nearRight = NSPoint(x: bounds.maxX - 20, y: bounds.midY)
                expectEqual(hover(dragged.id, nearRight), .move,
                            "hovering a tab over a pane offers a move")
                expectEqual(container.currentDropTarget?.direction, .right,
                            "near the right edge it will split right")
                expectEqual(container.currentDropHighlight,
                            SplitContainerView.highlightRect(.right, in: bounds),
                            "and the right half is highlighted")

                let nearBottom = NSPoint(x: bounds.midX, y: bounds.minY + 20)
                expectEqual(hover(dragged.id, nearBottom), .move, "still a move lower down")
                expectEqual(container.currentDropTarget?.direction, .down,
                            "near the bottom edge it will split down")

                // Its own tab is not a valid target: it is already there.
                expectEqual(hover(target.id, nearRight), [],
                            "a tab can't be dropped into itself")
                expect(container.currentDropHighlight == nil,
                       "and nothing is highlighted for it")

                _ = hover(dragged.id, nearRight)
                container.draggingExited(nil)
                expect(container.currentDropHighlight == nil, "leaving clears the highlight")

                controller.closeTab(target.id)
            }),

            .act("dragging a tab into another tab", {
                guard let target = controller.selectedTab, let pane = target.focusedPane else {
                    return expect(false, "a selected tab with a focused pane")
                }
                let panesBefore = target.paneCount

                let dragged = controller.addTab(.browser, url: example)
                expectEqual(controller.tabSnapshot.count, 2, "two tabs before the drop")

                // The same call the drop handler makes.
                controller.moveTab(
                    dragged.id,
                    into: target.id,
                    target: SplitDropTarget(paneID: pane.id, direction: .down)
                )

                expectEqual(controller.tabSnapshot.count, 1, "the dragged tab left the strip")
                expectEqual(target.paneCount, panesBefore + 1, "and became a pane")
                expect(
                    target.panes.contains { $0.content is BrowserTabContent },
                    "the browser came with it"
                )
                expectEqual(controller.selectedTabID, target.id, "the receiving tab is selected")
            }),

            .act("closing a split keeps the tab", {
                guard let tab = controller.selectedTab else {
                    return expect(false, "a selected tab")
                }
                for paneID in tab.panes.map(\.id).dropFirst() {
                    controller.closePane(tabID: tab.id, paneID: paneID)
                }
                expectEqual(tab.paneCount, 1, "the splits are gone")
                expectEqual(controller.tabSnapshot.count, 1, "the tab is still open")
                expect(controller.window?.attachedSheet == nil, "closing a split asked nothing")
            }),

            .act("hook events become agent states", {
                func state(_ event: String) -> AgentState? {
                    AgentActivityStore.state(forEvent: event)
                }
                expectEqual(state("UserPromptSubmit"), .working, "a prompt starts a turn")
                expectEqual(state("PostToolUse"), .working, "a finished tool call is progress")
                expectEqual(state("PermissionRequest"), .blocked, "a permission prompt blocks")
                expectEqual(state("Notification"), .blocked, "so does a notification")
                expectEqual(state("Stop"), .finished, "the turn ending wants the user")
                expectEqual(state("StopFailure"), .finished, "so does one that failed")
                expectEqual(state("SessionStart"), .idle, "a fresh session wants nothing")
                expect(state("SubagentStop") == nil, "unregistered events are ignored")

                // Every event we register has to map to something, or the hook
                // would fire into the void.
                expect(
                    ClaudeHooks.registrations.allSatisfy { state($0.event) != nil },
                    "every registered event maps to a state"
                )
            }),

            .act("a worktree shows its most demanding pane", {
                expectEqual(
                    [AgentState.working, .idle, .blocked].max(), .blocked,
                    "a blocked agent outranks a working one")
                expectEqual(
                    [AgentState.working, .finished].max(), .finished,
                    "and a finished turn outranks work still going on")
                expectEqual([AgentState]().max() ?? .idle, .idle, "no terminals, no dot")
            }),

            .act("reported events reach the store", {
                agents.start()
                expectEqual(agents.state(ofAgent: "alpha"), .idle, "an unknown terminal is idle")

                report("UserPromptSubmit", from: "alpha")
                report("PermissionRequest", from: "beta")
                agents.reload()

                expectEqual(agents.state(ofAgent: "alpha"), .working, "alpha is working")
                expectEqual(agents.state(ofAgent: "beta"), .blocked, "beta is blocked")
                expectEqual(
                    agents.state(ofAgents: ["alpha", "beta"]), .blocked,
                    "and together they ask for attention")
            }),

            .act("a finished turn clears once it has been seen", {
                report("Stop", from: "alpha")
                agents.reload()
                expectEqual(agents.state(ofAgent: "alpha"), .finished, "the turn ended")

                agents.acknowledge(["alpha", "beta"])
                expectEqual(agents.state(ofAgent: "alpha"), .idle, "looking at it puts it out")
                expectEqual(
                    agents.state(ofAgent: "beta"), .blocked,
                    "but a blocked agent stays lit until it is answered")

                report("UserPromptSubmit", from: "alpha")
                agents.reload()
                expectEqual(
                    agents.state(ofAgent: "alpha"), .working,
                    "and a new turn lights it again")
            }),

            .waitUntil("the directory watch notices a report", {
                // Written without calling reload: this is the path the hook
                // actually takes.
                report("Stop", from: "gamma")
                return agents.state(ofAgent: "gamma") == .finished
            }),

            .act("closing a terminal forgets its agent", {
                agents.forget("alpha")
                expectEqual(agents.state(ofAgent: "alpha"), .idle, "the state is dropped")
                expect(
                    !FileManager.default.fileExists(
                        atPath: agentDirectory.appendingPathComponent("alpha.json").path),
                    "and so is its file"
                )
            }),

            .act("hook entries merge into settings.json", {
                // A path with a space in it, because ours has one.
                let script = "/Users/someone/Library/Application Support/TabTerm/hooks/"
                    + ClaudeHooks.scriptName
                let command = ClaudeHooks.command(scriptPath: script, event: "Stop")
                expect(command.contains("'\(script)' Stop"), "the script path is quoted")

                let existing: [String: Any] = [
                    "model": "opus",
                    "hooks": [
                        "Stop": [["hooks": [["type": "command", "command": "say done"]]]]
                    ],
                ]

                let installed = ClaudeHooks.settings(byAdding: existing, scriptPath: script)
                expectEqual(installed["model"] as? String, "opus", "other settings survive")

                let hooks = installed["hooks"] as? [String: Any] ?? [:]
                expect(
                    ClaudeHooks.registrations.allSatisfy { hooks[$0.event] != nil },
                    "every event we watch is registered"
                )
                expectEqual(
                    (hooks["Stop"] as? [[String: Any]])?.count, 2,
                    "ours sits beside the user's own Stop hook")

                let again = ClaudeHooks.settings(byAdding: installed, scriptPath: script)
                expectEqual(
                    ((again["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count, 2,
                    "installing twice doesn't stack up duplicates")

                let removed = ClaudeHooks.settings(byRemoving: again, scriptPath: script)
                expectEqual(removed["model"] as? String, "opus", "removal leaves the rest alone")
                let stop = (removed["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
                expectEqual(stop?.count, 1, "the user's Stop hook is kept")
                expectEqual(
                    ((stop?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String),
                    "say done", "exactly as it was")
                expect(
                    (removed["hooks"] as? [String: Any])?["PermissionRequest"] == nil,
                    "and events only we used are gone entirely"
                )

                // A file that was ours alone comes back empty, not with a
                // leftover "hooks": {}.
                let ours = ClaudeHooks.settings(byAdding: [:], scriptPath: script)
                let bare = ClaudeHooks.settings(byRemoving: ours, scriptPath: script)
                expect(bare["hooks"] == nil, "nothing of ours is left behind")

                // An entry the user added their own command to keeps theirs.
                let shared: [String: Any] = [
                    "hooks": [
                        "Stop": [[
                            "hooks": [
                                ["type": "command", "command": "say done"],
                                ["type": "command", "command": command],
                            ]
                        ]]
                    ]
                ]
                let kept = ClaudeHooks.settings(byRemoving: shared, scriptPath: script)
                let entry = ((kept["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first
                expectEqual(
                    (entry?["hooks"] as? [[String: Any]])?.count, 1,
                    "a shared entry keeps the user's command")
            }),

            .act("a terminal carries its agent id into the pty", {
                let probe = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("tabterm-env-\(UUID().uuidString)")
                envProbe = probe

                let terminal = TerminalTabContent(
                    command: "sh -c 'printf %s \"$TABTERM_AGENT_ID\" > \(probe.path)'"
                )
                envTerminal = terminal

                expect(!terminal.agentID.isEmpty, "the terminal has an agent id")
                expectEqual(
                    AgentActivityStore.shared.environment(forAgent: terminal.agentID),
                    [
                        "TABTERM_AGENT_ID": terminal.agentID,
                        "TABTERM_AGENT_DIR": AgentActivityStore.shared.directory.path,
                    ],
                    "and hands the hook both the id and where to report"
                )
            }),

            .waitUntil("the shell sees TABTERM_AGENT_ID", {
                guard let envProbe, let terminal = envTerminal,
                      let written = try? String(contentsOf: envProbe, encoding: .utf8)
                else { return false }
                return written == terminal.agentID
            }),

            .act("done with the probe terminal", {
                envTerminal?.close()
                envTerminal = nil
                if let envProbe { try? FileManager.default.removeItem(at: envProbe) }
            }),

            .act("an agent reports into the workspace on screen", {
                // The whole chain, against the real store the app is watching:
                // an event lands the way the hook leaves it, and the row for the
                // workspace that terminal belongs to grows a dot.
                guard let agentID = controller.visibleAgentIDsForTesting.first else {
                    return expect(false, "a terminal in the visible workspace")
                }
                litAgent = agentID

                let store = AgentActivityStore.shared
                let event =
                    "{\"event\":\"PermissionRequest\",\"at\":\(Date().timeIntervalSince1970)}"
                try? event.write(
                    to: store.directory.appendingPathComponent("\(agentID).json"),
                    atomically: true,
                    encoding: .utf8
                )
                store.reload()
                // Blocked, so being the workspace on screen doesn't clear it —
                // a prompt you have looked at is still a prompt.
                expectEqual(store.state(ofAgent: agentID), .blocked, "the store took the event")
            }),

            .waitUntil("the sidebar row lights up", {
                // Rows are realized lazily, so lay out before looking for them.
                controller.window?.layoutIfNeeded()
                var cells: [SidebarCellView] = []
                collectViews(in: controller.sidebarPanel.view, into: &cells)
                guard !cells.isEmpty else { return false }
                return cells.contains { $0.agentStateForTesting == .blocked }
            }),

            .act("and goes out when the terminal does", {
                guard let agentID = litAgent else { return expect(false, "a lit agent") }
                AgentActivityStore.shared.forget(agentID)
                controller.sidebarPanel.refreshAgentStates()
                controller.window?.layoutIfNeeded()

                var cells: [SidebarCellView] = []
                collectViews(in: controller.sidebarPanel.view, into: &cells)
                expect(
                    cells.allSatisfy { $0.agentStateForTesting == .idle },
                    "no row is left showing a dot"
                )
            }),

            .act("the dot only colours the two states worth interrupting for", {
                expectEqual(
                    AgentStatusDotView.color(for: .working), ClaudeIcon.color,
                    "working borrows the mark's orange")
                expectEqual(
                    AgentStatusDotView.color(for: .blocked), NSColor.systemRed,
                    "blocked is red")
                expectEqual(
                    AgentStatusDotView.color(for: .finished), NSColor.systemRed,
                    "and so is a turn that ended")
                expect(
                    AgentStatusDotView.tooltip(for: .idle) == nil,
                    "an idle row explains nothing, because it shows nothing")
            }),
        ], then: {
            try? FileManager.default.removeItem(at: agentDirectory)
            if let temporaryRepo {
                try? FileManager.default.removeItem(atPath: temporaryRepo)
                try? FileManager.default.removeItem(atPath: temporaryRepo + "-worktrees")
            }

            print("\n\(checks - failures.count)/\(checks) checks passed")
            if failures.isEmpty {
                print("SELF-TEST PASSED")
                exit(0)
            }
            print("SELF-TEST FAILED:")
            for failure in failures { print("  - \(failure)") }
            exit(1)
        })
    }
}

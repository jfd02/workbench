import AppKit
import TabTermKit

/// An in-process smoke test, run with `Workbench --self-test`.
///
/// It calls the same methods the buttons and menu items call, so behavior can
/// be verified without synthesizing mouse or keyboard events. That means it
/// never moves the cursor and never steals focus from whatever you're doing.
/// Something being dragged over a view, without a real mouse involved.
///
/// AppKit hands the destination an `NSDraggingInfo`; this is the smallest one
/// that carries a pasteboard and a location.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard

    init(location: NSPoint = .zero, contents: (NSPasteboard) -> Void) {
        draggingLocation = location
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("tabterm-selftest"))
        draggingPasteboard.clearContents()
        contents(draggingPasteboard)
        super.init()
    }

    /// A tab from the tab bar.
    convenience init(tabID: UUID, location: NSPoint) {
        self.init(location: location) {
            $0.setString(tabID.uuidString, forType: SplitContainerView.tabPasteboardType)
        }
    }

    /// Files from Finder, or a screenshot's floating thumbnail.
    convenience init(files: [URL]) {
        self.init { pasteboard in
            pasteboard.writeObjects(files as [NSURL])
        }
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
/// driven without a real terminal behind it.
private extension NSView {
    /// The middle of the view in window coordinates, where a click on it lands.
    var centerInWindow: NSPoint {
        convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
    }
}

private final class StubContent: TabContent {
    /// Stands in for content with something at stake, which a real terminal
    /// can't be made into deterministically.
    var isDisposable: Bool

    init(disposable: Bool = true) {
        isDisposable = disposable
    }

    let view = NSView()
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

    /// A small solid-colour image, standing in for an icon that content
    /// reports about whatever it is running.
    static func swatch(size: Int = 64) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
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
    /// The sidebar row titled `title`, if one is on screen.
    private static func sidebarRow(
        _ title: String,
        in controller: MainWindowController
    ) -> SidebarCellView? {
        var cells: [SidebarCellView] = []
        collectViews(in: controller.window?.contentView, into: &cells)
        return cells.first { $0.textField?.stringValue == title }
    }

    private static func collectViews<T: NSView>(in root: NSView?, into found: inout [T]) {
        guard let root else { return }
        if let match = root as? T { found.append(match) }
        for subview in root.subviews { collectViews(in: subview, into: &found) }
    }

    /// The strip's button for one tab.
    private static func tabButton(for id: UUID?, in controller: MainWindowController) -> TabButtonView? {
        guard let id else { return nil }
        var buttons: [TabButtonView] = []
        collectViews(in: controller.window?.contentView, into: &buttons)
        return buttons.first { $0.tabID == id }
    }

    /// A click of a mouse button past left and right, at a point in window
    /// coordinates. `NSEvent`'s own constructor always reports button 0, so
    /// this goes through CGEvent, which takes a screen point with a flipped
    /// origin — and hands back an event whose `locationInWindow` reads as the
    /// unflipped point, which is what the view being clicked converts.
    private static func otherMouseUp(button: Int, at point: NSPoint) -> NSEvent? {
        guard let primary = NSScreen.screens.first,
              let button = CGMouseButton(rawValue: UInt32(button)),
              let event = CGEvent(
                  mouseEventSource: nil,
                  mouseType: .otherMouseUp,
                  mouseCursorPosition: CGPoint(x: point.x, y: primary.frame.maxY - point.y),
                  mouseButton: button
              )
        else { return nil }
        return NSEvent(cgEvent: event)
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
        print("Workbench self-test")

        var temporaryRepo: String?
        var scratchRepository: Repository?
        var featureWorktree: Worktree?
        var mainWorktreeID: Int64?
        var externalWorktreeID: Int64?

        // Agent status runs against a throwaway directory, never the one the
        // running app watches.
        let agentDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "tabterm-agents-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        let agents = AgentActivityStore(directory: agentDirectory)
        var envTerminal: TerminalTabContent?
        var nativeTerminal: TerminalTabContent?
        var envProbe: URL?
        var dropSurface: GhosttySurfaceView?
        var dropReady: URL?
        var dropProbe: URL?
        var dropFiles: [URL] = []
        var dropExpected = ""
        var litAgent: String?
        var resumeTerminal: TerminalTabContent?
        var resumeProbe: URL?
        var resumeRunner: URL?
        var restoreProbe: URL?
        var restoreRunner: URL?
        var phoneTerminal: TerminalTabContent?
        var phones: [TestPhone] = []
        var phonePort: UInt16 = 0
        var pairingCode = ""
        var macSize = TerminalSize(cols: 0, rows: 0)
        var phoneRepository: Repository?

        // The hook script is generated Swift-side as a string, so the only way
        // to know the escaping survives into bash is to run the real thing.
        let hookDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "tabterm-hooks-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )

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

        /// An executable stand-in for an agent: running it writes `mark` to a
        /// file, so a command typed into a terminal can be observed landing.
        ///
        /// Its argv has the shape a real agent's does — the path, then the path
        /// again — and it ignores the resume flags appended after it.
        func makeRunner(mark: String) -> (runner: URL, probe: URL) {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            let probe = directory.appendingPathComponent("tabterm-\(mark)-\(UUID().uuidString)")
            let runner = directory
                .appendingPathComponent("tabterm-runner-\(UUID().uuidString).sh")
            try? "#!/bin/sh\nprintf %s \(mark) > \(probe.path)\n"
                .write(to: runner, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: runner.path)
            return (runner, probe)
        }

        /// Run the installed hook script the way an agent runs it, and hand back
        /// whatever it left in the state directory.
        ///
        /// `onStdin` is the difference between the two: Claude Code pipes the
        /// payload in, while codex has passed it as an argument.
        func runHook(
            event: String,
            agent: String,
            payload: String,
            onStdin: Bool = true,
            from agentID: String
        ) -> [String: Any]? {
            try? FileManager.default.createDirectory(
                at: hookDirectory, withIntermediateDirectories: true)
            let script = hookDirectory.appendingPathComponent(AgentHooks.scriptName)
            try? AgentHooks.script.write(to: script, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, event, agent] + (onStdin ? [] : [payload])
            process.environment = [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "TABTERM_AGENT_ID": agentID,
                "TABTERM_AGENT_DIR": hookDirectory.path,
            ]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            try? process.run()
            if onStdin { input.fileHandleForWriting.write(Data(payload.utf8)) }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()

            let file = hookDirectory.appendingPathComponent("\(agentID).json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }

        run(steps: [
            .act("storage", {
                // main.swift redirected us to a temp file for this run.
                expect(AppDatabase.shared.openError == nil, "database opened cleanly")

                AppState.set("hello", forKey: "selftest")
                expectEqual(AppState.string(forKey: "selftest"), "hello", "app state round-trips")
                AppState.set("world", forKey: "selftest")
                expectEqual(AppState.string(forKey: "selftest"), "world", "app state overwrites")
                AppState.set(nil, forKey: "selftest")
                expect(AppState.string(forKey: "selftest") == nil, "app state deletes")
            }),

            .act("startup state", {
                expectEqual(controller.tabSnapshot.count, 1, "one tab at launch")
                expect(controller.selectedTabContent is TerminalTabContent, "it is a terminal")
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
                let icon = swatch()

                let stub = StubContent()
                let tab = Tab(content: stub)
                var refreshes = 0
                tab.onTitleChange = { refreshes += 1 }

                expect(tab.icon == nil, "a tab with no icon falls back to the terminal symbol")
                stub.emit(icon)
                expect(tab.icon === icon, "the tab takes the icon from its focused pane")
                expectEqual(refreshes, 1, "and asks the tab bar to redraw once")

                let button = TabButtonView(tabID: tab.id, title: "Example")
                let symbol = button.iconImageForTesting
                expect(symbol != nil, "a tab button starts with the terminal symbol")
                button.icon = icon
                expect(button.iconImageForTesting === icon, "an icon replaces the symbol")
                button.icon = nil
                expect(button.iconImageForTesting !== icon, "and clearing it puts the symbol back")

                tab.closeAll()
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

                expect(
                    ForegroundProcess.agent(commandLine: ["/Users/x/.local/bin/codex"]) == .codex,
                    "the codex binary is recognized too"
                )
                expect(
                    ForegroundProcess.agent(commandLine: [
                        "/Users/x/.local/bin/codex-code-mode-host",
                    ]) == nil,
                    "but not another binary its name is only the start of"
                )
                expect(
                    ForegroundProcess.agent(commandLine: ["/usr/bin/vim", "vim", "codex.md"]) == nil,
                    "nor an editor holding a file named after it"
                )
            }),

            .act("a resumed session keeps the flags it was started under", {
                // The shape the kernel actually reports, checked against a live
                // `claude` process: the executable path, then argv — which
                // repeats it — then the flags. A shell alias is long gone by
                // this point, so replaying argv is the only way to know that
                // this session was started in permission-skipping mode.
                let yolo = [
                    "/Users/x/.claude/local/node_modules/.bin/claude",
                    "/Users/x/.claude/local/node_modules/.bin/claude",
                    "--dangerously-skip-permissions",
                ]
                let claude = AgentSession(agent: .claude, sessionID: "abc-123", commandLine: yolo)
                expectEqual(
                    claude?.resumeCommand,
                    "/Users/x/.claude/local/node_modules/.bin/claude"
                        + " --dangerously-skip-permissions --resume abc-123",
                    "the recorded command line comes back with a resume flag"
                )

                let node = AgentSession(
                    agent: .claude,
                    sessionID: "n1",
                    commandLine: [
                        "/opt/homebrew/bin/node", "node",
                        "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                    ]
                )
                expectEqual(
                    node?.resumeCommand,
                    "/opt/homebrew/bin/node"
                        + " /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
                        + " --resume n1",
                    "an npm install replays as the node command it is"
                )

                // A pane restored twice must not accumulate resume flags.
                let again = AgentSession(
                    agent: .claude,
                    sessionID: "new",
                    commandLine: ["/bin/claude", "/bin/claude", "--resume", "old", "--model", "opus"]
                )
                expectEqual(
                    again?.resumeCommand,
                    "/bin/claude --model opus --resume new",
                    "an earlier resume is replaced, not appended to"
                )
                expectEqual(
                    AgentSession(
                        agent: .claude,
                        sessionID: "new",
                        commandLine: ["/bin/claude", "/bin/claude", "-c"]
                    )?.resumeCommand,
                    "/bin/claude --resume new",
                    "and so is a bare --continue"
                )

                expectEqual(
                    AgentSession(
                        agent: .codex,
                        sessionID: "c1",
                        commandLine: ["/bin/codex", "/bin/codex", "--search"]
                    )?.resumeCommand,
                    "/bin/codex resume --search c1",
                    "codex resumes through a subcommand, carrying its flags across"
                )
                expectEqual(
                    AgentSession(
                        agent: .codex,
                        sessionID: "c2",
                        commandLine: ["/bin/codex", "/bin/codex", "resume", "--last", "--search"]
                    )?.resumeCommand,
                    "/bin/codex resume --search c2",
                    "a session that was itself resumed doesn't stack subcommands"
                )
                expectEqual(
                    AgentSession(
                        agent: .codex,
                        sessionID: "c4",
                        commandLine: ["/bin/codex", "/bin/codex", "-m", "gpt-5.1-codex"]
                    )?.resumeCommand,
                    "/bin/codex resume -m gpt-5.1-codex c4",
                    "and a flag's value travels with it"
                )
                expect(
                    AgentSession(
                        agent: .codex,
                        sessionID: "c3",
                        commandLine: ["/bin/codex", "/bin/codex", "exec", "do a thing"]
                    ) == nil,
                    "a one-shot `codex exec` is not a session to come back to"
                )

                expectEqual(
                    AgentSession(
                        agent: .claude,
                        sessionID: "m1",
                        commandLine: ["/bin/claude", "/bin/claude", "--model", "opus"]
                    )?.resumeCommand,
                    "/bin/claude --model opus --resume m1",
                    "a flag that takes a value keeps it"
                )

                expectEqual(
                    AgentSession(
                        agent: .claude,
                        sessionID: "q1",
                        commandLine: ["/opt/My Tools/claude"]
                    )?.resumeCommand,
                    "'/opt/My Tools/claude' --resume q1",
                    "a path with a space in it is quoted"
                )
                expect(
                    AgentSession(agent: .claude, sessionID: "", commandLine: ["/bin/claude"]) == nil,
                    "a session with no id is nothing to resume"
                )
            }),

            .act("a session started with a prompt is not resumed at all", {
                // The prompt was an instruction, and it has already been given.
                // Sending it again on every restart — in whatever permission
                // mode the pane was in — is worse than not resuming, so a
                // command line carrying one is left as a plain shell.
                expect(
                    AgentSession(
                        agent: .claude,
                        sessionID: "p1",
                        commandLine: [
                            "/bin/claude", "/bin/claude",
                            "--dangerously-skip-permissions", "fix the tests",
                        ]
                    ) == nil,
                    "a prompt after a flag is still a prompt"
                )
                expect(
                    AgentSession(
                        agent: .claude,
                        sessionID: "p2",
                        commandLine: ["/bin/claude", "/bin/claude", "fix the tests"]
                    ) == nil,
                    "and so is one on its own"
                )
                expect(
                    AgentSession(
                        agent: .codex,
                        sessionID: "p3",
                        commandLine: ["/bin/codex", "/bin/codex", "fix the tests"]
                    ) == nil,
                    "codex is read the same way"
                )

                // The rule that separates the two: a value belongs to the flag
                // in front of it. A flag we don't know is assumed not to take
                // one, so its value reads as a prompt and the pane is left
                // alone — wrong in the safe direction.
                expect(
                    AgentSession(
                        agent: .claude,
                        sessionID: "p4",
                        commandLine: ["/bin/claude", "/bin/claude", "--future-flag", "value"]
                    ) == nil,
                    "an unknown flag's value is treated as a prompt, not replayed"
                )

                // The one bare word that isn't a prompt: the agent naming
                // itself, for an install that runs through a runtime.
                expectEqual(
                    AgentSession(
                        agent: .claude,
                        sessionID: "p5",
                        commandLine: [
                            "/opt/homebrew/bin/node", "node", "--enable-source-maps",
                            "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                        ]
                    )?.resumeCommand,
                    "/opt/homebrew/bin/node --enable-source-maps"
                        + " /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
                        + " --resume p5",
                    "which is kept wherever it sits"
                )
            }),

            .act("a session whose transcript is gone is left alone", {
                let transcript = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("tabterm-transcript-\(UUID().uuidString).jsonl")
                FileManager.default.createFile(atPath: transcript.path, contents: Data())

                let live = AgentSession(
                    agent: .claude,
                    sessionID: "t1",
                    commandLine: ["/bin/claude"],
                    transcript: transcript.path
                )
                expect(live?.isResumable == true, "a session whose transcript is there resumes")

                try? FileManager.default.removeItem(at: transcript)
                expect(
                    live?.isResumable == false,
                    "one deleted since the window closed does not"
                )
                expect(live?.resumeCommand == nil, "so nothing is typed for it")

                expect(
                    AgentSession(
                        agent: .claude, sessionID: "t2", commandLine: ["/bin/claude"]
                    )?.isResumable == true,
                    "a session the hook never named a transcript for is still tried"
                )
            }),

            .act("saved layouts carry the session, old ones decode without it", {
                let session = AgentSession(
                    agent: .codex,
                    sessionID: "s-1",
                    commandLine: ["/bin/codex", "/bin/codex", "--yolo"],
                    transcript: "/tmp/rollout.jsonl"
                )
                let layout = SavedLayout.split(
                    stacked: true,
                    ratio: 0.4,
                    first: .pane(directory: "/tmp", agent: session, focused: true),
                    second: .pane(directory: nil, agent: nil, focused: false)
                )
                guard let json = layout.json else {
                    return expect(false, "a layout with a session encodes")
                }
                expectEqual(SavedLayout(json: json), layout, "and round-trips unchanged")
                expectEqual(
                    SavedLayout(json: json)?.leaves.first?.agent?.sessionID, "s-1",
                    "with the session id on the right leaf")

                // Rows written before any of this existed, and before that by a
                // build that still had browser tabs. Both have to keep their
                // shape rather than collapsing to one pane.
                let old = #"{"split":{"stacked":true,"ratio":0.4,"#
                    + #""first":{"pane":{"directory":"/tmp","focused":true}},"#
                    + #""second":{"pane":{"kind":"browser","url":"https://x","focused":false}}}}"#
                guard let decoded = SavedLayout(json: old) else {
                    return expect(false, "a layout saved before agents were restored still decodes")
                }
                expectEqual(decoded.leaves.count, 2, "keeping both panes")
                expect(decoded.leaves.first?.agent == nil, "with no session to resume")
                expectEqual(decoded.leaves.first?.directory, "/tmp", "and the directory it had")
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
                        "-c", "user.name=Workbench Self Test",
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

                controller.reloadSidebar()

                // Home has whatever tabs the earlier steps left it.
                let homeTabs = controller.tabSnapshot.count
                controller.selectWorkspace(.worktree(id))
                expectEqual(controller.currentWorkspaceKey, .worktree(id), "switched workspace")
                expectEqual(controller.tabSnapshot.count, 1, "new workspace opens one terminal")

                controller.addTab()
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

            .act("changes and CI panels follow the workspace", {
                guard let id = featureWorktree?.id,
                      let split = controller.window?.contentViewController as? NSSplitViewController,
                      let inspector = split.splitViewItems.last,
                      let review = inspector.viewController as? ReviewViewController
                else { return expect(false, "the review panel is installed") }
                controller.selectWorkspace(.worktree(id))
                controller.toggleChangesPanel()
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                expect(!inspector.isCollapsed, "Changes opens the inspector")
                expect(!review.displaysCI, "Changes shows the file list")
                expect(review.view.bounds.width >= 299, "the inspector has usable width")
                controller.toggleCIPanel()
                expect(!inspector.isCollapsed && review.displaysCI, "CI switches the open inspector")
                controller.toggleCIPanel()
                expect(inspector.isCollapsed, "pressing CI again closes the inspector")
                controller.toggleChangesPanel()
                controller.selectWorkspace(.home)
                expect(inspector.isCollapsed, "Home hides repository review")
                let changes = findView(in: controller.window?.contentView, where: { $0.accessibilityIdentifier() == "showChanges" }) as? NSButton
                expect(changes?.isEnabled == false, "Home disables the Changes button")
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

            // Anything the sidebar asked git earlier has to land first, or it
            // could overwrite what the next step sets up.
            .waitUntil("git has answered for every worktree", {
                !WorktreeActivity.isCheckingForTesting
            }),

            .act("a worktree whose code sits unchanged goes stale", {
                guard let feature = featureWorktree
                else { return expect(false, "the scratch repo is still set up") }

                // The branch's last commit, and the worktree itself, from well back.
                let longAgo = Date().addingTimeInterval(
                    -Double(WorktreeActivity.staleAfterDays + 3) * 86_400 - 3_600)
                let commit = Process()
                commit.executableURL = GitService.executableURL
                commit.arguments = [
                    "-c", "user.email=selftest@tabterm.local",
                    "-c", "user.name=Workbench Self Test",
                    "commit", "--allow-empty", "-m", "old work",
                ]
                commit.currentDirectoryURL = URL(fileURLWithPath: feature.path)
                var environment = ProcessInfo.processInfo.environment
                let stamp = "@\(Int(longAgo.timeIntervalSince1970)) +0000"
                environment["GIT_AUTHOR_DATE"] = stamp
                environment["GIT_COMMITTER_DATE"] = stamp
                commit.environment = environment
                commit.standardOutput = FileHandle.nullDevice
                commit.standardError = FileHandle.nullDevice
                try? commit.run()
                commit.waitUntilExit()
                expectEqual(commit.terminationStatus, 0, "made a commit dated well back")
                try? FileManager.default.setAttributes(
                    [.creationDate: longAgo], ofItemAtPath: feature.path)

                WorktreeActivity.resetForTesting()
                controller.selectWorkspace(.home)
                controller.reloadSidebar()
            }),

            .waitUntil("an untouched worktree counts its days", {
                guard let feature = featureWorktree else { return false }
                return sidebarRow(feature.displayName, in: controller)?.staleDays
                    == WorktreeActivity.staleAfterDays + 3
            }),

            .act("and greys out, even when highlighted", {
                guard let feature = featureWorktree, let featureID = feature.id
                else { return expect(false, "the scratch repo is still set up") }

                expectEqual(
                    sidebarRow(feature.displayName, in: controller)?.iconTintForTesting,
                    NSColor.secondaryLabelColor,
                    "its icon goes grey"
                )
                expect(
                    sidebarRow("main", in: controller)?.staleDays == nil,
                    "the main checkout carries no count"
                )

                // Looking at it isn't a code change.
                controller.selectWorkspace(.worktree(featureID))
                controller.reloadSidebar()
                expect(
                    sidebarRow(feature.displayName, in: controller)?.staleDays != nil,
                    "opening it doesn't freshen it"
                )

                // The row on screen is the highlighted one, drawn by the row
                // view that keeps it blue without keyboard focus.
                var rowViews: [SidebarRowView] = []
                collectViews(in: controller.window?.contentView, into: &rowViews)
                let selected = rowViews.filter(\.isSelected)
                expectEqual(selected.count, 1, "exactly one sidebar row is highlighted")
                expect(
                    selected.first?.subviews.contains {
                        ($0 as? SidebarCellView)?.textField?.stringValue == feature.displayName
                    } == true,
                    "and it is the workspace on screen"
                )
                expectEqual(
                    selected.first?.interiorBackgroundStyle, .normal,
                    "its text keeps its colours on the pale tint"
                )

                // Rebuilding the tree on its own, as a worktree added or
                // removed on disk does, keeps the highlight where it was.
                controller.sidebarPanel.reload()
                rowViews = []
                collectViews(in: controller.window?.contentView, into: &rowViews)
                expect(
                    rowViews.filter(\.isSelected).first?.subviews.contains {
                        ($0 as? SidebarCellView)?.textField?.stringValue == feature.displayName
                    } == true,
                    "the highlight survives the sidebar rebuilding itself"
                )

                // An edit that hasn't been committed yet still counts.
                FileManager.default.createFile(
                    atPath: feature.path + "/notes.txt", contents: Data("wip".utf8))
                WorktreeActivity.resetForTesting()
                controller.reloadSidebar()
            }),

            .waitUntil("an uncommitted edit freshens it", {
                guard let feature = featureWorktree else { return false }
                return !WorktreeActivity.isCheckingForTesting
                    && sidebarRow(feature.displayName, in: controller)?.staleDays == nil
            }),

            .act("put the worktree back as it was", {
                guard let feature = featureWorktree else { return }
                // Left behind, it would stop git removing the worktree below.
                try? FileManager.default.removeItem(atPath: feature.path + "/notes.txt")
                controller.selectWorkspace(.home)
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

            .act("a worktree removed outside Workbench", {
                guard let repository = scratchRepository else {
                    return expect(false, "the scratch repo is still set up")
                }
                let path = GitService.defaultWorktreePath(
                    repositoryPath: repository.path, branch: "external")
                do {
                    try GitService.addWorktree(
                        repositoryPath: repository.path, path: path,
                        branch: "external", createBranch: true)
                    try RepositoryStore.refreshWorktrees(of: repository)
                } catch {
                    return expect(false, "git worktree add: \(error.localizedDescription)")
                }
                controller.reloadSidebar()
                guard let external = RepositoryStore.worktrees(ofRepository: repository.id ?? -1)
                    .first(where: { $0.path == path }), let id = external.id
                else { return expect(false, "the external worktree was picked up") }

                // As if an agent in this worktree's terminal removed it.
                controller.selectWorkspace(.worktree(id))
                do {
                    try GitService.run(["worktree", "remove", path], in: repository.path)
                } catch {
                    return expect(false, "git worktree remove: \(error.localizedDescription)")
                }
                externalWorktreeID = id
            }),

            .waitUntil("the sidebar notices", {
                guard let id = externalWorktreeID else { return true }
                return RepositoryStore.worktree(id: id) == nil
            }),

            .act("the terminal that removed it stays open", {
                guard let id = externalWorktreeID else { return }
                expect(RepositoryStore.worktree(id: id) == nil, "its row is gone")
                expectEqual(
                    controller.currentWorkspaceKey, .worktree(id),
                    "but the workspace on screen wasn't closed under the user"
                )
                controller.selectWorkspace(.home)
                expect(
                    !controller.openWorkspaceKeysForTesting.contains(.worktree(id)),
                    "and it's forgotten once the user moves away"
                )
            }),

            .act("removing a worktree git already forgot", {
                guard let repository = scratchRepository else {
                    return expect(false, "the scratch repo is still set up")
                }
                let path = GitService.defaultWorktreePath(
                    repositoryPath: repository.path, branch: "stale")
                do {
                    try GitService.addWorktree(
                        repositoryPath: repository.path, path: path,
                        branch: "stale", createBranch: true)
                    try RepositoryStore.refreshWorktrees(of: repository)
                } catch {
                    return expect(false, "git worktree add: \(error.localizedDescription)")
                }
                guard let stale = RepositoryStore.worktrees(ofRepository: repository.id ?? -1)
                    .first(where: { $0.path == path })
                else { return expect(false, "the stale worktree was picked up") }

                // Removed behind the sidebar's back, before it has refreshed.
                _ = try? GitService.run(["worktree", "remove", path], in: repository.path)
                let error = controller.sidebarPanel.performRemoveWorktree(stale, in: repository)
                expect(error == nil, "removing it again isn't an error")
                expect(
                    !RepositoryStore.worktrees(ofRepository: repository.id ?? -1)
                        .contains { $0.path == path },
                    "and its row is gone"
                )
            }),

            .act("remote branches can be checked out", {
                guard let repository = scratchRepository else {
                    return expect(false, "the scratch repo is still set up")
                }
                // A clone of the scratch repo stands in for GitHub: it gets a
                // branch the scratch repo has never seen, then becomes origin.
                let upstream = repository.path + "-upstream"
                try? FileManager.default.removeItem(atPath: upstream)
                do {
                    try GitService.run(["clone", "--quiet", repository.path, upstream], in: NSTemporaryDirectory())
                    try GitService.run(["branch", "remote-only"], in: upstream)
                    // "external" is local and unused; put it on the remote too.
                    try GitService.run(["branch", "external", "origin/external"], in: upstream)
                    try GitService.run(["remote", "add", "origin", upstream], in: repository.path)
                    try GitService.fetchAll(repositoryPath: repository.path)
                } catch {
                    return expect(false, "setting up a remote: \(error.localizedDescription)")
                }

                let choices = GitService.branchChoices(for: repository.path)
                expect(
                    choices.contains(BranchChoice(name: "remote-only", remoteRef: "origin/remote-only")),
                    "a branch only on the remote is offered"
                )
                expectEqual(
                    choices.first { $0.name == "remote-only" }?.remoteName, "origin",
                    "labelled with its remote"
                )
                expect(
                    !choices.contains { $0.name == "main" },
                    "a remote branch whose local one is checked out isn't offered"
                )
                expect(
                    choices.filter { $0.name == "external" } == [BranchChoice(name: "external", remoteRef: nil)],
                    "a branch on both sides shows once, as the local one"
                )
                if let firstRemote = choices.firstIndex(where: { $0.remoteRef != nil }) {
                    expect(
                        choices[firstRemote...].allSatisfy { $0.remoteRef != nil },
                        "local branches are listed before remote ones"
                    )
                }

                // The sheet lists them, and searching narrows the list.
                let dialog = NewWorktreeDialog(repository: repository) { _ in }
                var tables: [NSTableView] = []
                collectViews(in: dialog.view, into: &tables)
                var searches: [NSSearchField] = []
                collectViews(in: dialog.view, into: &searches)
                guard let table = tables.first, let search = searches.first else {
                    return expect(false, "the sheet has a search field and a branch list")
                }
                expectEqual(table.numberOfRows, choices.count, "the sheet lists every choice")
                search.stringValue = "remote only"
                NotificationCenter.default.post(
                    name: NSControl.textDidChangeNotification, object: search)
                expectEqual(table.numberOfRows, 1, "searching by words narrows the list")
                expectEqual(table.selectedRow, 0, "and the match is selected, ready for Return")

                let path = GitService.defaultWorktreePath(
                    repositoryPath: repository.path, branch: "remote-only")
                do {
                    try GitService.addWorktree(
                        repositoryPath: repository.path, path: path, branch: "remote-only",
                        createBranch: true, startPoint: "origin/remote-only", track: true)
                    let upstreamRef = try GitService.run(
                        ["rev-parse", "--abbrev-ref", "remote-only@{upstream}"], in: repository.path)
                    expectEqual(
                        upstreamRef.trimmingCharacters(in: .whitespacesAndNewlines),
                        "origin/remote-only",
                        "checking one out makes a local branch tracking it"
                    )
                    try GitService.run(["worktree", "remove", path], in: repository.path)
                    try GitService.run(["remote", "remove", "origin"], in: repository.path)
                } catch {
                    expect(false, "git worktree add from a remote: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(atPath: upstream)
                try? RepositoryStore.refreshWorktrees(of: repository)
            }),

            .act("confirming removes it for real", {
                guard let repository = scratchRepository, let feature = featureWorktree else {
                    return expect(false, "the scratch repo is still set up")
                }
                expect(
                    FileManager.default.fileExists(atPath: feature.path),
                    "cancelling left the worktree alone"
                )

                // The repository asks for a command once a worktree is gone. It
                // writes what it was told into the directory it runs in.
                let config = [
                    "worktreeRemoved": "printf '%s' \"$TABTERM_REMOVED_WORKTREES\" > removed-worktrees.txt",
                ]
                FileManager.default.createFile(
                    atPath: repository.path + "/" + RemovedWorktreeCommand.fileName,
                    contents: try? JSONSerialization.data(withJSONObject: config)
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

            .waitUntil("the repository's command ran in its main checkout, told which worktree went", {
                guard let repository = scratchRepository, let feature = featureWorktree else { return false }
                let told = try? String(
                    contentsOfFile: repository.path + "/removed-worktrees.txt", encoding: .utf8)
                return told == feature.path
            }),

            .act("a split layout survives a restore", {
                // Build a tab with three panes: one split right, then that half
                // split down, with an off-centre divider.
                controller.selectWorkspace(.home)
                for tab in controller.tabSnapshot { controller.closeTab(tab.id) }
                controller.addTab()

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
                controller.addTab()
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
                controller.addTab()
                controller.addTab()
                controller.addTab()
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
                controller.addTab()
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
                controller.addTab()

                let widthBefore = window.frame.width
                for _ in 1...12 { controller.addTab() }
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
                controller.addTab()
                for _ in 1...10 { controller.addTab() }
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

            .act("a new tab opens without asking anything", {
                let before = controller.tabSnapshot.count
                controller.addTab()
                expectEqual(controller.tabSnapshot.count, before + 1, "the tab is open")
                expect(controller.window?.attachedSheet == nil, "and no sheet was put up")
                expectEqual(
                    controller.selectedTabID,
                    controller.tabSnapshot.last?.id,
                    "and it is selected"
                )
                controller.closeTab(controller.tabSnapshot.last!.id)
            }),

            .act("open a tab to close", {
                controller.addTab()
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
                let tab = controller.addTab()
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

            .act("Return is on the close button", {
                expectEqual(
                    controller.window?.attachedSheet?.defaultButtonCell?.title,
                    "Close Tab",
                    "so Return confirms the close without reaching for the mouse"
                )
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

            .act("a side button leaves the tab alone", {
                guard let button = tabButton(for: controller.tabSnapshot.last?.id, in: controller) else {
                    return expect(false, "the tab has a button in the strip")
                }
                guard let event = otherMouseUp(button: 3, at: button.centerInWindow) else {
                    return expect(false, "a click to send")
                }

                button.otherMouseUp(with: event)
                expect(
                    controller.window?.attachedSheet == nil,
                    "the back button on a mouse doesn't close tabs"
                )
            }),

            .act("middle-click off the tab leaves it alone too", {
                guard let button = tabButton(for: controller.tabSnapshot.last?.id, in: controller) else {
                    return expect(false, "the tab has a button in the strip")
                }
                guard let event = otherMouseUp(button: 2, at: NSPoint(x: -50, y: -50)) else {
                    return expect(false, "a click to send")
                }

                button.otherMouseUp(with: event)
                expect(
                    controller.window?.attachedSheet == nil,
                    "releasing away from the tab cancels the click"
                )
            }),

            .act("middle-click on the tab asks the same way ⌘W does", {
                guard let button = tabButton(for: controller.tabSnapshot.last?.id, in: controller) else {
                    return expect(false, "the tab has a button in the strip")
                }
                guard let event = otherMouseUp(button: 2, at: button.centerInWindow) else {
                    return expect(false, "a click to send")
                }

                button.otherMouseUp(with: event)
            }),

            .waitUntil("middle-click puts up the confirmation", {
                controller.window?.attachedSheet != nil
            }),

            .act("and cancelling it keeps the tab", {
                expectEqual(controller.tabSnapshot.count, 2, "tab still open while asking")
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
            }),

            .waitUntil("middle-click confirmation dismissed", {
                controller.window?.attachedSheet == nil
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

            .waitUntil("the split's shell is running before it moves", {
                (controller.selectedTabContent as? TerminalTabContent)?.foregroundPID ?? 0 > 0
            }),

            .act("moving a live split to a new tab", {
                guard let source = controller.selectedTab,
                      let pane = source.focusedPane,
                      let terminal = pane.content as? TerminalTabContent
                else { return expect(false, "a focused terminal to move") }
                let session = terminal.session
                let process = terminal.foregroundPID
                let count = source.paneCount
                let outerRatio = source.root.ratio

                guard let delegate = NSApp.delegate as? AppDelegate,
                      let menu = NSApp.mainMenu?.items.compactMap(\.submenu)
                        .first(where: { $0.title == "View" }),
                      let item = menu.items.first(where: { $0.title == "Move Split to New Tab" })
                else { return expect(false, "the move command is in the View menu") }
                expect(delegate.validateMenuItem(item), "the move command is enabled for a split")
                expectEqual(item.keyEquivalent, "t", "the move shortcut uses T")
                expectEqual(item.keyEquivalentModifierMask, [.command, .shift],
                            "the move shortcut uses Command-Shift")
                menu.performActionForItem(at: menu.index(of: item))
                expect(!delegate.validateMenuItem(item), "the move command is disabled for a lone pane")

                guard let destination = controller.selectedTab else {
                    return expect(false, "the new tab is selected")
                }
                expect(destination.id != source.id, "the split has its own tab")
                expectEqual(controller.tabSnapshot.map(\.id), [source.id, destination.id],
                            "the new tab sits directly after the source")
                expectEqual(source.paneCount, count - 1, "only the moved split left the source")
                expectEqual(source.root.ratio, outerRatio, "the outer divider stays put")
                expect(source.pane(for: pane.id) == nil, "the source relinquished the pane")
                expect(source.focusedPane != nil, "the source retains a focused pane")
                expect(destination.focusedPane === pane, "the pane and its identity survive")
                expect(destination.focusedPane?.content === terminal, "the live terminal view survives")
                expect(terminal.session === session, "the shell session survives")
                expectEqual(terminal.foregroundPID, process, "the foreground process is unchanged")
                expectEqual(destination.paneCount, 1, "the new tab contains just the moved split")
                expect(controller.window?.attachedSheet == nil, "moving asks no close confirmation")

                controller.currentWorkspace.persist()
                let saved = SavedTabStore.tabs(forWorktree: controller.currentWorkspaceKey.worktreeId)
                expectEqual(saved.map { $0.savedLayout.leaves.count }, [count - 1, 1],
                            "both tab layouts are saved")
                expect(saved.last?.isSelected == true, "the new tab's selection is saved")
            }),

            .waitUntil("the moved terminal receives keyboard focus", {
                guard let view = controller.window?.firstResponder as? NSView,
                      let content = controller.selectedTabContent else { return false }
                return view === content.view || view.isDescendant(of: content.view)
            }),

            .act("moved terminal callbacks belong to its new tab", {
                guard let destination = controller.selectedTab,
                      let pane = destination.focusedPane,
                      let terminal = pane.content as? TerminalTabContent,
                      let source = controller.currentWorkspace.tabs.first,
                      let target = source.focusedPane
                else { return expect(false, "both tabs survived the move") }

                controller.moveFocusedPaneToNewTab()
                expectEqual(controller.tabSnapshot.count, 2, "a lone pane stays in its existing tab")
                expectEqual(controller.selectedTabID, destination.id, "a lone pane keeps its selection")

                terminal.onSplitRequest?(.right)
                expectEqual(destination.paneCount, 2, "split requests reach the new tab")
                if let added = destination.focusedPane, added.id != pane.id {
                    added.content.onRequestClose?(false)
                }
                expectEqual(destination.paneCount, 1, "close requests reach the new tab")

                controller.moveTab(destination.id, into: source.id,
                                   target: SplitDropTarget(paneID: target.id, direction: .down))
                expectEqual(source.paneCount, 3, "the moved pane can be merged back")
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
                let target = controller.addTab()
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

                let dragged = controller.addTab()
                let draggedContent = dragged.focusedPane?.content
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
                    draggedContent != nil
                        && target.panes.contains { $0.content === draggedContent },
                    "carrying its own terminal"
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
                func state(_ event: String) -> AgentStatus? {
                    AgentActivityStore.state(forEvent: event)
                }
                expectEqual(state("UserPromptSubmit"), .working, "a prompt starts a turn")
                expectEqual(state("PostToolUse"), .working, "a finished tool call is progress")
                expectEqual(state("PreToolUse"), .working, "starting a tool repairs a missed start")
                expectEqual(state("Interrupt"), .idle, "interrupting Codex clears working without a completion")
                expectEqual(state("ElicitationResult"), .working, "answering a question resumes work")
                expectEqual(state("IdlePrompt"), .idle, "an idle reminder is not a permission request")
                expectEqual(state("PermissionRequest"), .blocked, "a permission prompt blocks")
                expectEqual(state("Notification"), .blocked, "so does a notification")
                expectEqual(state("Stop"), .finished, "the turn ending wants the user")
                expectEqual(state("StopFailure"), .finished, "so does one that failed")
                expectEqual(state("SessionStart"), .idle, "a fresh session wants nothing")
                expect(state("SubagentStop") == nil, "unregistered events are ignored")

                // Every event we register has to map to something, or the hook
                // would fire into the void.
                expect(
                    AgentHooks.registrations.allSatisfy { state($0.event) != nil },
                    "every registered event maps to a state"
                )
            }),

            .act("a worktree shows its most demanding pane", {
                expectEqual(
                    [AgentStatus.working, .idle, .blocked].max(), .blocked,
                    "a blocked agent outranks a working one")
                expectEqual(
                    [AgentStatus.working, .finished].max(), .finished,
                    "and a finished turn outranks work still going on")
                expectEqual([AgentStatus]().max() ?? .idle, .idle, "no terminals, no dot")
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

            .act("a new completion survives a coalesced working event", {
                report("Stop", from: "alpha")
                agents.reload()
                agents.acknowledge(["alpha"])
                agents.reload()
                expectEqual(agents.state(ofAgent: "alpha"), .idle, "rereading a seen turn keeps it seen")
                report("Stop", from: "alpha")
                agents.reload()
                expectEqual(agents.state(ofAgent: "alpha"), .finished, "a later turn needs attention again")
            }),

            .act("completion sound plays once per new turn and respects mute", {
                var plays = 0
                var enabled = true
                let sound = AgentCompletionSound(isEnabled: { enabled }, play: { plays += 1 })
                var event = AgentReport(state: .working, at: Date(timeIntervalSince1970: 1))
                sound.update(["alpha": event])
                event.state = .blocked
                sound.update(["alpha": event])
                expectEqual(plays, 0, "work and permission prompts are not completion sounds")
                event.state = .finished
                sound.update(["alpha": event])
                sound.update(["alpha": event])
                event.transcript = "/tmp/transcript"
                sound.update(["alpha": event])
                expectEqual(plays, 1, "rereads and metadata changes do not replay a completion")
                event.at = Date(timeIntervalSince1970: 2)
                sound.update(["alpha": event])
                expectEqual(plays, 2, "a later completion chimes even if the working event was coalesced")
                enabled = false
                event.at = Date(timeIntervalSince1970: 3)
                sound.update(["alpha": event])
                enabled = true
                sound.update(["alpha": event])
                expectEqual(plays, 2, "unmuting does not replay old completions")
                event.at = Date(timeIntervalSince1970: 4)
                sound.update(["alpha": event, "beta": event])
                expectEqual(plays, 3, "simultaneous completions share one sound")
                sound.update([:])
                expectEqual(plays, 3, "removing a terminal is silent")
                expect(NSSound(named: "Glass") != nil, "the system completion sound is available")

                let saved = AppState.string(forKey: "agentCompletionSound")
                defer { AppState.set(saved, forKey: "agentCompletionSound") }
                AppState.set(nil, forKey: "agentCompletionSound")
                expect(AgentCompletionSound.isEnabled, "sound defaults to enabled")
                AgentCompletionSound.isEnabled = false
                expect(!AgentCompletionSound.isEnabled, "the mute setting persists")
            }),

            .act("sound selection and custom imports persist safely", {
                let keys = ["agentCompletionSound", "agentCompletionSoundName", "agentCompletionSoundCustomFile", "agentCompletionSoundCustomName"]
                let saved = keys.map { AppState.string(forKey: $0) }
                var imported: String?
                let source = agentDirectory.appendingPathComponent("custom sound.aiff")
                let invalid = agentDirectory.appendingPathComponent("not audio.wav")
                defer {
                    if let imported { try? FileManager.default.removeItem(atPath: imported) }
                    try? FileManager.default.removeItem(at: source)
                    try? FileManager.default.removeItem(at: invalid)
                    for (key, value) in zip(keys, saved) { AppState.set(value, forKey: key) }
                }
                AgentCompletionSound.select("Ping")
                expectEqual(AgentCompletionSound.selectedSound, "Ping", "the chosen system sound persists")
                expect(AgentCompletionSound.isEnabled, "choosing a sound unmutes it")
                AgentCompletionSound.select("not-a-preset")
                expectEqual(AgentCompletionSound.selectedSound, "Ping", "an unknown preset cannot replace the selection")
                do {
                    try FileManager.default.copyItem(atPath: "/System/Library/Sounds/Glass.aiff", toPath: source.path)
                    try AgentCompletionSound.importCustomSound(from: source)
                    imported = AppState.string(forKey: "agentCompletionSoundCustomFile")
                    try FileManager.default.removeItem(at: source)
                    expectEqual(AgentCompletionSound.selectedSound, "custom", "the custom sound is selected")
                    expectEqual(AgentCompletionSound.customName, "custom sound.aiff", "the menu remembers its readable name")
                    expect(imported.map { FileManager.default.fileExists(atPath: $0) } == true, "moving the original does not lose the imported sound")
                    try Data("not audio".utf8).write(to: invalid)
                    do {
                        try AgentCompletionSound.importCustomSound(from: invalid)
                        expect(false, "invalid audio is rejected")
                    } catch { expect(true, "invalid audio is rejected") }
                    expectEqual(AppState.string(forKey: "agentCompletionSoundCustomFile"), imported, "a failed import keeps the previous sound")
                } catch { expect(false, "custom sound import: \(error)") }
                let menu = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title == "Agent Completion Sound" }?.submenu
                expect(menu?.items.contains { $0.title == "Choose Custom Sound…" } == true, "the app menu exposes the custom picker")
                expect(menu?.items.contains { $0.title == "Preview Sound" } == true, "and an explicit preview")
                expect(menu?.items.contains { $0.title == "None" } == true, "and muting")
            }),

            .act("native activity recovers stale status without fabricating completions", {
                report("UserPromptSubmit", from: "native-ended")
                report("PermissionRequest", from: "native-blocked")
                report("UserPromptSubmit", from: "native-new-turn")
                report("UserPromptSubmit", from: "native-late-stop")
                agents.reload()
                agents.receiveNativeState(.idle, forAgent: "native-ended")
                agents.receiveNativeState(.idle, forAgent: "native-blocked")
                agents.receiveNativeState(.idle, forAgent: "native-new-turn")
                agents.receiveNativeState(.working, forAgent: "native-new-turn")
                agents.receiveNativeState(.idle, forAgent: "native-late-stop")
                report("Stop", from: "native-late-stop")
                agents.reload()
                expectEqual(agents.state(ofAgent: "native-ended"), .working, "a late Stop gets time to arrive")
            }),

            .waitUntil("native idle settles after the grace period", {
                agents.state(ofAgent: "native-ended") == .idle
            }),

            .act("recovery protects prompts, newer work, and unread completions", {
                expectEqual(agents.state(ofAgent: "native-blocked"), .blocked, "a permission request is not cleared by settlement")
                expectEqual(agents.state(ofAgent: "native-new-turn"), .working, "new native work cancels pending settlement")
                expectEqual(agents.state(ofAgent: "native-late-stop"), .finished, "a late real Stop retains its completion")
                expectEqual(agents.reports["native-ended"]?.state, .working, "recovery does not invent a Stop for sound or phone notifications")
                report("PostToolUse", from: "another-agent")
                agents.reload()
                expectEqual(agents.state(ofAgent: "native-ended"), .idle, "an unrelated hook cannot resurrect the stale state file")
                report("PreToolUse", from: "native-ended")
                agents.reload()
                expectEqual(agents.state(ofAgent: "native-ended"), .working, "a new hook supersedes the recovery")
                agents.agentReturnedToShell("native-ended")
                agents.agentReturnedToShell("native-blocked")
                agents.agentReturnedToShell("native-late-stop")
                expectEqual(agents.state(ofAgent: "native-ended"), .idle, "returning to the shell clears stale working")
                expectEqual(agents.state(ofAgent: "native-blocked"), .idle, "an exited agent cannot still need permission")
                expectEqual(agents.state(ofAgent: "native-late-stop"), .finished, "process exit keeps unread completion")
                report("IdlePrompt", from: "native-late-stop")
                agents.reload()
                expectEqual(agents.state(ofAgent: "native-late-stop"), .finished, "an idle reminder keeps unread completion too")
            }),

            .act("Codex recovery accepts explicit lifecycle records only", {
                let start = #"{"type":"event_msg","timestamp":"2026-10-27T10:00:00Z","payload":{"type":"task_started","turn_id":"turn-1"}}"#
                let stop = #"{"type":"event_msg","timestamp":"2026-10-27T10:00:10Z","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
                let aborted = stop.replacingOccurrences(of: "task_complete", with: "turn_aborted")
                let work = CodexTranscriptActivity.latest(in: Data((start + "\n").utf8))
                let done = CodexTranscriptActivity.latest(in: Data((start + "\n" + stop + "\n").utf8))
                expectEqual(work?.state, .working, "task_started supplies positive evidence of work")
                expectEqual(done?.state, .idle, "task_complete repairs a missed Stop silently")
                expectEqual(CodexTranscriptActivity.latest(in: Data((aborted + "\n").utf8))?.state, .idle, "an abort also clears working")
                expect(CodexTranscriptActivity.latest(in: Data(stop.utf8)) == nil, "a partially written final line is ignored")
                expect(CodexTranscriptActivity.latest(in: Data("unknown format\n".utf8)) == nil, "unknown formats cannot change status")
                guard let work, let done else { return }
                var hook = AgentReport(state: .working, at: work.at, agent: "codex", turnID: "turn-1")
                expect(done.follows(hook), "completion is tied to the expected turn")
                hook.turnID = "turn-2"
                expect(!done.follows(hook), "an older turn cannot settle a newer one")
                hook.state = .blocked
                expect(!work.follows(hook), "task_started in the same second cannot undo a permission prompt")
            }),

            .act("native activity crosses a real pty", {
                nativeTerminal = TerminalTabContent(command:
                    "sh -c 'printf \"\\033]7501;state=working:app=claude-code\\007\"; sleep 1; "
                    + "printf \"\\033]7501;state=idle:app=claude-code\\007\"; sleep 5'")
            }),

            .waitUntil("the pty's native report lights working", {
                guard let nativeTerminal else { return false }
                return AgentActivityStore.shared.state(ofAgent: nativeTerminal.agentID) == .working
            }),

            .waitUntil("and its idle report repairs the missing Stop", {
                guard let nativeTerminal else { return false }
                return AgentActivityStore.shared.state(ofAgent: nativeTerminal.agentID) == .idle
            }),

            .act("done with the native reporter", {
                nativeTerminal?.close()
                nativeTerminal = nil
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
                guard let target = AgentHooks.targets.first(where: { $0.agent == .claude }) else {
                    return expect(false, "claude is one of the agents we register with")
                }

                // A path with a space in it, because ours has one.
                let script = "/Users/someone/Library/Application Support/TabTerm/hooks/"
                    + AgentHooks.scriptName
                let command = AgentHooks.command(scriptPath: script, event: "Stop", agent: .claude)
                expect(command.contains("'\(script)' Stop claude"), "the script path is quoted")

                let existing: [String: Any] = [
                    "model": "opus",
                    "hooks": [
                        "Stop": [["hooks": [["type": "command", "command": "say done"]]]]
                    ],
                ]

                let installed = AgentHooks.settings(
                    byAdding: existing, scriptPath: script, target: target)
                expectEqual(installed["model"] as? String, "opus", "other settings survive")

                let hooks = installed["hooks"] as? [String: Any] ?? [:]
                expect(
                    AgentHooks.registrations(for: target).allSatisfy { hooks[$0.event] != nil },
                    "every event we watch is registered"
                )
                expectEqual(
                    (hooks["Stop"] as? [[String: Any]])?.count, 2,
                    "ours sits beside the user's own Stop hook")

                let again = AgentHooks.settings(
                    byAdding: installed, scriptPath: script, target: target)
                expectEqual(
                    ((again["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count, 2,
                    "installing twice doesn't stack up duplicates")

                let stop = (again["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
                expectEqual(
                    ((stop?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String),
                    "say done", "the user's Stop command survives reinstall unchanged")

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
                let kept = AgentHooks.settings(byAdding: shared, scriptPath: script, target: target)
                let entry = ((kept["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first
                expectEqual(
                    (entry?["hooks"] as? [[String: Any]])?.count, 1,
                    "a shared entry keeps the user's command")
            }),

            .act("the hook script reports which session it is in", {
                try? FileManager.default.removeItem(at: hookDirectory)

                let payload = #"{"session_id":"11111111-2222-3333-4444-555555555555","#
                    + #""transcript_path":"/tmp/tabterm-transcript.jsonl","#
                    + #""hook_event_name":"Stop","cwd":"/tmp"}"#

                guard let written = runHook(
                    event: "Stop", agent: "claude", payload: payload, from: "hooked"
                ) else {
                    return expect(false, "the hook script wrote a state file")
                }
                expect(true, "the hook script wrote a state file")
                expectEqual(written["event"] as? String, "Stop", "naming the event")
                expectEqual(written["agent"] as? String, "claude", "and the agent that sent it")
                expectEqual(
                    written["session"] as? String, "11111111-2222-3333-4444-555555555555",
                    "and the session id out of the payload")
                expectEqual(
                    written["transcript"] as? String, "/tmp/tabterm-transcript.jsonl",
                    "and where that session is written down")

                // A payload with no session in it at all still has to leave a
                // readable file behind, or the dot stops working.
                let bare = runHook(
                    event: "UserPromptSubmit", agent: "claude",
                    payload: #"{"hook_event_name":"UserPromptSubmit"}"#, from: "bare")
                expectEqual(bare?["event"] as? String, "UserPromptSubmit", "a payload with no id")
                expectEqual(bare?["session"] as? String, "", "leaves the session empty")
            }),

            .act("a subagent's tool calls are not the terminal's status", {
                let payload = #"{"session_id":"sub","agent_id":"agent_1","#
                    + #""hook_event_name":"PostToolUse"}"#
                expect(
                    runHook(event: "PostToolUse", agent: "claude", payload: payload, from: "sub")
                        == nil,
                    "a claude subagent's event is dropped before anything is written"
                )
                let nested = #"{"session_id":"main","tool_input":{"agent_id":"quoted-subagent"}}"#
                expect(runHook(event: "PostToolUse", agent: "claude", payload: nested, from: "nested") != nil,
                       "an agent_id inside tool input is not mistaken for a subagent hook")
                let idle = #"{"session_id":"main","notification_type":"idle_prompt"}"#
                expectEqual(runHook(event: "Notification", agent: "claude", payload: idle, from: "idle")?["event"] as? String,
                            "IdlePrompt", "idle reminders have their own silent recovery event")
                let escaped = #"{"session_id":"thr_123","turn_id":"turn_456","transcript_path":"/tmp/a \"quoted\" 路径.jsonl"}"#
                let written = runHook(event: "Stop", agent: "codex", payload: escaped, from: "escaped")
                expectEqual(written?["session"] as? String, "thr_123", "session ids are not stripped of underscores")
                expectEqual(written?["turn"] as? String, "turn_456", "turn ids support transcript correlation")
                expectEqual(written?["transcript"] as? String, "/tmp/a \"quoted\" 路径.jsonl", "JSON paths retain quotes and Unicode")
            }),

            .act("codex can hand the payload over as an argument", {
                let payload = #"{"session_id":"01a08a56-ec58-7bc3-9294-1b9806fc99ba","#
                    + #""transcript_path":"/tmp/rollout.jsonl","hook_event_name":"Stop"}"#
                let written = runHook(
                    event: "Stop", agent: "codex", payload: payload,
                    onStdin: false, from: "codexed")
                expectEqual(
                    written?["session"] as? String, "01a08a56-ec58-7bc3-9294-1b9806fc99ba",
                    "an argument payload is read the same way a piped one is")
                expectEqual(written?["agent"] as? String, "codex", "and named as codex's")
            }),

            .act("what the hook writes is what the store reads", {
                let store = AgentActivityStore(directory: hookDirectory)
                store.reload()

                expectEqual(store.state(ofAgent: "hooked"), .finished, "the turn ended")
                let session = store.session(ofAgent: "hooked", running: .claude)
                expectEqual(
                    session?.id, "11111111-2222-3333-4444-555555555555",
                    "the session id survives the round trip")
                expectEqual(
                    session?.transcript, "/tmp/tabterm-transcript.jsonl",
                    "and so does the transcript path")
                expect(
                    store.session(ofAgent: "hooked", running: .codex) == nil,
                    "a claude session is never offered to a codex process")
                expect(
                    store.session(ofAgent: "bare", running: .claude) == nil,
                    "and a report with no session id offers nothing")

                try? FileManager.default.removeItem(at: hookDirectory)
            }),

            .act("merging into the files on this machine keeps them intact", {
                // The fixtures above are made up; these are whatever is really
                // in the home directory, read and merged but never written.
                // A settings file full of other tools' hooks is the case that
                // matters, and it is the one hardest to invent.
                for target in AgentHooks.targets {
                    let agent = target.agent.rawValue
                    guard let data = try? Data(contentsOf: target.settingsURL),
                          let existing = (try? JSONSerialization.jsonObject(with: data))
                            as? [String: Any]
                    else {
                        expect(true, "no \(agent) settings on this machine to merge into")
                        continue
                    }

                    let theirs = (existing["hooks"] as? [String: Any])?
                        .mapValues { ($0 as? [[String: Any]])?.count ?? 0 } ?? [:]
                    let merged = AgentHooks.settings(
                        byAdding: existing, scriptPath: AgentHooks.scriptURL.path, target: target)

                    expectEqual(
                        merged.keys.count, existing.keys.count,
                        "\(agent): the merge adds no settings of its own")
                    for key in existing.keys where key != "hooks" {
                        expect(merged[key] != nil, "\(agent): \(key) is left alone")
                    }

                    let after = (merged["hooks"] as? [String: Any]) ?? [:]
                    for (event, count) in theirs {
                        expect(
                            ((after[event] as? [[String: Any]])?.count ?? 0) >= count,
                            "\(agent): nothing is dropped from \(event)")
                    }

                    // Ours replace ours rather than piling up, even though the
                    // command they contain has changed shape since.
                    let twice = AgentHooks.settings(
                        byAdding: merged, scriptPath: AgentHooks.scriptURL.path, target: target)
                    expectEqual(
                        ((twice["hooks"] as? [String: Any])?.mapValues {
                            ($0 as? [[String: Any]])?.count ?? 0
                        }) ?? [:],
                        after.mapValues { ($0 as? [[String: Any]])?.count ?? 0 },
                        "\(agent): installing again changes nothing")
                }
            }),

            .act("codex is registered with the events it actually has", {
                guard let codex = AgentHooks.targets.first(where: { $0.agent == .codex }),
                      let claude = AgentHooks.targets.first(where: { $0.agent == .claude })
                else { return expect(false, "both agents have a hook target") }

                expectEqual(
                    codex.settingsURL.lastPathComponent, "hooks.json",
                    "codex keeps its hooks in their own file")
                expect(
                    claude.settingsURL.path.hasSuffix("/.claude/settings.json"),
                    "claude keeps its in settings.json")

                let registered = AgentHooks.registrations(for: codex)
                expect(
                    registered.allSatisfy { codex.events.contains($0.event) },
                    "nothing is registered with codex that codex doesn't know")
                expect(
                    registered.count < AgentHooks.registrations.count,
                    "which is fewer than claude takes")
                expect(
                    registered.contains { $0.event == "Stop" },
                    "but still the event that ends a turn")
                expect(
                    !registered.contains { $0.event == "Notification" },
                    "and not the ones only claude sends")

                let settings = AgentHooks.settings(
                    byAdding: [:], scriptPath: "/tmp/\(AgentHooks.scriptName)", target: codex)
                let hooks = settings["hooks"] as? [String: Any] ?? [:]
                expectEqual(hooks.count, registered.count, "the file gets exactly those events")
                let stop = (hooks["Stop"] as? [[String: Any]])?.first
                let entry = (stop?["hooks"] as? [[String: Any]])?.first
                expect(
                    (entry?["command"] as? String)?.hasSuffix("Stop codex || true") == true,
                    "and each one tells the script which agent is calling it")
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

            .act("a terminal takes files dropped on it", {
                let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                let probe = directory.appendingPathComponent("tabterm-drop-\(UUID().uuidString)")
                let ready = directory.appendingPathComponent("tabterm-drop-ready-\(UUID().uuidString)")
                dropProbe = probe
                dropReady = ready

                // A name that needs escaping, as screenshots' names do.
                let files = [
                    directory.appendingPathComponent("Screenshot 2026-09-24 at 10.00.00.png"),
                    directory.appendingPathComponent("it's (1).jpg"),
                ]
                dropFiles = files
                dropExpected = files.map { Ghostty.Shell.escape($0.path) }.joined(separator: " ")
                expectEqual(
                    Ghostty.Shell.escape("/tmp/it's (1).jpg"),
                    "/tmp/it\\'s\\ \\(1\\).jpg",
                    "paths are escaped so the shell reads each as one word"
                )

                // No newline follows a drop, so read raw bytes rather than lines.
                let surface = GhosttySurfaceView(
                    command: "sh -c 'stty -icanon; : > \(ready.path); "
                        + "head -c \(dropExpected.utf8.count) > \(probe.path)'"
                )
                dropSurface = surface

                let types = surface.registeredDraggedTypes
                expect(types.contains(.fileURL), "the terminal accepts dropped files")
                expect(
                    !types.contains(SplitContainerView.tabPasteboardType),
                    "but leaves dragged tabs to the pane area behind it"
                )
                expectEqual(
                    surface.draggingEntered(FakeDrag(files: files)), .copy,
                    "hovering files over it offers a copy"
                )
                expectEqual(
                    surface.draggingEntered(FakeDrag(tabID: UUID(), location: .zero)), [],
                    "hovering a tab over it offers nothing"
                )
            }),

            .waitUntil("the drop reader is listening", {
                guard let dropReady else { return false }
                return FileManager.default.fileExists(atPath: dropReady.path)
            }),

            .act("drop the files", {
                expect(
                    dropSurface?.performDragOperation(FakeDrag(files: dropFiles)) == true,
                    "the drop is accepted"
                )
            }),

            .waitUntil("and the terminal receives their escaped paths", {
                guard let dropProbe,
                      let written = try? String(contentsOf: dropProbe, encoding: .utf8)
                else { return false }
                return written == dropExpected
            }),

            .act("done with the drop terminal", {
                dropSurface?.close()
                dropSurface = nil
                for file in [dropProbe, dropReady].compactMap({ $0 }) {
                    try? FileManager.default.removeItem(at: file)
                }
            }),

            .act("a restored terminal types its session back at the shell", {
                let (runner, probe) = makeRunner(mark: "resumed")
                resumeProbe = probe
                resumeRunner = runner

                let session = AgentSession(
                    agent: .claude,
                    sessionID: "probe",
                    commandLine: [runner.path, runner.path]
                )
                expectEqual(
                    session?.resumeCommand,
                    "\(runner.path) --resume probe",
                    "the line is built before anything is typed"
                )

                // No `command:` — a restored pane gets the user's own shell,
                // and the agent is typed at it, so quitting the agent leaves
                // them at a prompt rather than closing the pane.
                resumeTerminal = TerminalTabContent(resume: session)
            }),

            .waitUntil("and the shell runs it once it is ready", {
                guard let resumeProbe,
                      let written = try? String(contentsOf: resumeProbe, encoding: .utf8)
                else { return false }
                return written == "resumed"
            }),

            .act("a pane saved mid-session comes back in it", {
                let (runner, probe) = makeRunner(mark: "restored")
                restoreProbe = probe
                restoreRunner = runner

                // The row a quit with an agent still running leaves behind.
                // Written straight into the database because the alternative is
                // a live agent: `persist` reads the session off the process,
                // and there is no real one here to read.
                let session = AgentSession(
                    agent: .claude,
                    sessionID: "restored",
                    commandLine: [runner.path, runner.path]
                )
                let layout = SavedLayout.pane(directory: nil, agent: session, focused: true)

                controller.selectWorkspace(.home)
                SavedTabStore.replace(worktreeId: nil, with: [
                    SavedTab(worktreeId: nil, position: 0, isSelected: true, layout: layout.json)
                ])

                // Drop the live workspace so it has to rebuild from the row.
                controller.discardWorkspacesForTesting()
                controller.selectWorkspace(.home)
                expectEqual(controller.tabSnapshot.count, 1, "the saved tab came back")
                expect(
                    controller.selectedTabContent is TerminalTabContent,
                    "as a terminal, not something else"
                )
            }),

            .waitUntil("and the agent it was in is typed back into it", {
                guard let restoreProbe,
                      let written = try? String(contentsOf: restoreProbe, encoding: .utf8)
                else { return false }
                return written == "restored"
            }),

            .act("done with the resumed terminal", {
                resumeTerminal?.close()
                resumeTerminal = nil
                if let resumeProbe { try? FileManager.default.removeItem(at: resumeProbe) }
                if let resumeRunner { try? FileManager.default.removeItem(at: resumeRunner) }
                if let restoreProbe { try? FileManager.default.removeItem(at: restoreProbe) }
                if let restoreRunner { try? FileManager.default.removeItem(at: restoreRunner) }

                // Hand the later steps a plain tab again.
                for entry in controller.tabSnapshot { controller.closeTab(entry.id) }
                controller.addTab()
                expectEqual(controller.tabSnapshot.count, 1, "workspace reset for later steps")
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

            .act("hidden tabs keep their notifications when their workspace is selected", {
                let key = controller.currentWorkspaceKey
                let previous = controller.selectedTabID
                let hidden = controller.addTab()
                let visible = controller.addTab()
                defer {
                    controller.closeTab(hidden.id)
                    controller.closeTab(visible.id)
                    if let previous { controller.selectTab(previous) }
                }
                guard let agentID = hidden.agentIDs.first else {
                    return expect(false, "the hidden tab has an agent id")
                }
                let store = AgentActivityStore.shared
                let event = "{\"event\":\"Stop\",\"at\":\(Date().timeIntervalSince1970)}"
                try? event.write(
                    to: store.directory.appendingPathComponent("\(agentID).json"),
                    atomically: true, encoding: .utf8
                )
                store.reload()
                controller.selectWorkspace(key)
                expectEqual(store.state(ofAgent: agentID), .finished, "visiting the workspace does not acknowledge hidden tabs")
                let hiddenButton = tabButton(for: hidden.id, in: controller)
                let visibleButton = tabButton(for: visible.id, in: controller)
                expectEqual(hiddenButton?.agentState, .finished, "the hidden tab shows its completion")
                expect(hiddenButton?.isSelected == false, "attention does not select the tab")
                expect(visibleButton?.isSelected == true, "the current tab remains highlighted")
                expect(hiddenButton?.toolTip?.contains("Agent finished") == true, "the tab explains why it needs attention")

                store.acknowledge([agentID])
                expectEqual(tabButton(for: hidden.id, in: controller)?.agentState, .idle, "acknowledging refreshes the tab indicator")
                store.forget(agentID)
            }),

            // MARK: Sessions and phones

            .act("the pane's shell runs in a session Workbench owns", {
                controller.selectWorkspace(.home)
                if controller.tabSnapshot.isEmpty { controller.addTab() }
                guard let terminal = controller.selectedTabContent as? TerminalTabContent else {
                    return expect(false, "a terminal is selected")
                }
                phoneTerminal = terminal
                let phase = SessionManager.shared.queue.sync { terminal.session.phase }
                expect(phase != .pending, "the pane attached and started its shell")
            }),

            .waitUntil("shell integration reports the directory through the session", {
                phoneTerminal?.pwd != nil
            }),

            .act("nothing is running at the prompt", {
                expect(phoneTerminal?.hasRunningProcess == false, "a shell at its prompt has nothing to lose")
                phoneTerminal?.send("sleep 30\n")
            }),

            .waitUntil("but a command in the foreground counts", {
                phoneTerminal?.hasRunningProcess == true
            }),

            .act("interrupting it", {
                phoneTerminal?.send("\u{03}")
            }),

            .waitUntil("puts the shell back in front", {
                phoneTerminal?.hasRunningProcess == false
            }),

            .act("a phone pairs with a one-time code", {
                do {
                    phonePort = try RemoteServer.shared.startForTesting()
                } catch {
                    return expect(false, "the phone server listens on the loopback: \(error)")
                }
                let code = PairingStore.makeCode()
                pairingCode = code
                let phone = TestPhone()
                expect(phone.connect(port: phonePort), "a phone connects")
                phone.send(.hello(Hello(deviceName: "Self-test iPhone", deviceToken: nil, pairingCode: code)))
                phones.append(phone)
            }),

            .waitUntil("it is welcomed with a token of its own", {
                phones.first?.welcome?.deviceToken != nil
            }),

            .waitUntil("and sent the sidebar, focused on the terminal on screen", {
                guard let state = phones.first?.state, let terminal = phoneTerminal else { return false }
                return state.focus?.session == terminal.sessionID
                    && state.locate(terminal.sessionID) != nil
            }),

            .act("the same code doesn't let a second phone in", {
                let intruder = TestPhone()
                expect(intruder.connect(port: phonePort), "a second phone connects")
                intruder.send(.hello(Hello(deviceName: "Intruder", deviceToken: nil, pairingCode: pairingCode)))
                phones.append(intruder)
            }),

            .waitUntil("it is turned away", {
                phones.last?.denied?.reason == .unauthorized
            }),

            .act("the phone attaches to the terminal", {
                guard let phone = phones.first, let terminal = phoneTerminal else { return }
                macSize = SessionManager.shared.queue.sync { terminal.session.size }
                expect(macSize.cols > 40, "the Mac pane is wider than a phone (\(macSize.cols) columns)")
                phone.send(.attach(Attach(
                    session: terminal.sessionID,
                    anchor: .fresh,
                    size: TerminalSize(cols: 40, rows: 12)
                )))
            }),

            .waitUntil("a fresh phone is told to reset and replay", {
                guard let terminal = phoneTerminal else { return false }
                return phones.first?.synced(terminal.sessionID)?.mode == .reset
            }),

            .waitUntil("and the terminal takes the smaller size", {
                guard let terminal = phoneTerminal else { return false }
                let size = SessionManager.shared.queue.sync { terminal.session.size }
                return size.cols == 40 && size.rows == 12
            }),

            .act("a message typed on the phone", {
                guard let terminal = phoneTerminal else { return }
                phones.first?.send(.submit(Submit(session: terminal.sessionID, text: "echo tabterm-$((6*7))-phone")))
            }),

            .waitUntil("runs, and its output comes back to the phone", {
                guard let terminal = phoneTerminal else { return false }
                return phones.first?.text(terminal.sessionID).contains("tabterm-42-phone") == true
            }),

            .act("the phone drops off and reconnects with its token", {
                guard let first = phones.first, let token = first.welcome?.deviceToken,
                      let terminal = phoneTerminal
                else { return expect(false, "a paired phone") }
                let anchor = first.anchor(terminal.sessionID)
                first.close()

                let again = TestPhone()
                expect(again.connect(port: phonePort), "the phone reconnects")
                again.send(.hello(Hello(deviceName: "Self-test iPhone", deviceToken: token, pairingCode: nil)))
                again.send(.attach(Attach(
                    session: terminal.sessionID,
                    anchor: anchor,
                    size: TerminalSize(cols: 40, rows: 12)
                )))
                phones.append(again)
            }),

            .waitUntil("and is caught up exactly, keeping its screen", {
                guard let terminal = phoneTerminal else { return false }
                return phones.last?.synced(terminal.sessionID)?.mode == .exact
            }),

            .act("the phone goes to the background", {
                guard let terminal = phoneTerminal else { return }
                phones.last?.send(.visibility(Visibility(session: terminal.sessionID, visible: false)))
            }),

            .waitUntil("and the Mac gets its size back", {
                guard let terminal = phoneTerminal else { return false }
                let size = SessionManager.shared.queue.sync { terminal.session.size }
                return size.cols == macSize.cols && size.rows == macSize.rows
            }),

            .act("the phone asks for a worktree on a branch that doesn't exist yet", {
                // The scratch repository was taken out of the sidebar again
                // further up; its checkout is still on disk.
                guard let path = temporaryRepo,
                      let repository = try? RepositoryStore.add(path: path),
                      let main = RepositoryStore.worktrees(ofRepository: repository.id ?? -1)
                          .first(where: \.isMain)?.id
                else { return expect(false, "a repository for the phone to add to") }
                phoneRepository = repository
                controller.reloadSidebar()
                phones.last?.send(.newWorktree(NewWorktree(
                    workspace: WorkspaceKey.worktree(main).stateValue,
                    branch: "phone/made-this",
                    requestID: "worktree-1"
                )))
            }),

            .waitUntil("and is told the workspace it became, once the sidebar has it", {
                guard let phone = phones.last, let created = phone.worktreeCreated("worktree-1") else { return false }
                return phone.state?.workspace(id: created.workspace) != nil
            }),

            .act("the worktree is made the way the sheet makes one", {
                guard let phone = phones.last, let created = phone.worktreeCreated("worktree-1"),
                      let workspace = phone.state?.workspace(id: created.workspace),
                      let path = temporaryRepo
                else { return expect(false, "a workspace for the new worktree") }
                expectEqual(workspace.branch, "phone/made-this", "on a new branch of that name")
                expect(
                    workspace.directory?.hasSuffix("-worktrees/phone-made-this") == true
                        && FileManager.default.fileExists(atPath: path + "-worktrees/phone-made-this"),
                    "in the sibling folder, slashes flattened"
                )
                expect(!workspace.isOpen, "with no terminals until someone opens it")
                expect(
                    controller.currentWorkspaceKey.stateValue != created.workspace,
                    "and the Mac's window stays where it was"
                )

                // The branch is checked out now, and git won't have it twice.
                phone.send(.newWorktree(NewWorktree(
                    workspace: created.workspace,
                    branch: "phone/made-this",
                    requestID: "worktree-2"
                )))
            }),

            .waitUntil("asking for the same branch again is refused, in git's words", {
                guard let phone = phones.last, phone.worktreeCreated("worktree-2") == nil else { return false }
                return phone.errors.last?.contains("phone/made-this") == true
            }),

            .act("done with the phones", {
                if let phoneRepository { RepositoryStore.remove(phoneRepository) }
                controller.reloadSidebar()
                for phone in phones { phone.close() }
                phones.removeAll()
                RemoteServer.shared.stop()
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

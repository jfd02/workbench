import AppKit

/// A tab holding a real Ghostty terminal surface.
///
/// The shell doesn't belong to the surface. It runs in a `TerminalSession` the
/// app owns, and the surface runs the attach process that relays between the
/// two — so the same live terminal can also be shown on a phone.
final class TerminalTabContent: TabContent {
    private(set) var title: String = "Terminal"
    private(set) var icon: NSImage?

    var onTitleChange: ((String) -> Void)?
    var onIconChange: ((NSImage?) -> Void)?
    var onRequestClose: ((Bool) -> Void)?

    /// A split binding fired in this terminal (`cmd+d` and friends).
    var onSplitRequest: ((SplitDirection) -> Void)?

    /// A focus-movement binding fired (`cmd+opt+arrow` by default).
    var onFocusSplitRequest: ((SplitFocusTarget) -> Void)?

    /// An equalize-splits binding fired.
    var onEqualizeSplitsRequest: (() -> Void)?

    var closeConfirmationDetail: String {
        hasRunningProcess
            ? "A process is still running in this terminal and will be killed."
            : "This terminal session will end."
    }

    /// The pty and shell behind this pane.
    let session: TerminalSession

    private let surfaceView: GhosttySurfaceView
    private let container: NSView

    /// How often a terminal looks at what is running in it.
    ///
    /// Nothing tells us when the foreground process changes, so this polls.
    /// It costs one call into libghostty, and a `sysctl` only when the pid
    /// actually changed — cheap enough to keep running in background tabs,
    /// which is where seeing "Claude is still working in here" matters most.
    private static let pollInterval: TimeInterval = 2

    private var processTimer: Timer?
    private var lastForegroundPID: pid_t = -1
    private var consecutiveShellPolls = 0

    /// Identifies this terminal to the Claude Code hook running inside it.
    ///
    /// Not the pane's id: the session has to be handed its environment as it
    /// is created, before there is a pane to belong to. It is the session's id
    /// in string form, so the phone and the hook name a terminal the same way.
    let agentID: String

    /// The session's id, which is what a phone asks for.
    var sessionID: UUID { session.id }

    var view: NSView { container }

    /// The shell's current directory, when it reports one.
    var pwd: String? { surfaceView.pwd }

    /// True when something beyond the shell is still running.
    var hasRunningProcess: Bool {
        SessionManager.shared.queue.sync { session.isRunningSomething }
    }

    /// A shell waiting at a prompt has nothing to lose; one running something
    /// does. libghostty makes the same distinction for its own quit prompt.
    var isDisposable: Bool { !hasRunningProcess }

    /// The pid of whatever the terminal is running: its pty's foreground
    /// process group. Exposed for the self-test, which checks there is one.
    var foregroundPID: pid_t {
        SessionManager.shared.queue.sync { session.foregroundProcessGroup }
    }

    /// - Parameters:
    ///   - workingDirectory: where the shell starts, or nil for its default.
    ///   - command: a command to run instead of the shell.
    ///   - resume: an agent session to pick back up once the shell is ready.
    init(
        workingDirectory: String? = nil,
        command: String? = nil,
        resume: AgentSession? = nil
    ) {
        let id = UUID()
        let agentID = id.uuidString
        self.agentID = agentID
        session = SessionManager.shared.create(
            id: id,
            directory: workingDirectory,
            command: command,
            environment: AgentActivityStore.shared.environment(forAgent: agentID)
        )
        // The surface runs the attach process, not the shell; the shell's
        // directory and environment belong to the session.
        surfaceView = GhosttySurfaceView(
            command: SessionManager.shared.attachCommand(for: id)
        )
        container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        if let error = surfaceView.error {
            // Surface creation failed: show why instead of a black rectangle.
            let label = NSTextField(labelWithString: "Failed to start terminal\n\n\(error)")
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            title = "Error"
            return
        }

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surfaceView)
        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: container.topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        surfaceView.onTitleChange = { [weak self] newTitle in
            guard let self else { return }
            self.title = newTitle
            self.onTitleChange?(newTitle)
        }

        surfaceView.onClose = { [weak self] confirm in
            self?.onRequestClose?(confirm)
        }

        surfaceView.onSplit = { [weak self] direction in
            self?.onSplitRequest?(direction)
        }

        surfaceView.onGotoSplit = { [weak self] target in
            self?.onFocusSplitRequest?(target)
        }

        surfaceView.onEqualizeSplits = { [weak self] in
            self?.onEqualizeSplitsRequest?()
        }

        if let line = resume?.resumeCommand {
            armResume(line)
        }

        startWatchingProcess()
    }

    deinit {
        processTimer?.invalidate()
    }

    // MARK: - Resuming

    /// How long to wait for the shell to say where it is before typing anyway.
    private static let resumeTimeout: TimeInterval = 2

    /// The command a restored session wants typed, until it has been.
    private var pendingResume: String?

    /// Put a restored session's command back on the prompt once the shell is up.
    ///
    /// The first directory report is the signal: it comes from the shell
    /// integration libghostty injects, after the rc files have run, which is
    /// when a typed line lands on a prompt rather than ahead of one. A shell
    /// that never reports a directory still gets the command, just on a timer.
    private func armResume(_ command: String) {
        pendingResume = command + "\n"
        surfaceView.onPwdChange = { [weak self] _ in self?.fireResume() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeTimeout) { [weak self] in
            self?.fireResume()
        }
    }

    private func fireResume() {
        guard let command = pendingResume else { return }
        pendingResume = nil
        surfaceView.onPwdChange = nil
        // Straight to the session rather than through Ghostty: typed into the
        // surface before the attach process has put its pty in raw mode, the
        // line would be echoed twice.
        send(command)
    }

    /// Type into the terminal, exactly as if the user had.
    ///
    /// Used to put a command back on the prompt of a restored terminal. The
    /// text goes through the pty, so the shell echoes it, runs it, and keeps it
    /// in history — and when the command exits, the shell is still there.
    func send(_ text: String) {
        let session = self.session
        let bytes = Data(text.utf8)
        SessionManager.shared.queue.async { session.write(bytes) }
    }

    /// The agent session running in here, when there is one to come back to.
    ///
    /// Read from the process every time rather than remembered: an agent can be
    /// started, quit and restarted in the same terminal any number of times, and
    /// only what is running at the moment the window closes is worth restoring.
    var agentSession: AgentSession? {
        let commandLine = ForegroundProcess.commandLine(of: foregroundPID)
        guard let kind = ForegroundProcess.agent(commandLine: commandLine),
              let session = AgentActivityStore.shared.session(ofAgent: agentID, running: kind)
        else { return nil }

        return AgentSession(
            agent: kind,
            sessionID: session.id,
            commandLine: commandLine,
            transcript: session.transcript
        )
    }

    // MARK: - What's running

    private func startWatchingProcess() {
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.checkForegroundProcess()
        }
        // Common mode, so the icon keeps up while a menu or a resize is
        // holding the run loop in a tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        processTimer = timer
        checkForegroundProcess()
    }

    private func checkForegroundProcess() {
        let atShell = SessionManager.shared.queue.sync {
            session.command == nil && session.phase == .running
                && session.foregroundProcessGroup > 0 && !session.isRunningSomething
        }
        consecutiveShellPolls = atShell ? min(2, consecutiveShellPolls + 1) : 0
        let store = AgentActivityStore.shared
        if !atShell { store.checkCodexTranscript(forAgent: agentID) }
        if consecutiveShellPolls >= 2 {
            if let report = store.reports[agentID] {
                if report.agent != nil, Date().timeIntervalSince(report.at) >= 4 {
                    store.agentReturnedToShell(agentID)
                }
            } else {
                store.agentReturnedToShell(agentID)
            }
        }
        let pid = foregroundPID
        guard pid != lastForegroundPID else { return }
        lastForegroundPID = pid

        let newIcon = ForegroundProcess.isClaude(pid: pid) ? ClaudeIcon.image : nil
        guard newIcon !== icon else { return }
        icon = newIcon
        onIconChange?(newIcon)
    }

    func takeFocus() {
        guard surfaceView.error == nil else { return }
        surfaceView.window?.makeFirstResponder(surfaceView)
    }

    func setFocused(_ focused: Bool) {
        // libghostty draws the unfocused cursor hollow and stops it blinking.
        surfaceView.focusDidChange(focused)
    }

    func setVisible(_ visible: Bool) {
        surfaceView.setOcclusion(visible: visible)
        // A pane nobody can see shouldn't hold a phone to its size.
        let session = self.session
        SessionManager.shared.queue.async { session.setPaneVisible(visible) }
    }

    func close() {
        processTimer?.invalidate()
        processTimer = nil
        // Nothing left to type at.
        pendingResume = nil
        // Whatever the agent was doing, it isn't doing it here any more.
        AgentActivityStore.shared.forget(agentID)
        let session = self.session
        SessionManager.shared.queue.async { session.terminate() }
        surfaceView.close()
    }
}

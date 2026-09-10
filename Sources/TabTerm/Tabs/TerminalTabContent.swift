import AppKit

/// A tab holding a real Ghostty terminal surface.
final class TerminalTabContent: TabContent {
    let kind: TabKind = .terminal
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
        surfaceView.hasRunningProcess
            ? "A process is still running in this terminal and will be killed."
            : "This terminal session will end."
    }

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

    /// Identifies this terminal to the Claude Code hook running inside it.
    ///
    /// Not the pane's id: the surface has to be handed its environment as it is
    /// created, before there is a pane to belong to.
    let agentID: String

    var view: NSView { container }

    /// The shell's current directory, when it reports one.
    var pwd: String? { surfaceView.pwd }

    /// True when something beyond the shell is still running.
    var hasRunningProcess: Bool { surfaceView.hasRunningProcess }

    /// A shell waiting at a prompt has nothing to lose; one running something
    /// does. libghostty makes the same distinction for its own quit prompt.
    var isDisposable: Bool { !surfaceView.hasRunningProcess }

    /// The pid of whatever the terminal is running. Exposed for the self-test,
    /// which checks that libghostty actually reports one.
    var foregroundPID: pid_t { surfaceView.foregroundPID }

    init(workingDirectory: String? = nil, command: String? = nil) {
        let agentID = UUID().uuidString
        self.agentID = agentID
        surfaceView = GhosttySurfaceView(
            workingDirectory: workingDirectory,
            command: command,
            environment: AgentActivityStore.shared.environment(forAgent: agentID)
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

        startWatchingProcess()
    }

    deinit {
        processTimer?.invalidate()
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
        let pid = surfaceView.foregroundPID
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
    }

    func close() {
        processTimer?.invalidate()
        processTimer = nil
        // Whatever the agent was doing, it isn't doing it here any more.
        AgentActivityStore.shared.forget(agentID)
        surfaceView.close()
    }
}

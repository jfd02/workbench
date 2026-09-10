import Foundation

/// What the agent in one terminal is doing.
///
/// Ordered by how much it wants the user: a worktree showing several terminals
/// takes the highest state among them, so one prompt waiting for an answer is
/// never hidden behind another pane's progress bar.
enum AgentState: Int, Comparable {
    /// No agent, or one that has been seen and has nothing to say.
    case idle = 0
    /// Claude is running: thinking, or between tool calls.
    case working = 1
    /// The turn ended and the user hasn't looked since.
    case finished = 2
    /// Claude is stopped on a prompt and can't continue without an answer.
    case blocked = 3

    static func < (a: AgentState, b: AgentState) -> Bool { a.rawValue < b.rawValue }

    /// Whether this is the "your turn" red, rather than the working amber.
    var wantsAttention: Bool { self == .finished || self == .blocked }
}

/// The last thing a terminal's agent reported.
struct AgentReport: Equatable {
    var state: AgentState
    var at: Date
}

/// Which terminals have an agent in them, and what it is doing.
///
/// Nothing in a terminal announces this, so Claude Code is asked to say so
/// itself: `ClaudeHooks` registers a hook script on the events that mark the
/// edges of a turn, and each TabTerm terminal exports `TABTERM_AGENT_ID` and
/// `TABTERM_AGENT_DIR` so the script knows which terminal it is running in and
/// where to leave the answer. The script writes one small JSON file per
/// terminal; this watches that directory and turns the events back into state.
///
/// A file rather than a socket or a port: the hook is a shell script that has
/// to work with nothing but the shell, and a listening socket would put the app
/// in front of the firewall for no good reason. Writes are a rename, which is
/// atomic and moves the directory's mtime, so the watch below sees every one.
final class AgentActivityStore {
    static let shared = AgentActivityStore(directory: AgentActivityStore.defaultDirectory)

    /// `~/Library/Application Support/TabTerm/agent-state`
    static let defaultDirectory: URL = {
        AppSupport.directory.appendingPathComponent("agent-state", isDirectory: true)
    }()

    /// Called on the main queue after anything changes.
    var onChange: (() -> Void)?

    let directory: URL

    private(set) var reports: [String: AgentReport] = [:]

    /// Agents whose finished turn the user has already been shown. Kept out of
    /// `reports` so a later event can clear it without a second write.
    private var acknowledged: Set<String> = []

    private var source: DispatchSourceFileSystemObject?

    init(directory: URL) {
        self.directory = directory
    }

    deinit {
        source?.cancel()
    }

    /// What a terminal must export for the hook to report on it.
    func environment(forAgent agentID: String) -> [String: String] {
        [
            "TABTERM_AGENT_ID": agentID,
            "TABTERM_AGENT_DIR": directory.path,
        ]
    }

    // MARK: - Reading

    /// Start watching, after clearing out whatever the last run left behind.
    ///
    /// Every terminal is a fresh shell on launch, so no state file written
    /// before this moment describes a live agent.
    func start() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for url in files() {
            try? FileManager.default.removeItem(at: url)
        }
        reports.removeAll()
        acknowledged.removeAll()
        watch()
    }

    private func watch() {
        source?.cancel()
        source = nil

        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // The directory itself went away — re-open it and start again,
            // rather than holding a descriptor onto something unlinked.
            if source.data.contains(.delete) || source.data.contains(.rename) {
                try? FileManager.default.createDirectory(
                    at: self.directory,
                    withIntermediateDirectories: true
                )
                self.watch()
            }
            self.reload()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func files() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return (contents ?? []).filter { $0.pathExtension == "json" }
    }

    /// Re-read every state file. Called for any change in the directory, since
    /// there are only ever as many files as there are live terminals.
    func reload() {
        struct Row: Decodable {
            var event: String
            var at: TimeInterval
        }

        var next: [String: AgentReport] = [:]
        for url in files() {
            guard let data = try? Data(contentsOf: url),
                  let row = try? JSONDecoder().decode(Row.self, from: data),
                  let state = Self.state(forEvent: row.event)
            else { continue }
            next[url.deletingPathExtension().lastPathComponent] = AgentReport(
                state: state,
                at: Date(timeIntervalSince1970: row.at)
            )
        }

        guard next != reports else { return }
        reports = next
        // An agent that started working again has something new to say, so
        // whatever the user acknowledged before no longer applies.
        acknowledged = acknowledged.filter { reports[$0]?.state == .finished }
        onChange?()
    }

    // MARK: - State

    /// What to show for one terminal, allowing for what the user has seen.
    func state(ofAgent agentID: String) -> AgentState {
        guard let report = reports[agentID] else { return .idle }
        if report.state == .finished, acknowledged.contains(agentID) { return .idle }
        return report.state
    }

    /// The most demanding state across a set of terminals.
    func state(ofAgents agentIDs: [String]) -> AgentState {
        agentIDs.map(state(ofAgent:)).max() ?? .idle
    }

    /// Mark finished turns as seen, so their red dot goes out.
    ///
    /// A blocked agent is deliberately not acknowledgeable: it stays lit until
    /// the agent itself moves on, because looking at the prompt is not the same
    /// as answering it.
    func acknowledge(_ agentIDs: [String]) {
        var changed = false
        for id in agentIDs where reports[id]?.state == .finished {
            if acknowledged.insert(id).inserted { changed = true }
        }
        if changed { onChange?() }
    }

    /// Drop a terminal that has gone away, so its file doesn't outlive it.
    func forget(_ agentID: String) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(agentID).json")
        )
        acknowledged.remove(agentID)
        guard reports.removeValue(forKey: agentID) != nil else { return }
        onChange?()
    }

    /// What one hook event says the agent is now doing.
    ///
    /// Only the events TabTerm registers are mapped; anything else is ignored
    /// so an unrelated hook in the user's own settings can't move the dot.
    static func state(forEvent event: String) -> AgentState? {
        switch event {
        // A session that just started, or has just gone, is waiting on nothing.
        case "SessionStart", "SessionEnd":
            return .idle
        // The turn is under way. PostToolUse is what brings a blocked agent
        // back to working once the user has answered the prompt.
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            return .working
        // Stopped on something only the user can resolve.
        case "PermissionRequest", "Notification":
            return .blocked
        // The turn is over, one way or the other.
        case "Stop", "StopFailure":
            return .finished
        default:
            return nil
        }
    }
}

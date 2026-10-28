import Foundation
import TabTermKit

/// The last thing a terminal's agent reported.
struct AgentReport: Equatable {
    var state: AgentStatus
    var at: Date

    /// Which agent said so, as it named itself: `claude` or `codex`. Only the
    /// hook knows this; the file left behind by a previous agent in the same
    /// terminal is otherwise indistinguishable from a current one.
    var agent: String?

    /// The session the agent is in, and where it keeps the transcript, so the
    /// terminal can be brought back to it after a restart. Empty when the hook
    /// couldn't find them in the payload.
    var sessionID: String?
    var transcript: String?
    var turnID: String?

    /// A directory watch may coalesce the working event between two turns.
    /// The timestamp still distinguishes the new completion from the old one.
    func isNewCompletion(after previous: AgentReport?) -> Bool {
        state == .finished && (previous?.state != .finished || previous?.at != at)
    }
}

/// Which terminals have an agent in them, and what it is doing.
///
/// Nothing in a terminal announces this, so Claude Code is asked to say so
/// itself: `AgentHooks` registers a hook script on the events that mark the
/// edges of a turn, and each Workbench terminal exports `TABTERM_AGENT_ID` and
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

    /// Posted on the main queue when an agent reports something new, for
    /// anyone besides the window that cares — the phone's notifications.
    static let didChange = Notification.Name("AgentActivityStoreDidChange")

    let directory: URL

    private(set) var reports: [String: AgentReport] = [:]

    /// Agents whose finished turn the user has already been shown. Kept out of
    /// `reports` so a later event can clear it without a second write.
    private var acknowledged: Set<String> = []
    /// Recovery changes presentation only; it never invents a completion chime.
    private var recoveredStates: [String: AgentStatus] = [:]
    private var nativeRevisions: [String: UUID] = [:]
    private var transcriptReads: Set<String> = []

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
        recoveredStates.removeAll()
        nativeRevisions.removeAll()
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
            var agent: String?
            var session: String?
            var transcript: String?
            var turn: String?
        }

        var next: [String: AgentReport] = [:]
        for url in files() {
            guard let data = try? Data(contentsOf: url),
                  let row = try? JSONDecoder().decode(Row.self, from: data),
                  let state = Self.state(forEvent: row.event)
            else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            // The delayed idle reminder repairs stale working state, but must
            // not erase a real completion the user hasn't visited yet.
            if row.event == "IdlePrompt", reports[id]?.state == .finished {
                next[id] = reports[id]
                continue
            }
            next[id] = AgentReport(
                state: state,
                at: Date(timeIntervalSince1970: row.at),
                agent: row.agent.flatMap { $0.isEmpty ? nil : $0 },
                sessionID: row.session.flatMap { $0.isEmpty ? nil : $0 },
                transcript: row.transcript.flatMap { $0.isEmpty ? nil : $0 },
                turnID: row.turn.flatMap { $0.isEmpty ? nil : $0 }
            )
        }

        guard next != reports else { return }
        // A fresh hook is authoritative; an unrelated terminal's update must
        // not undo a recovery by rereading the same stale file.
        for id in Set(reports.keys).union(next.keys) where reports[id] != next[id] {
            recoveredStates.removeValue(forKey: id)
            nativeRevisions.removeValue(forKey: id)
        }
        // An agent that started working again has something new to say, so
        // whatever the user acknowledged before no longer applies. A newer
        // completion also counts when the watch missed the intervening work.
        acknowledged = acknowledged.filter { id in
            next[id]?.state == .finished && next[id]?.isNewCompletion(after: reports[id]) == false
        }
        // Only the live store emits user hooks; fixture stores and display-only
        // acknowledgements must never launch scripts.
        if self === Self.shared {
            WorkbenchHooks.agentReportsChanged(previous: reports, current: next)
        }
        reports = next
        onChange?()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - State

    /// What to show for one terminal, allowing for what the user has seen.
    func state(ofAgent agentID: String) -> AgentStatus {
        if let recovered = recoveredStates[agentID] { return recovered }
        guard let report = reports[agentID] else { return .idle }
        if report.state == .finished, acknowledged.contains(agentID) { return .idle }
        return report.state
    }

    /// The session one terminal's agent last reported being in.
    ///
    /// `agent` guards against a file left behind by a different agent in the
    /// same terminal: a claude session id would be meaningless to codex.
    func session(ofAgent agentID: String, running agent: ForegroundProcess.Agent) -> (
        id: String, transcript: String?
    )? {
        guard let report = reports[agentID], let sessionID = report.sessionID else { return nil }
        guard report.agent == nil || report.agent == agent.rawValue else { return nil }
        return (sessionID, report.transcript)
    }

    /// The most demanding state across a set of terminals.
    func state(ofAgents agentIDs: [String]) -> AgentStatus {
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
        nativeRevisions.removeValue(forKey: agentID)
        let recovered = recoveredStates.removeValue(forKey: agentID)
        guard reports.removeValue(forKey: agentID) != nil || recovered != nil else { return }
        onChange?()
    }

    /// A native Claude report can repair missed hooks. Let a late Stop land
    /// first, and never clear a permission prompt merely because work stopped.
    func receiveNativeState(_ state: AgentStatus, forAgent id: String) {
        guard reports[id]?.agent == nil || reports[id]?.agent == "claude" else { return }
        let revision = UUID()
        nativeRevisions[id] = revision
        if state == .working || state == .blocked {
            recover(state, forAgent: id)
            return
        }
        let expected = reports[id]
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.nativeRevisions[id] == revision,
                  self.reports[id] == expected, self.state(ofAgent: id) == .working else { return }
            self.recover(.idle, forAgent: id)
        }
    }

    /// The pty is back at its shell after an agent exited without SessionEnd.
    func agentReturnedToShell(_ id: String) {
        nativeRevisions[id] = UUID()
        let state = state(ofAgent: id)
        if state == .working || state == .blocked { recover(.idle, forAgent: id) }
    }

    /// Read a bounded tail off the UI thread, and discard it if a hook arrived
    /// while the read was in flight. Unknown transcript formats leave hooks alone.
    func checkCodexTranscript(forAgent id: String) {
        guard let report = reports[id], report.agent == "codex",
              let path = report.transcript, !transcriptReads.contains(id) else { return }
        transcriptReads.insert(id)
        let expectedRevision = nativeRevisions[id]
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let observation = CodexTranscriptActivity.read(path: path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.transcriptReads.remove(id)
                guard self.reports[id] == report, self.nativeRevisions[id] == expectedRevision,
                      let observation, observation.follows(report) else { return }
                // Keep real Stop notifications unread until visited. Recovery
                // repairs running/waiting without announcing an invented Stop.
                if observation.state == .idle, report.state == .finished || report.state == .idle { return }
                self.recover(observation.state, forAgent: id)
            }
        }
    }

    private func recover(_ state: AgentStatus, forAgent id: String) {
        guard self.state(ofAgent: id) != state else { return }
        recoveredStates[id] = state
        onChange?()
    }

    /// What one hook event says the agent is now doing.
    ///
    /// Only the events Workbench registers are mapped; anything else is ignored
    /// so an unrelated hook in the user's own settings can't move the dot.
    static func state(forEvent event: String) -> AgentStatus? {
        switch event {
        // A session that just started, or has just gone, is waiting on nothing.
        case "SessionStart", "SessionEnd", "Interrupt", "IdlePrompt":
            return .idle
        // The turn is under way. PostToolUse is what brings a blocked agent
        // back to working once the user has answered the prompt.
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied",
             "PreCompact", "PostCompact", "ElicitationResult":
            return .working
        // Stopped on something only the user can resolve.
        case "PermissionRequest", "Notification", "Elicitation":
            return .blocked
        // The turn is over, one way or the other.
        case "Stop", "StopFailure":
            return .finished
        default:
            return nil
        }
    }
}

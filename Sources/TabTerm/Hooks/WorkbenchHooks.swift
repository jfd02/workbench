import Foundation

/// Bridges app state to the public scripting payload, independently of the
/// incoming Claude/Codex hooks that feed agent status.
enum WorkbenchHooks {
    static var runner = HookRunner(
        globalConfig: SelfTest.isEnabled ? nil : AppSupport.directory.appendingPathComponent("hooks.json"),
        logDirectory: SelfTest.isEnabled
            ? FileManager.default.temporaryDirectory.appendingPathComponent("workbench-selftest-hooks")
            : AppSupport.directory.appendingPathComponent("logs")
    )

    static func event(_ name: String, workspace key: WorkspaceKey) -> HookEvent {
        var event = HookEvent(event: name, workspaceID: key.stateValue)
        if let id = key.worktreeId, let worktree = RepositoryStore.worktree(id: id) {
            event.worktreePath = worktree.path
            event.branch = worktree.branch
            event.repositoryPath = RepositoryStore.repository(id: worktree.repositoryId)?.path
        }
        return event
    }

    static func agentEventName(_ report: AgentReport, previous: AgentReport?) -> String? {
        guard report.state != previous?.state || report.isNewCompletion(after: previous) else { return nil }
        switch report.state {
        case .working: return "agent.working"
        case .blocked: return "agent.blocked"
        case .finished: return "agent.finished"
        case .idle: return nil
        }
    }

    static func agentReportsChanged(previous: [String: AgentReport], current: [String: AgentReport]) {
        for (id, report) in current {
            guard let name = agentEventName(report, previous: previous[id]),
                  var event = MainWindowController.current?.hookEvent(name, forAgent: id) else { continue }
            event.agent = report.agent
            event.agentSessionID = report.sessionID
            runner.emit(event)
        }
    }
}

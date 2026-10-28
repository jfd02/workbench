import XCTest
import TabTermKit
@testable import TabTerm

final class HookTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workbench hooks '\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func contents(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func runner(global: URL? = nil) -> HookRunner {
        HookRunner(globalConfig: global, logDirectory: root.appendingPathComponent("logs"))
    }

    func testPayloadEnvironmentWorkingDirectoryAndHandlerOrder() throws {
        let global = root.appendingPathComponent("global.json")
        let worktree = root.appendingPathComponent("feature $(touch SHOULD_NOT_EXIST)")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try write(["hooks": [
            "worktree.created": ["printf 'global\\n' >> order"],
            "*": ["printf 'wildcard\\n' >> order"],
        ]], to: global)
        try write(["hooks": ["worktree.created": [
            "cat > payload.json; printf '%s\\n' \"$WORKBENCH_EVENT\" \"$WORKBENCH_WORKTREE_PATH\" \"$WORKBENCH_BRANCH\" > env; printf 'repo\\n' >> order",
        ]]], to: root.appendingPathComponent(".tabterm.json"))
        let event = HookEvent(event: "worktree.created", repositoryPath: root.path,
                              worktreePath: worktree.path, branch: "feature/$(no-command)", workspaceID: "worktree:7")
        let hooks = runner(global: global)
        hooks.emit(event)
        hooks.flush()
        let payload = try JSONDecoder().decode(HookEvent.self, from: Data(contentsOf: worktree.appendingPathComponent("payload.json")))
        XCTAssertEqual(payload.id, event.id)
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.worktreePath, worktree.path)
        XCTAssertEqual(payload.workspaceID, "worktree:7")
        XCTAssertEqual(try contents(worktree.lastPathComponent + "/order"), "global\nwildcard\nrepo\n")
        XCTAssertEqual(try contents(worktree.lastPathComponent + "/env"), "worktree.created\n\(worktree.path)\nfeature/$(no-command)\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    func testRemovalRunsInCheckoutAndConfigChangesApplyWithoutRestart() throws {
        let config = root.appendingPathComponent(".tabterm.json")
        let hooks = runner()
        let event = HookEvent(event: "worktree.removed", repositoryPath: root.path,
                              worktreePath: root.appendingPathComponent("gone").path)
        hooks.emit(event) // Missing config is a no-op.
        hooks.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("logs/hooks.log").path))
        try write(["hooks": ["worktree.removed": ["printf first > result"]]], to: config)
        hooks.emit(event)
        hooks.flush()
        XCTAssertEqual(try contents("result"), "first")
        try write(["hooks": ["worktree.removed": ["printf second > result"]]], to: config)
        hooks.emit(event)
        hooks.flush()
        XCTAssertEqual(try contents("result"), "second")
    }

    func testInvalidGlobalConfigDoesNotPreventRepositoryHook() throws {
        let global = root.appendingPathComponent("global.json")
        try Data("{broken".utf8).write(to: global)
        try write(["hooks": ["agent.finished": ["printf done > result"]]], to: root.appendingPathComponent(".tabterm.json"))
        let hooks = runner(global: global)
        hooks.emit(HookEvent(event: "agent.finished", repositoryPath: root.path))
        hooks.flush()
        XCTAssertEqual(try contents("result"), "done")
        XCTAssertTrue(try contents("logs/hooks.log").contains("config"))
    }

    func testFailureTimeoutAndLargeOutputDoNotBlockFollowingHooks() throws {
        try write(["hooks": ["agent.finished": [
            ["command": "printf failure >&2; exit 7"],
            ["command": "sleep 30 & child=$!; printf '%s' \"$child\" > child.pid; wait", "timeoutSeconds": 0.1],
            ["command": "head -c 200000 /dev/zero"],
            ["command": "printf survived > result"],
        ]]], to: root.appendingPathComponent(".tabterm.json"))
        let hooks = runner()
        let started = Date()
        hooks.emit(HookEvent(event: "agent.finished", repositoryPath: root.path))
        hooks.flush()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(try contents("result"), "survived")
        let log = try contents("logs/hooks.log")
        XCTAssertTrue(log.contains("exit 7"))
        XCTAssertTrue(log.contains("failure"))
        XCTAssertTrue(log.contains("timed out"))
        XCTAssertTrue(log.contains("[output truncated]"))
        XCTAssertLessThan(log.utf8.count, 70_000)
        let child = try XCTUnwrap(Int32(contents("child.pid")))
        // A killed grandchild may briefly remain a zombie until launchd reaps it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "stat=", "-p", String(child)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let state = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(state.isEmpty || state.hasPrefix("Z"), "timed-out child is gone or reaped: \(state)")
    }

    func testInvalidTimeoutIsLoggedAndSkipped() throws {
        for timeout in [0, -1, 3601] {
            try write(["hooks": ["agent.finished": [["command": "touch should-not-run", "timeoutSeconds": timeout]]]],
                      to: root.appendingPathComponent(".tabterm.json"))
            let hooks = runner()
            hooks.emit(HookEvent(event: "agent.finished", repositoryPath: root.path))
            hooks.flush()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-run").path))
        XCTAssertTrue(try contents("logs/hooks.log").contains("config"))
    }

    func testLogRotationKeepsOnePreviousFile() throws {
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let old = Data(repeating: 120, count: 1_048_577)
        try old.write(to: logs.appendingPathComponent("hooks.log"))
        try Data("older".utf8).write(to: logs.appendingPathComponent("hooks.previous.log"))
        try write(["hooks": ["agent.finished": ["printf newest"]]], to: root.appendingPathComponent(".tabterm.json"))
        let hooks = runner()
        hooks.emit(HookEvent(event: "agent.finished", repositoryPath: root.path))
        hooks.flush()
        XCTAssertEqual(try Data(contentsOf: logs.appendingPathComponent("hooks.previous.log")), old)
        XCTAssertTrue(try contents("logs/hooks.log").contains("newest"))
        XCTAssertLessThan(try contents("logs/hooks.log").utf8.count, 1024)
    }

    func testAgentTransitionsSuppressRepeatedReportsButKeepNewCompletions() {
        var report = AgentReport(state: .working, at: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(WorkbenchHooks.agentEventName(report, previous: nil), "agent.working")
        var previous = report
        report.at = Date(timeIntervalSince1970: 2)
        XCTAssertNil(WorkbenchHooks.agentEventName(report, previous: previous))
        report.state = .blocked
        XCTAssertEqual(WorkbenchHooks.agentEventName(report, previous: previous), "agent.blocked")
        previous = report
        report.at = Date(timeIntervalSince1970: 3)
        XCTAssertNil(WorkbenchHooks.agentEventName(report, previous: previous))
        report.state = .finished
        XCTAssertEqual(WorkbenchHooks.agentEventName(report, previous: previous), "agent.finished")
        previous = report
        report.transcript = "/new/metadata"
        XCTAssertNil(WorkbenchHooks.agentEventName(report, previous: previous))
        report.at = Date(timeIntervalSince1970: 4)
        XCTAssertEqual(WorkbenchHooks.agentEventName(report, previous: previous), "agent.finished")
        report.state = .idle
        XCTAssertNil(WorkbenchHooks.agentEventName(report, previous: previous))
    }

    func testWorktreeDiscoveryDoesNotReplayBaselineOrRepeatedRefreshes() throws {
        let hooks = runner()
        let original = WorkbenchHooks.runner
        WorkbenchHooks.runner = hooks
        defer { hooks.flush(); WorkbenchHooks.runner = original }
        let database = AppDatabase.useTemporaryDatabase()
        try GitService.run(["init", "-b", "main"], in: root.path)
        try GitService.run(["-c", "user.email=test@example.com", "-c", "user.name=Test",
                            "commit", "--allow-empty", "-m", "initial"], in: root.path)
        let baseline = root.appendingPathComponent("baseline").path
        try GitService.run(["worktree", "add", "-b", "baseline", baseline], in: root.path)
        try write([
            "worktreeRemoved": "printf '%s' \"$TABTERM_REMOVED_WORKTREES\" > legacy.txt",
            "hooks": ["*": ["printf '%s\\n' \"$WORKBENCH_EVENT\" >> \"$WORKBENCH_REPOSITORY_PATH/events.txt\""]]],
                  to: root.appendingPathComponent(".tabterm.json"))
        let repository = try RepositoryStore.add(path: root.path)
        hooks.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.txt").path))
        // Git canonicalizes macOS's /var alias to /private/var.
        let feature = repository.path + "/new-feature"
        try GitService.run(["worktree", "add", "-b", "feature", feature], in: root.path)
        // A failed transaction must neither publish an event nor advance the
        // baseline. The next successful refresh still discovers this worktree.
        try database.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_worktree BEFORE INSERT ON worktree BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        XCTAssertThrowsError(try RepositoryStore.refreshWorktrees(of: repository))
        hooks.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.txt").path))
        try database.queue.write { db in try db.execute(sql: "DROP TRIGGER reject_worktree") }
        try RepositoryStore.refreshWorktrees(of: repository)
        try RepositoryStore.refreshWorktrees(of: repository)
        hooks.flush()
        XCTAssertEqual(try contents("events.txt"), "worktree.created\n")
        try GitService.run(["worktree", "remove", feature], in: root.path)
        try RepositoryStore.refreshWorktrees(of: repository)
        try RepositoryStore.refreshWorktrees(of: repository)
        hooks.flush()
        XCTAssertEqual(try contents("events.txt"), "worktree.created\nworktree.removed\n")
        let deadline = Date().addingTimeInterval(3)
        while (try? contents("legacy.txt")) != feature, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(try contents("legacy.txt"), feature)
        RepositoryStore.remove(repository)
        hooks.flush()
        XCTAssertEqual(try contents("events.txt"), "worktree.created\nworktree.removed\n")
    }
}

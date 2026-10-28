import AppKit
import XCTest
@testable import TabTerm

final class ReviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-review-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"])
        try git(["config", "user.email", "test@example.invalid"])
        try git(["config", "user.name", "Workbench Tests"])
        try git(["config", "commit.gpgsign", "false"])
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func git(_ args: [String]) throws -> String {
        try ReviewCommand.git(args, in: root.path)
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func testUnbornRepositoryAndLiteralUntrackedNames() throws {
        try write("hello\nworld.txt", "hello\n")
        try write(":(glob)*.txt", "literal\n")
        let snapshot = try ChangelistService.load(at: root.path)
        XCTAssertNil(snapshot.head)
        XCTAssertEqual(Set(snapshot.files.map(\.path)), ["hello\nworld.txt", ":(glob)*.txt"])
        XCTAssertTrue(snapshot.files.allSatisfy { $0.area == .untracked })
        XCTAssertEqual(try ChangelistService.preview(snapshot.files.first { $0.path == ":(glob)*.txt" }!, at: root.path), "literal\n")
    }

    func testStagedAndUnstagedDiffsStaySeparateAndPathsAreLiteral() throws {
        try write(":(glob)*.txt", "initial\n")
        try write("other.txt", "other\n")
        try git(["add", "."])
        try git(["commit", "-qm", "initial"])
        try write(":(glob)*.txt", "staged\n")
        try git(["add", "--", ":(glob)*.txt"])
        try write(":(glob)*.txt", "unstaged\n")
        try write("other.txt", "unrelated\n")
        let snapshot = try ChangelistService.load(at: root.path)
        let staged = try XCTUnwrap(snapshot.files.first { $0.path == ":(glob)*.txt" && $0.area == .staged })
        let unstaged = try XCTUnwrap(snapshot.files.first { $0.path == ":(glob)*.txt" && $0.area == .unstaged })
        let stagedDiff = try ChangelistService.preview(staged, at: root.path)
        let unstagedDiff = try ChangelistService.preview(unstaged, at: root.path)
        XCTAssertTrue(stagedDiff.contains("-initial\n+staged"))
        XCTAssertFalse(stagedDiff.contains("+unstaged"))
        XCTAssertTrue(unstagedDiff.contains("-staged\n+unstaged"))
        XCTAssertFalse(unstagedDiff.contains("other.txt"))
    }

    func testRenameAndDeletion() throws {
        try write("old name.txt", "unchanged\n")
        try write("removed.txt", "delete me\n")
        try git(["add", "."])
        try git(["commit", "-qm", "initial"])
        try git(["mv", "old name.txt", "new name.txt"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.txt"))
        let files = try ChangelistService.load(at: root.path).files
        let rename = try XCTUnwrap(files.first { $0.status == "R" })
        XCTAssertEqual(rename.path, "new name.txt")
        XCTAssertEqual(rename.originalPath, "old name.txt")
        XCTAssertTrue(try ChangelistService.preview(rename, at: root.path).contains("rename from old name.txt"))
        XCTAssertTrue(files.contains { $0.path == "removed.txt" && $0.status == "D" && $0.area == .unstaged })
    }

    func testConflictsAreSingleEntries() {
        let files = ChangelistService.parse("UU conflict\0AA both-added\0DD both-deleted\0?? normal\0")
        XCTAssertEqual(files.filter { $0.area == .conflicted }.count, 3)
        XCTAssertEqual(files.count, 4)
    }

    func testBinarySymlinkAndLargeUntrackedPreview() throws {
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/does/not/exist")
        try write("large", String(repeating: "a", count: 300_000))
        let files = try ChangelistService.load(at: root.path).files
        func preview(_ name: String) throws -> String { try ChangelistService.preview(files.first { $0.path == name }!, at: root.path) }
        XCTAssertTrue(try preview("binary").contains("Binary"))
        XCTAssertEqual(try preview("link"), "Symbolic link → /does/not/exist")
        XCTAssertTrue(try preview("large").hasSuffix("[Preview truncated at 256 KiB]"))
    }

    func testPaginatedChecksAndExternalStatuses() throws {
        let runs = Data(#"[{"check_runs":[{"name":"test","status":"completed","conclusion":"success","html_url":"https://github.com/example/check/1"},{"name":"build","status":"queued"}]},{"check_runs":[{"name":"lint","status":"completed","conclusion":"failure"},{"name":"optional","status":"completed","conclusion":"skipped"}]}]"#.utf8)
        let statuses = Data(#"[{"statuses":[{"context":"external","state":"pending","description":"Deploying","target_url":"https://ci.example/run"}]},{"statuses":[]}]"#.utf8)
        let ci = try CIService.decode(runs: runs, statuses: statuses)
        XCTAssertEqual(ci.checks.count, 5)
        XCTAssertEqual(ci.state, .failed)
        XCTAssertEqual(ci.summary, "1 failed")
        XCTAssertEqual(ci.checks.first?.name, "lint")
        XCTAssertEqual(ci.checks.first { $0.name == "external" }?.state, .pending)
        XCTAssertEqual(ci.checks.first { $0.name == "test" }?.url?.scheme, "https")
    }

    func testIncompleteUnknownAndSkippedChecksNeverTurnGreen() throws {
        for (conclusion, expected) in [("cancelled", CheckState.failed), ("timed_out", .failed), ("action_required", .failed), ("stale", .failed), ("neutral", .skipped), ("skipped", .skipped), ("new_future_state", .unknown)] {
            let runs = try JSONSerialization.data(withJSONObject: [["check_runs": [["name": "test", "status": "completed", "conclusion": conclusion]]]])
            let ci = try CIService.decode(runs: runs, statuses: Data(#"[{"statuses":[]}]"#.utf8))
            XCTAssertEqual(ci.state, expected, conclusion)
        }
        let empty = try CIService.decode(runs: Data(#"[{"check_runs":[]}]"#.utf8), statuses: Data(#"[{"statuses":[]}]"#.utf8))
        XCTAssertNil(empty.state)
        XCTAssertEqual(empty.summary, "No checks")
        XCTAssertThrowsError(try CIService.decode(runs: Data("invalid".utf8), statuses: Data()))
        XCTAssertNil(CIService.webURL("file:///tmp/script.command"))
        XCTAssertNil(CIService.webURL("javascript:alert(1)"))
    }

    func testPRRollupIsOnlyUsedForMatchingLocalCommit() throws {
        let data = Data(#"{"headRefOid":"abc123","statusCheckRollup":[{"name":"merge build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/example/check/2"},{"context":"deploy","state":"PENDING","targetUrl":"https://ci.example/deploy"}]}"#.utf8)
        XCTAssertNil(try CIService.decodePullRequest(data, matching: "new-local-commit"))
        let snapshot = try XCTUnwrap(CIService.decodePullRequest(data, matching: "abc123"))
        XCTAssertEqual(snapshot.checks.count, 2)
        XCTAssertEqual(snapshot.state, .pending)
        XCTAssertEqual(snapshot.checks.first?.name, "deploy")
    }

    @MainActor func testReviewPanelLayoutAndModes() async throws {
        try write("Example.swift", "let greeting = \"Hello\"\n")
        try git(["add", "."])
        try git(["commit", "-qm", "initial"])
        try write("Example.swift", "let greeting = \"Hello, Workbench\"\n")
        let controller = ReviewViewController()
        controller.loadCI = { _, _ in
            CISnapshot(checks: [
                CICheck(name: "Build and test / macOS", state: .failed, detail: "failure", url: URL(string: "https://github.com/example/check/1")),
                CICheck(name: "Deploy preview", state: .pending, detail: "queued", url: URL(string: "https://ci.example/preview")),
                CICheck(name: "Lint", state: .passed, detail: "success", url: nil),
            ])
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 420, height: 620))
        let loaded = expectation(description: "review loaded")
        controller.onSummary = { _, _, _ in if controller.ci != nil { loaded.fulfill() } }
        controller.select(directory: root.path, automaticallyRefresh: false)
        controller.refresh()
        await fulfillment(of: [loaded], timeout: 3)
        controller.onSummary = nil
        // Let the selected file's asynchronous diff finish before rendering.
        try await Task.sleep(nanoseconds: 100_000_000)
        func capture(_ name: String) throws {
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(controller.view.bounds.height, 500)
            guard let destination = ProcessInfo.processInfo.environment["WORKBENCH_REVIEW_PREVIEW_DIR"] else { return }
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
        }
        try capture("changes")
        controller.showCI(true)
        XCTAssertTrue(controller.displaysCI)
        try capture("ci")
        controller.showCI(false)
        XCTAssertFalse(controller.displaysCI)
        window.contentViewController = nil
    }

    func testCommandDrainsStderrAndTimesOut() throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        let output = try ReviewCommand.run(shell, ["-c", "i=0; while [ $i -lt 10000 ]; do echo stderr-output >&2; i=$((i+1)); done; echo done"], in: root.path)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "done\n")
        XCTAssertThrowsError(try ReviewCommand.run(shell, ["-c", "exec sleep 5"], in: root.path, timeout: 0.05)) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertThrowsError(try ReviewCommand.run(shell, ["-c", "printf 123456"], in: root.path, limit: 5))
    }

    @MainActor func testLateWorkspaceResultCannotReplaceCurrentWorkspace() async throws {
        let controller = ReviewViewController()
        let oldStarted = expectation(description: "old request started")
        let newLoaded = expectation(description: "new workspace loaded")
        let gate = DispatchSemaphore(value: 0)
        controller.loadChanges = { path in
            if path == "/old" {
                oldStarted.fulfill()
                _ = gate.wait(timeout: .now() + 5)
            }
            return ChangelistSnapshot(files: [], head: path)
        }
        controller.loadCI = { _, _ in CISnapshot(checks: []) }
        controller.onSummary = { _, _, _ in
            if controller.changes?.head == "/new", controller.ci != nil { newLoaded.fulfill() }
        }
        controller.select(directory: "/old", automaticallyRefresh: false)
        controller.refresh()
        await fulfillment(of: [oldStarted], timeout: 2)
        controller.select(directory: "/new", automaticallyRefresh: false)
        controller.refresh()
        await fulfillment(of: [newLoaded], timeout: 2)
        controller.onSummary = nil
        gate.signal()
        // Give the old request's main-queue completion a chance to run.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.changes?.head, "/new")
        XCTAssertEqual(controller.ci?.summary, "No checks")
    }

    @MainActor func testLateCIForPreviousCommitCannotTurnNewCommitGreen() async throws {
        let controller = ReviewViewController()
        let oldStarted = expectation(description: "old CI started")
        let newLoaded = expectation(description: "new CI loaded")
        let gate = DispatchSemaphore(value: 0)
        controller.loadChanges = { _ in ChangelistSnapshot(files: [], head: "old") }
        controller.loadCI = { _, head in
            if head == "old" { oldStarted.fulfill(); _ = gate.wait(timeout: .now() + 5) }
            return CISnapshot(checks: [CICheck(name: "tests", state: head == "old" ? .passed : .failed, detail: "", url: nil)])
        }
        controller.select(directory: root.path, automaticallyRefresh: false)
        controller.refresh()
        await fulfillment(of: [oldStarted], timeout: 2)
        controller.loadChanges = { _ in ChangelistSnapshot(files: [], head: "new") }
        controller.onSummary = { _, _, _ in
            if controller.changes?.head == "new", controller.ci?.state == .failed { newLoaded.fulfill() }
        }
        controller.refresh()
        await fulfillment(of: [newLoaded], timeout: 2)
        controller.onSummary = nil
        gate.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.changes?.head, "new")
        XCTAssertEqual(controller.ci?.state, .failed)
    }
}

import TabTermKit
import XCTest
@testable import tabterm

/// The real `workbench` binary, in a terminal of its own, against a stand-in
/// for the Mac. What is checked is what would be on screen and what the Mac
/// would have been sent.
final class EndToEndTests: XCTestCase {
    private var host: FakeHost!
    private var config: URL!
    private var runs: [TerminalRun] = []

    private let claude = UUID()
    private let shell = UUID()
    private let server = UUID()

    private let reset = "\u{1b}c"
    private let menuKey = "\u{1c}"
    private let listTitle = "Workbench on Studio"

    override func setUpWithError() throws {
        host = FakeHost(state: HostState(
            hostName: "Studio",
            workspaces: [
                WorkspaceInfo(
                    id: "home", name: "Home", repository: nil, branch: nil, directory: nil,
                    isOpen: true, status: .idle,
                    tabs: [FakeHost.tab("claude", claude), FakeHost.tab("zsh", shell, selected: false)]
                ),
                WorkspaceInfo(
                    id: "worktree:1", name: "main", repository: "myapp", branch: "main",
                    directory: "/Users/example/code/myapp", isOpen: true, status: .idle,
                    tabs: [FakeHost.tab("server", server)]
                ),
                WorkspaceInfo(
                    id: "worktree:2", name: "feature-auth", repository: "myapp", branch: "feature-auth",
                    directory: "/Users/example/code/myapp-worktrees/feature-auth", isOpen: false, status: .idle, tabs: []
                ),
            ],
            focus: HostState.Focus(workspace: "home", session: claude)
        ))

        config = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbench-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let paired = PairedHost(
            name: "Studio", hosts: ["127.0.0.1"], port: host.port, deviceID: "device-1", deviceToken: host.token)
        try JSONEncoder().encode(paired).write(to: config.appendingPathComponent("pairing.json"))
    }

    override func tearDown() {
        runs.forEach { $0.stop() }
        runs = []
        host.stop()
        try? FileManager.default.removeItem(at: config)
    }

    // MARK: - Helpers

    private func attach(_ arguments: [String] = []) throws -> TerminalRun {
        let run = try TerminalRun(["attach"] + arguments, config: config)
        runs.append(run)
        return run
    }

    /// Run a command that isn't in a terminal, and collect what it printed.
    private func command(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = TerminalRun.binary
        process.arguments = arguments
        process.environment = ["TABTERM_CONFIG_DIR": config.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    private func wait(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        until condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(10_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - pair, ls

    func testPairingKeepsATokenAndTheCodeWorksOnce() throws {
        let file = config.appendingPathComponent("pairing.json")
        try FileManager.default.removeItem(at: file)
        let unpaired = try command(["ls"])
        XCTAssertEqual(unpaired.status, 1)
        XCTAssertTrue(unpaired.output.contains("Not paired"))

        host.pairingCode = "one-time"
        let link = PairingLink(name: "Mac", hosts: ["127.0.0.1"], port: host.port, code: "one-time").url.absoluteString
        let paired = try command(["pair", link])
        XCTAssertEqual(paired.status, 0, paired.output)
        XCTAssertTrue(paired.output.contains("Paired with Studio"))

        let saved = try JSONDecoder().decode(PairedHost.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.deviceToken, host.token)
        XCTAssertEqual(saved.name, "Studio")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        // A second go with the same link is turned away, and leaves the
        // pairing that worked alone.
        let again = try command(["pair", link])
        XCTAssertEqual(again.status, 1)
        XCTAssertTrue(again.output.contains("already used"))
        XCTAssertEqual(try command(["ls"]).status, 0)
        XCTAssertEqual(host.hellos.last?.deviceToken, host.token)
    }

    func testListShowsEveryWorkspaceAndItsTerminals() throws {
        let listed = try command(["ls"])
        XCTAssertEqual(listed.status, 0, listed.output)
        XCTAssertEqual(listed.output, """
            Home
             * 1   claude
               2   zsh
            myapp/main  ~/code/myapp
               1   server
            myapp/feature-auth  not open

            """)
    }

    func testAMacThatForgotThisOneSaysSo() throws {
        var stranger = try JSONDecoder().decode(
            PairedHost.self, from: Data(contentsOf: config.appendingPathComponent("pairing.json")))
        stranger.deviceToken = "someone-else"
        try JSONEncoder().encode(stranger).write(to: config.appendingPathComponent("pairing.json"))

        let listed = try command(["ls"])
        XCTAssertEqual(listed.status, 1)
        XCTAssertTrue(listed.output.contains("doesn't know this Mac any more"))
    }

    // MARK: - attach

    func testAttachShowsTheTerminalAndPassesKeysThrough() throws {
        host.output(claude, "earlier\r\n")
        host.preamble = "\u{1b}[?2004h"
        let run = try attach()

        // With nothing named, it is the terminal the Mac has on screen.
        wait("the attach") { host.attaches.count == 1 }
        XCTAssertEqual(host.attaches[0].session, claude)
        XCTAssertEqual(host.attaches[0].anchor, .fresh)
        XCTAssertEqual(host.attaches[0].size, TerminalSize(cols: 80, rows: 24))

        // A clean screen, then the modes, then what the terminal had said.
        wait("the replay") { run.screen.contains("earlier") }
        let screen = run.screen
        let order = [reset, "\u{1b}[?2004h", "earlier"].compactMap { screen.range(of: $0)?.lowerBound }
        XCTAssertEqual(order.count, 3)
        XCTAssertEqual(order, order.sorted())

        host.output(claude, "live\r\n")
        wait("live output") { run.screen.contains("live") }

        run.type("ls\r")
        wait("typing") { host.typed(claude) == "ls\r" }

        // This terminal's answer to a question the Mac's terminal already
        // answered goes nowhere — even arriving in two pieces.
        run.type("\u{1b}[24;")
        usleep(5_000)
        run.type("1Rx")
        wait("the key after a reply") { host.typed(claude) == "ls\rx" }

        // Clicks and arrows are the user's, and go through.
        run.type("\u{1b}[<0;10;5M\u{1b}[A")
        wait("mouse and arrows") { host.typed(claude) == "ls\rx\u{1b}[<0;10;5M\u{1b}[A" }

        // So does Escape, once it is clear nothing follows it.
        run.type("\u{1b}")
        wait("escape") { host.typed(claude).hasSuffix("[A\u{1b}") }
    }

    func testAttachByNameAndTab() throws {
        // One at a time: the stand-in serves a single connection.
        let named = try attach(["main"])
        wait("the worktree's terminal") { host.attaches.last?.session == server }
        named.stop()

        let numbered = try attach(["home", "2"])
        wait("the second tab") { host.attaches.last?.session == shell }
        numbered.stop()

        let missing = try attach(["nope"])
        wait("a refusal") { missing.screen.contains("nothing called 'nope'") }
        wait("the exit") { !missing.process.isRunning }
        XCTAssertEqual(missing.process.terminationStatus, 1)

        let noTab = try attach(["home", "9"])
        wait("a refusal") { noTab.screen.contains("Home has no tab 9") }
    }

    func testAttachStartsAWorktreeNobodyHasOpened() throws {
        let run = try attach(["auth"])
        wait("the worktree to be opened") { host.messages.contains(.openWorkspace(WorkspaceRef(workspace: "worktree:2"))) }
        wait("its terminal") { host.attaches.count == 1 }
        XCTAssertEqual(host.attaches[0].session, host.state.workspaces[2].tabs.first?.panes.first?.session)
        XCTAssertTrue(run.screen.contains("Starting myapp/feature-auth"))
    }

    // MARK: - new

    private var worktreeRequests: [NewWorktree] {
        host.messages.compactMap { if case .newWorktree(let request) = $0 { return request } else { return nil } }
    }

    func testNewMakesAWorktreeAndOpensIt() throws {
        // One repository in the sidebar, so it doesn't need naming.
        let run = try TerminalRun(["new", "feature/search"], config: config)
        runs.append(run)

        wait("the request") { worktreeRequests.count == 1 }
        XCTAssertEqual(worktreeRequests[0].branch, "feature/search")
        XCTAssertEqual(host.state.workspace(id: worktreeRequests[0].workspace)?.repository, "myapp")

        // Nobody has opened it, so its terminals are started, then attached to.
        wait("the new worktree") { host.state.workspaces.count == 4 }
        let made = host.state.workspaces[3]
        wait("its terminals to be started") { host.messages.contains(.openWorkspace(WorkspaceRef(workspace: made.id))) }
        wait("the attach") { host.attaches.count == 1 }
        XCTAssertEqual(host.attaches[0].session, host.state.workspaces[3].tabs.first?.panes.first?.session)
        XCTAssertTrue(run.screen.contains("Making myapp/feature/search"))
    }

    func testNewWithoutATerminalOnlyMakesIt() throws {
        let made = try command(["new", "myapp", "hotfix"])
        XCTAssertEqual(made.status, 0, made.output)
        XCTAssertTrue(made.output.contains("Made myapp/hotfix in ~/code/myapp-worktrees/hotfix"), made.output)
        XCTAssertTrue(host.attaches.isEmpty)
        XCTAssertTrue(try command(["ls"]).output.contains("myapp/hotfix  not open"))
    }

    func testNewSaysWhyNot() throws {
        // git's own words, for a branch that already has a worktree.
        let taken = try command(["new", "feature-auth"])
        XCTAssertEqual(taken.status, 1)
        XCTAssertTrue(taken.output.contains("already used by worktree"), taken.output)

        let unknown = try command(["new", "nope", "x"])
        XCTAssertEqual(unknown.status, 1)
        XCTAssertTrue(unknown.output.contains("no repository called 'nope'"))
        XCTAssertEqual(worktreeRequests.count, 1, "nothing is asked of the Mac for a repository it doesn't have")
    }

    func testNewOnAMacThatIsTooOldSaysSo() throws {
        host.knowsWorktrees = false
        let refused = try command(["new", "hotfix"])
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.output.contains("older than this workbench"), refused.output)
        XCTAssertTrue(refused.output.contains("git worktree add"))
    }

    func testOldBellsAndNotificationsAreNotReplayed() throws {
        host.output(claude, "done\u{7}\u{1b}]777;notify;Claude;needs you\u{7}\r\n")
        let run = try attach()
        wait("the replay") { run.screen.contains("done") }
        XCTAssertFalse(run.screen.contains("\u{7}"))
        XCTAssertFalse(run.screen.contains("777"))

        // One that happens while attached is news.
        host.output(claude, "now\u{7}")
        wait("a live bell") { run.screen.contains("now\u{7}") }
    }

    func testResizingTellsTheMac() throws {
        let run = try attach()
        wait("the attach") { host.attaches.count == 1 }
        run.resize(cols: 100, rows: 30)
        let resized = ClientMessage.resize(Resize(session: claude, size: TerminalSize(cols: 100, rows: 30)))
        wait("the new size") { host.messages.contains(resized) }
    }

    // MARK: - The list

    func testTheListSwitchesTerminals() throws {
        host.output(claude, "in claude\r\n")
        host.output(shell, "in the shell\r\n")
        host.output(server, "in the server\r\n")
        let run = try attach()
        wait("the first terminal") { run.screen.contains("in claude") }

        run.type(menuKey)
        wait("the list") { run.screen.contains(listTitle) }
        XCTAssertTrue(run.screen.contains("myapp/feature-auth"))
        XCTAssertEqual(host.typed(claude), "", "the key that opens the list isn't typed")

        // Down one from where we are, and open it.
        run.type("j\r")
        wait("the switch") { host.attaches.last?.session == shell }
        XCTAssertEqual(host.attaches.last?.anchor, .fresh)
        XCTAssertTrue(host.messages.contains(.detach(SessionRef(session: claude))))
        wait("the second terminal") { run.screen.contains("in the shell") }
        XCTAssertEqual(count(reset, in: run.screen), 2, "each terminal starts from a clean screen")

        run.type("pwd\r")
        wait("typing in the second") { host.typed(shell) == "pwd\r" }
        XCTAssertEqual(host.typed(claude), "")

        // By number: the third row that can be chosen.
        run.type(menuKey + "3")
        wait("the jump") { host.attaches.last?.session == server }
        wait("the third terminal") { run.screen.contains("in the server") }
    }

    func testGoingBackFromTheListLosesNothing() throws {
        host.preamble = "\u{1b}[?2004h"
        let run = try attach()
        wait("the attach") { host.attaches.count == 1 }

        run.type(menuKey)
        wait("the list") { run.screen.contains(listTitle) }
        // The list has its own screen, and the program's modes are off while
        // it is up.
        XCTAssertTrue(run.screen.contains("\u{1b}[?2004l\u{1b}[?1049h"))
        host.output(claude, "while away\r\n")
        usleep(100_000)
        XCTAssertFalse(run.screen.contains("while away"), "nothing is drawn under the list")

        run.type("\u{1b}")
        wait("what was missed") { run.screen.contains("while away") }
        // Back on the terminal's screen, its modes on again, and then what
        // it wrote in the meantime — with no need to ask the Mac again.
        XCTAssertTrue(run.screen.contains("\u{1b}[?1049l\u{1b}[?2004hwhile away"))
        XCTAssertEqual(host.attaches.count, 1)
        XCTAssertEqual(count(reset, in: run.screen), 1)

        // Twice is the key itself, for a program that wants it.
        run.type(menuKey)
        wait("the list again") { count(listTitle, in: run.screen) >= 2 }
        run.type(menuKey + "after")
        wait("the key, typed") { host.typed(claude) == menuKey + "after" }
    }

    func testAFullScreenProgramIsRedrawnAfterTheList() throws {
        // The list borrows the alternate screen, so a program that was on it
        // has to be sent again from scratch.
        host.preamble = "\u{1b}[?1049h\u{1b}[?1000h"
        host.output(claude, "editor")
        let run = try attach()
        wait("the program") { run.screen.contains("editor") }

        run.type(menuKey)
        wait("the list") { run.screen.contains(listTitle) }
        run.type("\u{1b}")
        wait("a fresh attach") { host.attaches.count == 2 }
        XCTAssertEqual(host.attaches[1].anchor, .fresh)
        wait("the program again") { count("editor", in: run.screen) == 2 }
    }

    func testOpeningTerminalsFromTheList() throws {
        let run = try attach()
        wait("the attach") { host.attaches.count == 1 }

        // A new terminal beside the one we're in.
        run.type(menuKey)
        wait("the list") { run.screen.contains(listTitle) }
        run.type("n")
        wait("the new tab") { host.state.workspaces[0].tabs.count == 3 }
        let created = host.state.workspaces[0].tabs[2].panes[0].session
        wait("its terminal") { host.attaches.last?.session == created }

        // And a worktree nobody had opened: the last row that can be chosen.
        run.type(menuKey + "5")
        wait("the worktree to be opened") { host.state.workspaces[2].isOpen }
        let started = host.state.workspaces[2].tabs[0].panes[0].session
        wait("its terminal") { host.attaches.last?.session == started }
    }

    func testAShellExitingBringsUpTheList() throws {
        let run = try attach()
        wait("the attach") { host.attaches.count == 1 }

        host.send(.exit(SessionExit(session: claude, code: 0)))
        wait("the list") { run.screen.contains("That terminal's shell exited.") }

        // There is nothing to go back to, so Escape stays put.
        run.type("\u{1b}")
        usleep(200_000)
        XCTAssertTrue(run.process.isRunning)
        XCTAssertEqual(host.attaches.count, 1)

        run.type("2")
        wait("another terminal") { host.attaches.last?.session == shell }
    }

    func testDetachingHandsTheTerminalBack() throws {
        host.preamble = "\u{1b}[?1049h\u{1b}[?2004h\u{1b}[?1000h\u{1b}[?1006h\u{1b}[>1u"
        let run = try attach()
        wait("the attach") { host.attaches.count == 1 }
        wait("the modes") { run.screen.contains("\u{1b}[>1u") }

        run.type(menuKey + "q")
        wait("the exit") { !run.process.isRunning }
        XCTAssertEqual(run.process.terminationStatus, 0)
        XCTAssertTrue(run.screen.contains("[workbench: detached from Studio]"))
        XCTAssertTrue(host.messages.contains(.detach(SessionRef(session: claude))))

        // Everything the program had switched on is switched off again.
        let screen = run.screen
        let after = String(screen[screen.range(of: "\u{1b}[>1u")!.upperBound...])
        for off in ["\u{1b}[=0;1u", "\u{1b}[?1049l", "\u{1b}[?1000l", "\u{1b}[?1006l", "\u{1b}[?2004l"] {
            XCTAssertTrue(after.contains(off), "missing \(off.dropFirst())")
        }
    }

    // MARK: - Losing the connection

    func testABriefDropIsCaughtUpExactly() throws {
        host.output(claude, "one")
        let run = try attach()
        wait("the replay") { run.screen.contains("one") }

        host.drop()
        host.output(claude, "two")
        wait("the reconnect") { host.attaches.count == 2 }
        XCTAssertEqual(host.hellos.last?.deviceToken, host.token)
        // It says where it had got to, and is sent only what it missed.
        XCTAssertEqual(host.attaches[1].anchor, .position(epoch: host.epoch, seq: 3))
        wait("what was missed") { run.screen.contains("two") }
        XCTAssertEqual(count(reset, in: run.screen), 1, "the screen is kept")
        XCTAssertFalse(run.screen.contains("Lost the connection"), "too brief to mention")

        run.type("k")
        wait("typing again") { host.typed(claude) == "k" }
    }

    func testALongOutageSaysSoAndThenCarriesOn() throws {
        host.output(claude, "one")
        let run = try attach()
        wait("the replay") { run.screen.contains("one") }

        host.isRefusing = true
        host.drop()
        wait("the notice") { run.screen.contains("Lost the connection to Studio") }

        host.output(claude, "two")
        host.isRefusing = false
        wait("the reconnect", timeout: 10) { host.attaches.count == 2 }
        wait("what was missed") { run.screen.contains("two") }
        // The notice took itself down, and the terminal is as it was.
        XCTAssertTrue(run.screen.hasSuffix("\u{1b}[?1049ltwo"))
        XCTAssertEqual(count(reset, in: run.screen), 1)
    }
}

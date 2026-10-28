import TabTermKit
import XCTest
@testable import tabterm

private func bytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

final class InputScannerTests: XCTestCase {
    func testCutsKeysFromSequences() {
        var scanner = InputScanner()
        XCTAssertEqual(scanner.feed(bytes("ls\u{1b}[A\u{1b}OB\u{1b}[<0;10;5Mé\r")), [
            .text(bytes("ls")),
            .sequence(bytes("\u{1b}[A")),
            .sequence(bytes("\u{1b}OB")),
            .sequence(bytes("\u{1b}[<0;10;5M")),
            .text(bytes("é\r")),
        ])
        XCTAssertFalse(scanner.hasPending)
    }

    func testAReplySplitAcrossReadsIsStillOneSequence() {
        // However a colour report is cut, it comes out whole — and so is
        // dropped whole, rather than its tail being typed at the prompt.
        let reply = bytes("\u{1b}]11;rgb:1e1e/1e1e/2e2e\u{1b}\\")
        for cut in 1..<reply.count {
            var scanner = InputScanner()
            var tokens = scanner.feed(Array(reply[..<cut]))
            XCTAssertTrue(scanner.hasPending, "cut at \(cut)")
            tokens += scanner.feed(Array(reply[cut...]) + bytes("x"))
            XCTAssertEqual(tokens, [.sequence(reply), .text(bytes("x"))], "cut at \(cut)")

            let kept = tokens.flatMap { token -> [UInt8] in
                switch token {
                case .text(let text): return text
                case .sequence(let sequence): return ResponseFilter.keystrokes(from: sequence)
                }
            }
            XCTAssertEqual(kept, bytes("x"))
        }
    }

    func testALoneEscapeIsTheEscapeKeyOnceNothingFollows() {
        var scanner = InputScanner()
        XCTAssertEqual(scanner.feed([0x1B]), [])
        XCTAssertTrue(scanner.hasPending)
        XCTAssertEqual(scanner.flush(), [.text([0x1B])])
        XCTAssertFalse(scanner.hasPending)

        // But not when the rest of an arrow key was right behind it.
        XCTAssertEqual(scanner.feed([0x1B]), [])
        XCTAssertEqual(scanner.feed(bytes("[B")), [.sequence(bytes("\u{1b}[B"))])
    }

    func testAltKeysAndDoubledEscapes() {
        var scanner = InputScanner()
        XCTAssertEqual(scanner.feed(bytes("\u{1b}b\u{1b}\u{1b}[A")), [
            .sequence(bytes("\u{1b}b")),
            .text([0x1B]),
            .sequence(bytes("\u{1b}[A")),
        ])
    }
}

final class MenuKeyTests: XCTestCase {
    func testTheControlCharacter() {
        XCTAssertEqual(MenuKey.standard.byte, 0x1C)
        XCTAssertEqual(MenuKey("b")?.byte, 0x02)
        XCTAssertEqual(MenuKey("b")?.name, "ctrl-b")
        // Tab, Return and Escape can't be given up.
        XCTAssertNil(MenuKey("i"))
        XCTAssertNil(MenuKey("m"))
        XCTAssertNil(MenuKey("["))
        XCTAssertNil(MenuKey("é"))
    }

    func testTheKittyKeyboardForm() {
        let key = MenuKey.standard
        XCTAssertEqual(key.event(in: bytes("\u{1b}[92;5u")), .press)
        // Caps Lock on, alternate keys reported, a repeat.
        XCTAssertEqual(key.event(in: bytes("\u{1b}[92;69u")), .press)
        XCTAssertEqual(key.event(in: bytes("\u{1b}[92:124;5:2u")), .press)
        XCTAssertEqual(key.event(in: bytes("\u{1b}[92;5:3u")), .release)

        // The same character without Ctrl, with more than Ctrl, another key.
        XCTAssertNil(key.event(in: bytes("\u{1b}[92u")))
        XCTAssertNil(key.event(in: bytes("\u{1b}[92;6u")))
        XCTAssertNil(key.event(in: bytes("\u{1b}[98;5u")))
        XCTAssertNil(key.event(in: bytes("\u{1b}[A")))

        XCTAssertEqual(key.bytes(keyboardFlags: 1), [0x1C])
        XCTAssertEqual(key.bytes(keyboardFlags: 15), bytes("\u{1b}[92;5u"))
    }

    func testMouseReports() {
        XCTAssertTrue(isMouseReport(bytes("\u{1b}[<0;10;5M")))
        XCTAssertTrue(isMouseReport(bytes("\u{1b}[<65;10;5m")))
        XCTAssertFalse(isMouseReport(bytes("\u{1b}[5~")))
        XCTAssertFalse(isMouseReport(bytes("\u{1b}[M")))
    }
}

final class ReplayTests: XCTestCase {
    private func clean(_ text: String) -> String {
        String(decoding: Replay.withoutSideEffects(Data(text.utf8)), as: UTF8.self)
    }

    func testTakesOutWhatWouldHappenTwice() {
        XCTAssertEqual(clean("done\u{7}\r\n"), "done\r\n")
        XCTAssertEqual(clean("a\u{1b}]777;notify;Claude;needs you\u{7}b"), "ab")
        XCTAssertEqual(clean("a\u{1b}]9;needs you\u{1b}\\b"), "ab")
        XCTAssertEqual(clean("a\u{1b}]52;c;aGVsbG8=\u{7}b"), "ab")
    }

    func testKeepsWhatDraws() {
        // A title ends in a BEL that is part of it; a hyperlink is OSC 8.
        let kept = "\u{1b}]0;~/code\u{7}\u{1b}[31mred\u{1b}[0m\u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\"
        XCTAssertEqual(clean(kept), kept)
        // A BEL inside a DCS is data, not a bell.
        let sixel = "\u{1b}Pq#0\u{7}~~\u{1b}\\"
        XCTAssertEqual(clean(sixel), sixel)
        // A notification the replay ends in the middle of is left alone: the
        // rest of it is still on its way.
        XCTAssertEqual(clean("a\u{1b}]9;half"), "a\u{1b}]9;half")
    }
}

final class CatalogTests: XCTestCase {
    static let claude = UUID()
    static let shell = UUID()
    static let split = UUID()

    static let state = HostState(
        hostName: "Studio",
        workspaces: [
            WorkspaceInfo(
                id: "home", name: "Home", repository: nil, branch: nil, directory: nil,
                isOpen: true, status: .idle, tabs: []
            ),
            WorkspaceInfo(
                id: "worktree:1", name: "main", repository: "myapp", branch: "main",
                directory: "/Users/example/code/myapp", isOpen: true, status: .blocked,
                tabs: [
                    TabInfo(id: UUID(), title: "claude", isSelected: false, panes: [
                        PaneInfo(session: claude, title: "✳ Fix the tests", directory: "/Users/example/code/myapp", isClaude: true, status: .blocked, isFocused: true),
                    ]),
                    TabInfo(id: UUID(), title: "zsh", isSelected: true, panes: [
                        PaneInfo(session: shell, title: "~/code/myapp", directory: "/Users/example/code/myapp", isClaude: false, status: .idle, isFocused: false),
                        PaneInfo(session: split, title: "npm run dev", directory: "/Users/example/code/myapp/web", isClaude: false, status: .working, isFocused: true),
                    ]),
                ]
            ),
            WorkspaceInfo(
                id: "worktree:2", name: "feature/auth", repository: "myapp", branch: "feature/auth",
                directory: "/Users/example/code/myapp-worktrees/feature-auth", isOpen: false, status: .idle, tabs: []
            ),
            WorkspaceInfo(
                id: "worktree:3", name: "main", repository: "site", branch: "main",
                directory: "/Users/example/code/site", isOpen: false, status: .idle, tabs: []
            ),
        ],
        focus: HostState.Focus(workspace: "worktree:1", session: split)
    )

    private func find(_ query: String) -> String? {
        if case .one(let workspace) = Catalog.find(query, in: Self.state) { return workspace.id }
        return nil
    }

    func testFindsAWorkspaceByAnyPartOfItsName() {
        XCTAssertEqual(find("home"), "home")
        XCTAssertEqual(find("myapp/main"), "worktree:1")
        XCTAssertEqual(find("feature/auth"), "worktree:2")
        XCTAssertEqual(find("auth"), "worktree:2")
        XCTAssertEqual(find("feature-auth"), "worktree:2")
        XCTAssertEqual(find("SITE"), "worktree:3")

        XCTAssertEqual(Catalog.find("main", in: Self.state), .several(["myapp/main", "site/main"]))
        XCTAssertEqual(Catalog.find("nope", in: Self.state), .none)
    }

    func testFindsARepositoryForANewWorktree() {
        XCTAssertEqual(Catalog.findRepository("site", in: Self.state), .one(name: "site", workspace: "worktree:3"))
        XCTAssertEqual(Catalog.findRepository("my", in: Self.state), .one(name: "myapp", workspace: "worktree:1"))
        // A worktree stands for the repository it is in.
        XCTAssertEqual(Catalog.findRepository("auth", in: Self.state), .one(name: "myapp", workspace: "worktree:2"))
        XCTAssertEqual(Catalog.findRepository("nope", in: Self.state), .none)

        // Unnamed, it has to be the only one.
        XCTAssertEqual(Catalog.findRepository(nil, in: Self.state), .several(["myapp", "site"]))
        var one = Self.state
        one.workspaces.removeLast()
        XCTAssertEqual(Catalog.findRepository(nil, in: one), .one(name: "myapp", workspace: "worktree:1"))
        one.workspaces.removeLast(2)
        XCTAssertEqual(Catalog.findRepository(nil, in: one), .none)
    }

    func testPicksTheTerminalTheMacWouldShow() {
        let workspace = Self.state.workspaces[1]
        // The focused pane of the selected tab.
        XCTAssertEqual(Catalog.terminal(in: workspace), Self.split)
        XCTAssertEqual(Catalog.terminal(in: workspace, tab: 1), Self.claude)
        XCTAssertEqual(Catalog.terminal(in: workspace, tab: 2, pane: 1), Self.shell)
        XCTAssertNil(Catalog.terminal(in: workspace, tab: 3))
        XCTAssertNil(Catalog.terminal(in: workspace, tab: 2, pane: 3))
        XCTAssertNil(Catalog.terminal(in: Self.state.workspaces[0]))
    }

    func testListing() {
        XCTAssertEqual(Catalog.listing(Self.state, color: false), """
            Home  no terminals
            myapp/main  ~/code/myapp
               1   ✳ Fix the tests  ~/code/myapp  ● needs you
               2.1 ~/code/myapp
             * 2.2 npm run dev  ~/code/myapp/web  ● working
            myapp/feature/auth  not open
            site/main  not open
            """)
    }
}

final class MenuTests: XCTestCase {
    private func menu() -> Menu {
        var menu = Menu(hostName: "Studio", keyName: "ctrl-\\")
        menu.update(CatalogTests.state)
        return menu
    }

    func testOnlyRowsThatDoSomethingCanBeChosen() {
        var menu = menu()
        // Home has no terminals; the row under it opens one.
        XCTAssertEqual(menu.selected?.target, .empty)
        menu.move(1)
        XCTAssertEqual(menu.selected?.target, .terminal(CatalogTests.claude))
        menu.move(-5)
        XCTAssertEqual(menu.selected?.target, .empty)
        menu.move(50)
        XCTAssertEqual(menu.selected?.workspace, "worktree:3")
        XCTAssertEqual(menu.selected?.target, .unopened)

        XCTAssertEqual(menu.row(numbered: 2)?.target, .terminal(CatalogTests.claude))
        XCTAssertEqual(menu.row(numbered: 5)?.workspace, "worktree:2")
        XCTAssertNil(menu.row(numbered: 7))
    }

    func testSelectionStaysOnItsTerminalWhenTheSidebarChanges() {
        var menu = menu()
        menu.select(CatalogTests.split)

        var changed = CatalogTests.state
        changed.workspaces.remove(at: 0)
        changed.workspaces[0].tabs.remove(at: 0)
        menu.update(changed)
        XCTAssertEqual(menu.selected?.target, .terminal(CatalogTests.split))
    }

    func testDrawsOneScreenAndNoMore() {
        var menu = menu()
        menu.select(CatalogTests.split)
        menu.notice = "Reconnecting…"
        for rows in [5, 8, 24] {
            let screen = menu.render(size: TerminalSize(cols: 60, rows: rows))
            XCTAssertEqual(screen.components(separatedBy: "\r\n").count, rows)
            XCTAssertTrue(screen.contains("npm run dev"), "the selection is always in view (\(rows) rows)")
        }
        let screen = menu.render(size: TerminalSize(cols: 60, rows: 24))
        XCTAssertTrue(screen.contains("Workbench on Studio"))
        XCTAssertTrue(screen.contains("Reconnecting…"))
        XCTAssertTrue(screen.contains("● needs you"))
    }
}

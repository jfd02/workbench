#if DEBUG
import Foundation
import TabTermKit

/// A made-up Mac for exercising the UI without one: launch with `-demo`.
///
/// `-demoTerminal` opens straight into the Claude pane, `-demoUnpaired` shows
/// the pairing screen.
enum DemoData {
    static let claudeSession = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let shellSession = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let buildSession = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let reviewSession = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    static let mac = PairedHost(
        name: "demo-mac-studio",
        hosts: ["100.64.0.1"],
        port: TabTermProtocol.defaultPort,
        deviceID: "demo",
        deviceToken: "demo"
    )

    static let state = HostState(
        hostName: "demo-mac-studio",
        workspaces: [
            WorkspaceInfo(
                id: "home", name: "Home", repository: nil, branch: nil, directory: "~",
                isOpen: true, status: .idle,
                tabs: [
                    TabInfo(id: UUID(), title: "~", isSelected: true, panes: [
                        PaneInfo(session: shellSession, title: "~", directory: "~", isClaude: false, status: .idle, isFocused: true),
                    ]),
                ]
            ),
            WorkspaceInfo(
                id: "worktree:1", name: "main", repository: "myapp", branch: "main",
                directory: "~/code/myapp", isOpen: true, status: .blocked,
                tabs: [
                    TabInfo(id: UUID(), title: "claude", isSelected: true, panes: [
                        PaneInfo(session: claudeSession, title: "✳ Fix flaky sync test", directory: "~/code/myapp", isClaude: true, status: .blocked, isFocused: true),
                        PaneInfo(session: buildSession, title: "npm run dev", directory: "~/code/myapp", isClaude: false, status: .idle, isFocused: false),
                    ]),
                ]
            ),
            WorkspaceInfo(
                id: "worktree:2", name: "feature-auth", repository: "myapp", branch: "feature/auth",
                directory: "~/code/myapp-worktrees/feature-auth", isOpen: true, status: .working,
                tabs: [
                    TabInfo(id: UUID(), title: "claude", isSelected: true, panes: [
                        PaneInfo(session: reviewSession, title: "✳ Add passkey sign-in", directory: "~/code/myapp-worktrees/feature-auth", isClaude: true, status: .working, isFocused: true),
                    ]),
                ]
            ),
            WorkspaceInfo(
                id: "worktree:3", name: "bugfix-123", repository: "myapp", branch: "bugfix/123",
                directory: "~/code/myapp-worktrees/bugfix-123", isOpen: false, status: .idle, tabs: []
            ),
            WorkspaceInfo(
                id: "worktree:4", name: "main", repository: "workbench", branch: "master",
                directory: "~/code/workbench", isOpen: true, status: .finished,
                tabs: [
                    TabInfo(id: UUID(), title: "zsh", isSelected: true, panes: [
                        PaneInfo(session: UUID(), title: "zsh", directory: "~/code/workbench", isClaude: false, status: .finished, isFocused: true),
                    ]),
                ]
            ),
        ],
        focus: HostState.Focus(workspace: "worktree:1", session: claudeSession)
    )

    static func output(for session: UUID) -> String {
        let esc = "\u{1b}"
        guard session == claudeSession || session == reviewSession else {
            return "\(esc)[32m➜\(esc)[0m  \(esc)[36mmyapp\(esc)[0m \(esc)[34mgit:(\(esc)[31mmain\(esc)[34m)\(esc)[0m ls\r\n"
                + "README.md  package.json  src  test\r\n"
                + "\(esc)[32m➜\(esc)[0m  \(esc)[36mmyapp\(esc)[0m \(esc)[34mgit:(\(esc)[31mmain\(esc)[34m)\(esc)[0m "
        }
        let orange = "\(esc)[38;2;217;119;87m"
        let dim = "\(esc)[2m"
        let reset = "\(esc)[0m"
        let bold = "\(esc)[1m"
        let cyan = "\(esc)[36m"

        /// A rounded box like Claude Code draws, padded by visible width.
        func box(_ lines: [(styled: String, plain: String)], width: Int = 44) -> [String] {
            let inner = width - 4
            let rule = String(repeating: "─", count: width - 2)
            var out = ["\(orange)╭\(rule)╮\(reset)"]
            for line in lines {
                let pad = String(repeating: " ", count: max(inner - line.plain.count, 0))
                out.append("\(orange)│\(reset) \(line.styled)\(pad) \(orange)│\(reset)")
            }
            out.append("\(orange)╰\(rule)╯\(reset)")
            return out
        }

        var lines: [String] = []
        lines += box([
            ("\(orange)✻\(reset) Welcome to \(bold)Claude Code\(reset)!", "✻ Welcome to Claude Code!"),
            ("", ""),
            ("\(dim)cwd: ~/code/myapp\(reset)", "cwd: ~/code/myapp"),
        ])
        lines += [
            "",
            "\(dim)>\(reset) The sync test fails about one run in ten.",
            "  Find out why.",
            "",
            "\(orange)⏺\(reset) I'll look at the test and the sync code it",
            "  exercises.",
            "",
            "\(orange)⏺\(reset) \(bold)Read\(reset)(test/sync.test.ts)",
            "  ⎿  Read 142 lines",
            "",
            "\(orange)⏺\(reset) The test awaits \(cyan)sync()\(reset) but not the retry",
            "  timer it schedules, so the assertion races",
            "  the second attempt.",
            "",
            "\(orange)⏺\(reset) \(bold)Update\(reset)(test/sync.test.ts)",
            "",
        ]
        lines += box([
            ("\(bold)Edit file\(reset)", "Edit file"),
            ("test/sync.test.ts", "test/sync.test.ts"),
            ("\(esc)[31m- await sync()\(reset)", "- await sync()"),
            ("\(esc)[32m+ await sync({ waitForRetries: true })\(reset)", "+ await sync({ waitForRetries: true })"),
            ("", ""),
            ("Do you want to make this edit?", "Do you want to make this edit?"),
            ("\(cyan)❯ 1. Yes\(reset)", "❯ 1. Yes"),
            ("  2. Yes, allow all edits this session", "  2. Yes, allow all edits this session"),
            ("  3. No, and tell Claude what to do", "  3. No, and tell Claude what to do"),
        ])
        return lines.joined(separator: "\r\n")
    }
}
#endif

import Foundation
import TabTermKit

/// Finding the terminal someone meant, and saying what there is to choose from.
enum Catalog {
    /// How a workspace is written, here and on the command line: `Home`, or
    /// `repository/worktree`.
    static func label(_ workspace: WorkspaceInfo) -> String {
        guard let repository = workspace.repository, !repository.isEmpty else { return workspace.name }
        return "\(repository)/\(workspace.name)"
    }

    enum Match: Equatable {
        case one(WorkspaceInfo)
        case none
        /// More than one fits; their labels, to choose between.
        case several([String])
    }

    /// The workspace `query` names. An exact name wins, then the only one it
    /// begins, then the only one it appears in — so `auth` is enough for
    /// `myapp/feature-auth` until a second worktree has it in its name too.
    static func find(_ query: String, in state: HostState) -> Match {
        let wanted = query.lowercased()
        for fits in closeness {
            let found = state.workspaces.filter { names(of: $0).contains { fits($0, wanted) } }
            if found.count == 1 { return .one(found[0]) }
            if found.count > 1 { return .several(found.map(label)) }
        }
        return .none
    }

    /// How a name can fit what was typed, best first.
    private static let closeness: [(String, String) -> Bool] = [
        { $0 == $1 },
        { $0.hasPrefix($1) },
        { $0.contains($1) },
    ]

    enum RepositoryMatch: Equatable {
        /// The repository, and one of its workspaces. The Mac is asked for a
        /// new worktree by naming a workspace it goes beside.
        case one(name: String, workspace: String)
        case none
        case several([String])
    }

    /// The repository `query` names, or with no query the only one there is.
    /// A worktree's name will do as well, standing for the repository it is
    /// in.
    static func findRepository(_ query: String?, in state: HostState) -> RepositoryMatch {
        var repositories: [(name: String, workspace: String)] = []
        for workspace in state.workspaces {
            guard let name = workspace.repository, !repositories.contains(where: { $0.name == name }) else { continue }
            repositories.append((name, workspace.id))
        }

        guard let query else {
            if repositories.count == 1 { return .one(name: repositories[0].name, workspace: repositories[0].workspace) }
            return repositories.isEmpty ? .none : .several(repositories.map(\.name))
        }

        let wanted = query.lowercased()
        for fits in closeness {
            let found = repositories.filter { fits($0.name.lowercased(), wanted) }
            if found.count == 1 { return .one(name: found[0].name, workspace: found[0].workspace) }
            if found.count > 1 { return .several(found.map(\.name)) }
        }
        if case .one(let workspace) = find(query, in: state), let name = workspace.repository {
            return .one(name: name, workspace: workspace.id)
        }
        return .none
    }

    /// Everything a workspace answers to.
    private static func names(of workspace: WorkspaceInfo) -> [String] {
        var names = [workspace.id, workspace.name, label(workspace)]
        if let branch = workspace.branch {
            names.append(branch)
            if let repository = workspace.repository { names.append("\(repository)/\(branch)") }
        }
        if let directory = workspace.directory {
            names.append(URL(fileURLWithPath: directory).lastPathComponent)
        }
        return names.map { $0.lowercased() }
    }

    /// The terminal `attach` means in a workspace: the focused pane of its
    /// selected tab, as the Mac would show it — or of tab `tab`, or pane
    /// `pane` of that, both counted from 1. Nil when there is no such thing.
    static func terminal(in workspace: WorkspaceInfo, tab: Int? = nil, pane: Int? = nil) -> UUID? {
        let tabs = workspace.tabs
        let chosen: TabInfo?
        if let tab {
            chosen = tabs.indices.contains(tab - 1) ? tabs[tab - 1] : nil
        } else {
            chosen = tabs.first(where: \.isSelected) ?? tabs.first
        }
        guard let chosen else { return nil }
        if let pane {
            return chosen.panes.indices.contains(pane - 1) ? chosen.panes[pane - 1].session : nil
        }
        return (chosen.panes.first(where: \.isFocused) ?? chosen.panes.first)?.session
    }

    /// One terminal, and where it sits in its workspace.
    struct Entry: Equatable {
        var pane: PaneInfo
        /// `2`, or `2.1` in a tab that has been split.
        var address: String
    }

    static func entries(in workspace: WorkspaceInfo) -> [Entry] {
        workspace.tabs.enumerated().flatMap { tabIndex, tab in
            tab.panes.enumerated().map { paneIndex, pane in
                Entry(
                    pane: pane,
                    address: tab.panes.count > 1 ? "\(tabIndex + 1).\(paneIndex + 1)" : "\(tabIndex + 1)"
                )
            }
        }
    }

    /// A terminal's title, and its directory when the title doesn't already
    /// say it — a shell's title usually is its directory.
    static func describe(_ pane: PaneInfo) -> (title: String, detail: String) {
        let directory = pane.directory.map(abbreviated) ?? ""
        let title = pane.title.isEmpty ? (directory.isEmpty ? "terminal" : directory) : pane.title
        let said = directory.isEmpty || title.contains(directory) || abbreviated(title).contains(directory)
        return (title, said ? "" : directory)
    }

    /// `/Users/someone/code` as `~/code`. The home directory is the other
    /// Mac's, so it is recognised by shape rather than looked up.
    static func abbreviated(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users", !parts[2].isEmpty else { return path }
        return (["~"] + parts.dropFirst(3)).joined(separator: "/")
    }

    static func word(for status: AgentStatus) -> String? {
        switch status {
        case .idle: return nil
        case .working: return "working"
        case .finished: return "finished"
        case .blocked: return "needs you"
        }
    }

    /// The SGR colour of a status, matching the Mac's dots: amber while an
    /// agent works, red when it is waiting for you.
    static func color(for status: AgentStatus) -> String {
        status.wantsAttention ? "31" : "33"
    }

    // MARK: - ls

    /// The sidebar as text: each workspace, and under it its terminals by the
    /// number `attach` takes. `*` is the terminal the Mac has on screen.
    static func listing(_ state: HostState, color: Bool) -> String {
        func styled(_ text: String, _ code: String) -> String {
            color ? "\u{1b}[\(code)m\(text)\u{1b}[0m" : text
        }

        var lines: [String] = []
        for workspace in state.workspaces {
            var heading = styled(label(workspace), "1")
            if !workspace.isOpen {
                heading += styled("  not open", "2")
            } else if workspace.tabs.isEmpty {
                heading += styled("  no terminals", "2")
            } else if let directory = workspace.directory {
                heading += styled("  \(abbreviated(directory))", "2")
            }
            lines.append(heading)

            for entry in entries(in: workspace) {
                let (title, detail) = describe(entry.pane)
                let marker = entry.pane.session == state.focus?.session ? "*" : " "
                var line = " \(marker) \(entry.address.padding(toLength: 4, withPad: " ", startingAt: 0))\(title)"
                if !detail.isEmpty { line += styled("  \(detail)", "2") }
                if let word = word(for: entry.pane.status) {
                    line += "  " + styled("● \(word)", self.color(for: entry.pane.status))
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

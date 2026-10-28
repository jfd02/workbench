import Foundation

/// Identifies one tab set. Every worktree has its own; `home` is the workspace
/// used before any repository is added.
enum WorkspaceKey: Hashable {
    case home
    case worktree(Int64)

    var worktreeId: Int64? {
        if case .worktree(let id) = self { return id }
        return nil
    }

    /// Stable string form, for remembering the selection in `appState`.
    var stateValue: String {
        switch self {
        case .home: return "home"
        case .worktree(let id): return "worktree:\(id)"
        }
    }

    init?(stateValue: String) {
        if stateValue == "home" {
            self = .home
        } else if stateValue.hasPrefix("worktree:"),
                  let id = Int64(stateValue.dropFirst("worktree:".count)) {
            self = .worktree(id)
        } else {
            return nil
        }
    }
}

/// One workspace's tabs.
///
/// Tabs are materialized lazily: a workspace restored from the database holds
/// its saved rows until the user first visits it, so opening the app doesn't
/// spawn a shell for every worktree at once.
final class Workspace {
    let key: WorkspaceKey

    /// Directory new terminals start in. nil means the shell's default.
    var directory: String?

    /// Display name, used for the window title.
    var name: String

    var tabs: [Tab] = []
    var selectedID: UUID?

    /// Saved rows not yet turned into live tabs. Nil once materialized.
    private var pending: [SavedTab]?

    /// True once this workspace has been visited and its tabs built.
    private(set) var isMaterialized = false

    init(key: WorkspaceKey, name: String, directory: String?) {
        self.key = key
        self.name = name
        self.directory = directory
        self.pending = SavedTabStore.tabs(forWorktree: key.worktreeId)
    }

    var selectedTab: Tab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    /// Build the tabs for this workspace, restoring saved ones if there are any.
    ///
    /// `make` turns a description into a live tab so this type doesn't need to
    /// know how tabs are constructed.
    func materialize(_ make: (SavedLayout) -> Tab) {
        guard !isMaterialized else { return }
        isMaterialized = true

        let saved = pending ?? []
        pending = nil

        guard !saved.isEmpty else {
            // First visit: start with a terminal in the workspace directory.
            let tab = make(.pane(directory: nil, agent: nil, focused: true))
            tabs = [tab]
            selectedID = tab.id
            return
        }

        var restoredSelection: UUID?
        for row in saved {
            let tab = make(row.savedLayout)
            tabs.append(tab)
            if row.isSelected { restoredSelection = tab.id }
        }
        selectedID = restoredSelection ?? tabs.first?.id
    }

    /// Write the current tabs back to the database.
    func persist() {
        // An unvisited workspace still holds its saved rows; don't wipe them.
        guard isMaterialized else { return }

        let rows = tabs.map { tab in
            let layout = Self.layout(of: tab.root, focusedPaneID: tab.focusedPaneID)
            return SavedTab(
                worktreeId: key.worktreeId,
                position: 0,
                isSelected: tab.id == selectedID,
                layout: layout.json
            )
        }
        SavedTabStore.replace(worktreeId: key.worktreeId, with: rows)
    }

    /// Turn a live pane tree into its storable form.
    private static func layout(of node: SplitNode, focusedPaneID: UUID?) -> SavedLayout {
        if let pane = node.pane {
            // Remember where the shell ended up, not just where it started, and
            // which agent session was live in it — if any still is.
            let terminal = pane.content as? TerminalTabContent
            return .pane(
                directory: terminal?.pwd,
                agent: terminal?.agentSession,
                focused: pane.id == focusedPaneID
            )
        }

        guard let first = node.children.first, let second = node.children.last,
              node.children.count == 2
        else {
            return .pane(directory: nil, agent: nil, focused: false)
        }

        return .split(
            stacked: node.orientation == .stacked,
            ratio: Double(node.ratio),
            first: layout(of: first, focusedPaneID: focusedPaneID),
            second: layout(of: second, focusedPaneID: focusedPaneID)
        )
    }
}

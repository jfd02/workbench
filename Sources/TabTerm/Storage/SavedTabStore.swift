import Foundation
import GRDB

/// A tab's pane tree, as stored.
///
/// Mirrors `SplitNode`: a leaf holds one piece of content, a split holds two
/// children and the divider position between them.
indirect enum SavedLayout: Codable, Equatable {
    case pane(directory: String?, agent: AgentSession?, focused: Bool)
    case split(stacked: Bool, ratio: Double, first: SavedLayout, second: SavedLayout)

    /// Leaves left to right, top to bottom — the same order as `SplitNode.panes`.
    var leaves: [SavedLayout] {
        switch self {
        case .pane: return [self]
        case .split(_, _, let first, let second): return first.leaves + second.leaves
        }
    }

    var isFocused: Bool {
        if case .pane(_, _, let focused) = self { return focused }
        return false
    }

    var directory: String? {
        if case .pane(let directory, _, _) = self { return directory }
        return nil
    }

    /// The agent that was running in this pane, if one was.
    var agent: AgentSession? {
        if case .pane(_, let agent, _) = self { return agent }
        return nil
    }

    var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SavedLayout.self, from: data)
        else { return nil }
        self = decoded
    }
}

/// A tab as persisted between launches.
///
/// Terminals come back as fresh shells rooted at the directory they ended up
/// in; scrollback and running processes can't be restored. A coding agent is
/// the exception: it keeps its own transcript, so a pane that was running one
/// records the session and types it back on restore.
struct SavedTab: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "savedTab"

    var id: Int64?
    /// nil is the Home workspace.
    var worktreeId: Int64?
    var position: Int
    var isSelected: Bool
    /// The pane tree as JSON. Rows written before splits existed have none.
    var layout: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The stored tree, falling back to a single pane for pre-split rows.
    ///
    /// Layouts written by builds that still had a browser carry `kind` and
    /// `url` keys; decoding ignores them, so those panes come back as
    /// terminals rather than losing the whole tree. Ones written before agents
    /// were restored carry no `agent` key, which decodes as nil for the same
    /// reason.
    var savedLayout: SavedLayout {
        SavedLayout(json: layout) ?? .pane(directory: nil, agent: nil, focused: true)
    }
}

enum SavedTabStore {
    /// Rows for one workspace: a worktree, or Home when the id is nil.
    ///
    /// Written out rather than folded into one expression — `??` binds tighter
    /// than `==`, so the obvious one-liner compares the whole expression to
    /// nil instead of the column to the id, and quietly matches Home's rows.
    private static func belonging(to worktreeId: Int64?) -> SQLExpression {
        if let worktreeId {
            return Column("worktreeId") == worktreeId
        }
        return Column("worktreeId") == nil
    }

    static func tabs(forWorktree worktreeId: Int64?) -> [SavedTab] {
        (try? AppDatabase.shared.queue.read { db in
            return try SavedTab
                .filter(Self.belonging(to: worktreeId))
                .order(Column("position"), Column("id"))
                .fetchAll(db)
        }) ?? []
    }

    /// Replace the stored tabs for one workspace.
    static func replace(worktreeId: Int64?, with tabs: [SavedTab]) {
        try? AppDatabase.shared.queue.write { db in
            _ = try SavedTab.filter(Self.belonging(to: worktreeId)).deleteAll(db)

            for (index, tab) in tabs.enumerated() {
                var row = SavedTab(
                    worktreeId: worktreeId,
                    position: index,
                    isSelected: tab.isSelected,
                    layout: tab.layout
                )
                try row.insert(db)
            }
        }
    }
}

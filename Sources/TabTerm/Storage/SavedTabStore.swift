import Foundation
import GRDB

/// A tab's pane tree, as stored.
///
/// Mirrors `SplitNode`: a leaf holds one piece of content, a split holds two
/// children and the divider position between them.
indirect enum SavedLayout: Codable, Equatable {
    case pane(kind: String, url: String?, directory: String?, focused: Bool)
    case split(stacked: Bool, ratio: Double, first: SavedLayout, second: SavedLayout)

    /// Leaves left to right, top to bottom — the same order as `SplitNode.panes`.
    var leaves: [SavedLayout] {
        switch self {
        case .pane: return [self]
        case .split(_, _, let first, let second): return first.leaves + second.leaves
        }
    }

    var isFocused: Bool {
        if case .pane(_, _, _, let focused) = self { return focused }
        return false
    }

    var tabKind: TabKind {
        if case .pane(let kind, _, _, _) = self, kind == "browser" { return .browser }
        return .terminal
    }

    var url: URL? {
        if case .pane(_, let url, _, _) = self { return url.flatMap(URL.init(string:)) }
        return nil
    }

    var directory: String? {
        if case .pane(_, _, let directory, _) = self { return directory }
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
/// Terminals come back as fresh shells rooted at the workspace directory —
/// scrollback and running processes can't be restored.
struct SavedTab: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "savedTab"

    var id: Int64?
    /// nil is the Home workspace.
    var worktreeId: Int64?
    var kind: String
    var url: String?
    var position: Int
    var isSelected: Bool
    /// The pane tree as JSON. Rows written before splits existed have none.
    var layout: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var tabKind: TabKind {
        kind == "browser" ? .browser : .terminal
    }

    /// The stored tree, falling back to a single pane for pre-split rows.
    var savedLayout: SavedLayout {
        SavedLayout(json: layout)
            ?? .pane(kind: kind, url: url, directory: nil, focused: true)
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
                    kind: tab.kind,
                    url: tab.url,
                    position: index,
                    isSelected: tab.isSelected,
                    layout: tab.layout
                )
                try row.insert(db)
            }
        }
    }
}

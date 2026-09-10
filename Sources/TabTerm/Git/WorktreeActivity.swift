import Foundation

/// When each worktree was last opened, for the sidebar's "· just now" line.
///
/// Kept in `appState` rather than as a column on `worktree`, so this needs no
/// migration and a missing value simply falls back to the directory's date.
enum WorktreeActivity {
    private static func key(_ worktreeId: Int64) -> String {
        "worktreeLastUsed:\(worktreeId)"
    }

    static func markUsed(_ worktreeId: Int64, at date: Date = Date()) {
        AppState.set("\(date.timeIntervalSince1970)", forKey: key(worktreeId))
    }

    static func lastUsed(_ worktreeId: Int64) -> Date? {
        guard let raw = AppState.string(forKey: key(worktreeId)),
              let seconds = TimeInterval(raw)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func forget(_ worktreeId: Int64) {
        AppState.set(nil, forKey: key(worktreeId))
    }

    /// Last opened, or failing that when the directory appeared on disk.
    static func lastActivity(for worktree: Worktree) -> Date? {
        if let id = worktree.id, let used = lastUsed(id) { return used }
        let attributes = try? FileManager.default.attributesOfItem(atPath: worktree.path)
        return attributes?[.creationDate] as? Date
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// "just now", "5 minutes ago", "yesterday".
    static func relativeDescription(_ date: Date?) -> String? {
        guard let date else { return nil }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

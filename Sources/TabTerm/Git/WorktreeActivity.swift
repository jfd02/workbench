import Foundation

/// When each worktree was last opened, for the sidebar's "· just now" line,
/// and when its code last changed, for the stale badge under its icon.
///
/// Last opened is kept in `appState` rather than as a column on `worktree`, so
/// this needs no migration and a missing value simply falls back to the
/// directory's date. Code changes come from git, and are only cached.
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

    /// Last opened, or failing that when the directory appeared on disk.
    static func lastActivity(for worktree: Worktree) -> Date? {
        if let id = worktree.id, let used = lastUsed(id) { return used }
        let attributes = try? FileManager.default.attributesOfItem(atPath: worktree.path)
        return attributes?[.creationDate] as? Date
    }

    // MARK: - Code changes

    /// How long a worktree's code can sit unchanged before the sidebar greys
    /// it out.
    static let staleAfterDays = 7

    /// When each worktree's code last changed, keyed by path, and when that
    /// was worked out.
    private static var codeChanges: [String: (checked: Date, changed: Date?)] = [:]
    private static var checking: Set<String> = []
    private static let queue = DispatchQueue(label: "com.tabterm.code-changes", qos: .utility)

    /// How long an answer is reused before asking git again.
    static let codeChangeFreshness: TimeInterval = 60

    /// Whole days since a worktree's code last changed, once there have been
    /// enough to call it stale. Nil while it's fresh, or not yet checked.
    ///
    /// The main checkout never goes stale: it's the repository itself, not
    /// something left lying around to clean up.
    static func staleDays(for worktree: Worktree, now: Date = Date()) -> Int? {
        guard !worktree.isMain, let changed = codeChanges[worktree.path]?.changed else { return nil }
        let days = Int(now.timeIntervalSince(changed) / 86_400)
        return days >= staleAfterDays ? days : nil
    }

    /// Ask git about any of these worktrees not checked in the last minute.
    ///
    /// `completion` runs on the main queue, and only when an answer changed,
    /// so callers can redraw unconditionally.
    static func refreshCodeChanges(for worktrees: [Worktree], completion: @escaping () -> Void) {
        let now = Date()
        for worktree in worktrees where !worktree.isMain {
            let path = worktree.path
            if let entry = codeChanges[path], now.timeIntervalSince(entry.checked) < codeChangeFreshness {
                continue
            }
            guard checking.insert(path).inserted else { continue }

            queue.async {
                let changed = lastCodeChange(at: path)
                DispatchQueue.main.async {
                    checking.remove(path)
                    let differs = codeChanges[path]?.changed != changed
                    codeChanges[path] = (Date(), changed)
                    if differs { completion() }
                }
            }
        }
    }

    /// Blocking: the newest of the last commit on HEAD, the newest file with
    /// uncommitted changes, and when the worktree was created — so a fresh
    /// worktree off an old commit doesn't start out stale.
    private static func lastCodeChange(at path: String) -> Date? {
        func modified(_ relative: String) -> Date? {
            let full = (path as NSString).appendingPathComponent(relative)
            let attributes = try? FileManager.default.attributesOfItem(atPath: full)
            return attributes?[.modificationDate] as? Date
        }

        var dates: [Date] = []
        if let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date {
            dates.append(created)
        }
        if let output = try? GitService.run(["log", "-1", "--format=%ct"], in: path),
           let seconds = TimeInterval(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            dates.append(Date(timeIntervalSince1970: seconds))
        }
        if let output = try? GitService.run(["status", "--porcelain", "-z"], in: path) {
            var entries = output.split(separator: "\0")[...]
            while let entry = entries.popFirst() {
                guard entry.count > 3 else { continue }
                let code = entry.prefix(2)
                // A rename or copy is followed by the path it came from.
                if code.contains("R") || code.contains("C") { _ = entries.popFirst() }
                let relative = String(entry.dropFirst(3))
                // A deleted file can't be dated, but its folder changed with it.
                if let date = modified(relative)
                    ?? modified((relative as NSString).deletingLastPathComponent) {
                    dates.append(date)
                }
            }
        }
        return dates.max()
    }

    /// Forget every answer, so the self-test starts from what's on disk.
    static func resetForTesting() {
        codeChanges.removeAll()
    }

    /// Whether git is still being asked about any worktree.
    static var isCheckingForTesting: Bool { !checking.isEmpty }

    // MARK: - Formatting

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

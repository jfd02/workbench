import Foundation
import GRDB

/// A git repository the user added to the sidebar.
struct Repository: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "repository"

    var id: Int64?
    /// Absolute path to the main working tree.
    var path: String
    var name: String
    var position: Int

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A worktree belonging to a repository. The main checkout is one of these.
struct Worktree: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "worktree"

    var id: Int64?
    var repositoryId: Int64
    var path: String
    var branch: String?
    var isMain: Bool
    var position: Int

    var displayName: String {
        branch ?? URL(fileURLWithPath: path).lastPathComponent
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum RepositoryStore {
    static var all: [Repository] {
        (try? AppDatabase.shared.queue.read { db in
            try Repository.order(Column("position"), Column("id")).fetchAll(db)
        }) ?? []
    }

    static func worktrees(ofRepository repositoryId: Int64) -> [Worktree] {
        (try? AppDatabase.shared.queue.read { db in
            try Worktree
                .filter(Column("repositoryId") == repositoryId)
                .order(Column("position"), Column("id"))
                .fetchAll(db)
        }) ?? []
    }

    static func worktree(id: Int64) -> Worktree? {
        try? AppDatabase.shared.queue.read { db in
            try Worktree.fetchOne(db, key: id)
        }
    }

    static func repository(id: Int64) -> Repository? {
        try? AppDatabase.shared.queue.read { db in
            try Repository.fetchOne(db, key: id)
        }
    }

    /// Add a repository and record the worktrees git reports for it.
    ///
    /// Returns the stored repository, or the existing one if the path was
    /// already added.
    @discardableResult
    static func add(path: String) throws -> Repository {
        guard let root = GitService.repositoryRoot(at: path) else {
            throw GitError.notARepository(path)
        }

        let discovered = try GitService.worktrees(for: root)

        let result = try AppDatabase.shared.queue.write { db -> (Repository, WorktreeChanges?) in
            if let existing = try Repository.filter(Column("path") == root).fetchOne(db) {
                let changes = try syncWorktrees(discovered, repositoryId: existing.id!, in: db)
                return (existing, changes)
            }

            let nextPosition = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM repository"
            ) ?? 0

            var repository = Repository(
                path: root,
                name: URL(fileURLWithPath: root).lastPathComponent,
                position: nextPosition
            )
            try repository.insert(db)
            _ = try syncWorktrees(discovered, repositoryId: repository.id!, in: db)
            // Registering a repository is a baseline, not worktree creation.
            return (repository, nil)
        }
        result.1?.deliver(repositoryPath: result.0.path)
        return result.0
    }

    /// Re-read worktrees from git and reconcile the stored rows.
    ///
    /// Rows are matched by path so a worktree keeps its id — and therefore its
    /// saved tabs — across refreshes.
    static func refreshWorktrees(of repository: Repository) throws {
        guard let repositoryId = repository.id else { return }
        let discovered = try GitService.worktrees(for: repository.path)
        let changes = try AppDatabase.shared.queue.write { db in
            try syncWorktrees(discovered, repositoryId: repositoryId, in: db)
        }
        changes.deliver(repositoryPath: repository.path)
    }

    /// Deliver only after the database commits. Repeated refreshes then have
    /// no changes to deliver, and a rolled-back write cannot run a user script.
    private struct WorktreeChanges {
        var added: [Worktree] = []
        var removed: [Worktree] = []

        func deliver(repositoryPath: String) {
            let gone = removed.filter { !FileManager.default.fileExists(atPath: $0.path) }
            XcodeBuildFolders.removeFolders(ofRemovedWorktrees: gone.map(\.path), checkoutPath: repositoryPath)
            RemovedWorktreeCommand.run(forRemovedWorktrees: gone.map(\.path), checkoutPath: repositoryPath)
            for (name, worktrees) in [("worktree.created", added), ("worktree.removed", gone)] {
                for worktree in worktrees where !worktree.isMain {
                    WorkbenchHooks.runner.emit(HookEvent(
                        event: name, repositoryPath: repositoryPath,
                        worktreePath: worktree.path, branch: worktree.branch,
                        workspaceID: worktree.id.map { WorkspaceKey.worktree($0).stateValue }
                    ))
                }
            }
        }
    }

    private static func syncWorktrees(
        _ discovered: [GitWorktree],
        repositoryId: Int64,
        in db: Database
    ) throws -> WorktreeChanges {
        let existing = try Worktree
            .filter(Column("repositoryId") == repositoryId)
            .fetchAll(db)
        var byPath = Dictionary(uniqueKeysWithValues: existing.compactMap { worktree in
            worktree.id.map { _ in (worktree.path, worktree) }
        })
        var changes = WorktreeChanges()

        for (index, found) in discovered.enumerated() {
            if var row = byPath.removeValue(forKey: found.path) {
                row.branch = found.branch
                row.isMain = found.isMain
                row.position = index
                try row.update(db)
            } else {
                var row = Worktree(
                    repositoryId: repositoryId,
                    path: found.path,
                    branch: found.branch,
                    isMain: found.isMain,
                    position: index
                )
                try row.insert(db)
                changes.added.append(row)
            }
        }

        // Anything git no longer reports has been removed on disk, and so can
        // the build output Xcode tools kept for it elsewhere, and whatever else
        // the repository asks to have cleared away.
        for (_, stale) in byPath {
            try stale.delete(db)
            changes.removed.append(stale)
        }
        return changes
    }

    /// Forget a repository. Does not touch anything on disk.
    static func remove(_ repository: Repository) {
        guard let id = repository.id else { return }
        try? AppDatabase.shared.queue.write { db in
            _ = try Repository.deleteOne(db, key: id)
        }
    }
}

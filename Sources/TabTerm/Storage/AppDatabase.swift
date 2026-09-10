import Foundation
import GRDB

/// `~/Library/Application Support/TabTerm`: the database, and the two things
/// that can't live in it because a shell script has to write them — the agent
/// status hook and the state files it leaves.
enum AppSupport {
    static let directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return base.appendingPathComponent("TabTerm", isDirectory: true)
    }()
}

/// The app's SQLite store. Everything TabTerm persists lives here.
///
/// If the database file can't be opened we fall back to an in-memory one so the
/// app still runs — it just won't remember anything between launches.
final class AppDatabase {
    let queue: DatabaseQueue

    /// Set when we fell back to memory, so the UI can explain itself.
    private(set) var openError: String?

    /// `~/Library/Application Support/TabTerm/tabterm.sqlite`
    static let defaultURL: URL = AppSupport.directory
        .appendingPathComponent("tabterm.sqlite")

    private static var instance: AppDatabase?

    static var shared: AppDatabase {
        if let instance { return instance }
        let database = AppDatabase(url: defaultURL)
        instance = database
        return database
    }

    /// Point the app at a throwaway database. Must run before `shared` is first
    /// touched; the self-test calls this so it never writes real data.
    @discardableResult
    static func useTemporaryDatabase() -> AppDatabase {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "tabterm-selftest-\(ProcessInfo.processInfo.processIdentifier).sqlite"
            )
        try? FileManager.default.removeItem(at: url)
        let database = AppDatabase(url: url)
        instance = database
        return database
    }

    init(url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            queue = try DatabaseQueue(path: url.path)
        } catch {
            openError = "Could not open \(url.path): \(error.localizedDescription)"
            // An in-memory queue has no file to fail on.
            queue = try! DatabaseQueue()
        }

        do {
            try Self.migrator.migrate(queue)
        } catch {
            openError = "Database migration failed: \(error.localizedDescription)"
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-pinnedSite") { db in
            try db.create(table: "pinnedSite") { t in
                t.autoIncrementedPrimaryKey("id")
                // Scheme+host+path, so query strings don't create duplicates.
                t.column("normalizedURL", .text).notNull().unique()
                t.column("url", .text).notNull()
                t.column("title", .text).notNull()
                t.column("position", .integer).notNull()
            }
        }

        migrator.registerMigration("v2-appState") { db in
            try db.create(table: "appState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v3-repositories") { db in
            try db.create(table: "repository") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("position", .integer).notNull()
            }

            try db.create(table: "worktree") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("repository", onDelete: .cascade).notNull()
                t.column("path", .text).notNull().unique()
                t.column("branch", .text)
                t.column("isMain", .boolean).notNull().defaults(to: false)
                t.column("position", .integer).notNull()
            }

            // A null worktreeId is the Home workspace, which belongs to no repo.
            try db.create(table: "savedTab") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("worktree", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("url", .text)
                t.column("position", .integer).notNull()
                t.column("isSelected", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v4-savedTabLayout") { db in
            // The pane tree as JSON. Nested, always read and written whole, so
            // a column beats a second table with parent pointers.
            try db.alter(table: "savedTab") { t in
                t.add(column: "layout", .text)
            }
        }

        migrator.registerMigration("v5-favicon") { db in
            // One icon per host, so a pinned site can be drawn with its icon
            // before anything has been loaded. Only successful fetches land
            // here; a host we couldn't find an icon for is simply absent.
            try db.create(table: "favicon") { t in
                t.primaryKey("host", .text)
                // A 32×32 PNG, whatever the site actually served.
                t.column("data", .blob).notNull()
                t.column("fetchedAt", .double).notNull()
            }
        }

        return migrator
    }
}

/// Small key/value table for odds and ends like the window frame.
enum AppState {
    private struct Row: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "appState"
        var key: String
        var value: String
    }

    static func string(forKey key: String) -> String? {
        try? AppDatabase.shared.queue.read { db in
            try Row.filter(Column("key") == key).fetchOne(db)?.value
        }
    }

    static func set(_ value: String?, forKey key: String) {
        try? AppDatabase.shared.queue.write { db in
            guard let value else {
                _ = try Row.deleteOne(db, key: key)
                return
            }
            try Row(key: key, value: value).upsert(db)
        }
    }
}

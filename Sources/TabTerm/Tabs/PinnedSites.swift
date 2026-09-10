import Foundation
import GRDB

/// A site the user pinned for quick access from the new-tab dialog.
struct PinnedSite: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "pinnedSite"

    var id: Int64?
    /// Scheme+host+path, used as the uniqueness key.
    var normalizedURL: String
    var url: URL
    var title: String
    var position: Int

    /// Short label under the title, e.g. "news.ycombinator.com".
    var host: String {
        url.host ?? url.absoluteString
    }

    /// A name for a site the user hasn't named: "figma.com" → "Figma".
    static func suggestedTitle(for url: URL) -> String {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }

        let name = host.split(separator: ".").first.map(String.init) ?? host
        guard !name.isEmpty else { return host }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    init(id: Int64? = nil, url: URL, title: String, position: Int = 0) {
        self.id = id
        self.url = url
        self.normalizedURL = url.normalizedForPinning
        self.title = title
        self.position = position
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Persistent store for pinned sites, backed by SQLite.
enum PinnedSites {
    /// All pins in display order.
    static var all: [PinnedSite] {
        (try? AppDatabase.shared.queue.read { db in
            try PinnedSite
                .order(Column("position"), Column("id"))
                .fetchAll(db)
        }) ?? []
    }

    static func isPinned(_ url: URL) -> Bool {
        let key = url.normalizedForPinning
        return (try? AppDatabase.shared.queue.read { db in
            try PinnedSite
                .filter(Column("normalizedURL") == key)
                .fetchCount(db) > 0
        }) ?? false
    }

    /// Add a site, or update the title if it's already pinned.
    static func add(title: String, url: URL) {
        let key = url.normalizedForPinning
        try? AppDatabase.shared.queue.write { db in
            if var existing = try PinnedSite
                .filter(Column("normalizedURL") == key)
                .fetchOne(db)
            {
                existing.title = title
                try existing.update(db)
                return
            }

            let nextPosition = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM pinnedSite"
            ) ?? 0
            var site = PinnedSite(url: url, title: title, position: nextPosition)
            try site.insert(db)
        }
    }

    static func remove(_ url: URL) {
        let key = url.normalizedForPinning
        try? AppDatabase.shared.queue.write { db in
            _ = try PinnedSite
                .filter(Column("normalizedURL") == key)
                .deleteAll(db)
        }
    }

    /// Replace the whole list, keeping the given order.
    static func replaceAll(with sites: [PinnedSite]) {
        try? AppDatabase.shared.queue.write { db in
            _ = try PinnedSite.deleteAll(db)
            for (index, site) in sites.enumerated() {
                var copy = PinnedSite(url: site.url, title: site.title, position: index)
                try copy.insert(db)
            }
        }
    }

    /// One-time move of pins written by the old UserDefaults build.
    static func migrateFromUserDefaultsIfNeeded() {
        let key = "pinnedSites"
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key) else { return }

        struct LegacyPin: Decodable {
            var title: String
            var url: URL
        }

        if let legacy = try? JSONDecoder().decode([LegacyPin].self, from: data) {
            for pin in legacy {
                add(title: pin.title, url: pin.url)
            }
        }

        // Drop it either way, so a corrupt blob doesn't get retried forever.
        defaults.removeObject(forKey: key)
    }
}

extension URL {
    /// Compare pins by scheme+host+path, so "?utm_source=..." doesn't create
    /// a second pin for a page the user already pinned.
    var normalizedForPinning: String {
        var path = self.path
        if path.hasSuffix("/") { path.removeLast() }
        return "\(scheme ?? "https")://\(host ?? "")\(path)".lowercased()
    }
}

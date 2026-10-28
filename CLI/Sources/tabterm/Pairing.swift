import Foundation

import TabTermKit

/// Where the pairing is kept: `~/.config/tabterm/pairing.json`, readable only
/// by its owner, as an ssh key is. The token in it is all the Mac asks for.
enum PairingFile {
    /// `TABTERM_CONFIG_DIR` moves it — for the tests, or for pairing with a
    /// second copy of Workbench without losing the first.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["TABTERM_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tabterm", isDirectory: true)
    }

    static var url: URL { directory.appendingPathComponent("pairing.json") }

    static func load() -> PairedHost? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PairedHost.self, from: data)
    }

    static func save(_ host: PairedHost) throws {
        let files = FileManager.default
        try files.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(host)

        // Created private rather than written and then locked down, so the
        // token is never on disk for anyone else to read.
        guard files.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // An older file keeps the permissions it had; make sure of them.
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// True if there was a pairing to remove.
    @discardableResult
    static func remove() -> Bool {
        (try? FileManager.default.removeItem(at: url)) != nil
    }
}

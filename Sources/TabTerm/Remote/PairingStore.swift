import CryptoKit
import Foundation
import GRDB
import TabTermKit

/// A phone allowed to connect.
struct PairedDevice: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pairedDevice"

    var id: String
    var name: String
    var tokenHash: String
    var createdAt: Double
    var lastSeenAt: Double?
    var pushToken: String?
    var pushEnvironment: String?
    var pushTopic: String?
}

/// Which phones may connect, and the one-time codes that let a new one in.
///
/// Pairing is two steps. The Mac shows a QR code holding a random code that
/// is good for one use and ten minutes; that proves the phone was in front of
/// the screen. The phone trades it for a long-lived token of its own, which it
/// keeps in its keychain and presents from then on. Only a hash of that token
/// is stored here.
///
/// Thread-safe: the database queue serializes access, and the codes are
/// behind a lock, because connections are handled off the main thread.
enum PairingStore {
    static let codeLifetime: TimeInterval = 10 * 60

    private static let lock = NSLock()
    private static var activeCode: (code: String, expires: Date)?

    /// Posted on the main queue when the list of devices changes.
    static let didChange = Notification.Name("PairingStoreDidChange")

    // MARK: - Codes

    /// A fresh code, replacing any earlier one.
    static func makeCode() -> String {
        let code = SecureToken.make(bytes: 16)
        lock.withLock { activeCode = (code, Date().addingTimeInterval(codeLifetime)) }
        return code
    }

    static func cancelCode() {
        lock.withLock { activeCode = nil }
    }

    /// Use up a code. True only once, and only before it expires.
    private static func redeem(_ code: String) -> Bool {
        lock.withLock {
            guard let active = activeCode, active.expires > Date(),
                  constantTimeEqual(active.code, code)
            else { return false }
            activeCode = nil
            return true
        }
    }

    // MARK: - Devices

    /// Admit a phone presenting a pairing code, returning its new record and
    /// the token it must keep. Nil when the code is wrong or spent.
    static func pair(code: String, name: String) -> (PairedDevice, token: String)? {
        guard redeem(code) else { return nil }
        let token = SecureToken.make(bytes: 32)
        let device = PairedDevice(
            id: UUID().uuidString,
            name: name.isEmpty ? "iPhone" : String(name.prefix(80)),
            tokenHash: hash(token),
            createdAt: Date().timeIntervalSince1970,
            lastSeenAt: Date().timeIntervalSince1970
        )
        do {
            try AppDatabase.shared.queue.write { db in try device.insert(db) }
        } catch {
            return nil
        }
        notify()
        return (device, token)
    }

    /// The device a token belongs to, noting that it was seen.
    static func authenticate(token: String) -> PairedDevice? {
        let tokenHash = hash(token)
        return try? AppDatabase.shared.queue.write { db -> PairedDevice? in
            guard var device = try PairedDevice
                .filter(Column("tokenHash") == tokenHash)
                .fetchOne(db)
            else { return nil }
            device.lastSeenAt = Date().timeIntervalSince1970
            try device.update(db)
            return device
        }
    }

    static var devices: [PairedDevice] {
        (try? AppDatabase.shared.queue.read { db in
            try PairedDevice.order(Column("createdAt")).fetchAll(db)
        }) ?? []
    }

    static func forget(_ id: String) {
        _ = try? AppDatabase.shared.queue.write { db in
            try PairedDevice.deleteOne(db, key: id)
        }
        notify()
    }

    static func setPush(deviceID: String, token: String, environment: String, topic: String) {
        _ = try? AppDatabase.shared.queue.write { db in
            guard var device = try PairedDevice.fetchOne(db, key: deviceID) else { return }
            device.pushToken = token
            device.pushEnvironment = environment
            device.pushTopic = topic
            try device.update(db)
        }
    }

    // MARK: - Helpers

    private static func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<x.count { difference |= x[i] ^ y[i] }
        return difference == 0
    }
}

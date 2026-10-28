import Foundation

/// The Mac a remote client is paired with, and the credential it issued.
/// Clients choose their own storage: the iPhone Keychain or a private CLI file.
public struct PairedHost: Codable, Equatable, Sendable {
    public var name: String
    /// Addresses to try in order: the Tailscale IP, then its MagicDNS name.
    public var hosts: [String]
    public var port: UInt16
    public var deviceID: String
    public var deviceToken: String

    public init(name: String, hosts: [String], port: UInt16, deviceID: String, deviceToken: String) {
        self.name = name
        self.hosts = hosts
        self.port = port
        self.deviceID = deviceID
        self.deviceToken = deviceToken
    }
}

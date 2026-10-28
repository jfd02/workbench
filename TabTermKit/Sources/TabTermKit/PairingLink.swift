import Foundation
import Security

/// What the Mac's pairing QR code holds: where to find it, and a one-time code
/// that proves the phone was in front of the Mac when it asked.
///
/// `tabterm://pair?v=1&n=<name>&h=<host>,<host>&p=<port>&c=<code>`
///
/// A link rather than a bare payload so the phone's own Camera app can open it
/// — scanning the code there launches Workbench with the link.
public struct PairingLink: Equatable, Sendable {
    /// The Mac's name, for the phone to show.
    public var name: String
    /// Addresses to try in order: its Tailscale IP first, then its MagicDNS name.
    public var hosts: [String]
    public var port: UInt16
    public var code: String

    public init(name: String, hosts: [String], port: UInt16, code: String) {
        self.name = name
        self.hosts = hosts
        self.port = port
        self.code = code
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = TabTermProtocol.urlScheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(TabTermProtocol.version)),
            URLQueryItem(name: "n", value: name),
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "c", value: code),
        ]
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == TabTermProtocol.urlScheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        guard let code = value("c"),
              let hosts = value("h")?.split(separator: ",").map(String.init), !hosts.isEmpty
        else { return nil }

        self.name = value("n") ?? "Mac"
        self.hosts = hosts
        self.port = value("p").flatMap(UInt16.init) ?? TabTermProtocol.defaultPort
        self.code = code
    }
}

/// Random tokens for pairing, as URL-safe base64.
public enum SecureToken {
    public static func make(bytes count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes doesn't fail in practice; the system RNG is
            // still a CSPRNG if it ever does.
            var generator = SystemRandomNumberGenerator()
            for i in 0..<count { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import Foundation

/// Where this Mac can be reached over Tailscale.
///
/// The phone server listens on the Tailscale address and nothing else, so it
/// is only reachable from devices on your tailnet — never from the café Wi-Fi
/// the Mac happens to be on. Tailscale also encrypts the traffic, which is why
/// the connection itself doesn't add TLS.
enum Tailscale {
    struct Address: Equatable {
        /// The 100.x.y.z address.
        var ip: String
        /// The MagicDNS name, when the CLI could tell us.
        var dnsName: String?
    }

    /// The first IPv4 address in Tailscale's 100.64.0.0/10 range on a tunnel
    /// interface. Read from the interfaces rather than the CLI: it works
    /// whichever way Tailscale was installed, and costs no process launch.
    static var ipv4: String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }

            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                UInt32(bigEndian: inet.pointee.sin_addr.s_addr)
            }
            // 100.64.0.0/10: the shared address space Tailscale hands out.
            guard ip & 0xFFC0_0000 == 0x6440_0000 else { continue }

            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var raw = in_addr(s_addr: ip.bigEndian)
            inet_ntop(AF_INET, &raw, &text, socklen_t(text.count))
            return String(cString: text)
        }
        return nil
    }

    /// The MagicDNS name, from the Tailscale CLI. Slow (it launches a process),
    /// so call it off the main thread.
    static func dnsName() -> String? {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["status", "--json", "--self=true", "--peers=false"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              var name = me["DNSName"] as? String, !name.isEmpty
        else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }
}

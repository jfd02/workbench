import Foundation

/// Which APNs environment this build's device token belongs to.
///
/// A token is only valid against the gateway matching the provisioning profile
/// the app was signed with — development for a build run from Xcode,
/// production for TestFlight and the App Store — and sending to the wrong one
/// fails with `BadDeviceToken`. The profile embedded in the app says which, so
/// read it rather than guessing from the build configuration.
enum PushEnvironment {
    static let current: String = {
        if let fromProfile = readProfileEnvironment() { return fromProfile }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }()

    private static func readProfileEnvironment() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return nil }

        // The profile is a signed CMS envelope around a plist; the plist is
        // stored in the clear, so find it rather than verifying the signature.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>") else { return nil }
        let plistData = Data(text[start.lowerBound..<end.upperBound].utf8)

        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String
        else { return nil }
        return environment == "production" ? "production" : "sandbox"
    }
}

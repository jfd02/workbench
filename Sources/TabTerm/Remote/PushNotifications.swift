import CryptoKit
import Foundation
import IOKit.pwr_mgt
import TabTermKit

/// The APNs key this Mac signs notifications with.
///
/// Apple only delivers a push to an iPhone app when it is signed with a key
/// from the app's developer team, so the key has to come from you: create one
/// under Certificates, Identifiers & Profiles ▸ Keys with Apple Push
/// Notifications enabled, download the `.p8`, and give it to Workbench in
/// Pair iPhone. The Mac then talks to APNs directly — there is no server in
/// between, and nothing but the notification text leaves the Mac.
struct APNsConfiguration: Equatable {
    var keyID: String
    var teamID: String
    /// PEM text of the `.p8` key.
    var key: String

    private static let keyIDKey = "apnsKeyID"
    private static let teamIDKey = "apnsTeamID"

    /// `…/TabTerm/apns/AuthKey.p8`, readable only by you.
    static var keyURL: URL {
        AppSupport.directory.appendingPathComponent("apns/AuthKey.p8")
    }

    static var current: APNsConfiguration? {
        guard let keyID = AppState.string(forKey: keyIDKey),
              let teamID = AppState.string(forKey: teamIDKey),
              let key = try? String(contentsOf: keyURL, encoding: .utf8)
        else { return nil }
        return APNsConfiguration(keyID: keyID, teamID: teamID, key: key)
    }

    /// Check the key parses, then keep a private copy of it.
    static func save(keyFile: URL?, keyID: String, teamID: String) throws {
        if let keyFile {
            let text = try String(contentsOf: keyFile, encoding: .utf8)
            _ = try P256.Signing.PrivateKey(pemRepresentation: text)
            try FileManager.default.createDirectory(
                at: keyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: keyURL, atomically: true, encoding: .utf8)
            chmod(keyURL.path, 0o600)
        }
        AppState.set(keyID.trimmingCharacters(in: .whitespaces), forKey: keyIDKey)
        AppState.set(teamID.trimmingCharacters(in: .whitespaces), forKey: teamIDKey)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: keyURL)
        AppState.set(nil, forKey: keyIDKey)
        AppState.set(nil, forKey: teamIDKey)
    }
}

/// Sends notifications to paired phones through APNs.
final class PushSender {
    static let shared = PushSender()

    private var cachedToken: (jwt: String, keyID: String, made: Date)?
    private let session = URLSession(configuration: .ephemeral)

    struct Alert {
        var title: String
        var body: String
        var session: UUID
        var workspace: String
    }

    /// Send to every paired phone that has registered for notifications.
    func send(_ alert: Alert) {
        guard let configuration = APNsConfiguration.current else { return }
        for device in PairingStore.devices {
            guard let token = device.pushToken, let topic = device.pushTopic else { continue }
            send(alert, to: token, topic: topic, sandbox: device.pushEnvironment != "production", configuration: configuration)
        }
    }

    private func send(_ alert: Alert, to deviceToken: String, topic: String, sandbox: Bool, configuration: APNsConfiguration) {
        guard let jwt = token(for: configuration) else { return }

        let host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(deviceToken)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        // A newer notice about the same terminal replaces the older one.
        request.setValue(String(alert.session.uuidString.prefix(64)), forHTTPHeaderField: "apns-collapse-id")

        let payload: [String: Any] = [
            "aps": [
                "alert": ["title": alert.title, "body": alert.body],
                "sound": "default",
                "thread-id": alert.workspace,
            ],
            "session": alert.session.uuidString,
            "workspace": alert.workspace,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        session.dataTask(with: request) { data, response, error in
            if let error {
                Ghostty.logger.warning("push failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
            let reason = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Ghostty.logger.warning("push rejected \(http.statusCode): \(reason, privacy: .public)")
        }.resume()
    }

    /// The provider token, an ES256 JWT that APNs accepts for up to an hour
    /// and asks not to be regenerated more than every twenty minutes.
    private func token(for configuration: APNsConfiguration) -> String? {
        if let cachedToken, cachedToken.keyID == configuration.keyID,
           Date().timeIntervalSince(cachedToken.made) < 40 * 60 {
            return cachedToken.jwt
        }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: configuration.key) else {
            return nil
        }

        let header = ["alg": "ES256", "kid": configuration.keyID]
        let claims: [String: Any] = ["iss": configuration.teamID, "iat": Int(Date().timeIntervalSince1970)]
        guard let headerData = try? JSONSerialization.data(withJSONObject: header),
              let claimsData = try? JSONSerialization.data(withJSONObject: claims)
        else { return nil }

        let signingInput = "\(headerData.base64URL).\(claimsData.base64URL)"
        guard let signature = try? key.signature(for: Data(signingInput.utf8)) else { return nil }
        // JWS wants the raw r‖s form, not DER.
        let jwt = "\(signingInput).\(signature.rawRepresentation.base64URL)"
        cachedToken = (jwt, configuration.keyID, Date())
        return jwt
    }
}

/// Decides when an agent's news goes to the phone.
///
/// When an agent stops to ask permission or finishes its turn, and nobody is
/// at this Mac — the screen is locked or it has been untouched for two
/// minutes — the phone gets a notification naming the worktree. Tapping it
/// opens that terminal. A phone already looking at the terminal isn't told
/// what it can see.
final class AgentNotifier {
    static let shared = AgentNotifier()

    private var lastStates: [String: AgentStatus] = [:]

    func start() {
        NotificationCenter.default.addObserver(
            forName: AgentActivityStore.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.agentsChanged()
        }
    }

    private func agentsChanged() {
        let reports = AgentActivityStore.shared.reports
        var alerts: [PushSender.Alert] = []

        for (agentID, report) in reports {
            let previous = lastStates[agentID]
            guard report.state != previous else { continue }
            if report.state.wantsAttention, let alert = alert(for: agentID, report: report) {
                alerts.append(alert)
            }
        }
        lastStates = reports.mapValues(\.state)

        guard !alerts.isEmpty, UserActivity.isAway,
              APNsConfiguration.current != nil,
              PairingStore.devices.contains(where: { $0.pushToken != nil })
        else { return }

        SessionManager.shared.queue.async {
            let unseen = alerts.filter { !RemoteServer.shared.isViewedByPhone($0.session) }
            for alert in unseen { PushSender.shared.send(alert) }
        }
    }

    private func alert(for agentID: String, report: AgentReport) -> PushSender.Alert? {
        guard let session = UUID(uuidString: agentID),
              let place = RemoteHost.shared.snapshot().locate(session)
        else { return nil }

        let agent = report.agent == "codex" ? "Codex" : "Claude"
        let body: String
        switch report.state {
        case .blocked: body = "\(agent) is waiting for your answer."
        case .finished: body = "\(agent) finished its turn."
        default: return nil
        }

        let title: String
        if let repository = place.workspace.repository {
            title = "\(repository) — \(place.workspace.name)"
        } else {
            title = place.workspace.name
        }
        return PushSender.Alert(title: title, body: body, session: session, workspace: place.workspace.id)
    }
}

/// Keeps the Mac from idle-sleeping while a phone may want it.
///
/// A sleeping Mac drops off Tailscale, and the phone has nothing to connect
/// to. This holds the same assertion `caffeinate -i` does: the display still
/// sleeps and the screen still locks, the machine just stays reachable.
enum SleepGuard {
    private static var assertion: IOPMAssertionID = 0
    private static var held = false

    static func update(active: Bool) {
        if active, !held {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Workbench: a paired iPhone may connect" as CFString,
                &assertion
            )
            held = result == kIOReturnSuccess
        } else if !active, held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

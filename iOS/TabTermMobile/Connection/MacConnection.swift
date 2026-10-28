import Foundation
import Network
import TabTermKit

/// The phone's one connection to Workbench on the Mac.
///
/// A plain TCP connection to the Mac's Tailscale address, carrying TabTermKit
/// frames. It owns everything about staying connected — trying each of the
/// Mac's addresses in turn, the hello, noticing a dead link, reconnecting with
/// backoff — so the rest of the app only ever hears "connected", "gone" and the
/// messages in between.
///
/// Everything runs on the main queue. The traffic is one person's terminals,
/// and SwiftTerm wants to be fed on the main thread anyway, so a background
/// queue would only add hops.
@MainActor
final class MacConnection {
    enum Status: Equatable {
        /// Not trying: no pairing, or stopped.
        case idle
        case connecting
        case connected
        /// Lost, and a retry is scheduled.
        case retrying
        /// The Mac said no. Retrying won't change its mind.
        case denied(Denied)
    }

    struct Credentials: Equatable {
        var hosts: [String]
        var port: UInt16
        var deviceName: String
        var deviceToken: String?
        var pairingCode: String?
    }

    var onStatusChange: ((Status) -> Void)?
    var onWelcome: ((Welcome) -> Void)?
    var onMessage: ((ServerMessage) -> Void)?
    /// Output and synthesized frames, for the terminal they belong to.
    var onTerminalFrame: ((Frame) -> Void)?

    private(set) var status: Status = .idle {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    var isConnected: Bool { status == .connected }

    private var credentials: Credentials?
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var hostIndex = 0
    /// Bumped for every new attempt, so a callback from an abandoned
    /// connection can tell it no longer matters.
    private var generation = 0
    private var lastHeard = Date.distantPast
    private var failures = 0
    private var pingTimer: Timer?
    private var attemptTimer: Timer?
    private var retryTimer: Timer?
    private var nextPingID = 1

    /// How long one address gets to answer before the next is tried.
    private static let attemptTimeout: TimeInterval = 6
    /// The Mac pings every 15 s and we ping every 10 s, so this much silence
    /// means the link is gone even if TCP hasn't noticed.
    private static let silenceLimit: TimeInterval = 25
    private static let pingInterval: TimeInterval = 10

    // MARK: - Lifecycle

    func start(_ credentials: Credentials) {
        self.credentials = credentials
        failures = 0
        connectNow()
    }

    func stop() {
        credentials = nil
        tearDown()
        retryTimer?.invalidate()
        retryTimer = nil
        status = .idle
    }

    /// The Mac issued a token on the pairing visit; use it from now on rather
    /// than the one-time code.
    func adoptToken(_ token: String) {
        credentials?.deviceToken = token
        credentials?.pairingCode = nil
    }

    /// Coming back to the foreground. A connection that survived the time in
    /// the background is kept; one that went quiet is replaced straight away
    /// rather than after the usual backoff.
    func appDidBecomeActive() {
        guard credentials != nil else { return }
        if case .denied = status { return }
        if status == .connected, Date().timeIntervalSince(lastHeard) < 12 {
            sendPing()
            return
        }
        failures = 0
        connectNow()
    }

    private func connectNow() {
        tearDown()
        retryTimer?.invalidate()
        retryTimer = nil
        hostIndex = 0
        attempt()
    }

    private func attempt() {
        guard let credentials else { return }
        guard hostIndex < credentials.hosts.count,
              let port = NWEndpoint.Port(rawValue: credentials.port)
        else {
            scheduleRetry()
            return
        }

        generation += 1
        let current = generation
        status = .connecting
        decoder = FrameDecoder()

        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(credentials.hosts[hostIndex]),
            port: port,
            using: parameters
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, current == self.generation else { return }
                self.connectionStateChanged(state)
            }
        }
        connection.start(queue: .main)

        attemptTimer?.invalidate()
        attemptTimer = Timer.scheduledTimer(withTimeInterval: Self.attemptTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, current == self.generation, self.status != .connected else { return }
                self.tryNextHost()
            }
        }
    }

    private func connectionStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendHello()
            receive()
        case .waiting, .failed:
            // Waiting means unreachable for now: Tailscale off, or the Mac
            // asleep. Move on rather than let Network retry the same address.
            if status == .connected {
                connectionLost()
            } else {
                tryNextHost()
            }
        case .cancelled, .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func tryNextHost() {
        tearDown()
        hostIndex += 1
        attempt()
    }

    private func sendHello() {
        guard let credentials else { return }
        send(.hello(Hello(
            deviceName: credentials.deviceName,
            deviceToken: credentials.deviceToken,
            pairingCode: credentials.deviceToken == nil ? credentials.pairingCode : nil
        )), force: true)
    }

    private func receive() {
        guard let connection else { return }
        let current = generation
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, current == self.generation else { return }
                if let data, !data.isEmpty {
                    self.lastHeard = Date()
                    self.consume(data)
                    // Handling a message can end the connection (a denial).
                    guard current == self.generation else { return }
                }
                if isComplete || error != nil {
                    self.connectionLost()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func consume(_ data: Data) {
        let frames: [Frame]
        do {
            frames = try decoder.append(data)
        } catch {
            // Out of step with the stream; nothing after this can be trusted.
            connectionLost()
            return
        }
        let current = generation
        for frame in frames {
            guard current == generation else { return }
            handle(frame)
        }
    }

    private func handle(_ frame: Frame) {
        switch frame.kind {
        case .control:
            guard let message = try? frame.decode(ServerMessage.self) else { return }
            handle(message)
        case .output, .synthesized:
            onTerminalFrame?(frame)
        case .input:
            break
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome(let welcome):
            attemptTimer?.invalidate()
            failures = 0
            if let token = welcome.deviceToken { adoptToken(token) }
            status = .connected
            startPinging()
            onWelcome?(welcome)
        case .denied(let denied):
            tearDown()
            retryTimer?.invalidate()
            status = .denied(denied)
        case .ping(let ping):
            send(.pong(ping))
        case .pong:
            break
        default:
            onMessage?(message)
        }
    }

    // MARK: - Sending

    /// Send a control message. Dropped when not connected: every caller
    /// re-sends what matters after reconnecting (attach, viewing, push token).
    func send(_ message: ClientMessage) {
        send(message, force: false)
    }

    private func send(_ message: ClientMessage, force: Bool) {
        send(frame: .control(message), force: force)
    }

    func send(frame: Frame) {
        send(frame: frame, force: false)
    }

    private func send(frame: Frame, force: Bool) {
        guard let connection, force || status == .connected else { return }
        connection.send(content: frame.encoded(), completion: .contentProcessed { _ in })
    }

    // MARK: - Liveness

    private func startPinging() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLiveness() }
        }
    }

    private func checkLiveness() {
        guard status == .connected else { return }
        if Date().timeIntervalSince(lastHeard) > Self.silenceLimit {
            connectionLost()
        } else {
            sendPing()
        }
    }

    private func sendPing() {
        nextPingID += 1
        send(.ping(Ping(id: nextPingID)))
    }

    private func connectionLost() {
        let wasConnected = status == .connected
        tearDown()
        if wasConnected {
            // A connection that was working is worth an immediate retry: the
            // usual cause is a network change, which the next attempt survives.
            failures = 0
            status = .retrying
            retryTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.connectNow() }
            }
        } else {
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard credentials != nil else { return }
        tearDown()
        failures += 1
        status = .retrying
        let delay = min(pow(2, Double(failures - 1)) * 0.5, 15)
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.connectNow() }
        }
    }

    private func tearDown() {
        generation += 1
        attemptTimer?.invalidate()
        attemptTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }
}

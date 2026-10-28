import Foundation
import TabTermKit

/// Lets phones reach this Mac's terminals, over Tailscale.
///
/// Listens on the Mac's Tailscale address only, so nothing outside your
/// tailnet can even open a connection, and admits only phones that paired by
/// scanning the code on this screen (`PairingStore`). A connected phone can
/// see the sidebar, attach to any terminal as another client of its session,
/// and type into it — see `TabTermKit/PROTOCOL.md` for the conversation.
///
/// Connections live on the session queue, next to the sessions they talk to.
/// Anything that needs the window — the sidebar, opening a tab — hops to the
/// main queue through `RemoteHost`.
final class RemoteServer {
    static let shared = RemoteServer()

    var queue: DispatchQueue { SessionManager.shared.queue }

    enum Status: Equatable {
        case stopped
        /// Tailscale isn't up on this Mac, so there is nowhere safe to listen.
        case waitingForTailscale
        case failed(String)
        case listening(Tailscale.Address, port: UInt16)
    }

    /// Main queue only.
    private(set) var status: Status = .stopped {
        didSet {
            guard status != oldValue else { return }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// Posted on the main queue when `status` or the connected phones change.
    static let didChange = Notification.Name("RemoteServerDidChange")

    private var listener: SocketListener?
    private var retryTimer: Timer?
    private var connections: [ObjectIdentifier: RemoteConnection] = [:]
    /// Device ids of the phones connected right now. Main queue.
    private(set) var connectedDeviceIDs: Set<String> = []

    /// 7766, unless `TABTERM_REMOTE_PORT` says otherwise — for running a
    /// second copy beside the real one.
    var port: UInt16 {
        if let override = ProcessInfo.processInfo.environment["TABTERM_REMOTE_PORT"].flatMap(UInt16.init) {
            return override
        }
        return TabTermProtocol.defaultPort
    }

    // MARK: - Lifecycle

    /// Start listening on the Tailscale address, and keep trying every half
    /// minute while there isn't one — Tailscale often comes up after login.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard listener == nil else { return }
        attemptListen()
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkAddress()
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        closeListener()
        status = .stopped
    }

    /// Listen on an explicit address — the self-test uses the loopback, with
    /// port 0 for any free port. Returns the port.
    @discardableResult
    func startForTesting(host: String = "127.0.0.1", port: UInt16 = 0) throws -> UInt16 {
        closeListener()
        let listener = try SocketListener.tcp(host: host, port: port, queue: queue) { [weak self] fd in
            self?.accept(fd)
        }
        self.listener = listener
        let bound = listener.port
        status = .listening(Tailscale.Address(ip: host, dnsName: nil), port: bound)
        return bound
    }

    private func attemptListen() {
        guard let ip = Tailscale.ipv4 else {
            status = .waitingForTailscale
            return
        }
        do {
            let listener = try SocketListener.tcp(host: ip, port: port, queue: queue) { [weak self] fd in
                self?.accept(fd)
            }
            self.listener = listener
            status = .listening(Tailscale.Address(ip: ip, dnsName: nil), port: port)
            // The MagicDNS name only makes the pairing link sturdier; fetch it
            // without holding anything up.
            DispatchQueue.global().async { [weak self] in
                let name = Tailscale.dnsName()
                DispatchQueue.main.async {
                    guard let self, case .listening(var address, let port) = self.status,
                          address.ip == ip
                    else { return }
                    address.dnsName = name
                    self.status = .listening(address, port: port)
                }
            }
        } catch {
            status = .failed("Couldn't listen on \(ip):\(port) — \(error.localizedDescription)")
        }
    }

    /// Tailscale came up, went down, or moved to another address.
    private func checkAddress() {
        let ip = Tailscale.ipv4
        switch status {
        case .listening(let address, _) where address.ip != "127.0.0.1":
            if ip != address.ip {
                closeListener()
                attemptListen()
            }
        case .waitingForTailscale, .failed:
            if ip != nil { attemptListen() }
        default:
            break
        }
    }

    private func closeListener() {
        listener?.close()
        listener = nil
    }

    // MARK: - Connections

    private func accept(_ fd: Int32) {
        let socket = FramedSocket(fd: fd, queue: queue)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))

        let connection = RemoteConnection(socket: socket, server: self)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        socket.onClose = { [weak self] in
            connection.closed()
            self?.connections.removeValue(forKey: key)
            self?.connectionsChanged()
        }
        socket.start()
        connection.started()
    }

    /// Called on the session queue when a phone authenticates or leaves.
    func connectionsChanged() {
        let ids = Set(connections.values.compactMap(\.device?.id))
        DispatchQueue.main.async {
            guard ids != self.connectedDeviceIDs else { return }
            self.connectedDeviceIDs = ids
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            RemoteHost.shared.clientsChanged(connected: !ids.isEmpty)
        }
    }

    /// Send the sidebar to every connected phone. Call from any queue.
    func broadcast(_ state: HostState) {
        queue.async {
            for connection in self.connections.values where connection.device != nil {
                connection.socket.send(control: .state(state))
            }
        }
    }

    /// Drop a phone that was just forgotten.
    func disconnect(deviceID: String) {
        queue.async {
            for connection in self.connections.values where connection.device?.id == deviceID {
                connection.socket.close()
            }
        }
    }

    /// Whether any phone is looking at `session` right now. Session queue.
    func isViewedByPhone(_ session: UUID) -> Bool {
        connections.values.contains { $0.isShowing(session) }
    }
}

/// One phone's connection.
final class RemoteConnection {
    let socket: FramedSocket
    unowned let server: RemoteServer

    private(set) var device: PairedDevice?
    private var proxies: [UUID: SessionProxy] = [:]
    private var timer: DispatchSourceTimer?
    private var pingID = 0
    private var unansweredPings = 0
    private var hasAnsweredPing = false

    /// How long a connection gets to say who it is.
    static let helloTimeout: TimeInterval = 10
    static let pingInterval: TimeInterval = 15

    init(socket: FramedSocket, server: RemoteServer) {
        self.socket = socket
        self.server = server
        socket.onFrame = { [weak self] frame in self?.received(frame) }
    }

    func started() {
        let timer = DispatchSource.makeTimerSource(queue: socket.queue)
        timer.schedule(deadline: .now() + Self.helloTimeout, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// How long a dropped phone keeps its place in its terminals.
    ///
    /// A phone moving from Wi-Fi to cellular loses its connection and is back
    /// a second later. Released at once, its size would leave the minimum, the
    /// Mac pane would grow back, and that resize would make an exact catch-up
    /// impossible — the phone would come back to a reset and a redraw instead
    /// of simply the bytes it missed. Held for a few seconds, the new
    /// connection finds everything as it was.
    static let reconnectGrace: TimeInterval = 3

    func closed() {
        timer?.cancel()
        timer = nil
        let held = proxies
        proxies.removeAll()
        device = nil
        socket.queue.asyncAfter(deadline: .now() + Self.reconnectGrace) {
            for (id, proxy) in held {
                SessionManager.shared.session(id)?.detach(proxy)
            }
        }
    }

    func isShowing(_ session: UUID) -> Bool {
        guard let proxy = proxies[session] else { return false }
        return SessionManager.shared.session(session)?.isVisible(to: proxy) ?? false
    }

    /// Liveness. A phone that suspends mid-session sends no FIN, and its
    /// socket would otherwise sit here holding its size in the minimum — every
    /// other client pinned at phone width — for as long as TCP takes to give
    /// up, which is hours. So it is pinged, and one that stops answering while
    /// it claims to be on screen is dropped. One that said it went to the
    /// background is expected to be silent, and isn't holding anything.
    private func tick() {
        guard device != nil else {
            // Never said hello.
            socket.close()
            return
        }
        let showingSomething = proxies.keys.contains(where: isShowing)
        if hasAnsweredPing, unansweredPings >= 2, showingSomething {
            socket.close()
            return
        }
        if unansweredPings >= 12 {
            socket.close()
            return
        }
        pingID += 1
        unansweredPings += 1
        socket.send(control: .ping(Ping(id: pingID)))
    }

    // MARK: - Receiving

    private func received(_ frame: Frame) {
        switch frame.kind {
        case .control:
            guard let message = try? frame.decode(ClientMessage.self) else {
                socket.send(control: .error(ErrorMessage(message: "Unrecognized message.")))
                return
            }
            handle(message)

        case .input:
            // Only into a terminal this phone has attached to.
            guard device != nil, let id = frame.session, proxies[id] != nil,
                  let session = SessionManager.shared.session(id)
            else { return }
            session.write(frame.payload)

        case .output, .synthesized:
            break
        }
    }

    private func handle(_ message: ClientMessage) {
        if case .hello(let hello) = message {
            authenticate(hello)
            return
        }
        guard let device else {
            socket.close()
            return
        }

        switch message {
        case .attach(let attach):
            guard let session = SessionManager.shared.session(attach.session) else {
                socket.send(control: .exit(SessionExit(session: attach.session, code: SessionExit.unknownSession)))
                return
            }
            let proxy = proxies[attach.session] ?? SessionProxy(connection: self, sessionID: attach.session)
            proxies[attach.session] = proxy
            session.attach(proxy, anchor: attach.anchor, size: attach.size, visible: attach.visible)

        case .detach(let ref):
            if let proxy = proxies.removeValue(forKey: ref.session) {
                SessionManager.shared.session(ref.session)?.detach(proxy)
            }

        case .resize(let resize):
            if let proxy = proxies[resize.session] {
                SessionManager.shared.session(resize.session)?.resize(proxy, to: resize.size)
            }

        case .visibility(let visibility):
            if let proxy = proxies[visibility.session] {
                SessionManager.shared.session(visibility.session)?.setVisible(proxy, visibility.visible)
            }

        case .submit(let submit):
            SessionManager.shared.session(submit.session)?.submit(submit.text, pressEnter: submit.pressEnter)

        case .openWorkspace(let ref):
            DispatchQueue.main.async { RemoteHost.shared.openWorkspace(ref.workspace) }

        case .newTab(let request):
            DispatchQueue.main.async { [weak self] in
                let session = RemoteHost.shared.newTab(in: request.workspace)
                self?.socket.queue.async {
                    guard let self else { return }
                    if let session {
                        self.socket.send(control: .tabCreated(TabCreated(
                            requestID: request.requestID,
                            workspace: request.workspace,
                            session: session
                        )))
                    } else {
                        self.socket.send(control: .error(ErrorMessage(
                            message: "Couldn't open a terminal there.")))
                    }
                }
            }

        case .newWorktree(let request):
            DispatchQueue.main.async { [weak self] in
                RemoteHost.shared.newWorktree(beside: request.workspace, branch: request.branch) { result in
                    self?.socket.queue.async {
                        guard let self else { return }
                        switch result {
                        case .success(let workspace):
                            self.socket.send(control: .worktreeCreated(WorktreeCreated(
                                requestID: request.requestID,
                                workspace: workspace
                            )))
                        case .failure(let error):
                            self.socket.send(control: .error(ErrorMessage(
                                message: error.localizedDescription)))
                        }
                    }
                }
            }

        case .viewing(let viewing):
            DispatchQueue.main.async { RemoteHost.shared.phoneIsViewing(viewing.session) }

        case .registerPush(let push):
            PairingStore.setPush(
                deviceID: device.id,
                token: push.token,
                environment: push.environment,
                topic: push.bundleID
            )

        case .ping(let ping):
            socket.send(control: .pong(ping))

        case .pong:
            unansweredPings = 0
            hasAnsweredPing = true

        case .hello, .attachHello:
            break
        }
    }

    private func authenticate(_ hello: Hello) {
        guard device == nil else { return }
        guard hello.protocolVersion == TabTermProtocol.version else {
            deny(.versionMismatch, "This Mac speaks Workbench protocol \(TabTermProtocol.version) and the app speaks \(hello.protocolVersion). Update whichever is older.")
            return
        }

        var issuedToken: String?
        if let token = hello.deviceToken, let known = PairingStore.authenticate(token: token) {
            device = known
        } else if let code = hello.pairingCode, let (paired, token) = PairingStore.pair(code: code, name: hello.deviceName) {
            device = paired
            issuedToken = token
        } else {
            deny(.unauthorized, "This iPhone isn't paired with this Mac. On the Mac, choose Workbench ▸ Pair iPhone… and scan the code.")
            return
        }

        guard let device else { return }
        socket.send(control: .welcome(Welcome(
            hostName: Host.current().localizedName ?? "Mac",
            deviceID: device.id,
            deviceToken: issuedToken
        )))
        server.connectionsChanged()

        // The sidebar straight away, so the phone has something to show.
        DispatchQueue.main.async { [weak self] in
            let state = RemoteHost.shared.snapshot()
            self?.socket.queue.async { self?.socket.send(control: .state(state)) }
        }
    }

    private func deny(_ reason: Denied.Reason, _ message: String) {
        socket.send(control: .denied(Denied(reason: reason, message: message)))
        // Let the reply drain before closing.
        socket.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.socket.close() }
    }

    fileprivate func dropped(_ sessionID: UUID) {
        proxies.removeValue(forKey: sessionID)
    }
}

/// A phone's view of one session: forwards what the session says, tagged with
/// its id, down the phone's connection.
private final class SessionProxy: SessionClient {
    weak var connection: RemoteConnection?
    let sessionID: UUID

    init(connection: RemoteConnection, sessionID: UUID) {
        self.connection = connection
        self.sessionID = sessionID
    }

    var bufferedBytes: Int { connection?.socket.bufferedBytes ?? 0 }

    func session(_ session: TerminalSession, didOutput bytes: Data) {
        connection?.socket.send(.output(sessionID, bytes))
    }

    func session(_ session: TerminalSession, didSynthesize bytes: Data) {
        connection?.socket.send(.synthesized(sessionID, bytes))
    }

    func session(_ session: TerminalSession, didSync synced: Synced) {
        connection?.socket.send(control: .synced(synced))
    }

    func session(_ session: TerminalSession, didExit code: Int32) {
        connection?.socket.send(control: .exit(SessionExit(session: sessionID, code: code)))
        connection?.dropped(sessionID)
    }

    func sessionDidDropForBackpressure(_ session: TerminalSession) {
        // Hopelessly behind; the phone reconnects and is caught up or reset.
        connection?.socket.close()
    }
}

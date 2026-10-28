import Foundation
import TabTermKit

/// Every live terminal session, and the Unix socket the panes attach through.
///
/// A pane's Ghostty surface runs `Workbench --attach <socket> <session>` instead
/// of a shell. That process connects here, says which session it is for, and
/// from then on passes bytes both ways. See `AttachClient` for its side.
final class SessionManager {
    static let shared = SessionManager()

    /// All session I/O happens here: pty reads and writes, and every client
    /// socket. One serial queue, as tmux is one thread — a handful of terminals
    /// is nowhere near what it takes to need more.
    let queue = DispatchQueue(label: "com.tabterm.sessions", qos: .userInteractive)

    private var sessions: [UUID: TerminalSession] = [:]
    private var listener: SocketListener?
    private var attachConnections: [ObjectIdentifier: AttachConnection] = [:]

    /// Where panes connect. Per process, so two running copies of Workbench (the
    /// app and its self-test, say) never cross wires.
    let socketPath: String

    private init() {
        socketPath = Self.makeSocketPath()
        do {
            listener = try SocketListener.unix(path: socketPath, queue: queue) { [weak self] fd in
                self?.accept(fd)
            }
        } catch {
            Ghostty.logger.critical("session socket failed at \(self.socketPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `…/TabTerm/run/<pid>.sock`, or a short path under /tmp when that is too
    /// long for a Unix socket address (104 bytes on macOS).
    private static func makeSocketPath() -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let run = AppSupport.directory.appendingPathComponent("run", isDirectory: true)
        try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        Self.removeStaleSockets(in: run.path)

        let preferred = run.appendingPathComponent("\(pid).sock").path
        if preferred.utf8.count < 100 { return preferred }

        let fallback = "/tmp/tabterm-\(getuid())"
        mkdir(fallback, 0o700)
        return "\(fallback)/\(pid).sock"
    }

    /// Sockets left by a copy of Workbench that has since died.
    private static func removeStaleSockets(in directory: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names where name.hasSuffix(".sock") {
            guard let pid = Int32(name.dropLast(5)) else { continue }
            if kill(pid, 0) != 0, errno == ESRCH {
                unlink("\(directory)/\(name)")
            }
        }
    }

    /// Hang up every shell and remove the socket, on the way out.
    func shutdown() {
        LiveSessions.hangUpAll()
        listener?.close()
        listener = nil
        unlink(socketPath)
    }

    // MARK: - Sessions

    /// Register a session for a new pane. The shell starts when the pane
    /// attaches, with the environment Ghostty gave the attach process.
    func create(id: UUID, directory: String?, command: String?, environment: [String: String]) -> TerminalSession {
        let session = TerminalSession(
            id: id,
            directory: directory,
            command: command,
            environment: environment,
            queue: queue
        )
        session.onFinish = { [weak self] finished in
            self?.sessions.removeValue(forKey: finished.id)
        }
        queue.sync { sessions[id] = session }
        return session
    }

    /// Look a session up. Call on `queue`.
    func session(_ id: UUID) -> TerminalSession? {
        dispatchPrecondition(condition: .onQueue(queue))
        return sessions[id]
    }

    /// The command a pane's Ghostty surface runs to attach to `id`.
    ///
    /// Ghostty runs it through `bash -c "exec -l …"`, so it is a shell word
    /// list, and each part is quoted in case the app lives somewhere with a
    /// space in the path.
    func attachCommand(for id: UUID) -> String {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return [executable, AttachClient.flag, socketPath, id.uuidString]
            .map(AgentSession.shellQuoted)
            .joined(separator: " ")
    }

    // MARK: - Attach connections

    private func accept(_ fd: Int32) {
        let socket = FramedSocket(fd: fd, queue: queue)
        let connection = AttachConnection(socket: socket, manager: self)
        let key = ObjectIdentifier(connection)
        attachConnections[key] = connection
        socket.onClose = { [weak self] in
            connection.closed()
            self?.attachConnections.removeValue(forKey: key)
        }
        socket.start()
    }
}

/// The session side of one pane's attach process.
private final class AttachConnection: SessionClient {
    let socket: FramedSocket
    weak var manager: SessionManager?
    private var session: TerminalSession?

    init(socket: FramedSocket, manager: SessionManager) {
        self.socket = socket
        self.manager = manager
        socket.onFrame = { [weak self] frame in self?.received(frame) }
    }

    var bufferedBytes: Int { socket.bufferedBytes }

    private func received(_ frame: Frame) {
        switch frame.kind {
        case .control:
            guard let message = try? frame.decode(ClientMessage.self) else { return }
            handle(message)
        case .input:
            session?.write(frame.payload)
        case .output, .synthesized:
            break
        }
    }

    private func handle(_ message: ClientMessage) {
        switch message {
        case .attachHello(let hello):
            guard hello.protocolVersion == TabTermProtocol.version else {
                refuse("This pane was started by a different version of Workbench.")
                return
            }
            guard session == nil, let found = manager?.session(hello.session) else {
                refuse("This terminal's session is gone.")
                return
            }
            session = found
            found.attach(
                self,
                anchor: .fresh,
                size: hello.size,
                visible: true,
                ghosttyEnvironment: hello.environment
            )
        case .resize(let resize):
            session.map { $0.resize(self, to: resize.size) }
        default:
            break
        }
    }

    /// Say why on the pane itself, then close — the attach process exits and
    /// Ghostty closes the pane.
    private func refuse(_ reason: String) {
        socket.send(.output(UUID(), Data("\r\n[Workbench] \(reason)\r\n".utf8)))
        socket.send(control: .exit(SessionExit(session: UUID(), code: 1)))
        socket.close()
    }

    func closed() {
        session?.detach(self)
        session = nil
    }

    // MARK: SessionClient

    func session(_ session: TerminalSession, didOutput bytes: Data) {
        socket.send(.output(session.id, bytes))
    }

    func session(_ session: TerminalSession, didSynthesize bytes: Data) {
        // The pane's Ghostty has been attached since the start, so there is
        // never anything to re-assert to it.
    }

    func session(_ session: TerminalSession, didSync synced: Synced) {}

    func session(_ session: TerminalSession, didExit code: Int32) {
        socket.send(control: .exit(SessionExit(session: session.id, code: code)))
        self.session = nil
    }

    func sessionDidDropForBackpressure(_ session: TerminalSession) {
        // Only possible if Ghostty stopped reading its own pty entirely.
        self.session = nil
        socket.close()
    }
}

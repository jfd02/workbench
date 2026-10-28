import Foundation
import TabTermKit

/// A stand-in for Workbench on the other Mac: the server's side of the
/// protocol over the loopback, with terminals that hold whatever a test wrote
/// to them.
///
/// It serves one connection at a time, which is all one `workbench` makes, on a
/// thread of its own. Everything a test reads or changes is behind the lock.
final class FakeHost {
    let port: UInt16
    let epoch = "epoch-1"
    let token = "token-for-tests"

    private let listener: Int32
    private let lock = NSRecursiveLock()
    private var connection: Int32 = -1

    private var _state: HostState
    private var _pairingCode: String?
    private var _messages: [ClientMessage] = []
    private var _typed: [UUID: Data] = [:]
    private var _logs: [UUID: Data] = [:]
    private var _attached: Set<UUID> = []
    private var _preamble = Data()
    private var _isRefusing = false
    private var _knowsWorktrees = true

    init(state: HostState) {
        _state = state

        // Any free port on the loopback.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(listener, $0, length)
                _ = getsockname(listener, $0, &length)
            }
        }
        listen(listener, 4)

        self.listener = listener
        port = UInt16(bigEndian: address.sin_port)
        Thread { [self] in acceptLoop() }.start()
    }

    func stop() {
        drop()
        Darwin.close(listener)
    }

    // MARK: - What a test sets up

    var state: HostState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    var pairingCode: String? {
        get { lock.withLock { _pairingCode } }
        set { lock.withLock { _pairingCode = newValue } }
    }

    /// The modes a fresh attach is told the terminal is in.
    var preamble: String {
        get { lock.withLock { String(decoding: _preamble, as: UTF8.self) } }
        set { lock.withLock { _preamble = Data(newValue.utf8) } }
    }

    /// Hang up on everyone who connects, as a Mac that can't be reached does
    /// for as long as it lasts.
    var isRefusing: Bool {
        get { lock.withLock { _isRefusing } }
        set { lock.withLock { _isRefusing = newValue } }
    }

    /// False for a Workbench from before worktrees could be asked for.
    var knowsWorktrees: Bool {
        get { lock.withLock { _knowsWorktrees } }
        set { lock.withLock { _knowsWorktrees = newValue } }
    }

    /// The terminal wrote something: kept for whoever attaches later, and
    /// sent now to whoever is attached.
    func output(_ session: UUID, _ text: String) {
        lock.withLock {
            let bytes = Data(text.utf8)
            _logs[session, default: Data()].append(bytes)
            if _attached.contains(session) { send(.output(session, bytes)) }
        }
    }

    func send(_ message: ServerMessage) {
        send(.control(message))
    }

    /// Cut the connection without a word, as a network going away does.
    func drop() {
        lock.withLock {
            if connection >= 0 { shutdown(connection, SHUT_RDWR) }
        }
    }

    // MARK: - What a test checks

    var messages: [ClientMessage] { lock.withLock { _messages } }

    var attaches: [Attach] {
        messages.compactMap { if case .attach(let attach) = $0 { return attach } else { return nil } }
    }

    var hellos: [Hello] {
        messages.compactMap { if case .hello(let hello) = $0 { return hello } else { return nil } }
    }

    func typed(_ session: UUID) -> String {
        lock.withLock { String(decoding: _typed[session] ?? Data(), as: UTF8.self) }
    }

    // MARK: - Serving

    private func acceptLoop() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            if isRefusing {
                Darwin.close(fd)
                continue
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { connection = fd }

            var decoder = FrameDecoder()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0, let frames = try? decoder.append(Data(buffer[0..<count])) else { break }
                for frame in frames { lock.withLock { handle(frame) } }
            }

            lock.withLock {
                connection = -1
                _attached.removeAll()
            }
            Darwin.close(fd)
        }
    }

    private func send(_ frame: Frame) {
        lock.withLock {
            guard connection >= 0 else { return }
            let data = frame.encoded()
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(connection, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }

    private func handle(_ frame: Frame) {
        if frame.kind == .input, let session = frame.session {
            _typed[session, default: Data()].append(frame.payload)
            return
        }
        guard frame.kind == .control, let message = try? frame.decode(ClientMessage.self) else { return }
        _messages.append(message)

        switch message {
        case .hello(let hello):
            var issued: String?
            if hello.deviceToken == token {
                issued = nil
            } else if let code = _pairingCode, hello.pairingCode == code {
                _pairingCode = nil
                issued = token
            } else {
                send(.denied(Denied(reason: .unauthorized, message: "Not paired.")))
                return
            }
            send(.welcome(Welcome(hostName: _state.hostName, deviceID: "device-1", deviceToken: issued)))
            send(.state(_state))

        case .attach(let attach):
            guard _state.locate(attach.session) != nil else {
                send(.exit(SessionExit(session: attach.session, code: SessionExit.unknownSession)))
                return
            }
            _attached.insert(attach.session)
            let log = _logs[attach.session] ?? Data()
            let size = TerminalSize(cols: 80, rows: 24)

            if case .position(let theirs, let seq) = attach.anchor, theirs == epoch, seq <= UInt64(log.count) {
                send(.synced(Synced(session: attach.session, epoch: epoch, seq: seq, mode: .exact, size: size)))
                let missed = log.dropFirst(Int(seq))
                if !missed.isEmpty { send(.output(attach.session, Data(missed))) }
            } else {
                send(.synced(Synced(session: attach.session, epoch: epoch, seq: 0, mode: .reset, size: size)))
                if !_preamble.isEmpty { send(.synthesized(attach.session, _preamble)) }
                if !log.isEmpty { send(.output(attach.session, log)) }
            }

        case .detach(let ref):
            _attached.remove(ref.session)

        case .openWorkspace(let ref):
            guard let index = _state.workspaces.firstIndex(where: { $0.id == ref.workspace }) else { return }
            _state.workspaces[index].isOpen = true
            _state.workspaces[index].tabs = [Self.tab("zsh", UUID())]
            send(.state(_state))

        case .newTab(let request):
            guard let index = _state.workspaces.firstIndex(where: { $0.id == request.workspace }) else {
                send(.error(ErrorMessage(message: "Couldn't open a terminal there.")))
                return
            }
            let session = UUID()
            _state.workspaces[index].tabs.append(Self.tab("new", session))
            send(.tabCreated(TabCreated(requestID: request.requestID, workspace: request.workspace, session: session)))
            send(.state(_state))

        case .newWorktree(let request):
            guard _knowsWorktrees else {
                send(.error(ErrorMessage(message: "Unrecognized message.")))
                return
            }
            guard let repository = _state.workspace(id: request.workspace)?.repository else {
                send(.error(ErrorMessage(message: "That workspace isn't in a repository.")))
                return
            }
            // What git says to a branch that already has a worktree.
            if let taken = _state.workspaces.first(where: { $0.repository == repository && $0.branch == request.branch }) {
                send(.error(ErrorMessage(
                    message: "fatal: '\(request.branch)' is already used by worktree at '\(taken.directory ?? "")'")))
                return
            }
            let id = "worktree:\(100 + _state.workspaces.count)"
            let folder = request.branch.replacingOccurrences(of: "/", with: "-")
            _state.workspaces.append(WorkspaceInfo(
                id: id, name: request.branch, repository: repository, branch: request.branch,
                directory: "/Users/example/code/\(repository)-worktrees/\(folder)", isOpen: false, status: .idle, tabs: []
            ))
            send(.state(_state))
            send(.worktreeCreated(WorktreeCreated(requestID: request.requestID, workspace: id)))

        case .ping(let ping):
            send(.pong(ping))

        default:
            break
        }
    }

    static func tab(_ title: String, _ session: UUID, selected: Bool = true) -> TabInfo {
        TabInfo(id: UUID(), title: title, isSelected: selected, panes: [
            PaneInfo(session: session, title: title, directory: nil, isClaude: false, status: .idle, isFocused: true),
        ])
    }
}

/// `workbench`, run in a terminal of its own: a pty the test holds the other
/// end of, so it can type and can read exactly what would be on screen.
final class TerminalRun {
    let process = Process()
    private let master: Int32
    private let lock = NSLock()
    private var received = Data()
    private var isStopped = false

    /// The binary this package built, next to the test bundle.
    static var binary: URL {
        Bundle(for: TerminalRun.self).bundleURL.deletingLastPathComponent().appendingPathComponent("workbench")
    }

    init(_ arguments: [String], config: URL, cols: UInt16 = 80, rows: UInt16 = 24) throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw CocoaError(.fileReadUnknown) }
        self.master = master

        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.executableURL = Self.binary
        process.arguments = arguments
        process.environment = ["TABTERM_CONFIG_DIR": config.path, "TERM": "xterm-256color"]
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        try process.run()
        Darwin.close(slave)

        let fd = master
        Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { return }
                lock.withLock { received.append(contentsOf: buffer[0..<count]) }
            }
        }.start()
    }

    /// Everything written to the terminal so far.
    var screen: String {
        lock.withLock { String(decoding: received, as: UTF8.self) }
    }

    func type(_ text: String) {
        let bytes = Array(text.utf8)
        _ = write(master, bytes, bytes.count)
    }

    func resize(cols: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        // The pty isn't this process's controlling terminal, so the kernel
        // has nobody to tell.
        kill(process.processIdentifier, SIGWINCH)
    }

    /// End it the way closing its window would, and wait for it to go.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        Darwin.close(master)
    }
}

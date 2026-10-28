import Foundation
import TabTermKit

/// One TCP connection to Workbench on the other Mac, carrying TabTermKit frames.
///
/// Blocking and single-threaded on purpose. Everything `workbench` does is one
/// loop around `poll`, the way a pane's own attach process works, and all it
/// ever writes is keystrokes and a few small messages.
final class HostLink {
    let fd: Int32
    private var decoder = FrameDecoder()
    private var backlog: [Frame] = []
    private var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    private var isClosed = false

    /// When the Mac was last heard from, to tell a dead link from a quiet one.
    private(set) var lastHeard = Date()

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }

    // MARK: - Connecting

    /// Connect to the first address that answers, and return its socket.
    ///
    /// Each address gets `timeout` and no more: one that is unreachable right
    /// now — Tailscale off, the Mac asleep — would otherwise be waited on for
    /// the kernel's minute and more before the next was tried.
    static func open(hosts: [String], port: UInt16, timeout: TimeInterval) -> Int32? {
        for host in hosts {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &list) == 0 else { continue }
            defer { freeaddrinfo(list) }

            var cursor = list
            while let info = cursor {
                if let fd = connect(to: info.pointee, timeout: timeout) { return fd }
                cursor = info.pointee.ai_next
            }
        }
        return nil
    }

    private static func connect(to info: addrinfo, timeout: TimeInterval) -> Int32? {
        let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard fd >= 0 else { return nil }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var connected = Darwin.connect(fd, info.ai_addr, info.ai_addrlen) == 0
        if !connected, errno == EINPROGRESS {
            let deadline = Date().addingTimeInterval(timeout)
            var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var ready: Int32 = 0
            repeat {
                let remaining = max(deadline.timeIntervalSinceNow, 0)
                ready = poll(&waiting, 1, Int32(remaining * 1000))
            } while ready < 0 && errno == EINTR

            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
            connected = ready > 0 && failure == 0
        }
        guard connected else {
            Darwin.close(fd)
            return nil
        }

        _ = fcntl(fd, F_SETFL, flags)
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, size)
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &on, size)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, size)
        // A link that has stopped taking bytes must not hold the keyboard
        // hostage: give up on the write and let the silence be noticed.
        var patience = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &patience, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    // MARK: - Sending

    @discardableResult
    func send(_ message: ClientMessage) -> Bool {
        send(.control(message))
    }

    /// False when the frame couldn't be written; the connection is gone, and
    /// the next read will say so.
    @discardableResult
    func send(_ frame: Frame) -> Bool {
        guard !isClosed else { return false }
        let data = frame.encoded()
        return data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer += written
                remaining -= written
            }
            return true
        }
    }

    // MARK: - Receiving

    /// Read what has arrived, once `fd` is readable. False when the
    /// connection is gone or what came off it isn't frames.
    func fill() -> Bool {
        guard !isClosed else { return false }
        let count = read(fd, &buffer, buffer.count)
        if count < 0, errno == EINTR || errno == EAGAIN { return true }
        guard count > 0, let frames = try? decoder.append(Data(buffer[0..<count])) else { return false }
        lastHeard = Date()
        backlog += frames
        return true
    }

    /// The frames read so far, oldest first.
    func drain() -> [Frame] {
        defer { backlog.removeAll() }
        return backlog
    }

    /// Wait for one frame. Nil when `deadline` passes or the connection goes.
    func next(before deadline: Date) -> Frame? {
        while backlog.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, !isClosed else { return nil }
            var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32(min(remaining, 1) * 1000) + 1)
            if ready < 0, errno != EINTR { return nil }
            if ready > 0, !fill() { return nil }
        }
        return backlog.removeFirst()
    }
}

/// Why a command couldn't get as far as the Mac's sidebar.
enum HostError: Error {
    /// Nothing answered at any of its addresses.
    case unreachable
    /// It answered and said no.
    case denied(Denied)
    /// It took the connection and then said nothing useful.
    case silent
}

/// A connection that has said hello and been let in: the Mac's welcome, and
/// its sidebar, kept current for as long as something is waiting on it.
///
/// This is the whole of `pair` and `ls`, and how `attach` finds its terminal
/// before it takes over the screen — while a mistake can still be reported as
/// an ordinary line of text.
final class HostClient {
    let link: HostLink
    let welcome: Welcome
    private(set) var state: HostState

    private init(link: HostLink, welcome: Welcome, state: HostState) {
        self.link = link
        self.welcome = welcome
        self.state = state
    }

    /// What this Mac calls itself, for the other one's list of paired devices.
    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    static func hello(for host: PairedHost, pairingCode: String? = nil) -> ClientMessage {
        .hello(Hello(
            deviceName: deviceName,
            deviceToken: host.deviceToken.isEmpty ? nil : host.deviceToken,
            pairingCode: pairingCode
        ))
    }

    static func open(_ host: PairedHost, pairingCode: String? = nil) throws -> HostClient {
        guard let fd = HostLink.open(hosts: host.hosts, port: host.port, timeout: 4) else {
            throw HostError.unreachable
        }
        let link = HostLink(fd: fd)
        link.send(hello(for: host, pairingCode: pairingCode))

        // The welcome, then the sidebar straight behind it.
        var welcome: Welcome?
        var state: HostState?
        let deadline = Date().addingTimeInterval(10)
        while state == nil, let frame = link.next(before: deadline) {
            guard frame.kind == .control, let message = try? frame.decode(ServerMessage.self) else { continue }
            switch message {
            case .welcome(let value): welcome = value
            case .state(let value): state = value
            case .ping(let ping): link.send(.pong(ping))
            case .denied(let denied):
                link.close()
                throw HostError.denied(denied)
            default: break
            }
        }
        guard let welcome, let state else {
            link.close()
            throw HostError.silent
        }
        return HostClient(link: link, welcome: welcome, state: state)
    }

    /// Keep listening until `done` accepts a message. False if `timeout`
    /// passes or the connection goes first. The sidebar is kept up to date
    /// along the way, so `done` can simply look at `state`.
    func wait(_ timeout: TimeInterval, until done: (ServerMessage) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while let frame = link.next(before: deadline) {
            guard frame.kind == .control, let message = try? frame.decode(ServerMessage.self) else { continue }
            switch message {
            case .state(let value): state = value
            case .ping(let ping): link.send(.pong(ping))
            default: break
            }
            if done(message) { return true }
        }
        return false
    }
}

/// Dials the Mac off the main loop.
///
/// A connect to an address that isn't answering takes seconds to give up,
/// and while a dropped connection is being retried the keyboard has to keep
/// working — the list of terminals, quitting. So the dialling happens on
/// another thread and its result arrives as a byte on a pipe the loop polls.
final class Connector {
    enum Outcome {
        case connected(Int32)
        case failed
    }

    let wakeRead: Int32
    private let wakeWrite: Int32
    private let lock = NSLock()
    private var outcome: Outcome?

    /// Main loop only.
    private(set) var isBusy = false

    init() {
        var ends: [Int32] = [0, 0]
        pipe(&ends)
        wakeRead = ends[0]
        wakeWrite = ends[1]
    }

    func start(hosts: [String], port: UInt16) {
        guard !isBusy else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let fd = HostLink.open(hosts: hosts, port: port, timeout: 4)
            lock.withLock { outcome = fd.map(Outcome.connected) ?? .failed }
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
        }
    }

    /// Collect the result, once `wakeRead` is readable.
    func take() -> Outcome? {
        var drained = [UInt8](repeating: 0, count: 16)
        _ = read(wakeRead, &drained, drained.count)
        isBusy = false
        return lock.withLock {
            defer { outcome = nil }
            return outcome
        }
    }
}

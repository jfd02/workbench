import Foundation
import TabTermKit

/// A stand-in iPhone for the self-test: speaks the phone's side of the
/// protocol over a real TCP connection to the real server, and keeps what it
/// hears so the test can check it.
///
/// Everything it receives lands on its own queue; the test reads it from the
/// main thread, so the collected state is behind a lock.
final class TestPhone {
    private let queue = DispatchQueue(label: "com.tabterm.selftest.phone")
    private var socket: FramedSocket?
    private let lock = NSLock()

    private var messages: [ServerMessage] = []
    private var output: [UUID: Data] = [:]
    private var positions: [UUID: (epoch: String, seq: UInt64)] = [:]
    private var closed = false

    /// Connect to the loopback. False if nothing is listening.
    func connect(port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return false
        }

        let socket = FramedSocket(fd: fd, queue: queue)
        socket.onFrame = { [weak self] frame in self?.received(frame) }
        socket.onClose = { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.closed = true }
        }
        queue.sync {
            self.socket = socket
            socket.start()
        }
        return true
    }

    func send(_ message: ClientMessage) {
        queue.async { self.socket?.send(.control(message)) }
    }

    func close() {
        queue.sync { self.socket?.close() }
    }

    private func received(_ frame: Frame) {
        switch frame.kind {
        case .control:
            guard let message = try? frame.decode(ServerMessage.self) else { return }
            if case .ping(let ping) = message {
                socket?.send(.control(ClientMessage.pong(ping)))
            }
            lock.withLock {
                messages.append(message)
                if case .synced(let synced) = message {
                    positions[synced.session] = (synced.epoch, synced.seq)
                }
            }
        case .output:
            guard let session = frame.session else { return }
            lock.withLock {
                output[session, default: Data()].append(frame.payload)
                if let position = positions[session] {
                    positions[session] = (position.epoch, position.seq + UInt64(frame.payload.count))
                }
            }
        case .synthesized, .input:
            break
        }
    }

    // MARK: - What it heard

    var isClosed: Bool { lock.withLock { closed } }

    var welcome: Welcome? {
        lock.withLock {
            messages.lazy.compactMap { if case .welcome(let w) = $0 { return w } else { return nil } }.last
        }
    }

    var denied: Denied? {
        lock.withLock {
            messages.lazy.compactMap { if case .denied(let d) = $0 { return d } else { return nil } }.last
        }
    }

    var state: HostState? {
        lock.withLock {
            messages.lazy.compactMap { if case .state(let s) = $0 { return s } else { return nil } }.last
        }
    }

    func worktreeCreated(_ requestID: String) -> WorktreeCreated? {
        lock.withLock {
            messages.lazy.compactMap {
                if case .worktreeCreated(let w) = $0, w.requestID == requestID { return w } else { return nil }
            }.last
        }
    }

    /// What the Mac said it couldn't do, oldest first.
    var errors: [String] {
        lock.withLock {
            messages.compactMap { if case .error(let e) = $0 { return e.message } else { return nil } }
        }
    }

    func synced(_ session: UUID) -> Synced? {
        lock.withLock {
            messages.lazy.compactMap {
                if case .synced(let s) = $0, s.session == session { return s } else { return nil }
            }.last
        }
    }

    func text(_ session: UUID) -> String {
        lock.withLock { String(decoding: output[session] ?? Data(), as: UTF8.self) }
    }

    /// Where this phone is in a session's stream, to reconnect from.
    func anchor(_ session: UUID) -> StreamAnchor {
        lock.withLock {
            positions[session].map { .position(epoch: $0.epoch, seq: $0.seq) } ?? .fresh
        }
    }
}

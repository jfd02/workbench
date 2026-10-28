import Foundation
import TabTermKit

/// A connected stream socket that speaks in `Frame`s.
///
/// Used for both kinds of client a session has: the attach process behind a
/// Ghostty pane (a Unix socket) and a phone (TCP over Tailscale). Everything
/// happens on the queue it was created with, including its callbacks.
///
/// Writes are buffered rather than blocking: a client that stops reading —
/// a phone that went into a tunnel — must never stall the terminal. The
/// buffer is visible through `bufferedBytes` so the session can cut off a
/// client that has fallen hopelessly behind.
final class FramedSocket {
    let fd: Int32
    let queue: DispatchQueue

    /// Called for each whole frame received.
    var onFrame: ((Frame) -> Void)?

    /// Called once, when the socket closes for any reason.
    var onClose: (() -> Void)?

    private var decoder = FrameDecoder()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false
    private var outbox: [Data] = []
    private var outboxOffset = 0
    private(set) var bufferedBytes = 0
    private(set) var isClosed = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
        // A peer that vanishes mid-write must not kill the whole app.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Start reading. Separate from init so callbacks can be set first.
    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source

        let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        writer.setEventHandler { [weak self] in self?.flush() }
        writeSource = writer
        // Created suspended; resumed only while there is something to write.
    }

    func send(_ frame: Frame) {
        send(encoded: frame.encoded())
    }

    func send(control message: ServerMessage) {
        send(.control(message))
    }

    func send(encoded data: Data) {
        guard !isClosed, !data.isEmpty else { return }
        outbox.append(data)
        bufferedBytes += data.count
        flush()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true

        readSource?.cancel()
        readSource = nil
        if let writeSource {
            // A suspended source must be resumed before it can be cancelled.
            if !writeSourceActive { writeSource.resume() }
            writeSource.cancel()
        }
        writeSource = nil
        outbox.removeAll()
        bufferedBytes = 0
        Darwin.close(fd)

        let onClose = self.onClose
        self.onClose = nil
        self.onFrame = nil
        onClose?()
    }

    // MARK: - Reading

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !isClosed {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let frames: [Frame]
                do {
                    frames = try decoder.append(Data(buffer[0..<count]))
                } catch {
                    // Nothing after a malformed frame can be trusted.
                    close()
                    return
                }
                for frame in frames {
                    guard !isClosed else { return }
                    onFrame?(frame)
                }
                continue
            }
            if count == 0 {
                close()
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            close()
            return
        }
    }

    // MARK: - Writing

    private func flush() {
        while !isClosed, let first = outbox.first {
            let remaining = first.count - outboxOffset
            let written = first.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(fd, base + outboxOffset, remaining)
            }
            if written > 0 {
                bufferedBytes -= written
                if written == remaining {
                    outbox.removeFirst()
                    outboxOffset = 0
                } else {
                    outboxOffset += written
                }
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                setWriteSource(active: true)
                return
            }
            close()
            return
        }
        setWriteSource(active: false)
    }

    private func setWriteSource(active: Bool) {
        guard let writeSource, active != writeSourceActive else { return }
        writeSourceActive = active
        if active { writeSource.resume() } else { writeSource.suspend() }
    }
}

/// A listening socket that hands each accepted connection to a callback.
final class SocketListener {
    let fd: Int32
    private let source: DispatchSourceRead

    init(fd: Int32, queue: DispatchQueue, onAccept: @escaping (Int32) -> Void) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                onAccept(client)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    func close() {
        source.cancel()
    }

    /// Listen on a Unix socket at `path`, readable only by this user.
    static func unix(path: String, queue: DispatchQueue, onAccept: @escaping (Int32) -> Void) throws -> SocketListener {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let error = POSIXError.current
            Darwin.close(fd)
            throw error
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let error = POSIXError.current
            Darwin.close(fd)
            throw error
        }
        return SocketListener(fd: fd, queue: queue, onAccept: onAccept)
    }

    /// Listen on TCP at one IPv4 address. Port 0 picks a free one; see `port`.
    static func tcp(host: String, port: UInt16, queue: DispatchQueue, onAccept: @escaping (Int32) -> Void) throws -> SocketListener {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw POSIXError(.EINVAL)
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let error = POSIXError.current
            Darwin.close(fd)
            throw error
        }
        return SocketListener(fd: fd, queue: queue, onAccept: onAccept)
    }

    /// The port actually bound, for listeners opened on port 0.
    var port: UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return result == 0 ? UInt16(bigEndian: address.sin_port) : 0
    }
}

extension POSIXError {
    static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

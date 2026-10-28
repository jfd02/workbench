import Foundation
import TabTermKit

/// `Workbench --attach <socket> <session>`: what a pane's Ghostty surface runs.
///
/// Ghostty gives every surface a pty and a child process. The child used to be
/// the shell; now it is this, a relay between Ghostty's pty and the session the
/// app holds. It puts its terminal in raw mode so every byte Ghostty sends —
/// Ctrl-C included — goes to the session untouched, and writes everything the
/// session outputs straight back. The session's own pty does the line
/// discipline, echo and job control, exactly as it would have in Ghostty.
///
/// It exits when the session ends (with the shell's status, so Ghostty closes
/// the pane the same way it did when the shell was its own child) or when the
/// app goes away.
enum AttachClient {
    static let flag = "--attach"

    static var isRequested: Bool {
        CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == flag
    }

    static func run() -> Never {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4, let session = UUID(uuidString: arguments[3]) else {
            fail("usage: Workbench --attach <socket> <session>")
        }
        let socketPath = arguments[2]

        let socket = connect(to: socketPath)
        let original = TerminalIO.makeRaw(STDIN_FILENO)

        // SIGWINCH arrives on a self-pipe so the poll loop sees it.
        var signalPipe: [Int32] = [0, 0]
        pipe(&signalPipe)
        winchPipe = signalPipe[1]
        signal(SIGWINCH) { _ in
            var byte: UInt8 = 1
            _ = write(AttachClient.winchPipe, &byte, 1)
        }
        signal(SIGPIPE, SIG_IGN)

        let hello = AttachHello(
            session: session,
            size: TerminalIO.size(of: STDIN_FILENO),
            environment: ProcessInfo.processInfo.environment
        )
        send(socket, .control(ClientMessage.attachHello(hello)))

        var decoder = FrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pollFDs = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: socket, events: Int16(POLLIN), revents: 0),
            pollfd(fd: signalPipe[0], events: Int16(POLLIN), revents: 0),
        ]

        while true {
            let ready = poll(&pollFDs, nfds_t(pollFDs.count), -1)
            if ready < 0 {
                if errno == EINTR { continue }
                exitRestoring(original, code: 1)
            }

            // Ghostty → session.
            if pollFDs[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 {
                    send(socket, .input(session, Data(buffer[0..<count])))
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    // Ghostty closed the pane.
                    exitRestoring(original, code: 0)
                }
            }

            // Session → Ghostty.
            if pollFDs[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = read(socket, &buffer, buffer.count)
                if count <= 0 {
                    if count < 0, errno == EINTR { continue }
                    // The app went away; so does the pane.
                    exitRestoring(original, code: 1)
                }
                guard let frames = try? decoder.append(Data(buffer[0..<count])) else {
                    exitRestoring(original, code: 1)
                }
                for frame in frames {
                    switch frame.kind {
                    case .output, .synthesized:
                        TerminalIO.writeAll(frame.payload, to: STDOUT_FILENO)
                    case .control:
                        if case .exit(let exit)? = try? frame.decode(ServerMessage.self) {
                            exitRestoring(original, code: exit.code)
                        }
                    case .input:
                        break
                    }
                }
            }

            // Ghostty resized the pane.
            if pollFDs[2].revents & Int16(POLLIN) != 0 {
                var drain = [UInt8](repeating: 0, count: 64)
                _ = read(signalPipe[0], &drain, drain.count)
                let resize = Resize(session: session, size: TerminalIO.size(of: STDIN_FILENO))
                send(socket, .control(ClientMessage.resize(resize)))
            }
        }
    }

    // MARK: - Plumbing

    nonisolated(unsafe) static var winchPipe: Int32 = -1

    private static func connect(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("Workbench: couldn't create a socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            fail("Workbench isn't running, so this terminal can't start.")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func send(_ fd: Int32, _ frame: Frame) {
        TerminalIO.writeAll(frame.encoded(), to: fd)
    }

    private static func exitRestoring(_ original: termios?, code: Int32) -> Never {
        TerminalIO.restore(original, to: STDIN_FILENO)
        exit(code)
    }

    /// Say what went wrong where the user will see it — this process's stdout
    /// is the pane — and linger long enough to be read before the pane closes.
    private static func fail(_ message: String) -> Never {
        let text = "\r\n\(message)\r\n"
        TerminalIO.writeAll(Data(text.utf8), to: STDOUT_FILENO)
        sleep(3)
        exit(1)
    }
}

#if os(macOS)
import Darwin
import Foundation

/// Terminal operations shared by the local Ghostty relay and the remote CLI.
public enum TerminalIO {
    public static func size(of fd: Int32) -> TerminalSize {
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
            return TerminalSize(cols: 80, rows: 24)
        }
        return TerminalSize(
            cols: Int(size.ws_col), rows: Int(size.ws_row),
            pixelWidth: Int(size.ws_xpixel), pixelHeight: Int(size.ws_ypixel)
        )
    }

    /// Put a terminal in raw mode and return the settings needed to restore it.
    public static func makeRaw(_ fd: Int32) -> termios? {
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { return nil }
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(fd, TCSANOW, &raw)
        return original
    }

    public static func restore(_ original: termios?, to fd: Int32) {
        if var original { tcsetattr(fd, TCSANOW, &original) }
    }

    /// Write all bytes to a blocking descriptor, retrying interrupted writes.
    /// False means the descriptor stopped accepting bytes.
    @discardableResult
    public static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0, errno == EINTR || errno == EAGAIN { continue }
                guard written > 0 else { return false }
                pointer += written
                remaining -= written
            }
            return true
        }
    }
}
#endif

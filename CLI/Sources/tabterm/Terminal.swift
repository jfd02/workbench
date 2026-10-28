import Foundation
import TabTermKit

/// This process's own terminal: the window `workbench` was run in.
enum Terminal {
    static var isInteractive: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    static var size: TerminalSize { TerminalIO.size(of: STDOUT_FILENO) }

    /// Raw mode, so every key — Ctrl-C included — reaches the Mac untouched.
    static func makeRaw() -> termios? { TerminalIO.makeRaw(STDIN_FILENO) }

    static func restore(_ original: termios?) {
        TerminalIO.restore(original, to: STDIN_FILENO)
    }

    static func write(_ text: String) {
        write(Data(text.utf8))
    }

    static func write(_ data: Data) {
        TerminalIO.writeAll(data, to: STDOUT_FILENO)
    }

    /// Start a screen over, as the protocol asks of a client that couldn't be
    /// caught up: a full reset, so nothing the last program switched on
    /// outlives it, and the scrollback with it, so scrolling up from one
    /// terminal never runs into another's.
    static let reset = "\u{1b}c\u{1b}[3J"

    /// What a full-screen program can leave behind that `TerminalModes.undo`
    /// doesn't cover, put back, and the cursor parked on a fresh line at the
    /// bottom — the margins and origin mode both move it on the way.
    static func tidy(rows: Int) -> String {
        "\u{1b}[0m\u{1b}[?2026l\u{1b}[4l\u{1b}[?6l\u{1b}[r\u{1b}(B\u{0f}\u{1b}[\(rows);1H\r\n"
    }
}

/// Signals, delivered as bytes on a pipe so the poll loop meets them in order
/// with everything else instead of in the middle of a write.
enum Signals {
    nonisolated(unsafe) static var pipeWrite: Int32 = -1

    /// Returns the end of the pipe to poll; each byte read is a signal number.
    static func watch(_ numbers: [Int32]) -> Int32 {
        var ends: [Int32] = [0, 0]
        pipe(&ends)
        pipeWrite = ends[1]
        for number in numbers {
            signal(number) { number in
                var byte = UInt8(truncatingIfNeeded: number)
                _ = write(Signals.pipeWrite, &byte, 1)
            }
        }
        // A Mac that vanished mid-write is a lost connection, not a crash.
        signal(SIGPIPE, SIG_IGN)
        return ends[0]
    }
}

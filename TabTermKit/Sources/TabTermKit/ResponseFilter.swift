/// Removes a terminal's automatic replies from what it sends back.
///
/// When a program asks the terminal something — where is the cursor, what are
/// you, what colour is your background — the terminal answers by writing into
/// the program's input as if the user had typed it. With two terminals showing
/// one session, both answer, and the program gets its answer twice: the second
/// copy lands on the command line as garbage like `^[[24;1R`.
///
/// The Mac's Ghostty is always attached, so it is the one that answers. The
/// phone runs what it sends through this first, keeping keystrokes and dropping
/// replies. Replies and keystrokes can be told apart because a keyboard never
/// produces the shapes replies take: an OSC or DCS string, a CSI ending in `R`,
/// `c`, `n`, `t` or `$y`, a `?`-prefixed `u`, a focus report, a mouse report.
public enum ResponseFilter {
    public static func keystrokes(from bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x1B, i + 1 < bytes.count else {
                out.append(bytes[i])
                i += 1
                continue
            }

            switch bytes[i + 1] {
            case 0x5B: // CSI
                let (end, isReply) = scanCSI(bytes, from: i + 2)
                if !isReply { out.append(contentsOf: bytes[i..<end]) }
                i = end

            case 0x5D, 0x50, 0x5F, 0x5E, 0x58: // OSC, DCS, APC, PM, SOS
                i = scanString(bytes, from: i + 2)

            default:
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    /// Returns the index just past the sequence, and whether it is a reply.
    private static func scanCSI(_ bytes: [UInt8], from start: Int) -> (Int, Bool) {
        var j = start
        var prefix: UInt8 = 0
        var intermediate: UInt8 = 0
        var hasParams = false

        if j < bytes.count, (0x3C...0x3F).contains(bytes[j]) {
            prefix = bytes[j]
            j += 1
        }
        while j < bytes.count {
            let b = bytes[j]
            switch b {
            case 0x30...0x3F:
                hasParams = true
                j += 1
            case 0x20...0x2F:
                intermediate = b
                j += 1
            case 0x40...0x7E:
                return (j + 1, isReply(prefix: prefix, intermediate: intermediate, final: b, hasParams: hasParams))
            default:
                // Not a well-formed CSI; pass the introducer through as typed.
                return (j, false)
            }
        }
        return (j, false)
    }

    private static func isReply(
        prefix: UInt8,
        intermediate: UInt8,
        final: UInt8,
        hasParams: Bool
    ) -> Bool {
        switch final {
        case 0x52: return true                          // R  cursor position report
        case 0x63: return prefix != 0                   // c  device attributes (?, >, =)
        case 0x6E: return true                          // n  device status report
        case 0x74: return hasParams                     // t  window reports
        case 0x78: return hasParams                     // x  DECREQTPARM reply
        case 0x79: return intermediate == 0x24          // $y mode report
        case 0x75: return prefix == 0x3F                // ?u keyboard flags reply
        case 0x49, 0x4F: return !hasParams && prefix == 0   // I / O focus in/out
        case 0x4D, 0x6D: return prefix == 0x3C          // <…M / <…m  SGR mouse report
        default: return false
        }
    }

    /// Returns the index just past the string's terminator (BEL or ST).
    private static func scanString(_ bytes: [UInt8], from start: Int) -> Int {
        var j = start
        while j < bytes.count {
            if bytes[j] == 0x07 { return j + 1 }
            if bytes[j] == 0x1B, j + 1 < bytes.count, bytes[j + 1] == 0x5C { return j + 2 }
            j += 1
        }
        return j
    }
}

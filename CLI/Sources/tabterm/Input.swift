import Foundation
import TabTermKit

/// What the terminal sent, cut where a key ends.
enum InputToken: Equatable {
    /// Ordinary bytes — text and control characters. An ESC on its own is the
    /// Escape key.
    case text([UInt8])
    /// One whole escape sequence, introducer included.
    case sequence([UInt8])
}

/// Cuts a terminal's input into keys and whole escape sequences.
///
/// A read ends wherever the kernel cut it, which can be halfway through a
/// sequence, and a reply filtered in two halves isn't filtered at all: its
/// tail lands on the Mac's command line as text. So a sequence that hasn't
/// finished waits here for the rest. A lone ESC hasn't finished either — it
/// is how every sequence begins — which is what `flush` is for: when nothing
/// follows within a moment, it was the Escape key.
struct InputScanner {
    private var pending: [UInt8] = []

    /// A string reply this long isn't one; stop waiting for its end.
    private static let limit = 4 * 1024 * 1024

    var hasPending: Bool { !pending.isEmpty }

    mutating func feed(_ bytes: [UInt8]) -> [InputToken] {
        pending += bytes
        guard pending.count <= Self.limit else { return flush() }

        var tokens: [InputToken] = []
        var textStart = 0
        var index = 0
        while index < pending.count {
            guard pending[index] == 0x1B else {
                index += 1
                continue
            }
            if index > textStart { tokens.append(.text(Array(pending[textStart..<index]))) }
            guard let length = Self.sequenceLength(pending, at: index) else {
                pending.removeFirst(index)
                return tokens
            }
            let sequence = Array(pending[index..<(index + length)])
            tokens.append(length == 1 ? .text(sequence) : .sequence(sequence))
            index += length
            textStart = index
        }
        if index > textStart { tokens.append(.text(Array(pending[textStart..<index]))) }
        pending.removeAll(keepingCapacity: true)
        return tokens
    }

    /// Nothing more came: whatever is waiting is what was typed.
    mutating func flush() -> [InputToken] {
        guard !pending.isEmpty else { return [] }
        defer { pending.removeAll(keepingCapacity: true) }
        return [.text(pending)]
    }

    /// The length of the sequence that starts with the ESC at `start`, or nil
    /// while it is still arriving. 1 is an ESC that begins nothing.
    static func sequenceLength(_ bytes: [UInt8], at start: Int) -> Int? {
        guard start + 1 < bytes.count else { return nil }
        switch bytes[start + 1] {
        case 0x5B: // CSI: parameters and intermediates, then one final byte
            var j = start + 2
            while j < bytes.count {
                switch bytes[j] {
                case 0x20...0x3F: j += 1
                case 0x40...0x7E: return j + 1 - start
                // Not a CSI after all: Alt-[ and whatever was typed next.
                default: return 2
                }
            }
            return nil

        case 0x4F: // SS3: one more byte
            return start + 2 < bytes.count ? 3 : nil

        case 0x5D, 0x50, 0x5F, 0x5E, 0x58: // OSC, DCS, APC, PM, SOS: to BEL or ST
            var j = start + 2
            while j < bytes.count {
                if bytes[j] == 0x07 { return j + 1 - start }
                if bytes[j] == 0x1B, j + 1 < bytes.count, bytes[j + 1] == 0x5C { return j + 2 - start }
                j += 1
            }
            return nil

        case 0x1B: // Escape, then the start of something else
            return 1

        default: // Alt and a key
            return 2
        }
    }
}

/// The markers a terminal puts around pasted text.
enum Paste {
    static let start = Array("\u{1b}[200~".utf8)
    static let end = Array("\u{1b}[201~".utf8)
}

/// A mouse report in the SGR encoding: `CSI < button ; column ; row M` or `m`.
///
/// `ResponseFilter` drops these, because a phone's touches are for scrolling
/// and never for clicking into a program on the Mac. A Mac's pointer is the
/// real thing, so here they are let through.
func isMouseReport(_ sequence: [UInt8]) -> Bool {
    sequence.count > 3 && sequence[1] == 0x5B && sequence[2] == 0x3C
        && (sequence.last == 0x4D || sequence.last == 0x6D)
}

/// The key that opens the list of terminals: Ctrl and a character.
///
/// A terminal sends it one of two ways. Usually as the control character
/// itself; but a program that asked for the kitty keyboard protocol with
/// every key reported gets `CSI code ; modifiers u` instead, and a key that
/// only worked at a shell prompt would be no way out of that program.
struct MenuKey: Equatable {
    let character: Character
    /// The control character.
    let byte: UInt8

    var name: String { "ctrl-\(character)" }

    private var code: UInt32 {
        character.lowercased().unicodeScalars.first?.value ?? 0
    }

    static let standard = MenuKey("\\")!

    /// `TABTERM_MENU_KEY=b` makes it Ctrl-B, for a keyboard where Ctrl-\ is a
    /// stretch or a program that wants it.
    static var configured: MenuKey {
        ProcessInfo.processInfo.environment["TABTERM_MENU_KEY"]
            .flatMap { $0.count == 1 ? $0.first : nil }
            .flatMap(MenuKey.init) ?? standard
    }

    init?(_ character: Character) {
        // Not Tab, Return or Escape, which Ctrl-I, Ctrl-M and Ctrl-[ are.
        guard let bytes = TerminalKey.control(character), bytes.count == 1,
              bytes[0] < 0x20, ![0x09, 0x0A, 0x0D, 0x1B].contains(bytes[0])
        else { return nil }
        self.character = character
        self.byte = bytes[0]
    }

    /// What kind of event `sequence` is for this key, if it is one at all.
    func event(in sequence: [UInt8]) -> Event? {
        guard sequence.count > 3, sequence[1] == 0x5B, sequence.last == 0x75 else { return nil }
        let body = String(decoding: sequence[2..<(sequence.count - 1)], as: UTF8.self)
        let fields = body.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }

        // `code:shifted:base ; modifiers:event`
        let key = fields[0].split(separator: ":", omittingEmptySubsequences: false)
        let state = fields[1].split(separator: ":", omittingEmptySubsequences: false)
        guard let pressed = key.first.flatMap({ UInt32($0) }), pressed == code,
              let modifiers = state.first.flatMap({ Int($0) })
        else { return nil }

        // Ctrl alone, whatever Caps Lock and Num Lock are doing.
        guard (modifiers - 1) & 0b0011_1111 == 0b100 else { return nil }
        return state.count > 1 && state[1] == "3" ? .release : .press
    }

    enum Event {
        case press
        /// Reported by a program that asked for key releases too. It belongs
        /// to a press that was taken, so it is taken as well.
        case release
    }

    /// The key as the program in the terminal expects to receive it.
    func bytes(keyboardFlags: Int) -> [UInt8] {
        keyboardFlags & 8 != 0 ? Array("\u{1b}[\(code);5u".utf8) : [byte]
    }
}

/// Takes out of a replay what would happen a second time.
///
/// Attaching replays a terminal's recent output, and some of what a program
/// wrote back then did something rather than showed something: rang the bell,
/// raised a notification, put text on the clipboard. Written to a second
/// terminal it does it again — every "Claude needs your attention" of the
/// last hour, at once, on attaching. Everything that draws is kept.
enum Replay {
    /// OSC numbers that act rather than draw: 9, 99 and 777 raise
    /// notifications, 52 writes the clipboard.
    private static let actions: Set<Int> = [9, 52, 99, 777]

    static func withoutSideEffects(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)

        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x07 {
                i += 1
                continue
            }
            guard byte == 0x1B, i + 1 < bytes.count else {
                out.append(byte)
                i += 1
                continue
            }

            switch bytes[i + 1] {
            case 0x5D: // OSC
                let (end, terminated) = stringEnd(bytes, from: i + 2, bellEnds: true)
                // One cut off by the end of the replay is kept: its tail is
                // still to come, and would print as text without its head.
                if !(terminated && actions.contains(number(bytes, from: i + 2))) {
                    out += bytes[i..<end]
                }
                i = end

            case 0x50, 0x5F, 0x5E, 0x58: // DCS, APC, PM, SOS: a BEL inside is data
                let (end, _) = stringEnd(bytes, from: i + 2, bellEnds: false)
                out += bytes[i..<end]
                i = end

            default:
                out.append(byte)
                i += 1
            }
        }
        return Data(out)
    }

    private static func stringEnd(_ bytes: [UInt8], from start: Int, bellEnds: Bool) -> (Int, Bool) {
        var j = start
        while j < bytes.count {
            if bellEnds, bytes[j] == 0x07 { return (j + 1, true) }
            if bytes[j] == 0x1B, j + 1 < bytes.count, bytes[j + 1] == 0x5C { return (j + 2, true) }
            j += 1
        }
        return (j, false)
    }

    private static func number(_ bytes: [UInt8], from start: Int) -> Int {
        var value = 0
        var j = start
        while j < bytes.count, (0x30...0x39).contains(bytes[j]), value < 100_000 {
            value = value * 10 + Int(bytes[j] - 0x30)
            j += 1
        }
        return j > start ? value : -1
    }
}

import Foundation

/// The terminal settings a program switches on once and then relies on.
///
/// A program enters the alternate screen, turns on bracketed paste or hides
/// the cursor when it starts, and never says so again. A client that joins
/// later — a phone opening a terminal mid-session — only sees what comes after,
/// so these have to be re-asserted to it before anything else. That is all this
/// is for: it is not a terminal emulator, and it knows nothing about the
/// screen's contents.
public struct TerminalModes: Equatable, Sendable {
    /// DECCKM: arrow keys send `ESC O A` rather than `ESC [ A`.
    public var applicationCursor = false
    /// DECAWM.
    public var autowrap = true
    /// DECTCEM.
    public var cursorVisible = true
    /// Which alternate-screen mode is active (47, 1047 or 1049), if any.
    public var alternateScreen: Int?
    /// Which mouse tracking mode is on (9, 1000, 1002 or 1003), if any.
    public var mouseTracking: Int?
    /// Mouse report encodings that are on (1005, 1006, 1015, 1016).
    public var mouseEncodings: Set<Int> = []
    public var focusReporting = false
    public var bracketedPaste = false
    /// DECKPAM (`ESC =`) versus DECKPNM (`ESC >`).
    public var applicationKeypad = false
    /// DECSCUSR's parameter, when a program chose a cursor shape.
    public var cursorStyle: Int?
    /// The kitty keyboard protocol keeps one stack per screen. Each starts
    /// with a base entry that `CSI = … u` edits when nothing was pushed.
    public var mainKeyboardStack: [Int] = [0]
    public var alternateKeyboardStack: [Int] = [0]

    public init() {}

    public var keyboardFlags: Int {
        (alternateScreen == nil ? mainKeyboardStack : alternateKeyboardStack).last ?? 0
    }

    /// Bytes that put a freshly reset terminal into these modes.
    ///
    /// The alternate screen goes first: entering it clears it, and anything
    /// that applies per screen has to land on the right one.
    public var preamble: Data {
        var out = ""
        let csi = "\u{1b}["

        if let alternateScreen { out += "\(csi)?\(alternateScreen)h" }
        if applicationCursor { out += "\(csi)?1h" }
        if !autowrap { out += "\(csi)?7l" }
        if !cursorVisible { out += "\(csi)?25l" }
        if let mouseTracking { out += "\(csi)?\(mouseTracking)h" }
        for encoding in mouseEncodings.sorted() { out += "\(csi)?\(encoding)h" }
        if focusReporting { out += "\(csi)?1004h" }
        if bracketedPaste { out += "\(csi)?2004h" }
        if applicationKeypad { out += "\u{1b}=" }
        if let cursorStyle { out += "\(csi)\(cursorStyle) q" }
        if keyboardFlags != 0 { out += "\(csi)=\(keyboardFlags);1u" }
        return Data(out.utf8)
    }

    /// Bytes that take a terminal in these modes back to a fresh one's,
    /// leaving what it shows alone.
    ///
    /// The opposite of `preamble`, for a client that is letting go of a
    /// terminal it doesn't own — its own window, which the user gets back —
    /// and so can't simply reset it. The keyboard flags are per screen: the
    /// alternate screen's are cleared before leaving it, the main screen's
    /// after.
    public var undo: Data {
        var out = ""
        let csi = "\u{1b}["

        if keyboardFlags != 0 { out += "\(csi)=0;1u" }
        if let alternateScreen {
            out += "\(csi)?\(alternateScreen)l"
            if (mainKeyboardStack.last ?? 0) != 0 { out += "\(csi)=0;1u" }
        }
        if applicationCursor { out += "\(csi)?1l" }
        if !autowrap { out += "\(csi)?7h" }
        if !cursorVisible { out += "\(csi)?25h" }
        if let mouseTracking { out += "\(csi)?\(mouseTracking)l" }
        for encoding in mouseEncodings.sorted() { out += "\(csi)?\(encoding)l" }
        if focusReporting { out += "\(csi)?1004l" }
        if bracketedPaste { out += "\(csi)?2004l" }
        if applicationKeypad { out += "\u{1b}>" }
        if cursorStyle != nil { out += "\(csi)0 q" }
        return Data(out.utf8)
    }

    fileprivate mutating func setPrivate(_ mode: Int, _ on: Bool) {
        switch mode {
        case 1: applicationCursor = on
        case 7: autowrap = on
        case 25: cursorVisible = on
        case 47, 1047, 1049:
            if on {
                alternateScreen = mode
            } else if alternateScreen != nil {
                alternateScreen = nil
            }
        case 9, 1000, 1002, 1003:
            if on {
                mouseTracking = mode
            } else if mouseTracking == mode {
                mouseTracking = nil
            }
        case 1005, 1006, 1015, 1016:
            if on { mouseEncodings.insert(mode) } else { mouseEncodings.remove(mode) }
        case 1004: focusReporting = on
        case 2004: bracketedPaste = on
        default: break
        }
    }

    fileprivate mutating func editKeyboardStack(_ edit: (inout [Int]) -> Void) {
        if alternateScreen == nil {
            edit(&mainKeyboardStack)
        } else {
            edit(&alternateKeyboardStack)
        }
    }

    /// DECSTR: the modes a soft reset puts back.
    fileprivate mutating func softReset() {
        applicationCursor = false
        applicationKeypad = false
        cursorVisible = true
        autowrap = true
    }
}

/// Watches a terminal's output stream for mode changes.
///
/// A small escape-sequence parser that understands just enough to find the
/// sequences `TerminalModes` cares about, and to know which bytes are inside
/// some other sequence — so a `?2004h` quoted in a window title isn't mistaken
/// for the real thing. It is a value type, so it can be copied to remember the
/// modes at a point in the stream and fed forward from there.
public struct ModeTracker: Equatable, Sendable {
    public private(set) var modes = TerminalModes()

    private enum State: Equatable, Sendable {
        case ground
        case escape
        /// `ESC` then intermediates, waiting for the final byte (charsets).
        case escapeIntermediate
        case csi
        /// OSC, DCS, APC, PM or SOS, skipped until BEL or ST.
        case string(allowsBell: Bool)
        /// Inside a string, just after an `ESC` that may begin ST.
        case stringEscape(allowsBell: Bool)
    }

    private var state: State = .ground
    private var params: [UInt8] = []
    private var intermediates: [UInt8] = []
    private var overflow = false

    /// Long enough for any real mode sequence; anything longer is junk.
    private static let maxSequence = 64

    public init() {}

    public mutating func feed(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            feed(UnsafeBufferPointer(start: base, count: raw.count))
        }
    }

    public mutating func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    public mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        var index = 0
        let count = bytes.count
        while index < count {
            // Most output is plain text: skip straight to the next escape.
            if state == .ground {
                guard let next = Self.nextSpecial(bytes, from: index) else { return }
                index = next
            }
            step(bytes[index])
            index += 1
        }
    }

    private static func nextSpecial(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var i = start
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x1B { return i }
            i += 1
        }
        return nil
    }

    private mutating func step(_ byte: UInt8) {
        // CAN and SUB abandon whatever sequence was in progress.
        if byte == 0x18 || byte == 0x1A {
            if case .string = state { state = .ground; return }
            if case .stringEscape = state { state = .ground; return }
            state = .ground
            return
        }

        switch state {
        case .ground:
            if byte == 0x1B { state = .escape }

        case .escape:
            beginEscape(byte)

        case .escapeIntermediate:
            if byte == 0x1B {
                state = .escape
            } else if (0x30...0x7E).contains(byte) {
                state = .ground
            } else if !(0x20...0x2F).contains(byte) {
                state = .ground
            }

        case .csi:
            switch byte {
            case 0x1B:
                state = .escape
            case 0x30...0x3F:
                if params.count < Self.maxSequence { params.append(byte) } else { overflow = true }
            case 0x20...0x2F:
                if intermediates.count < 4 { intermediates.append(byte) } else { overflow = true }
            case 0x40...0x7E:
                if !overflow { dispatchCSI(final: byte) }
                state = .ground
            default:
                // C0 controls inside a CSI are executed, not part of it.
                break
            }

        case .string(let allowsBell):
            if byte == 0x1B {
                state = .stringEscape(allowsBell: allowsBell)
            } else if byte == 0x07, allowsBell {
                state = .ground
            }

        case .stringEscape(let allowsBell):
            if byte == 0x5C {
                state = .ground
            } else if byte == 0x1B {
                state = .stringEscape(allowsBell: allowsBell)
            } else {
                state = .string(allowsBell: allowsBell)
            }
        }
    }

    private mutating func beginEscape(_ byte: UInt8) {
        switch byte {
        case 0x5B: // [
            state = .csi
            params.removeAll(keepingCapacity: true)
            intermediates.removeAll(keepingCapacity: true)
            overflow = false
        case 0x5D: // ] OSC ends at BEL or ST
            state = .string(allowsBell: true)
        case 0x50, 0x5F, 0x5E, 0x58: // P DCS, _ APC, ^ PM, X SOS
            state = .string(allowsBell: false)
        case 0x3D: // = DECKPAM
            modes.applicationKeypad = true
            state = .ground
        case 0x3E: // > DECKPNM
            modes.applicationKeypad = false
            state = .ground
        case 0x63: // c RIS
            modes = TerminalModes()
            state = .ground
        case 0x1B:
            state = .escape
        case 0x20...0x2F:
            state = .escapeIntermediate
        default:
            state = .ground
        }
    }

    private mutating func dispatchCSI(final: UInt8) {
        // 0 when there is no private-parameter prefix (`?`, `>`, `<`, `=`).
        let prefix: UInt8 = params.first.map { (0x3C...0x3F).contains($0) ? $0 : 0 } ?? 0
        let numbers = Self.numbers(prefix == 0 ? params[...] : params.dropFirst())
        let first = numbers.first.flatMap { $0 }
        let intermediate: UInt8 = intermediates.count == 1 ? intermediates[0] : (intermediates.isEmpty ? 0 : 0xFF)

        switch (prefix, intermediate, final) {
        case (0x3F, 0, 0x68): // CSI ? Pm h
            for mode in numbers { modes.setPrivate(mode ?? 0, true) }
        case (0x3F, 0, 0x6C): // CSI ? Pm l
            for mode in numbers { modes.setPrivate(mode ?? 0, false) }

        case (0, 0x20, 0x71): // CSI Ps SP q  DECSCUSR
            let style = first ?? 0
            modes.cursorStyle = style == 0 ? nil : style

        case (0, 0x21, 0x70): // CSI ! p  DECSTR
            modes.softReset()

        case (0x3E, 0, 0x75): // CSI > flags u  push
            let flags = first ?? 0
            modes.editKeyboardStack { stack in
                stack.append(flags)
                // Kitty caps the stack; the oldest pushes fall off the bottom
                // above the base entry.
                if stack.count > 16 { stack.remove(at: 1) }
            }
        case (0x3C, 0, 0x75): // CSI < n u  pop
            let count = max(first ?? 1, 1)
            modes.editKeyboardStack { stack in
                if count >= stack.count {
                    stack = [0]
                } else {
                    stack.removeLast(count)
                }
            }
        case (0x3D, 0, 0x75): // CSI = flags ; mode u  set
            let flags = first ?? 0
            let how = numbers.count > 1 ? (numbers[1] ?? 1) : 1
            modes.editKeyboardStack { stack in
                let current = stack.last ?? 0
                let next: Int
                switch how {
                case 2: next = current | flags
                case 3: next = current & ~flags
                default: next = flags
                }
                stack[stack.count - 1] = next
            }

        default:
            break
        }
    }

    /// Semicolon-separated parameters. Empty ones are nil, which each
    /// sequence reads as its own default.
    private static func numbers(_ bytes: ArraySlice<UInt8>) -> [Int?] {
        var result: [Int?] = []
        var current: Int?
        for byte in bytes {
            switch byte {
            case 0x30...0x39:
                current = (current ?? 0) &* 10 &+ Int(byte - 0x30)
                if current! > 99_999 { current = 99_999 }
            case 0x3B:
                result.append(current)
                current = nil
            default:
                // Sub-parameters (`:`) and stray prefixes don't matter here.
                break
            }
        }
        result.append(current)
        return result
    }
}

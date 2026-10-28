import Foundation

/// Keys a phone keyboard doesn't have, as the bytes a terminal sends for them.
public enum TerminalKey: String, CaseIterable, Codable, Sendable {
    case escape, tab, backTab, enter, backspace
    case up, down, left, right
    case home, end, pageUp, pageDown
    case ctrlC, ctrlD, ctrlZ, ctrlL, ctrlR

    /// The bytes to send.
    ///
    /// `applicationCursor` is DECCKM: a full-screen program that turned it on
    /// expects arrows as `ESC O A` rather than `ESC [ A`.
    public func bytes(applicationCursor: Bool = false) -> [UInt8] {
        let arrowIntroducer: [UInt8] = applicationCursor ? [0x1B, 0x4F] : [0x1B, 0x5B]
        switch self {
        case .escape: return [0x1B]
        case .tab: return [0x09]
        case .backTab: return [0x1B, 0x5B, 0x5A]
        case .enter: return [0x0D]
        case .backspace: return [0x7F]
        case .up: return arrowIntroducer + [0x41]
        case .down: return arrowIntroducer + [0x42]
        case .right: return arrowIntroducer + [0x43]
        case .left: return arrowIntroducer + [0x44]
        case .home: return arrowIntroducer + [0x48]
        case .end: return arrowIntroducer + [0x46]
        case .pageUp: return Array("\u{1b}[5~".utf8)
        case .pageDown: return Array("\u{1b}[6~".utf8)
        case .ctrlC: return [0x03]
        case .ctrlD: return [0x04]
        case .ctrlZ: return [0x1A]
        case .ctrlL: return [0x0C]
        case .ctrlR: return [0x12]
        }
    }

    /// The control character for Ctrl plus a letter, or nil for anything that
    /// has none.
    public static func control(_ character: Character) -> [UInt8]? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x40...0x5F: return [ascii - 0x40]         // @ A-Z [ \ ] ^ _
        case 0x61...0x7A: return [ascii - 0x60]         // a-z
        case 0x3F: return [0x7F]                        // ?
        case 0x20: return [0x00]                        // space
        default: return nil
        }
    }
}

import SwiftTerm
import SwiftUI
import UIKit

/// The look of the terminal and the chrome around it.
///
/// Dark and quiet, so the terminal's own colours are what stands out. The
/// ANSI palette is Ghostty's default, since that is what the same output looks
/// like on the Mac.
enum TerminalTheme {
    static let background = UIColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1)
    static let foreground = UIColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
    static let caret = UIColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    /// The bars under the terminal: a step up from the terminal's black.
    static let chrome = SwiftUI.Color(red: 0.086, green: 0.090, blue: 0.106)
    static let key = SwiftUI.Color(red: 0.165, green: 0.169, blue: 0.192)
    static let keyPressed = SwiftUI.Color(red: 0.24, green: 0.245, blue: 0.275)
    static let hairline = SwiftUI.Color.white.opacity(0.08)

    /// Claude's orange, the same the Mac uses for the working dot and the mark.
    static let claude = SwiftUI.Color(red: 0.851, green: 0.467, blue: 0.341)

    /// The soft blue behind the worktree the Mac has on screen, as its
    /// sidebar tints the same row.
    static let onScreen = SwiftUI.Color.blue.opacity(0.2)

    /// Columns to aim for in portrait. Enough for Claude Code's layout to
    /// hold together, big enough to read without zooming.
    static let targetColumns: CGFloat = 48

    /// A monospaced font sized so `targetColumns` fit across `width`.
    static func font(forWidth width: CGFloat) -> UIFont {
        let probe = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let advance = ("W" as NSString).size(withAttributes: [.font: probe]).width / 10
        let size = width > 0 ? width / targetColumns / advance : 13
        return UIFont.monospacedSystemFont(ofSize: min(max(size.rounded(.down), 10), 15), weight: .regular)
    }

    /// Ghostty's default 16 colours.
    static let palette: [SwiftTerm.Color] = {
        let rgb: [(UInt16, UInt16, UInt16)] = [
            (0x1D, 0x1F, 0x21), (0xCC, 0x66, 0x66), (0xB5, 0xBD, 0x68), (0xF0, 0xC6, 0x74),
            (0x81, 0xA2, 0xBE), (0xB2, 0x94, 0xBB), (0x8A, 0xBE, 0xB7), (0xC5, 0xC8, 0xC6),
            (0x66, 0x66, 0x66), (0xD5, 0x4E, 0x53), (0xB9, 0xCA, 0x4A), (0xE7, 0xC5, 0x47),
            (0x7A, 0xA6, 0xDA), (0xC3, 0x97, 0xD8), (0x70, 0xC0, 0xB1), (0xEA, 0xEA, 0xEA),
        ]
        return rgb.map { SwiftTerm.Color(red8: $0.0, green8: $0.1, blue8: $0.2) }
    }()

    static func apply(to view: TerminalView) {
        view.backgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = caret
        view.installColors(palette)
        view.font = font(forWidth: UIScreen.main.bounds.width)
    }
}

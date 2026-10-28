import Foundation
import TabTermKit

extension PaneInfo {
    /// The title without the status glyph Claude Code puts in front of it.
    ///
    /// Claude Code titles its terminal `✳ Fix the tests`, swapping the `✳` for
    /// a braille spinner while it works. The Mac shows that as-is in a tab; on
    /// the phone the `✳` renders as a green emoji, and the dot beside the row
    /// already says what the glyph was trying to.
    var displayTitle: String {
        let stripped = Self.strippingStatusGlyph(title)
        return stripped.isEmpty ? title : stripped
    }

    static func strippingStatusGlyph(_ title: String) -> String {
        var scalars = Substring.UnicodeScalarView(title.unicodeScalars)
        var removed = false
        while let first = scalars.first, isStatusGlyph(first) {
            scalars.removeFirst()
            removed = true
        }
        guard removed else { return title }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    private static func isStatusGlyph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2800...0x28FF: return true           // braille spinner frames
        case 0xFE0E, 0xFE0F: return true            // variation selectors
        default: return "✳✻✽✶✢✦✧·•*".unicodeScalars.contains(scalar)
        }
    }
}

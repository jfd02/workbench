import AppKit

/// Keeps the source text intact for selection and copying. Only actual patch
/// bodies get addition/deletion styling; file headers and raw previews do not.
struct ReviewDiffPresentation {
    // Semantic system colors are too bright for small code text in light mode.
    static let addedColor = ink(light: 0x18733A, dark: 0x80D99C)
    static let removedColor = ink(light: 0xB42336, dark: 0xFF929C)
    static let hunkColor = ink(light: 0x245EB5, dark: 0x8EBEFF)

    private static func ink(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }

    let attributedText: NSAttributedString
    let statistics: NSAttributedString
    let hunks: [NSRange]
    let additions: Int
    let deletions: Int

    init(text: String, isDiff: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 28.8
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ])
        var hunks: [NSRange] = []
        var additions = 0
        var deletions = 0
        var position = 0
        var inHunk = false
        // Combined conflict diffs use multiple prefix columns; don't report
        // misleading ordinary +/- totals for those patches.
        var combined = false
        if isDiff {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let length = (String(line) as NSString).length
                let range = NSRange(location: position, length: length)
                var foreground: NSColor?
                var background: NSColor?
                if line.hasPrefix("diff ") {
                    inHunk = false
                    foreground = .secondaryLabelColor
                } else if line.hasPrefix("@@") {
                    inHunk = true
                    combined = line.hasPrefix("@@@")
                    hunks.append(range)
                    foreground = Self.hunkColor
                    background = Self.hunkColor.withAlphaComponent(0.08)
                } else if inHunk && !combined && line.hasPrefix("+") {
                    additions += 1
                    foreground = Self.addedColor
                    background = Self.addedColor.withAlphaComponent(0.10)
                } else if inHunk && !combined && line.hasPrefix("-") {
                    deletions += 1
                    foreground = Self.removedColor
                    background = Self.removedColor.withAlphaComponent(0.10)
                } else if !inHunk || line.hasPrefix("\\ No newline") {
                    foreground = .secondaryLabelColor
                }
                if let foreground { result.addAttribute(.foregroundColor, value: foreground, range: range) }
                if let background { result.addAttribute(.backgroundColor, value: background, range: range) }
                position += length + 1
            }
        }
        self.attributedText = result
        self.hunks = hunks
        self.additions = additions
        self.deletions = deletions
        let stats = NSMutableAttributedString(string: "")
        if additions + deletions > 0 {
            stats.append(NSAttributedString(string: "+\(additions)", attributes: [.foregroundColor: Self.addedColor]))
            stats.append(NSAttributedString(string: "  −\(deletions)", attributes: [.foregroundColor: Self.removedColor]))
        }
        self.statistics = stats
    }
}

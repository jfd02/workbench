import AppKit

/// The mark a tab shows while its terminal is running Claude Code.
///
/// Drawn from an SF Symbol in Claude's orange, so it reads as "Claude is
/// working in here" at tab-bar size. Drop a `claude.png` into
/// `Resources/Icons/` and that is used instead — `scripts/bundle.sh` copies
/// the folder into the app when it exists.
enum ClaudeIcon {
    /// #D97757.
    static let color = NSColor(red: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)

    static let image: NSImage? = make()

    private static func make() -> NSImage? {
        if let bundled = Bundle.main.image(forResource: "claude") {
            bundled.size = NSSize(width: 14, height: 14)
            bundled.isTemplate = false
            return bundled
        }

        let symbol = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Claude")
            ?? NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude")
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))

        let image = symbol?.withSymbolConfiguration(configuration)
        // Not a template: the tab bar tints template images with the label
        // color, which would throw the orange away.
        image?.isTemplate = false
        return image
    }
}

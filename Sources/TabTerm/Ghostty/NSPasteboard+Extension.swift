import AppKit

extension Ghostty {
    enum Shell {
        /// Characters a shell would otherwise treat specially.
        private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

        /// Backslash-escape shell-sensitive characters, so a path pastes as
        /// one word. Matches Ghostty's own escaping.
        static func escape(_ string: String) -> String {
            var result = string
            for character in escapeCharacters {
                result = result.replacingOccurrences(
                    of: String(character),
                    with: "\\\(character)"
                )
            }
            return result
        }
    }
}

extension NSPasteboard {
    /// What pasting or dropping this into a terminal should type.
    ///
    /// Files become their escaped paths, space-separated, the way Ghostty does
    /// it. That's what lets tools like Claude Code recognise a dropped image:
    /// they see a pasted path to an image file and attach it.
    func terminalStringContents() -> String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? Ghostty.Shell.escape($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }
        return string(forType: .string)
    }
}

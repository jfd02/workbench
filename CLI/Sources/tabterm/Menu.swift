import Foundation
import TabTermKit

/// The list of terminals shown over an attached one: the Mac's sidebar, with
/// each workspace's terminals under it and the agent dots beside them.
///
/// It is the one piece of interface `workbench` draws. Everything else on
/// screen is the terminal's own output passed straight through, which is why
/// this is a list you call up rather than a sidebar that is always there —
/// sharing the screen with a terminal means redrawing that terminal yourself.
struct Menu {
    struct Row: Equatable {
        enum Target: Equatable {
            case terminal(UUID)
            /// A worktree nobody has opened since Workbench started. Choosing it
            /// starts its terminals.
            case unopened
            /// A workspace whose every tab was closed. Choosing it opens one.
            case empty
        }

        /// Nil for a workspace's heading, which can't be chosen.
        var target: Target?
        /// The id of the workspace this row belongs to.
        var workspace: String
        var text: String
        var detail = ""
        var status = AgentStatus.idle
    }

    let hostName: String
    let keyName: String
    private(set) var rows: [Row] = []
    private var selection = 0

    /// A line under the title: what just happened, or what is being waited for.
    var notice: String?
    /// Put up by `workbench` to say the connection dropped, rather than asked
    /// for — so it takes itself down again when the connection comes back.
    var isAutomatic = false
    /// Whether there is a terminal behind the list to go back to.
    var canGoBack = true

    init(hostName: String, keyName: String) {
        self.hostName = hostName
        self.keyName = keyName
    }

    // MARK: - Rows

    /// Rebuild from the sidebar, keeping the selection on what it was on.
    mutating func update(_ state: HostState) {
        let previous = selected
        rows = state.workspaces.flatMap { workspace -> [Row] in
            var rows = [Row(target: nil, workspace: workspace.id, text: Catalog.label(workspace))]
            if !workspace.isOpen {
                rows.append(Row(target: .unopened, workspace: workspace.id, text: "not open", detail: "⏎ starts its terminals"))
            } else if workspace.tabs.isEmpty {
                rows.append(Row(target: .empty, workspace: workspace.id, text: "no terminals", detail: "⏎ opens one"))
            }
            for entry in Catalog.entries(in: workspace) {
                let (title, detail) = Catalog.describe(entry.pane)
                rows.append(Row(
                    target: .terminal(entry.pane.session),
                    workspace: workspace.id,
                    text: title,
                    detail: detail,
                    status: entry.pane.status
                ))
            }
            return rows
        }

        let kept = previous.flatMap { old in
            rows.firstIndex { $0.target == old.target && $0.workspace == old.workspace }
        }
        selection = kept ?? choosable.first ?? 0
    }

    private var choosable: [Int] {
        rows.indices.filter { rows[$0].target != nil }
    }

    var selected: Row? {
        rows.indices.contains(selection) && rows[selection].target != nil ? rows[selection] : nil
    }

    mutating func select(_ session: UUID) {
        if let index = rows.firstIndex(where: { $0.target == .terminal(session) }) { selection = index }
    }

    mutating func move(_ delta: Int) {
        let indices = choosable
        guard let current = indices.firstIndex(of: selection) else {
            selection = indices.first ?? 0
            return
        }
        selection = indices[min(max(current + delta, 0), indices.count - 1)]
    }

    /// The row a digit jumps to: the first nine that can be chosen are numbered.
    func row(numbered number: Int) -> Row? {
        let indices = choosable
        return (1...9).contains(number) && number <= indices.count ? rows[indices[number - 1]] : nil
    }

    // MARK: - Drawing

    /// Switched on for as long as the list is up: its own screen, so the
    /// terminal underneath is still there afterwards; no cursor; lines that
    /// are cut at the edge rather than wrapped; and pastes marked, so a paste
    /// that misses its target isn't read as a string of commands.
    static let enter = "\u{1b}[?1049h\u{1b}[?25l\u{1b}[?7l\u{1b}[?2004h"
    static let leave = "\u{1b}[?2004l\u{1b}[?7h\u{1b}[?25h\u{1b}[?1049l"

    /// The whole screen, to be written in one go.
    func render(size: TerminalSize) -> String {
        let width = size.cols
        var lines = ["\u{1b}[1m Workbench on \(clip(hostName, width - 14))\u{1b}[0m"]
        lines.append(notice.map { "\u{1b}[33m \(clip($0, width - 1))\u{1b}[0m" } ?? "")

        // Whatever is left between those two lines and the hints at the
        // bottom is a window onto the rows, kept around the selection.
        let space = max(size.rows - 3, 1)
        let top = min(max(selection - space / 2, 0), max(rows.count - space, 0))
        let numbers = Dictionary(uniqueKeysWithValues: zip(choosable.prefix(9), 1...9))
        for index in rows.indices.dropFirst(top).prefix(space) {
            lines.append(render(rows[index], number: numbers[index], isSelected: index == selection, width: width))
        }
        while lines.count < size.rows - 1 { lines.append("") }

        // In the order they matter: a narrow terminal cuts the end off.
        var hints = "⏎ open · 1-9 jump · n new tab · q detach"
        if canGoBack { hints += " · esc back · \(keyName) twice types it" }
        lines.append("\u{1b}[2m \(clip(hints, width - 1))\u{1b}[0m")

        return "\u{1b}[H" + lines.prefix(size.rows).map { "\u{1b}[2K" + $0 }.joined(separator: "\r\n")
    }

    private func render(_ row: Row, number: Int?, isSelected: Bool, width: Int) -> String {
        guard row.target != nil else {
            return "\u{1b}[1m \(clip(row.text, width - 1))\u{1b}[0m"
        }

        let status = Catalog.word(for: row.status).map { "● \($0)" } ?? ""
        let prefix = " \(number.map(String.init) ?? " ")  "
        // The title gets what the status leaves, and the detail what the
        // title leaves.
        var room = width - prefix.count - (status.isEmpty ? 0 : status.count + 2)
        let text = clip(row.text, room)
        room -= text.count + 2
        let detail = room > 6 ? clip(row.detail, room) : ""

        let dim = isSelected ? "" : "\u{1b}[2m"
        let plain = isSelected ? "\u{1b}[0;7m" : "\u{1b}[0m"
        var line = (isSelected ? "\u{1b}[7m" : "") + dim + prefix + plain + text
        var used = prefix.count + text.count
        if !detail.isEmpty {
            line += "  " + dim + detail + plain
            used += 2 + detail.count
        }
        if !status.isEmpty {
            // A selected row is drawn in reverse, where a colour would be the
            // background; the word carries it there.
            line += "  " + (isSelected ? status : "\u{1b}[\(Catalog.color(for: row.status))m\(status)\(plain)")
            used += 2 + status.count
        }
        if isSelected { line += String(repeating: " ", count: max(width - used, 0)) }
        return line + "\u{1b}[0m"
    }

    private func clip(_ text: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        return text.count <= width ? text : String(text.prefix(max(width - 1, 0))) + "…"
    }
}

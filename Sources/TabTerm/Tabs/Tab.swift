import AppKit

/// A single tab: a tree of panes, plus which one holds the keyboard.
///
/// A tab starts as one pane and grows a split tree as the user splits panes or
/// drags other tabs in. Everything the window needs — title, focus, closing —
/// is answered in terms of the focused pane.
final class Tab {
    let id = UUID()

    /// Something the tab bar shows for this tab changed.
    var onTitleChange: (() -> Void)?

    /// A pane wants to close. `confirm` is true when the user asked for it and
    /// may be discarding something, false when the content already finished.
    var onPaneCloseRequest: ((_ paneID: UUID, _ confirm: Bool) -> Void)?

    /// A split binding fired inside one of the panes.
    var onSplitRequest: ((_ paneID: UUID, _ direction: SplitDirection) -> Void)?

    /// Asked whether a tab dragged from the tab bar may be dropped in here.
    var canAcceptTab: ((UUID) -> Bool)?

    /// A tab was dropped onto one of the panes.
    var onDropTab: ((_ tabID: UUID, _ target: SplitDropTarget) -> Void)?

    /// The focused pane changed, so the title and tab bar may need a refresh.
    var onFocusChange: (() -> Void)?

    private let tree: SplitTree
    private let container = SplitContainerView()

    private(set) var focusedPaneID: UUID?

    var view: NSView { container }

    var panes: [Pane] { tree.panes }
    var paneCount: Int { tree.paneCount }

    var agentIDs: [String] {
        panes.compactMap { ($0.content as? TerminalTabContent)?.agentID }
    }

    var focusedPane: Pane? {
        guard let focusedPaneID else { return panes.first }
        return tree.pane(for: focusedPaneID) ?? panes.first
    }

    /// The tab bar shows the focused pane's title and icon.
    var title: String { focusedPane?.content.title ?? "Workbench" }
    var icon: NSImage? { focusedPane?.content.icon }

    convenience init(content: TabContent) {
        self.init(pane: Pane(content: content))
    }

    /// Reuse a live pane when moving it out of another tab.
    init(pane: Pane) {
        tree = SplitTree(pane: pane)
        focusedPaneID = pane.id

        container.canAcceptTab = { [weak self] tabID in
            self?.canAcceptTab?(tabID) ?? false
        }
        container.onDropTab = { [weak self] tabID, target in
            self?.onDropTab?(tabID, target)
        }

        adopt(pane)
        container.tree = tree
        container.focusedPaneID = pane.id
    }

    /// Wire a pane's content back to this tab. Called for new panes and for
    /// panes that arrive from another tab.
    private func adopt(_ pane: Pane) {
        let paneID = pane.id

        pane.content.onTitleChange = { [weak self] _ in
            self?.onTitleChange?()
        }
        // Same refresh either way: the tab bar redraws from the tab.
        pane.content.onIconChange = { [weak self] _ in
            self?.onTitleChange?()
        }
        pane.content.onRequestClose = { [weak self] confirm in
            self?.onPaneCloseRequest?(paneID, confirm)
        }

        guard let terminal = pane.content as? TerminalTabContent else { return }
        terminal.onSplitRequest = { [weak self] direction in
            self?.onSplitRequest?(paneID, direction)
        }
        terminal.onFocusSplitRequest = { [weak self] target in
            self?.focusNeighbor(of: paneID, target)
        }
        terminal.onEqualizeSplitsRequest = { [weak self] in
            self?.equalizeSplits()
        }
    }

    func pane(for paneID: UUID) -> Pane? { tree.pane(for: paneID) }

    /// The pane tree, for saving the layout.
    var root: SplitNode { tree.root }

    /// Set the divider of the split that `paneID` sits directly under.
    ///
    /// Used when restoring: each split is recreated, then given back the
    /// divider position it had.
    func setRatio(_ ratio: CGFloat, ofSplitAbove paneID: UUID) {
        guard let branch = tree.leaf(for: paneID)?.parent else { return }
        branch.ratio = ratio
        container.rebuild()
    }

    // MARK: - Splitting

    /// Split `paneID`, putting `content` in the new pane, and focus it.
    @discardableResult
    func split(_ paneID: UUID, _ direction: SplitDirection, content: TabContent) -> Pane? {
        guard let target = tree.leaf(for: paneID) else { return nil }

        let pane = Pane(content: content)
        adopt(pane)
        tree.insert(SplitNode(pane: pane), direction, of: target)
        container.rebuild()
        focusPane(pane.id)
        return pane
    }

    /// Take in another tab's panes, beside `paneID`.
    func insert(_ node: SplitNode, _ direction: SplitDirection, of paneID: UUID) {
        guard let target = tree.leaf(for: paneID) else { return }

        for pane in node.panes { adopt(pane) }
        tree.insert(node, direction, of: target)
        container.rebuild()
        if let first = node.panes.first { focusPane(first.id) }
    }

    /// Hand this tab's panes to another tab. The tab must be discarded after.
    func detachRoot() -> SplitNode {
        let root = tree.root
        // Drop our views so the new owner can re-parent the content.
        container.tree = nil
        return root
    }

    /// Remove a split without closing its content. The last pane stays put.
    func detachPane(_ paneID: UUID) -> Pane? {
        guard let leaf = tree.leaf(for: paneID), let pane = leaf.pane else { return nil }
        let order = panes.map(\.id)
        guard tree.remove(leaf) else { return nil }

        container.rebuild()
        if focusedPaneID == paneID {
            let index = order.firstIndex(of: paneID) ?? 0
            let remaining = panes.map(\.id)
            // The destination tab will claim the keyboard after the move.
            focusPane(remaining[min(index, remaining.count - 1)], moveResponder: false)
        }
        return pane
    }

    /// Close one pane. Returns false when it was the last one, which means the
    /// whole tab should close.
    @discardableResult
    func removePane(_ paneID: UUID) -> Bool {
        guard let leaf = tree.leaf(for: paneID), let pane = leaf.pane else { return true }

        let order = panes.map(\.id)
        guard tree.remove(leaf) else { return false }

        pane.content.setVisible(false)
        pane.content.close()
        container.rebuild()

        // Focus the pane that took its place: the next one along, or the last.
        // Rebuilding drops the first responder, so the surviving focused pane
        // has to claim it again either way.
        if focusedPaneID == paneID {
            let index = order.firstIndex(of: paneID) ?? 0
            let remaining = panes.map(\.id)
            focusPane(remaining[min(index, remaining.count - 1)])
        } else if let focusedPaneID {
            focusPane(focusedPaneID)
        }
        return true
    }

    func equalizeSplits() {
        tree.root.equalize()
        container.applyStoredRatios()
    }

    // MARK: - Focus

    func focusPane(_ paneID: UUID, moveResponder: Bool = true) {
        guard tree.pane(for: paneID) != nil else { return }

        let changed = focusedPaneID != paneID
        focusedPaneID = paneID
        container.focusedPaneID = paneID
        syncPaneFocus()

        if moveResponder {
            // After layout, so a freshly created surface has its real size.
            DispatchQueue.main.async { [weak self] in
                self?.tree.pane(for: paneID)?.content.takeFocus()
            }
        }
        if changed { onFocusChange?() }
    }

    func focusNeighbor(of paneID: UUID, _ target: SplitFocusTarget) {
        let order = panes.map(\.id)
        guard order.count > 1, let index = order.firstIndex(of: paneID) else { return }

        switch target {
        case .previous:
            focusPane(order[(index - 1 + order.count) % order.count])
        case .next:
            focusPane(order[(index + 1) % order.count])
        case .up, .down, .left, .right:
            if let neighbor = container.neighborPane(of: paneID, target) {
                focusPane(neighbor)
            }
        }
    }

    /// Track focus wherever it lands by mapping the window's first responder
    /// back to the pane that contains it.
    func firstResponderDidChange(_ responder: NSResponder?) {
        var view = responder as? NSView
        while let current = view {
            if let host = current as? PaneHostView {
                if host.paneID != focusedPaneID {
                    focusPane(host.paneID, moveResponder: false)
                }
                return
            }
            view = current.superview
        }
    }

    func takeFocus() {
        guard let pane = focusedPane else { return }
        focusPane(pane.id)
    }

    /// Tell every pane whether it is the focused one, so an unfocused terminal
    /// dims its cursor instead of blinking away in the corner.
    private func syncPaneFocus(allUnfocused: Bool = false) {
        for pane in panes {
            pane.content.setFocused(!allUnfocused && pane.id == focusedPaneID)
        }
    }

    // MARK: - Lifecycle

    func setVisible(_ visible: Bool) {
        for pane in panes { pane.content.setVisible(visible) }
        syncPaneFocus(allUnfocused: !visible)
    }

    /// Close every pane. Called when the tab or the window goes away.
    func closeAll() {
        for pane in panes {
            pane.content.setVisible(false)
            pane.content.close()
        }
    }

    /// True when every pane is disposable, so closing needn't ask.
    var isDisposable: Bool {
        panes.allSatisfy(\.content.isDisposable)
    }

    /// One sentence for the close confirmation describing what is lost.
    var closeConfirmationDetail: String {
        let panes = self.panes
        guard panes.count > 1 else {
            return panes.first?.content.closeConfirmationDetail ?? "This tab will be closed."
        }

        let running = panes.filter {
            ($0.content as? TerminalTabContent)?.hasRunningProcess == true
        }.count

        if running == 1 {
            return "\(panes.count) splits will be closed, and a process still running in one of them will be killed."
        }
        if running > 1 {
            return "\(panes.count) splits will be closed, and \(running) processes still running in them will be killed."
        }
        return "\(panes.count) splits will be closed."
    }
}

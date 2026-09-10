import AppKit

/// Where a new pane goes, relative to an existing one.
enum SplitDirection {
    case right
    case down
    case left
    case up

    var orientation: SplitOrientation {
        switch self {
        case .right, .left: return .sideBySide
        case .down, .up: return .stacked
        }
    }

    /// True when the new pane takes the leading slot: left of, or above, the
    /// pane being split.
    var placesNewPaneFirst: Bool {
        self == .left || self == .up
    }
}

/// How a split arranges its two children.
enum SplitOrientation {
    /// Children left and right of a vertical divider.
    case sideBySide
    /// Children above and below a horizontal divider.
    case stacked
}

/// Which neighbouring pane a focus-movement binding is asking for.
enum SplitFocusTarget {
    case previous
    case next
    case up
    case down
    case left
    case right
}

/// One pane inside a tab: a piece of content plus a stable identity.
final class Pane {
    let id = UUID()
    let content: TabContent

    init(content: TabContent) {
        self.content = content
    }
}

/// A node in a tab's split tree: either a single pane, or two children split
/// side by side or stacked.
///
/// Nodes are a tree rather than a list because splits nest: splitting the right
/// half of a tab again divides only that half.
final class SplitNode {
    /// The pane held by a leaf. nil for a branch.
    let pane: Pane?

    private(set) var orientation: SplitOrientation?
    private(set) var first: SplitNode?
    private(set) var second: SplitNode?

    /// Fraction of the node's length given to `first`. Branches only.
    var ratio: CGFloat = 0.5

    weak var parent: SplitNode?

    init(pane: Pane) {
        self.pane = pane
    }

    init(orientation: SplitOrientation, first: SplitNode, second: SplitNode) {
        pane = nil
        self.orientation = orientation
        self.first = first
        self.second = second
        first.parent = self
        second.parent = self
    }

    var isLeaf: Bool { pane != nil }

    var children: [SplitNode] {
        guard let first, let second else { return [] }
        return [first, second]
    }

    /// Every pane under this node, left to right and top to bottom.
    var panes: [Pane] {
        if let pane { return [pane] }
        return children.flatMap(\.panes)
    }

    var leaves: [SplitNode] {
        if isLeaf { return [self] }
        return children.flatMap(\.leaves)
    }

    func leaf(for paneID: UUID) -> SplitNode? {
        leaves.first { $0.pane?.id == paneID }
    }

    /// Reset every divider under this node to the middle.
    func equalize() {
        ratio = 0.5
        for child in children { child.equalize() }
    }

    /// Swap one child for another, keeping the slot it occupied.
    ///
    /// The outgoing child's `parent` is left alone: callers sometimes move it
    /// under the incoming node, and clearing it here would undo that.
    fileprivate func replace(_ child: SplitNode, with node: SplitNode) {
        if first === child {
            first = node
        } else if second === child {
            second = node
        } else {
            return
        }
        node.parent = self
    }
}

/// The panes of one tab, as a tree of splits.
final class SplitTree {
    private(set) var root: SplitNode

    init(pane: Pane) {
        root = SplitNode(pane: pane)
    }

    var panes: [Pane] { root.panes }
    var paneCount: Int { root.leaves.count }

    func leaf(for paneID: UUID) -> SplitNode? { root.leaf(for: paneID) }

    func pane(for paneID: UUID) -> Pane? { leaf(for: paneID)?.pane }

    /// Put `node` beside `target`, dividing the space `target` occupies.
    func insert(_ node: SplitNode, _ direction: SplitDirection, of target: SplitNode) {
        let parent = target.parent
        let branch = direction.placesNewPaneFirst
            ? SplitNode(orientation: direction.orientation, first: node, second: target)
            : SplitNode(orientation: direction.orientation, first: target, second: node)

        if let parent {
            parent.replace(target, with: branch)
        } else {
            branch.parent = nil
            root = branch
        }
    }

    /// Drop a node. Its sibling takes over the space they shared.
    ///
    /// Returns false when the node was the last one, which means the whole tab
    /// is now empty and the caller should close it.
    @discardableResult
    func remove(_ node: SplitNode) -> Bool {
        guard let parent = node.parent,
              let sibling = parent.first === node ? parent.second : parent.first
        else { return false }

        if let grandparent = parent.parent {
            grandparent.replace(parent, with: sibling)
        } else {
            sibling.parent = nil
            root = sibling
        }

        node.parent = nil
        return true
    }
}

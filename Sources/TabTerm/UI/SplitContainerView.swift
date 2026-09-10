import AppKit

/// Where a tab being dragged would land: which pane it is over, and which half
/// of that pane it would take.
struct SplitDropTarget: Equatable {
    let paneID: UUID
    let direction: SplitDirection
}

/// One pane's slot in the layout: the content view, plus the wash that dims it
/// while another pane has focus.
final class PaneHostView: NSView {
    let paneID: UUID

    var isFocused: Bool = false {
        didSet { updateDimming() }
    }

    /// Only dimmed when the tab is actually split; a lone pane is never dim.
    var isSplit: Bool = false {
        didSet { updateDimming() }
    }

    /// Ghostty dims inactive splits by washing them with `unfocused-split-fill`
    /// at `1 - unfocused-split-opacity`. This is that wash, as a sibling above
    /// the content because the terminal draws through its own Metal layer.
    private let dimming = DimmingView()

    init(paneID: UUID, content: NSView) {
        self.paneID = paneID
        super.init(frame: .zero)

        wantsLayer = true

        content.translatesAutoresizingMaskIntoConstraints = false
        dimming.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(dimming)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),

            dimming.topAnchor.constraint(equalTo: topAnchor),
            dimming.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimming.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimming.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        updateDimming()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateDimming() {
        dimming.isHidden = isFocused || !isSplit
    }
}

/// The wash over an unfocused split.
private final class DimmingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let fill = GhosttyApp.shared.unfocusedSplitFill
        layer?.backgroundColor = fill
            .withAlphaComponent(1 - GhosttyApp.shared.unfocusedSplitOpacity)
            .cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Decoration only: clicks belong to the terminal underneath, so a click on
    /// a dimmed pane focuses it as usual.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The translucent rectangle showing where a dragged tab will land.
///
/// It sits above the panes rather than being drawn by them, because the
/// terminal renders through a Metal layer we can't draw into.
private final class DropHighlightView: NSView {
    var highlightRect: NSRect? {
        didSet {
            guard highlightRect != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Never intercept the mouse: this view is decoration only.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let highlightRect else { return }
        let path = NSBezierPath(
            roundedRect: highlightRect.insetBy(dx: 3, dy: 3),
            xRadius: 6,
            yRadius: 6
        )
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

/// The view for one tab: its split tree rendered as nested `NSSplitView`s, and
/// the drop target for tabs dragged in from the tab bar.
final class SplitContainerView: NSView, NSSplitViewDelegate {
    /// A pane can't be dragged smaller than this.
    private static let minimumPaneLength: CGFloat = 90

    static let tabPasteboardType = NSPasteboard.PasteboardType("com.tabterm.tab")

    /// The tree to display. Setting it rebuilds the view hierarchy.
    var tree: SplitTree? {
        didSet { rebuild() }
    }

    var focusedPaneID: UUID? {
        didSet { updateDimming() }
    }

    /// Asked whether a tab being dragged may be dropped here.
    var canAcceptTab: ((UUID) -> Bool)?

    /// Called when a tab is dropped onto a pane.
    var onDropTab: ((UUID, SplitDropTarget) -> Void)?

    private var hosts: [UUID: PaneHostView] = [:]
    private var nodesBySplitView: [ObjectIdentifier: SplitNode] = [:]
    private let highlight = DropHighlightView()
    private var dropTarget: SplitDropTarget?

    /// Set while we're setting subview frames ourselves, so the resulting
    /// delegate callback doesn't feed our own numbers back into the model.
    private var isApplyingRatios = false

    /// Fresh subviews have no frames yet, so the first layout has to place them.
    private var needsRatioPass = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        registerForDraggedTypes([Self.tabPasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Building

    /// Rebuild the whole hierarchy from the tree.
    ///
    /// Splits are rare, and content views are owned by their panes, so throwing
    /// the views away and re-adding them is simpler than patching the tree in
    /// place. Divider positions survive because they live in the model.
    func rebuild() {
        for view in subviews where view !== highlight {
            view.removeFromSuperview()
        }
        hosts.removeAll()
        nodesBySplitView.removeAll()

        guard let tree else { return }

        let rootView = makeView(for: tree.root)
        rootView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootView, positioned: .below, relativeTo: highlight)
        NSLayoutConstraint.activate([
            rootView.topAnchor.constraint(equalTo: topAnchor),
            rootView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        updateDimming()
        needsRatioPass = true
        needsLayout = true
    }

    private func makeView(for node: SplitNode) -> NSView {
        let view: NSView
        if let pane = node.pane {
            let host = PaneHostView(paneID: pane.id, content: pane.content.view)
            hosts[pane.id] = host
            view = host
        } else {
            let splitView = NSSplitView()
            splitView.isVertical = node.orientation == .sideBySide
            splitView.dividerStyle = .thin
            splitView.delegate = self
            nodesBySplitView[ObjectIdentifier(splitView)] = node
            for child in node.children {
                let childView = makeView(for: child)
                // Children of a split view are positioned by frame, so their
                // autoresizing masks must stay in play.
                childView.translatesAutoresizingMaskIntoConstraints = true
                splitView.addSubview(childView)
            }
            view = splitView
        }
        return view
    }

    private func updateDimming() {
        let split = hosts.count > 1
        for (id, host) in hosts {
            host.isSplit = split
            host.isFocused = id == focusedPaneID
        }
    }

    // MARK: - Divider positions

    /// Re-apply the ratios held in the tree, after they change without the
    /// layout changing shape.
    func applyStoredRatios() {
        needsRatioPass = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard needsRatioPass, bounds.width > 0, bounds.height > 0 else { return }
        needsRatioPass = false
        for view in subviews where view !== highlight {
            applyRatios(in: view)
        }
    }

    private func applyRatios(in view: NSView) {
        guard let splitView = view as? NSSplitView else { return }
        applyRatio(to: splitView)
        for child in splitView.subviews {
            applyRatios(in: child)
        }
    }

    /// Lay a split view's two children out at the node's stored ratio.
    private func applyRatio(to splitView: NSSplitView) {
        guard let node = nodesBySplitView[ObjectIdentifier(splitView)],
              splitView.subviews.count == 2
        else { return }

        let first = splitView.subviews[0]
        let second = splitView.subviews[1]
        let thickness = splitView.dividerThickness
        let size = splitView.bounds.size
        let total = splitView.isVertical ? size.width : size.height
        let usable = max(0, total - thickness)

        var firstLength = (usable * node.ratio).rounded()
        if usable >= Self.minimumPaneLength * 2 {
            firstLength = min(max(firstLength, Self.minimumPaneLength),
                              usable - Self.minimumPaneLength)
        }
        let secondLength = usable - firstLength

        isApplyingRatios = true
        if splitView.isVertical {
            first.frame = NSRect(x: 0, y: 0, width: firstLength, height: size.height)
            second.frame = NSRect(
                x: firstLength + thickness,
                y: 0,
                width: secondLength,
                height: size.height
            )
        } else if splitView.isFlipped {
            first.frame = NSRect(x: 0, y: 0, width: size.width, height: firstLength)
            second.frame = NSRect(
                x: 0,
                y: firstLength + thickness,
                width: size.width,
                height: secondLength
            )
        } else {
            first.frame = NSRect(
                x: 0,
                y: secondLength + thickness,
                width: size.width,
                height: firstLength
            )
            second.frame = NSRect(x: 0, y: 0, width: size.width, height: secondLength)
        }
        isApplyingRatios = false
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        applyRatio(to: splitView)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, Self.minimumPaneLength)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return min(
            proposedMaximumPosition,
            total - splitView.dividerThickness - Self.minimumPaneLength
        )
    }

    /// The user dragged a divider: remember where they put it.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingRatios,
              let splitView = notification.object as? NSSplitView,
              let node = nodesBySplitView[ObjectIdentifier(splitView)],
              splitView.subviews.count == 2
        else { return }

        let thickness = splitView.dividerThickness
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let usable = total - thickness
        guard usable > 0 else { return }

        let firstFrame = splitView.subviews[0].frame
        let firstLength = splitView.isVertical ? firstFrame.width : firstFrame.height
        node.ratio = min(max(firstLength / usable, 0), 1)
    }

    // MARK: - Pane geometry

    /// The pane frames, in this view's coordinates.
    private func paneFrames() -> [(id: UUID, frame: NSRect)] {
        hosts.map { ($0.key, $0.value.convert($0.value.bounds, to: self)) }
    }

    /// The pane next to `paneID` in the given direction, if there is one.
    func neighborPane(of paneID: UUID, _ target: SplitFocusTarget) -> UUID? {
        let frames = paneFrames()
        guard let source = frames.first(where: { $0.id == paneID })?.frame else { return nil }

        var best: (id: UUID, score: CGFloat)?
        for candidate in frames where candidate.id != paneID {
            let frame = candidate.frame
            let gap: CGFloat
            let offset: CGFloat

            switch target {
            case .left:
                guard frame.midX < source.midX else { continue }
                gap = source.minX - frame.maxX
                offset = abs(frame.midY - source.midY)
            case .right:
                guard frame.midX > source.midX else { continue }
                gap = frame.minX - source.maxX
                offset = abs(frame.midY - source.midY)
            case .up:
                // AppKit's y grows upwards, so "up" is the larger midY.
                guard frame.midY > source.midY else { continue }
                gap = frame.minY - source.maxY
                offset = abs(frame.midX - source.midX)
            case .down:
                guard frame.midY < source.midY else { continue }
                gap = source.minY - frame.maxY
                offset = abs(frame.midX - source.midX)
            case .previous, .next:
                return nil
            }

            // Prefer the closest pane in the direction of travel, then the one
            // best lined up with the pane we came from.
            let score = abs(gap) * 2 + offset
            if best == nil || score < best!.score {
                best = (candidate.id, score)
            }
        }
        return best?.id
    }

    // MARK: - Dropping a tab in

    /// Which half of `rect` a point falls in, dividing it along its diagonals.
    ///
    /// Coordinates are AppKit's, so y grows upwards.
    static func dropDirection(for point: NSPoint, in rect: NSRect) -> SplitDirection {
        let dx = (point.x - rect.midX) / max(rect.width, 1)
        let dy = (point.y - rect.midY) / max(rect.height, 1)
        if abs(dx) >= abs(dy) {
            return dx >= 0 ? .right : .left
        }
        return dy >= 0 ? .up : .down
    }

    /// The half of `rect` a pane dropped in `direction` would occupy.
    static func highlightRect(_ direction: SplitDirection, in rect: NSRect) -> NSRect {
        switch direction {
        case .left:
            return NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right:
            return NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .up:
            return NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        case .down:
            return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        }
    }

    /// Read the dragged tab's id off the pasteboard.
    static func draggedTabID(from info: NSDraggingInfo) -> UUID? {
        guard let string = info.draggingPasteboard.string(forType: tabPasteboardType) else {
            return nil
        }
        return UUID(uuidString: string)
    }

    /// Where a drag in progress would land, and the rectangle drawn for it.
    /// Exposed so the self-test can check drop targeting without a real mouse.
    var currentDropTarget: SplitDropTarget? { dropTarget }
    var currentDropHighlight: NSRect? { highlight.highlightRect }

    private func target(at point: NSPoint) -> SplitDropTarget? {
        for (id, frame) in paneFrames() where frame.contains(point) {
            return SplitDropTarget(paneID: id, direction: Self.dropDirection(for: point, in: frame))
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let tabID = Self.draggedTabID(from: sender),
              canAcceptTab?(tabID) == true,
              let target = target(at: convert(sender.draggingLocation, from: nil))
        else {
            clearHighlight()
            return []
        }

        if target != dropTarget {
            dropTarget = target
            let frames = paneFrames()
            if let frame = frames.first(where: { $0.id == target.paneID })?.frame {
                highlight.highlightRect = Self.highlightRect(target.direction, in: frame)
            }
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearHighlight()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearHighlight()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let tabID = Self.draggedTabID(from: sender), let target = dropTarget else {
            clearHighlight()
            return false
        }
        clearHighlight()
        onDropTab?(tabID, target)
        return true
    }

    private func clearHighlight() {
        dropTarget = nil
        highlight.highlightRect = nil
    }
}

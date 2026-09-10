import AppKit

/// A single clickable tab in the tab bar.
///
/// Tabs are also drag sources: dropping one onto a pane of another tab moves it
/// in as a split. See `SplitContainerView` for the receiving end.
final class TabButtonView: NSView, NSDraggingSource {
    let tabID: UUID

    var isSelected: Bool = false {
        didSet { needsDisplay = true; updateAppearance() }
    }

    var title: String = "" {
        didSet { titleLabel.stringValue = title; toolTip = title }
    }

    /// A tab shows the kind of its focused pane, which changes as panes are
    /// split, dropped in, or closed.
    var kind: TabKind {
        didSet {
            guard kind != oldValue else { return }
            updateIcon()
        }
    }

    /// A favicon, or the mark of the program running in a terminal. Nil falls
    /// back to the symbol for the tab's kind.
    var icon: NSImage? {
        didSet {
            guard icon !== oldValue else { return }
            updateIcon()
        }
    }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let closeButton = NSButton()
    private let shortcutLabel = NSTextField(labelWithString: "")

    /// 1…9 for the tabs ⌘1…⌘9 can reach, nil beyond that.
    var shortcutNumber: Int? {
        didSet {
            guard shortcutNumber != oldValue else { return }
            shortcutLabel.stringValue = shortcutNumber.map { "⌘\($0)" } ?? ""
            updateAppearance()
        }
    }

    /// What the badge reads, for the self-test.
    var shortcutTextForTesting: String { shortcutLabel.stringValue }
    private var isHovered = false {
        didSet { updateAppearance() }
    }
    private var trackingArea: NSTrackingArea?

    /// Where the mouse went down, so a drag can be told from a click.
    private var mouseDownLocation: NSPoint?

    init(tabID: UUID, kind: TabKind, title: String) {
        self.tabID = tabID
        self.kind = kind
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false

        updateIcon()
        iconView.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close tab"
        )
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.alphaValue = 0
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        shortcutLabel.font = .systemFont(ofSize: 10, weight: .medium)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.alphaValue = 0
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(shortcutLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The badge and the close button share the trailing slot; only one
            // shows at a time, so the title stops short of whichever is wider.
            titleLabel.trailingAnchor.constraint(
                equalTo: shortcutLabel.leadingAnchor, constant: -4),

            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// What the tab is actually drawing, for the self-test.
    var iconImageForTesting: NSImage? { iconView.image }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        mouseDownLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }

        // Wait for real movement so a slightly shaky click still selects.
        let location = event.locationInWindow
        let distance = hypot(location.x - start.x, location.y - start.y)
        guard distance > 5 else { return }

        mouseDownLocation = nil
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
    }

    @objc private func closeClicked() {
        onClose?()
    }

    // MARK: - Dragging

    private func beginDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(tabID.uuidString, forType: SplitContainerView.tabPasteboardType)

        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())

        isHovered = false
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    /// A picture of the tab to drag around.
    private func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Tabs move within the window; they mean nothing to other apps.
        context == .withinApplication ? .move : []
    }

    private func updateIcon() {
        if let icon {
            iconView.image = icon
            iconView.imageScaling = .scaleProportionallyUpOrDown
        } else {
            let symbol = kind == .terminal ? "terminal" : "globe"
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        updateAppearance()
    }

    private func updateAppearance() {
        let background: NSColor
        if isSelected {
            background = .controlAccentColor.withAlphaComponent(0.18)
        } else if isHovered {
            background = .labelColor.withAlphaComponent(0.08)
        } else {
            background = .clear
        }
        layer?.backgroundColor = background.cgColor

        let textColor: NSColor = isSelected ? .labelColor : .secondaryLabelColor
        titleLabel.textColor = textColor
        iconView.contentTintColor = textColor

        // Hovering (or being the current tab) offers the close button; the rest
        // of the time an unselected tab advertises the key that reaches it.
        let showsClose = isHovered || isSelected
        closeButton.animator().alphaValue = showsClose ? 1 : 0
        shortcutLabel.animator().alphaValue =
            (!showsClose && shortcutNumber != nil) ? 1 : 0
    }
}

/// The tab strip across the top of the window, with the "+" button.
final class TabBarView: NSView {
    var onNewTab: (() -> Void)?
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onToggleSidebar: (() -> Void)?

    private let stack = NSStackView()
    /// The strip scrolls rather than growing: tabs must never widen the window.
    private let scrollView = NSScrollView()
    private let plusButton = NSButton()
    private let sidebarButton = NSButton()

    /// Height of the strip with no scroller taking space, and of the scroll
    /// view inside it. Both grow to make room when a scroller does.
    private static let baseHeight: CGFloat = 42
    private static let baseScrollHeight: CGFloat = 34

    private var barHeight: NSLayoutConstraint!
    private var scrollHeight: NSLayoutConstraint!
    private var scrollerAllowance: CGFloat = 0

    /// Extra vertical room a scroller needs.
    ///
    /// Overlay scrollers float above the content and cost nothing. Legacy ones
    /// — what you get with "Show scroll bars: Always" — take a strip along the
    /// bottom, and without this the tabs lose that much of their height and
    /// become hard to hit.
    static func scrollerAllowance(
        overflowing: Bool,
        style: NSScroller.Style
    ) -> CGFloat {
        guard overflowing, style == .legacy else { return 0 }
        return NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
    }
    private var buttons: [UUID: TabButtonView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        plusButton.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        plusButton.isBordered = false
        plusButton.bezelStyle = .inline
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.target = self
        plusButton.action = #selector(plusClicked)
        plusButton.toolTip = "New tab"
        plusButton.setAccessibilityIdentifier("newTabButton")
        plusButton.setAccessibilityLabel("New tab")
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        plusButton.setContentHuggingPriority(.required, for: .horizontal)

        // Always visible, so a collapsed sidebar can always be brought back.
        sidebarButton.image = NSImage(
            systemSymbolName: "sidebar.leading",
            accessibilityDescription: "Show or hide the sidebar"
        )
        sidebarButton.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        sidebarButton.isBordered = false
        sidebarButton.bezelStyle = .inline
        sidebarButton.contentTintColor = .secondaryLabelColor
        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarClicked)
        sidebarButton.toolTip = "Show or hide the sidebar (⌃⌘S)"
        sidebarButton.setAccessibilityIdentifier("toggleSidebarButton")
        sidebarButton.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stack
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScroller?.controlSize = .small
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // Without this the document's width would still push the bar wider.
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(sidebarButton)
        addSubview(scrollView)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([

            sidebarButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            sidebarButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            sidebarButton.widthAnchor.constraint(equalToConstant: 28),
            sidebarButton.heightAnchor.constraint(equalToConstant: 28),

            scrollView.leadingAnchor.constraint(
                equalTo: sidebarButton.trailingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.centerYAnchor.constraint(equalTo: centerYAnchor),

            // The stack holds the tabs and, as its last item, the + button —
            // so + trails the last tab instead of being pinned to the edge.
            // Its trailing edge is deliberately unconstrained so it can run
            // past the clip view and scroll.
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: scrollView.contentView.centerYAnchor),

            plusButton.widthAnchor.constraint(equalToConstant: 30),
            plusButton.heightAnchor.constraint(equalToConstant: 28),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        barHeight = heightAnchor.constraint(equalToConstant: Self.baseHeight)
        scrollHeight = scrollView.heightAnchor.constraint(
            equalToConstant: Self.baseScrollHeight)
        barHeight.isActive = true
        scrollHeight.isActive = true

        // The setting can change while we're running.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollerStyleChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )

        stack.addArrangedSubview(plusButton)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrollerStyleChanged() {
        updateScrollerAllowance()
    }

    override func layout() {
        super.layout()
        updateScrollerAllowance()
    }

    /// Grow the strip when a scroller is going to eat into it.
    private func updateScrollerAllowance() {
        let available = scrollView.contentView.bounds.width
        let overflowing = available > 0 && stack.fittingSize.width > available + 1
        let allowance = Self.scrollerAllowance(
            overflowing: overflowing,
            style: NSScroller.preferredScrollerStyle
        )

        // Guard against re-entering layout forever.
        guard allowance != scrollerAllowance else { return }
        scrollerAllowance = allowance
        barHeight.constant = Self.baseHeight + allowance
        scrollHeight.constant = Self.baseScrollHeight + allowance
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Scroll the selected tab into view — with a strip that overflows, the
    /// tab you just switched to can easily be off screen.
    private func revealSelectedTab(_ selectedID: UUID?) {
        guard let selectedID, let button = buttons[selectedID] else { return }
        DispatchQueue.main.async {
            guard button.superview != nil else { return }
            button.scrollToVisible(button.bounds.insetBy(dx: -8, dy: 0))
        }
    }

    @objc private func plusClicked() {
        onNewTab?()
    }

    @objc private func sidebarClicked() {
        onToggleSidebar?()
    }

    /// Rebuild the strip to match the given tabs.
    /// How many times the strip has been rebuilt, for the self-test.
    private(set) var rebuildCountForTesting = 0

    func reload(tabs: [Tab], selectedID: UUID?) {
        // Drop buttons for tabs that no longer exist.
        let liveIDs = Set(tabs.map(\.id))
        for (id, button) in buttons where !liveIDs.contains(id) {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
            buttons.removeValue(forKey: id)
        }

        var ordered: [TabButtonView] = []
        for tab in tabs {
            let button: TabButtonView
            if let existing = buttons[tab.id] {
                button = existing
            } else {
                button = TabButtonView(tabID: tab.id, kind: tab.kind, title: tab.title)
                button.onSelect = { [weak self] in self?.onSelectTab?(tab.id) }
                button.onClose = { [weak self] in self?.onCloseTab?(tab.id) }
                buttons[tab.id] = button
            }

            button.title = tab.title
            button.kind = tab.kind
            button.icon = tab.icon
            button.isSelected = tab.id == selectedID
            // ⌘1…⌘9 only reach the first nine.
            button.shortcutNumber = ordered.count < 9 ? ordered.count + 1 : nil
            ordered.append(button)
        }

        // Only touch the view hierarchy when the order actually changed.
        //
        // Selecting a tab happens on mouse down and reloads the strip. Pulling
        // a button out of its superview mid-click ends the tracking that click
        // started, so the drag that would move the tab into a pane never
        // begins — it just looks like the tab was selected.
        let current = stack.arrangedSubviews.compactMap { ($0 as? TabButtonView)?.tabID }
        guard current != ordered.map(\.tabID) else {
            revealSelectedTab(selectedID)
            return
        }

        defer { revealSelectedTab(selectedID) }
        rebuildCountForTesting += 1
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for button in ordered {
            stack.addArrangedSubview(button)
        }

        // The + always sits immediately after the last tab.
        stack.addArrangedSubview(plusButton)
    }
}

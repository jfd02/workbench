import AppKit

/// What the user picked in the new-tab dialog.
enum NewTabChoice {
    case terminal
    /// nil opens the browser's default home page.
    case browser(URL?)
}

/// One row in the new-tab list.
private final class ListRowView: NSView {
    let title: String

    var onActivate: (() -> Void)?
    var onRemove: (() -> Void)?

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let removeButton = NSButton()
    private var isHovered = false {
        didSet { updateAppearance() }
    }
    private var trackingArea: NSTrackingArea?

    /// True once a favicon replaced the symbol, so the row stops tinting it.
    private var hasSiteIcon = false

    init(symbol: String, title: String, subtitle: String?, removable: Bool) {
        self.title = title
        titleLabel = NSTextField(labelWithString: title)
        subtitleLabel = NSTextField(labelWithString: subtitle ?? "")
        super.init(frame: .zero)

        setAccessibilityIdentifier("newTabRow")
        setAccessibilityLabel(title)
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = subtitle

        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        removeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Remove pin"
        )
        removeButton.isBordered = false
        removeButton.bezelStyle = .inline
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.toolTip = "Remove pin"
        removeButton.isHidden = !removable
        removeButton.alphaValue = 0
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setContentHuggingPriority(.required, for: .horizontal)

        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labels)
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),

            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -8),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 16),
            removeButton.heightAnchor.constraint(equalToConstant: 16),
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

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Swap the globe for the site's own icon. Called straight away when the
    /// icon is cached and later when one has to be fetched.
    func setSiteIcon(_ image: NSImage?) {
        guard let image else { return }
        hasSiteIcon = true
        iconView.image = image
        iconView.imageScaling = .scaleProportionallyUpOrDown
        updateAppearance()
    }

    // This is a launcher, so a single click opens the row.
    override func mouseUp(with event: NSEvent) {
        onActivate?()
    }

    @objc private func removeClicked() {
        onRemove?()
    }

    private func updateAppearance() {
        let background: NSColor
        if isSelected {
            background = .controlAccentColor.withAlphaComponent(0.16)
        } else if isHovered {
            background = .labelColor.withAlphaComponent(0.07)
        } else {
            background = .clear
        }
        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor

        // A favicon carries its own colors; only the symbols get tinted.
        iconView.contentTintColor = hasSiteIcon
            ? nil
            : (isSelected ? .controlAccentColor : .secondaryLabelColor)
        removeButton.animator().alphaValue = isHovered ? 1 : 0
    }
}

/// Root view that owns keyboard navigation for the dialog.
private final class KeyCatcherView: NSView {
    var onKey: ((UInt16) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event.keyCode) == true { return }
        super.keyDown(with: event)
    }
}

/// The sheet shown when the user clicks "+" or presses ⌘T.
///
/// A vertical launcher: Terminal, Web Browser, the user's pinned sites, and a
/// row for adding one.
final class NewTabDialog: NSViewController {
    private let completion: (NewTabChoice?) -> Void

    /// What each row does, parallel to `rowViews`. Most open a tab and close
    /// the sheet; "Add Site…" opens another sheet instead, which is why rows
    /// carry an action rather than a choice.
    private var rowActions: [() -> Void] = []
    private var rowViews: [ListRowView] = []
    private var selectedIndex = 0

    private let listStack = NSStackView()

    init(completion: @escaping (NewTabChoice?) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = KeyCatcherView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.onKey = { [weak self] keyCode in self?.handleKey(keyCode) ?? false }

        let heading = NSTextField(labelWithString: "New Tab")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let hint = NSTextField(labelWithString: "↑↓ to move, ↩ to open")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [hint, NSView(), cancelButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(heading)
        root.addSubview(listStack)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 380),

            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),

            listStack.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            listStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            listStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            footer.topAnchor.constraint(equalTo: listStack.bottomAnchor, constant: 14),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
        rebuildList()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }

    // MARK: - List

    /// Rebuild the rows. `selecting` highlights the pin with that URL, so a
    /// site the user just added is the one sitting under Return.
    private func rebuildList(selecting: URL? = nil) {
        for subview in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        rowActions = []
        rowViews = []

        addRow(symbol: "terminal", title: "Terminal", subtitle: "Ghostty session") {
            [weak self] in self?.finish(.terminal)
        }
        addRow(symbol: "globe", title: "Web Browser", subtitle: BrowserTabContent.defaultHome.host)
        {
            [weak self] in self?.finish(.browser(nil))
        }

        addSectionHeader("PINNED")

        let pins = PinnedSites.all
        var indexToSelect: Int?
        for pin in pins {
            if pin.url == selecting { indexToSelect = rowViews.count }
            let row = addRow(
                symbol: "globe",
                title: pin.title,
                subtitle: pin.host,
                pinnedURL: pin.url
            ) { [weak self] in
                self?.finish(.browser(pin.url))
            }
            showIcon(for: pin.url, in: row)
        }

        addRow(
            symbol: "plus",
            title: "Add Site…",
            subtitle: pins.isEmpty
                ? "Save a link — Figma, a dashboard — to open it from here"
                : nil
        ) { [weak self] in
            self?.presentAddSite()
        }

        selectedIndex = indexToSelect ?? min(selectedIndex, max(0, rowViews.count - 1))
        updateSelection()
    }

    /// Draw a pin with the site's own icon: straight away if we have it, and
    /// otherwise whenever the fetch lands. Rows outlive neither, hence weak.
    private func showIcon(for url: URL, in row: ListRowView) {
        if let cached = FaviconStore.cached(for: url) {
            return row.setSiteIcon(cached)
        }
        FaviconStore.icon(for: url) { [weak row] image in
            row?.setSiteIcon(image)
        }
    }

    /// Adds a small caption row. The width constraint has to be activated after
    /// the view joins the stack, or the anchors have no common ancestor.
    private func addSectionHeader(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        listStack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    @discardableResult
    private func addRow(
        symbol: String,
        title: String,
        subtitle: String?,
        pinnedURL: URL? = nil,
        action: @escaping () -> Void
    ) -> ListRowView {
        let row = ListRowView(
            symbol: symbol,
            title: title,
            subtitle: subtitle,
            removable: pinnedURL != nil
        )
        let index = rowViews.count
        row.onActivate = { [weak self] in self?.activate(index) }
        if let pinnedURL {
            row.onRemove = { [weak self] in
                PinnedSites.remove(pinnedURL)
                self?.rebuildList()
            }
        }

        listStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true

        rowActions.append(action)
        rowViews.append(row)
        return row
    }

    // MARK: - Adding a site

    /// A sheet on top of this one, so the launcher is still behind it when the
    /// new site appears in the list.
    private func presentAddSite() {
        guard let window = view.window else { return }

        let dialog = AddSiteDialog { [weak self] site in
            guard let self, let site else { return }
            PinnedSites.add(title: site.title, url: site.url)
            self.rebuildList(selecting: site.url)
            self.view.window?.makeFirstResponder(self.view)
        }

        let sheet = NSWindow(contentViewController: dialog)
        sheet.styleMask = [.titled]
        window.beginSheet(sheet)
    }

    private func updateSelection() {
        for (index, row) in rowViews.enumerated() {
            row.isSelected = index == selectedIndex
        }
    }

    // MARK: - Test hooks

    /// Row titles in display order, so the self-test can check the list without
    /// clicking anything.
    var rowTitles: [String] {
        rowViews.map(\.title)
    }

    /// Open the add-site sheet, as clicking its row does.
    func presentAddSiteForTesting() {
        presentAddSite()
    }

    func cancelForTesting() {
        cancel()
    }

    // MARK: - Input

    /// Returns true when the key was handled.
    private func handleKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 125:  // down
            guard !rowViews.isEmpty else { return true }
            selectedIndex = (selectedIndex + 1) % rowViews.count
            updateSelection()
            return true
        case 126:  // up
            guard !rowViews.isEmpty else { return true }
            selectedIndex = (selectedIndex - 1 + rowViews.count) % rowViews.count
            updateSelection()
            return true
        case 36, 76:  // return, keypad enter
            activate(selectedIndex)
            return true
        default:
            return false
        }
    }

    private func activate(_ index: Int) {
        guard index >= 0, index < rowActions.count else { return }
        rowActions[index]()
    }

    @objc private func cancel() {
        finish(nil)
    }

    private func finish(_ choice: NewTabChoice?) {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window)
        completion(choice)
    }
}

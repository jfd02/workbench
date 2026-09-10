import AppKit

/// The sheet behind "Add Site…" in the new-tab list.
///
/// Saves a link without visiting it first, which is the difference between
/// this and the browser's pin button: you can put Figma in the launcher
/// without opening Figma to do it.
final class AddSiteDialog: NSViewController {
    struct Site {
        let title: String
        let url: URL
    }

    private let completion: (Site?) -> Void

    private let titleField = NSTextField()
    private let addressField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")

    init(completion: @escaping (Site?) -> Void) {
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Add Site")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let caption = NSTextField(
            labelWithString: "It appears in the new-tab list, with the site's icon."
        )
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        addressField.placeholderString = "figma.com"
        addressField.setAccessibilityIdentifier("addSiteAddress")
        titleField.placeholderString = "Optional — taken from the address"
        titleField.setAccessibilityIdentifier("addSiteTitle")

        for field in [addressField, titleField] {
            field.font = .systemFont(ofSize: 12)
            field.bezelStyle = .roundedBezel
            field.translatesAutoresizingMaskIntoConstraints = false
            field.target = self
            field.action = #selector(add)
        }

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let form = NSGridView(views: [
            [label("Address"), addressField],
            [label("Name"), titleField],
        ])
        form.rowSpacing = 8
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let addButton = NSButton(title: "Add", target: self, action: #selector(add))
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.setAccessibilityIdentifier("addSiteButton")

        let footer = NSStackView(views: [NSView(), cancelButton, addButton])
        footer.orientation = .horizontal
        footer.spacing = 10

        let stack = NSStackView(views: [heading, caption, form, errorLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 380),

            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            addressField.widthAnchor.constraint(equalToConstant: 280),
        ])

        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(addressField)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        return field
    }

    // MARK: - Actions

    @objc private func add() {
        // Clear whatever the last attempt complained about before judging
        // this one, so a corrected address doesn't keep the old error.
        errorLabel.isHidden = true

        guard let site = site(address: addressField.stringValue, title: titleField.stringValue)
        else {
            errorLabel.stringValue = "That doesn't look like a web address."
            errorLabel.isHidden = false
            view.window?.makeFirstResponder(addressField)
            return
        }
        finish(site)
    }

    @objc private func cancel() {
        finish(nil)
    }

    /// A site from what was typed, or nil when the address isn't one. An empty
    /// name is filled in from the host.
    private func site(address: String, title: String) -> Site? {
        guard let url = BrowserTabContent.address(address) else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Site(
            title: trimmed.isEmpty ? PinnedSite.suggestedTitle(for: url) : trimmed,
            url: url
        )
    }

    private func finish(_ site: Site?) {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window)
        completion(site)
    }

    // MARK: - Test hooks

    /// Fill the fields and press Add. Returns false when the sheet rejected
    /// the address, which leaves it open with its error showing.
    @discardableResult
    func addForTesting(address: String, title: String = "") -> Bool {
        addressField.stringValue = address
        titleField.stringValue = title
        add()
        return errorLabel.isHidden
    }

    func cancelForTesting() {
        cancel()
    }
}

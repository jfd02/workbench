import AppKit

/// What the user chose in the new-worktree sheet.
struct NewWorktreeRequest {
    var branch: String
    var path: String
    var createBranch: Bool
    /// Base commit for a new branch. nil means the latest origin default branch.
    var startPoint: String?
    /// Make the new branch track `startPoint` — set when checking out a
    /// remote branch.
    var trackStartPoint = false
}

/// Sheet for `git worktree add`.
///
/// Existing branches are picked from a searchable list of local and remote
/// branches. Typing in either field switches to its mode, so the radios rarely
/// need clicking.
final class NewWorktreeDialog: NSViewController {
    private let repository: Repository
    private let completion: (NewWorktreeRequest?) -> Void

    private let branchField = NSTextField()
    private let searchField = NSSearchField()
    private let branchTable = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let fetchSpinner = NSProgressIndicator()
    private let fetchLabel = NSTextField(labelWithString: "Updating remote branches…")
    private let newBranchRadio = NSButton()
    private let existingBranchRadio = NSButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let createButton = NSButton()

    private var allChoices: [BranchChoice] = []
    private var shownChoices: [BranchChoice] = []

    init(repository: Repository, completion: @escaping (NewWorktreeRequest?) -> Void) {
        self.repository = repository
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "New Worktree")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let subheading = NSTextField(labelWithString: repository.name)
        subheading.font = .systemFont(ofSize: 12)
        subheading.textColor = .secondaryLabelColor
        subheading.translatesAutoresizingMaskIntoConstraints = false

        newBranchRadio.setButtonType(.radio)
        newBranchRadio.title = "Create a new branch"
        newBranchRadio.target = self
        newBranchRadio.action = #selector(modeChanged)
        newBranchRadio.state = .on

        existingBranchRadio.setButtonType(.radio)
        existingBranchRadio.title = "Check out an existing branch"
        existingBranchRadio.target = self
        existingBranchRadio.action = #selector(modeChanged)

        branchField.placeholderString = "feature/my-change"
        branchField.font = .systemFont(ofSize: 12)
        branchField.delegate = self
        branchField.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search local and remote branches"
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        fetchSpinner.style = .spinning
        fetchSpinner.controlSize = .small
        fetchSpinner.isDisplayedWhenStopped = false
        fetchLabel.font = .systemFont(ofSize: 11)
        fetchLabel.textColor = .tertiaryLabelColor

        let existingHeader = NSStackView(views: [existingBranchRadio, NSView(), fetchSpinner, fetchLabel])
        existingHeader.orientation = .horizontal
        existingHeader.spacing = 6
        existingHeader.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("branch"))
        column.resizingMask = .autoresizingMask
        branchTable.addTableColumn(column)
        branchTable.headerView = nil
        branchTable.style = .inset
        branchTable.rowHeight = 24
        branchTable.intercellSpacing = NSSize(width: 0, height: 0)
        branchTable.dataSource = self
        branchTable.delegate = self
        branchTable.target = self
        branchTable.doubleAction = #selector(tableDoubleClicked)

        let scroll = NSScrollView()
        scroll.documentView = branchTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)

        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        createButton.title = "Create"
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(create)
        createButton.isEnabled = false

        let buttons = NSStackView(views: [NSView(), cancelButton, createButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            newBranchRadio,
            branchField,
            existingHeader,
            searchField,
            scroll,
            pathLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: branchField)
        stack.setCustomSpacing(4, after: searchField)
        stack.setCustomSpacing(12, after: scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(heading)
        root.addSubview(subheading)
        root.addSubview(stack)
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 460),

            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            subheading.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
            subheading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            stack.topAnchor.constraint(equalTo: subheading.bottomAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            branchField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            branchField.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            existingHeader.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            existingHeader.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            searchField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 216),
            pathLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 18),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])

        view = root
        allChoices = GitService.branchChoices(for: repository.path)
        applyFilter()
        refreshRemoteBranches()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(branchField)
    }

    /// Show what's known now, then fetch so remote branches pushed since the
    /// last fetch turn up too.
    private func refreshRemoteBranches() {
        fetchSpinner.startAnimation(nil)
        fetchLabel.isHidden = false
        let path = repository.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? GitService.fetchAll(repositoryPath: path)
            let choices = GitService.branchChoices(for: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchSpinner.stopAnimation(nil)
                self.fetchLabel.isHidden = true
                self.allChoices = choices
                self.applyFilter()
            }
        }
    }

    // MARK: - Mode

    private var isCreatingBranch: Bool { newBranchRadio.state == .on }

    private func setCreating(_ creating: Bool) {
        guard creating != isCreatingBranch else { return }
        newBranchRadio.state = creating ? .on : .off
        existingBranchRadio.state = creating ? .off : .on
        // Drop the list's selection so a later fetch reselecting it can't
        // flip the mode back.
        if creating { branchTable.deselectAll(nil) }
        if !creating, branchTable.selectedRow < 0, !shownChoices.isEmpty {
            selectRow(0)
        }
        updatePathPreview()
    }

    @objc private func modeChanged(_ sender: NSButton) {
        let creating = sender == newBranchRadio
        setCreating(creating)
        view.window?.makeFirstResponder(creating ? branchField : searchField)
    }

    // MARK: - Branch list

    private var selectedChoice: BranchChoice? {
        let row = branchTable.selectedRow
        return shownChoices.indices.contains(row) ? shownChoices[row] : nil
    }

    /// Keep only branches matching every word typed, in any order.
    private func applyFilter() {
        let previous = selectedChoice
        let words = searchField.stringValue
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
        shownChoices = allChoices.filter { choice in
            let haystack = (choice.remoteRef ?? choice.name).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        branchTable.reloadData()

        if allChoices.isEmpty {
            emptyLabel.stringValue = "No branches that aren't already checked out"
        } else {
            emptyLabel.stringValue = "No branches match"
        }
        emptyLabel.isHidden = !shownChoices.isEmpty

        // Keep the same branch selected across fetches and filtering, else
        // the best match, so Return picks what the search narrowed to.
        if let previous, let row = shownChoices.firstIndex(of: previous) {
            selectRow(row)
        } else if !isCreatingBranch, !shownChoices.isEmpty {
            selectRow(0)
        } else {
            branchTable.deselectAll(nil)
        }
        updatePathPreview()
    }

    private func selectRow(_ row: Int) {
        branchTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        branchTable.scrollRowToVisible(row)
    }

    private func moveSelection(by offset: Int) {
        guard !shownChoices.isEmpty else { return }
        setCreating(false)
        let current = branchTable.selectedRow
        let next = current < 0 ? 0 : min(max(current + offset, 0), shownChoices.count - 1)
        selectRow(next)
    }

    @objc private func tableDoubleClicked() {
        guard branchTable.clickedRow >= 0 else { return }
        create()
    }

    // MARK: - Result

    /// The local branch the worktree will be on.
    private var chosenBranch: String {
        isCreatingBranch
            ? branchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : (selectedChoice?.name ?? "")
    }

    private func updatePathPreview() {
        let branch = chosenBranch
        let taken = isCreatingBranch && localBranchExists(branch)
        createButton.isEnabled = !branch.isEmpty && !taken

        guard !branch.isEmpty else {
            pathLabel.stringValue = " "
            return
        }
        if taken {
            pathLabel.stringValue = "Branch “\(branch)” already exists."
            pathLabel.textColor = .systemRed
            return
        }

        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.stringValue = GitService.defaultWorktreePath(
            repositoryPath: repository.path,
            branch: branch
        )
    }

    private func localBranchExists(_ branch: String) -> Bool {
        let all = (try? GitService.branches(for: repository.path)) ?? []
        return all.contains(branch)
    }

    @objc private func create() {
        let branch = chosenBranch
        guard !branch.isEmpty, createButton.isEnabled else { return }
        let path = GitService.defaultWorktreePath(repositoryPath: repository.path, branch: branch)

        if isCreatingBranch {
            finish(NewWorktreeRequest(branch: branch, path: path, createBranch: true, startPoint: nil))
        } else if let remoteRef = selectedChoice?.remoteRef {
            // Only on the remote: make a local branch that tracks it.
            finish(NewWorktreeRequest(
                branch: branch, path: path, createBranch: true,
                startPoint: remoteRef, trackStartPoint: true))
        } else {
            finish(NewWorktreeRequest(branch: branch, path: path, createBranch: false, startPoint: nil))
        }
    }

    @objc private func cancel() {
        finish(nil)
    }

    private func finish(_ request: NewWorktreeRequest?) {
        guard let window = view.window else { return }
        window.sheetParent?.endSheet(window)
        completion(request)
    }
}

extension NewWorktreeDialog: NSTextFieldDelegate, NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === searchField {
            setCreating(false)
            applyFilter()
        } else {
            setCreating(true)
            updatePathPreview()
        }
    }

    /// Arrow keys move through the list without leaving the search field, and
    /// Escape backs out of the search before it backs out of the sheet.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            create()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                cancel()
            } else {
                searchField.stringValue = ""
                applyFilter()
            }
            return true
        default:
            return false
        }
    }
}

extension NewWorktreeDialog: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        shownChoices.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("branchCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BranchCellView
            ?? {
                let created = BranchCellView()
                created.identifier = identifier
                return created
            }()
        cell.configure(for: shownChoices[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // A click in the list means the user wants an existing branch.
        if branchTable.selectedRow >= 0 { setCreating(false) }
        updatePathPreview()
    }
}

/// One branch in the list: its name, with where it lives on the right.
private final class BranchCellView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.alignment = .right
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceLabel.setContentHuggingPriority(.required, for: .horizontal)
        sourceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(nameLabel)
        addSubview(sourceLabel)
        textField = nameLabel

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: sourceLabel.leadingAnchor, constant: -8),
            sourceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            sourceLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(for choice: BranchChoice) {
        nameLabel.stringValue = choice.name
        sourceLabel.stringValue = choice.remoteName ?? "local"
        setAccessibilityLabel(choice.remoteRef ?? choice.name)
    }
}

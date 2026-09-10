import AppKit

/// What the user chose in the new-worktree sheet.
struct NewWorktreeRequest {
    var branch: String
    var path: String
    var createBranch: Bool
    /// Base commit for a new branch. nil means the current HEAD.
    var startPoint: String?
}

/// Sheet for `git worktree add`.
final class NewWorktreeDialog: NSViewController {
    private let repository: Repository
    private let completion: (NewWorktreeRequest?) -> Void

    private let branchField = NSTextField()
    private let existingBranchPopUp = NSPopUpButton()
    private let newBranchRadio = NSButton()
    private let existingBranchRadio = NSButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let createButton = NSButton()

    private var availableBranches: [String] = []

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

        // Branches already checked out can't be used for another worktree.
        let checkedOut = GitService.checkedOutBranches(for: repository.path)
        availableBranches = ((try? GitService.branches(for: repository.path)) ?? [])
            .filter { !checkedOut.contains($0) }

        newBranchRadio.setButtonType(.radio)
        newBranchRadio.title = "Create a new branch"
        newBranchRadio.target = self
        newBranchRadio.action = #selector(modeChanged)
        newBranchRadio.state = .on
        newBranchRadio.translatesAutoresizingMaskIntoConstraints = false

        existingBranchRadio.setButtonType(.radio)
        existingBranchRadio.title = "Check out an existing branch"
        existingBranchRadio.target = self
        existingBranchRadio.action = #selector(modeChanged)
        existingBranchRadio.isEnabled = !availableBranches.isEmpty
        existingBranchRadio.translatesAutoresizingMaskIntoConstraints = false

        branchField.placeholderString = "feature/my-change"
        branchField.font = .systemFont(ofSize: 12)
        branchField.delegate = self
        branchField.translatesAutoresizingMaskIntoConstraints = false

        existingBranchPopUp.addItems(withTitles: availableBranches)
        existingBranchPopUp.isEnabled = false
        existingBranchPopUp.target = self
        existingBranchPopUp.action = #selector(updatePathPreview)
        existingBranchPopUp.translatesAutoresizingMaskIntoConstraints = false
        if availableBranches.isEmpty {
            existingBranchPopUp.addItem(withTitle: "No unused branches")
        }

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
            existingBranchRadio,
            existingBranchPopUp,
            pathLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: branchField)
        stack.setCustomSpacing(14, after: existingBranchPopUp)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(heading)
        root.addSubview(subheading)
        root.addSubview(stack)
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 440),

            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            subheading.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
            subheading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            stack.topAnchor.constraint(equalTo: subheading.bottomAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            branchField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            branchField.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            existingBranchPopUp.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            existingBranchPopUp.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 18),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])

        view = root
        updatePathPreview()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(branchField)
    }

    private var isCreatingBranch: Bool { newBranchRadio.state == .on }

    private var chosenBranch: String {
        isCreatingBranch
            ? branchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : (existingBranchPopUp.titleOfSelectedItem ?? "")
    }

    @objc private func modeChanged(_ sender: NSButton) {
        let creating = sender == newBranchRadio
        newBranchRadio.state = creating ? .on : .off
        existingBranchRadio.state = creating ? .off : .on
        branchField.isEnabled = creating
        existingBranchPopUp.isEnabled = !creating && !availableBranches.isEmpty
        view.window?.makeFirstResponder(creating ? branchField : existingBranchPopUp)
        updatePathPreview()
    }

    @objc private func updatePathPreview() {
        let branch = chosenBranch
        let valid = !branch.isEmpty && !(isCreatingBranch && availableBranchExists(branch))
        createButton.isEnabled = valid

        guard !branch.isEmpty else {
            pathLabel.stringValue = " "
            return
        }

        if isCreatingBranch && availableBranchExists(branch) {
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

    private func availableBranchExists(_ branch: String) -> Bool {
        let all = (try? GitService.branches(for: repository.path)) ?? []
        return all.contains(branch)
    }

    @objc private func create() {
        let branch = chosenBranch
        guard !branch.isEmpty else { return }

        finish(
            NewWorktreeRequest(
                branch: branch,
                path: GitService.defaultWorktreePath(
                    repositoryPath: repository.path,
                    branch: branch
                ),
                createBranch: isCreatingBranch,
                startPoint: nil
            )
        )
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

extension NewWorktreeDialog: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updatePathPreview()
    }
}

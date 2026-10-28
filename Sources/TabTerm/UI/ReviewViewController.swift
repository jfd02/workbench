import AppKit

/// Read-only worktree review. Request identities prevent a late result from a
/// previous workspace, commit, or selected file replacing what is on screen.
final class ReviewViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onClose: (() -> Void)?
    var loadFilePreview: (ChangedFile, String) throws -> String = ChangelistService.preview
    var onSummary: ((String, String, CheckState?) -> Void)?
    var loadChanges: (String) throws -> ChangelistSnapshot = ChangelistService.load
    var loadCI: (String, String) throws -> CISnapshot = { try CIService.load(at: $0, head: $1) }
    var displaysCI: Bool { isCI }
    private let modes = NSSegmentedControl(labels: ["Changes", "CI"], trackingMode: .selectOne, target: nil, action: nil)
    private let context = NSTextField(wrappingLabelWithString: "Select a worktree to review changes and CI.")
    private let table = NSTableView()
    private let preview = NSTextView()
    private let diffScroll = NSScrollView()
    private let listScroll = NSScrollView()
    private let search = NSSearchField()
    private let fileTitle = NSTextField(labelWithString: "Changes")
    private let fileDetail = NSTextField(labelWithString: "")
    private let statistics = NSTextField(labelWithString: "")
    private let previousHunk = NSButton()
    private let nextHunk = NSButton()
    private let hunkPosition = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let wrapButton = NSButton()
    private let progress = NSProgressIndicator()
    private let emptyList = NSTextField(wrappingLabelWithString: "")
    private var rows: [FileRow] = []
    private var reloadingList = false
    private var renderedFileID: String?
    private var presentation = ReviewDiffPresentation(text: "", isDiff: false)
    private var currentHunk = -1
    private var previewIsDiff = false
    private enum FileRow {
        case group(ChangedFile.Area, Int)
        case file(ChangedFile)
    }
    private var selectedFile: ChangedFile? {
        guard case .file(let file) = rows[safe: table.selectedRow] else { return nil }
        return file
    }
    private let actionButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private var timer: Timer?
    private var directory: String?
    private var generation = UUID()
    private var previewRequest = UUID()
    private var loadingChanges = false
    private var loadingCI = false
    private var lastCIFetch = Date.distantPast
    private(set) var changes: ChangelistSnapshot?
    private(set) var ci: CISnapshot?
    private var changeError: String?
    private var ciError: String?
    private var ciMessage = "Checking CI…"
    private var selectedFileID: String?
    private var selectedCheck: CICheck?
    private var isCI: Bool { modes.selectedSegment == 1 }

    override func loadView() {
        view = ReviewBackgroundView()
        modes.selectedSegment = 0
        modes.target = self
        modes.action = #selector(modeChanged)
        modes.setAccessibilityIdentifier("reviewMode")
        let refresh = iconButton("arrow.clockwise", "Refresh changes and CI", #selector(refreshClicked))
        refresh.setAccessibilityIdentifier("refreshReview")
        let close = iconButton("xmark", "Close review panel", #selector(closeClicked))
        close.setAccessibilityIdentifier("closeReview")
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let toolbar = NSStackView(views: [modes, NSView(), progress, refresh, close])
        toolbar.spacing = 10
        context.font = .systemFont(ofSize: 11)
        context.textColor = .secondaryLabelColor
        context.maximumNumberOfLines = 2
        context.lineBreakMode = .byTruncatingMiddle
        context.setContentHuggingPriority(.required, for: .vertical)
        context.setAccessibilityIdentifier("reviewContext")
        search.placeholderString = "Filter files by name or path"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityIdentifier("filterReviewFiles")
        search.setAccessibilityLabel("Filter changed files")

        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 46
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("reviewList")
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        emptyList.font = .systemFont(ofSize: 12)
        emptyList.textColor = .secondaryLabelColor
        emptyList.alignment = .center
        emptyList.isHidden = true
        let listContainer = NSView()
        for child in [listScroll, emptyList] {
            child.translatesAutoresizingMaskIntoConstraints = false
            listContainer.addSubview(child)
        }
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: listContainer.topAnchor),
            listScroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            emptyList.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
            emptyList.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 20),
            emptyList.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -20),
        ])

        preview.isEditable = false
        preview.isRichText = false
        preview.isAutomaticLinkDetectionEnabled = false
        preview.isAutomaticQuoteSubstitutionEnabled = false
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textContainerInset = NSSize(width: 12, height: 12)
        preview.minSize = .zero
        preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        preview.autoresizingMask = [.width]
        preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = true
        preview.textContainer?.widthTracksTextView = false
        preview.textContainer?.containerSize = preview.maxSize
        preview.setAccessibilityIdentifier("changePreview")
        diffScroll.documentView = preview
        diffScroll.hasVerticalScroller = true
        diffScroll.hasHorizontalScroller = true
        diffScroll.autohidesScrollers = true

        fileTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        fileTitle.lineBreakMode = .byTruncatingMiddle
        fileTitle.setAccessibilityIdentifier("reviewFileTitle")
        fileDetail.font = .systemFont(ofSize: 11)
        fileDetail.textColor = .secondaryLabelColor
        fileDetail.lineBreakMode = .byTruncatingMiddle
        statistics.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statistics.setContentCompressionResistancePriority(.required, for: .horizontal)
        statistics.setAccessibilityIdentifier("reviewDiffStatistics")
        let heading = NSStackView(views: [fileTitle, NSView(), statistics])
        let fileHeader = NSStackView(views: [heading, fileDetail])
        fileHeader.orientation = .vertical
        fileHeader.alignment = .leading
        fileHeader.spacing = 4
        fileHeader.setHuggingPriority(.required, for: .vertical)
        fileHeader.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        heading.widthAnchor.constraint(equalTo: fileHeader.widthAnchor, constant: -24).isActive = true
        fileDetail.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
        configureIcon(previousHunk, "chevron.up", "Previous change (⌥↑)", #selector(previousChange))
        configureIcon(nextHunk, "chevron.down", "Next change (⌥↓)", #selector(nextChange))
        previousHunk.keyEquivalent = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        nextHunk.keyEquivalent = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        previousHunk.keyEquivalentModifierMask = [.option]
        nextHunk.keyEquivalentModifierMask = [.option]
        previousHunk.setAccessibilityIdentifier("previousReviewChange")
        nextHunk.setAccessibilityIdentifier("nextReviewChange")
        configureIcon(wrapButton, "arrow.turn.down.left", "Wrap long lines", #selector(toggleWrap))
        wrapButton.setButtonType(.toggle)
        wrapButton.setAccessibilityIdentifier("wrapReviewLines")
        configureIcon(copyButton, "doc.on.doc", "Copy diff", #selector(copyPreview))
        copyButton.setAccessibilityIdentifier("copyReviewDiff")
        hunkPosition.font = .systemFont(ofSize: 11)
        hunkPosition.textColor = .secondaryLabelColor
        hunkPosition.setAccessibilityIdentifier("reviewChangePosition")
        let diffTools = NSStackView(views: [previousHunk, nextHunk, hunkPosition, NSView(), wrapButton, copyButton])
        diffTools.spacing = 8
        diffTools.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 8, right: 10)
        let previewContainer = NSStackView(views: [fileHeader, diffTools, diffScroll])
        previewContainer.orientation = .vertical
        previewContainer.alignment = .leading
        previewContainer.spacing = 0
        previewContainer.distribution = .fill
        previewContainer.setHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        for child in [fileHeader, diffTools, diffScroll] {
            child.widthAnchor.constraint(equalTo: previewContainer.widthAnchor).isActive = true
        }
        diffTools.heightAnchor.constraint(equalToConstant: 32).isActive = true

        actionButton.target = self
        actionButton.action = #selector(openSelected)
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.isEnabled = false
        let readOnly = NSTextField(labelWithString: "Read-only")
        readOnly.font = .systemFont(ofSize: 10)
        readOnly.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [actionButton, NSView(), readOnly])
        footer.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let body = NSSplitView()
        body.isVertical = false
        body.dividerStyle = .thin
        body.addArrangedSubview(listContainer)
        body.addArrangedSubview(previewContainer)
        let top = NSStackView(views: [toolbar, context, search])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 10
        top.setHuggingPriority(.required, for: .vertical)
        for child in [toolbar, context, search] {
            child.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        }
        for child in [top, body, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            toolbar.heightAnchor.constraint(equalToConstant: 24),
            body.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            listContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            footer.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
        listContainer.heightAnchor.constraint(equalTo: body.heightAnchor, multiplier: 0.34).withPriority(.defaultLow).isActive = true
        displayPreview("Select a worktree to review changes.")
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton()
        configureIcon(button, symbol, label, action)
        return button
    }

    private func configureIcon(_ button: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .inline
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @objc private func closeClicked() { onClose?() }

    func focusList() { view.window?.makeFirstResponder(table) }

    deinit { timer?.invalidate() }

    func select(directory: String?, automaticallyRefresh: Bool = true) {
        loadViewIfNeeded()
        guard self.directory != directory else { return }
        self.directory = directory
        generation = UUID()
        previewRequest = UUID()
        loadingChanges = false
        loadingCI = false
        changes = nil
        ci = nil
        changeError = nil
        ciError = nil
        selectedFileID = nil
        renderedFileID = nil
        rows = []
        search.stringValue = ""
        selectedCheck = nil
        ciMessage = "Checking CI…"
        lastCIFetch = .distantPast
        actionButton.isEnabled = false
        fileTitle.stringValue = isCI ? "Commit checks" : "Changes"
        fileDetail.stringValue = ""
        table.deselectAll(nil)
        table.reloadData()
        displayPreview(directory == nil ? "Select a worktree to review changes and CI." : "Loading changes…")
        updateSummary()
        timer?.invalidate()
        timer = nil
        guard directory != nil, automaticallyRefresh else { return }
        refresh(forceCI: true)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.view.window?.isVisible == true else { return }
            self.refresh(forceCI: false)
        }
    }

    func showCI(_ show: Bool) {
        loadViewIfNeeded()
        modes.selectedSegment = show ? 1 : 0
        modeChanged()
    }

    @objc private func refreshClicked() { refresh(forceCI: true) }

    func refresh(forceCI: Bool = false) {
        guard let directory, !loadingChanges else { return }
        let request = generation
        loadingChanges = true
        updateProgress()
        let load = loadChanges
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try load(directory) }
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                self.loadingChanges = false
                switch result {
                case .success(let snapshot):
                    let headChanged = self.changes?.head != snapshot.head
                    let listChanged = self.changes?.files != snapshot.files || self.changeError != nil
                    self.changes = snapshot
                    self.changeError = nil
                    if headChanged {
                        // Invalidate the CI request for the old commit, even in the same worktree.
                        self.ciGeneration = UUID()
                        self.loadingCI = false
                        self.ci = nil
                        self.ciError = nil
                        self.ciMessage = "Checking CI…"
                        self.lastCIFetch = .distantPast
                        if self.isCI {
                            self.selectedCheck = nil
                            self.table.reloadData()
                            self.showCIOverview()
                        }
                    }
                    if !self.isCI {
                        if listChanged { self.reloadFiles() }
                        self.loadPreview(showLoading: self.renderedFileID != self.selectedFile?.identity)
                    }
                    self.refreshCI(force: forceCI || headChanged)
                case .failure(let error):
                    self.changes = nil
                    self.ci = nil
                    self.previewRequest = UUID()
                    self.selectedFileID = nil
                    self.selectedCheck = nil
                    self.actionButton.isEnabled = false
                    self.ciGeneration = UUID()
                    self.loadingCI = false
                    self.changeError = error.localizedDescription
                    self.ciMessage = "CI unavailable"
                    self.rows = []
                    self.renderedFileID = nil
                    self.fileTitle.stringValue = "Changes unavailable"
                    self.fileDetail.stringValue = "Refresh to try again"
                    self.table.reloadData()
                    self.displayPreview(error.localizedDescription)
                }
                self.updateSummary()
            }
        }
    }

    private var ciGeneration = UUID()

    private func refreshCI(force: Bool) {
        guard let directory else { return }
        guard let head = changes?.head else {
            ciMessage = "No commit yet"
            ci = nil
            if isCI { showCIOverview() }
            updateSummary()
            return
        }
        guard !loadingCI, force || Date().timeIntervalSince(lastCIFetch) >= 30 else { return }
        let workspaceRequest = generation
        let request = UUID()
        ciGeneration = request
        loadingCI = true
        updateProgress()
        if ci == nil { ciMessage = "Checking CI…" }
        let load = loadCI
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try load(directory, head) }
            DispatchQueue.main.async {
                guard let self, self.generation == workspaceRequest, self.ciGeneration == request else { return }
                self.loadingCI = false
                self.lastCIFetch = Date()
                switch result {
                case .success(let snapshot):
                    self.ci = snapshot
                    self.ciError = nil
                    self.ciMessage = snapshot.summary
                case .failure(let error):
                    self.ci = nil
                    self.ciError = error.localizedDescription
                    self.ciMessage = "Unavailable"
                }
                if self.isCI {
                    let selected = self.selectedCheck
                    self.table.reloadData()
                    if let row = self.ci?.checks.firstIndex(where: { $0.name == selected?.name && $0.url == selected?.url }) {
                        self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        self.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
                    } else {
                        self.table.deselectAll(nil)
                        self.selectedCheck = nil
                        self.showCIOverview()
                    }
                }
                self.updateSummary()
            }
        }
    }

    private func updateProgress() {
        if loadingChanges || (isCI && loadingCI) { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
    }

    private func updateSummary() {
        updateProgress()
        updateEmptyList()
        let count = Set(changes?.files.map(\.path) ?? []).count
        let changeTitle = changeError != nil ? "Changes unavailable" : changes == nil ? "Changes" : "Changes · \(count)"
        onSummary?(changeTitle, directory == nil ? "CI" : "CI · \(ciMessage)", ci?.state)
        if directory == nil { context.stringValue = "Select a worktree to review changes and CI." }
        else if isCI {
            context.stringValue = "\(ciMessage) · HEAD \(changes?.head.map { String($0.prefix(8)) } ?? "—")\nChecks apply to this commit, not uncommitted changes."
        } else {
            let worktree = directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Worktree"
            context.stringValue = changeError != nil ? "Could not read changes. Refresh to try again."
                : changes == nil ? "\(worktree) · Loading changes…"
                : "\(worktree) · \(count) changed \(count == 1 ? "file" : "files")"
            context.toolTip = directory

        }
    }

    @objc private func modeChanged() {
        previewRequest = UUID()
        reloadingList = true
        table.deselectAll(nil)
        selectedCheck = nil
        table.reloadData()
        reloadingList = false
        search.isHidden = isCI
        actionButton.title = isCI ? "Open Check Logs ↗" : "Reveal in Finder"
        actionButton.isEnabled = false
        if isCI { showCIOverview() } else { reloadFiles(); loadPreview(showLoading: true) }
        updateSummary()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isCI else { return }
        reloadFiles()
        loadPreview(showLoading: renderedFileID != selectedFile?.identity)
        updateEmptyList()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search,
              commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.insertNewline(_:))
        else { return false }
        focusList()
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
        return true
    }

    private func reloadFiles() {
        let selected = selectedFileID
        let scrollOrigin = listScroll.contentView.bounds.origin
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = (changes?.files ?? []).filter {
            query.isEmpty || $0.path.localizedStandardContains(query) || ($0.originalPath?.localizedStandardContains(query) ?? false)
        }
        rows = []
        for area: ChangedFile.Area in [.conflicted, .staged, .unstaged, .untracked] {
            let group = files.filter { $0.area == area }
            guard !group.isEmpty else { continue }
            rows.append(.group(area, group.count))
            rows.append(contentsOf: group.map(FileRow.file))
        }
        reloadingList = true
        table.reloadData()
        let selectedRow = rows.firstIndex { if case .file(let file) = $0 { return file.identity == selected }; return false }
        let firstFile = rows.firstIndex { if case .file = $0 { return true }; return false }
        if let row = selectedRow ?? firstFile {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            selectedFileID = selectedFile?.identity
        } else {
            table.deselectAll(nil)
            selectedFileID = nil
        }
        reloadingList = false
        listScroll.contentView.scroll(to: scrollOrigin)
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    private func updateEmptyList() {
        emptyList.isHidden = numberOfRows(in: table) > 0
        if directory == nil { emptyList.stringValue = "Select a worktree to get started." }
        else if isCI { emptyList.stringValue = loadingCI ? "Checking CI…" : ciError == nil ? ciMessage : "Checks unavailable" }
        else if changeError != nil { emptyList.stringValue = "Changes unavailable" }
        else if changes == nil { emptyList.stringValue = "Loading changes…" }
        else if changes?.files.isEmpty == true { emptyList.stringValue = "✓  Working tree clean" }
        else { emptyList.stringValue = "No files match “\(search.stringValue)”." }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { isCI ? ci?.checks.count ?? 0 : rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard !isCI, case .group = rows[safe: row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        self.tableView(tableView, isGroupRow: row) ? 28 : 46
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if !isCI, case .group(let area, let count) = rows[safe: row] {
            let label = NSTextField(labelWithString: "\(area.rawValue)  ·  \(count)")
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = area == .conflicted ? .systemOrange : .secondaryLabelColor
            return label
        }
        let title: String
        let detail: String
        let symbol: String
        let color: NSColor
        if isCI {
            guard let check = ci?.checks[safe: row] else { return nil }
            title = check.name
            detail = "\(check.state.rawValue) · \(check.detail)"
            symbol = check.state.symbol
            color = Self.color(check.state)
        } else {
            guard case .file(let file) = rows[safe: row] else { return nil }
            title = (file.path as NSString).lastPathComponent
            let parent = (file.path as NSString).deletingLastPathComponent
            detail = file.originalPath.map { "\(file.statusDescription) · from \($0)" }
                ?? "\(file.statusDescription)\(parent.isEmpty ? "" : " · " + parent)"
            symbol = file.area == .conflicted ? "exclamationmark.triangle.fill"
                : file.status == "D" ? "minus.circle" : file.status == "A" || file.area == .untracked ? "plus.circle" : "doc.text"
            color = file.area == .conflicted ? .systemOrange : file.status == "D" ? .systemRed
                : file.status == "A" || file.area == .untracked ? .systemGreen : .secondaryLabelColor
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: detail)!)
        icon.contentTintColor = color
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [name, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let rowView = NSStackView(views: [icon, labels])
        rowView.spacing = 8
        rowView.toolTip = title + "\n" + detail
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        labels.widthAnchor.constraint(equalTo: rowView.widthAnchor, constant: -24).isActive = true
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        subtitle.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        if !isCI, case .file(let file) = rows[safe: row] { rowView.toolTip = file.title + "\n" + file.area.rawValue + " · " + file.statusDescription }
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingList else { return }
        if isCI {
            selectedCheck = ci?.checks[safe: table.selectedRow]
            if let check = selectedCheck {
                fileTitle.stringValue = check.name
                fileDetail.stringValue = check.state.rawValue + " · " + check.detail
                displayPreview("\(check.name)\n\n\(check.state.rawValue): \(check.detail)\n\n\(check.url?.absoluteString ?? "No log link was provided by this check.")")
            } else { showCIOverview() }
            actionButton.isEnabled = selectedCheck?.url != nil
        } else {
            selectedFileID = selectedFile?.identity
            loadPreview(showLoading: true)
        }
    }

    private func loadPreview(showLoading: Bool) {
        let request = UUID()
        previewRequest = request
        guard !isCI, !view.isHiddenOrHasHiddenAncestor, let directory else { return }
        guard let file = selectedFile else {
            renderedFileID = nil
            actionButton.isEnabled = false
            fileTitle.stringValue = "Changes"
            fileDetail.stringValue = ""
            displayPreview(changeError ?? (changes == nil ? "Loading changes…" : changes?.files.isEmpty == true
                ? "Working tree clean\n\nNew edits will appear here automatically."
                : "No matching files\n\nTry another name or clear the filter to see all changes."))
            return
        }
        let sameFile = renderedFileID == file.identity
        renderedFileID = file.identity
        actionButton.isEnabled = true
        fileTitle.stringValue = (file.path as NSString).lastPathComponent
        fileTitle.toolTip = file.title
        fileDetail.stringValue = "\(file.area.rawValue) · \(file.path)"
        fileDetail.toolTip = file.title
        if showLoading && !sameFile { displayPreview(file.area == .untracked ? "Loading preview…" : "Loading diff…") }
        let load = loadFilePreview
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try load(file, directory) }
            DispatchQueue.main.async {
                guard let self, self.previewRequest == request else { return }
                switch result {
                case .success(let text):
                    self.displayPreview(text, isDiff: file.area != .untracked, preservePosition: sameFile)
                    self.copyButton.isEnabled = true
                    let copyLabel = file.area == .untracked ? "Copy file contents" : "Copy diff"
                    self.copyButton.toolTip = copyLabel
                    self.copyButton.setAccessibilityLabel(copyLabel)
                case .failure(let error): self.displayPreview(error.localizedDescription)
                }
            }
        }
    }

    private func showCIOverview() {
        renderedFileID = nil
        fileTitle.stringValue = "Commit checks"
        fileDetail.stringValue = changes?.head.map { "HEAD " + String($0.prefix(8)) } ?? "No commit yet"
        actionButton.isEnabled = false
        if let ciError {
            displayPreview("CI unavailable\n\n\(ciError)\n\nCI requires a GitHub remote and gh authentication. A local commit must be pushed before GitHub can report checks for it. Refresh to retry.")
        } else if let ci, ci.checks.isEmpty {
            displayPreview("No checks reported for this commit.\n\nPush this commit and wait for your CI provider to start. Repositories without CI will have no checks.")
        } else {
            displayPreview("\(ciMessage)\n\nSelect a check to see details and open its logs.")
        }
    }

    private func displayPreview(_ text: String, isDiff: Bool = false, preservePosition: Bool = false) {
        guard preview.string != text || previewIsDiff != isDiff else { return }
        let origin = diffScroll.contentView.bounds.origin
        let selection = preview.selectedRange()
        previewIsDiff = isDiff
        presentation = ReviewDiffPresentation(text: text, isDiff: isDiff)
        currentHunk = -1
        hunkPosition.stringValue = presentation.hunks.isEmpty ? ""
            : "\(presentation.hunks.count) \(presentation.hunks.count == 1 ? "change" : "changes")"
        preview.textStorage?.setAttributedString(presentation.attributedText)
        statistics.attributedStringValue = presentation.statistics
        copyButton.isEnabled = false
        previousHunk.isEnabled = !presentation.hunks.isEmpty
        nextHunk.isEnabled = !presentation.hunks.isEmpty
        if preservePosition {
            let length = (text as NSString).length
            let start = min(selection.location, length)
            preview.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
            preview.layoutManager?.ensureLayout(for: preview.textContainer!)
            diffScroll.contentView.scroll(to: origin)
        } else {
            preview.setSelectedRange(NSRange(location: 0, length: 0))
            diffScroll.contentView.scroll(to: .zero)
        }
        diffScroll.reflectScrolledClipView(diffScroll.contentView)
    }

    @objc private func copyPreview() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview.string, forType: .string)
    }

    @objc private func toggleWrap() {
        let wraps = wrapButton.state == .on
        preview.isHorizontallyResizable = !wraps
        preview.textContainer?.widthTracksTextView = wraps
        preview.textContainer?.containerSize = NSSize(width: wraps ? diffScroll.contentSize.width : CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
        if wraps { preview.setFrameSize(NSSize(width: diffScroll.contentSize.width, height: preview.frame.height)) }
        diffScroll.hasHorizontalScroller = !wraps
        preview.layoutManager?.ensureLayout(for: preview.textContainer!)
    }

    @objc private func previousChange() { navigateChange(forward: false) }
    @objc private func nextChange() { navigateChange(forward: true) }

    private func navigateChange(forward: Bool) {
        let hunks = presentation.hunks
        guard !hunks.isEmpty else { return }
        currentHunk = currentHunk < 0 ? (forward ? 0 : hunks.count - 1)
            : (currentHunk + (forward ? 1 : hunks.count - 1)) % hunks.count
        let range = hunks[currentHunk]
        hunkPosition.stringValue = "\(currentHunk + 1) of \(hunks.count)"
        preview.setSelectedRange(NSRange(location: range.location, length: 0))
        preview.scrollRangeToVisible(range)
        preview.showFindIndicator(for: range)
    }

    @objc private func openSelected() {
        if isCI, let url = selectedCheck?.url { NSWorkspace.shared.open(url) }
        else if !isCI, let directory, let file = selectedFile {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(file.path)
            NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()])
        }
    }

    static func color(_ state: CheckState) -> NSColor {
        switch state {
        case .failed: return .systemRed
        case .pending: return .systemOrange
        case .passed: return .systemGreen
        case .unknown, .skipped: return .secondaryLabelColor
        }
    }
}

private final class ReviewBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension NSLayoutConstraint {
    func withPriority(_ value: NSLayoutConstraint.Priority) -> NSLayoutConstraint { priority = value; return self }
}

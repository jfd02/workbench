import AppKit
import XCTest
@testable import TabTerm

final class WorkspaceChromeTests: XCTestCase {
    @MainActor func testSidebarSelectionSurvivesStatusRefreshes() throws {
        let database = AppDatabase.useTemporaryDatabase()
        // Seed rows directly: the refresh must preserve a child selection as
        // well as Home, even when a repository is unavailable on disk.
        try database.queue.write { db in
            try db.execute(sql: "INSERT INTO repository (id, path, name, position) VALUES (1, '/tmp/workbench-missing-demo-repo', 'Demo', 0)")
            try db.execute(sql: "INSERT INTO worktree (id, repositoryId, path, branch, isMain, position) VALUES (1, 1, '/tmp/workbench-missing-demo-repo', 'main', 1, 0)")
        }
        let sidebar = SidebarViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = sidebar
        defer { window.contentViewController = nil }
        func outline(in view: NSView) -> NSOutlineView? {
            if let found = view as? NSOutlineView { return found }
            return view.subviews.compactMap { outline(in: $0) }.first
        }
        let table = try XCTUnwrap(outline(in: sidebar.view))
        var navigationEvents = 0
        sidebar.onSelect = { _ in navigationEvents += 1 }

        for key in [WorkspaceKey.home, .worktree(1)] {
            sidebar.select(key)
            window.makeFirstResponder(nil)
            for _ in 0..<3 {
                sidebar.refreshAgentStates()
                sidebar.view.layoutSubtreeIfNeeded()
                let node = try XCTUnwrap(table.item(atRow: table.selectedRow) as? SidebarNode)
                XCTAssertEqual(node.workspaceKey, key, "Agent refreshes must keep the active workspace selected")
                let row = try XCTUnwrap(table.rowView(atRow: table.selectedRow, makeIfNecessary: true))
                XCTAssertTrue(row.isSelected, "The active row must still draw its highlight")
            }
        }
        XCTAssertEqual(navigationEvents, 0, "Refreshing status must not navigate or steal terminal focus")
    }

    @MainActor func testReviewControlsStayVisibleBesideOverflowingTabs() throws {
        let bar = TabBarView(frame: .zero)
        let changes = NSButton(title: "Changes · 123", target: nil, action: nil)
        let ci = NSButton(title: "CI · Unavailable", target: nil, action: nil)
        for button in [changes, ci] {
            button.bezelStyle = .inline
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            bar.trailingControls.addArrangedSubview(button)
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = root
        defer { window.contentView = nil }

        let tabs = (0..<20).map { _ in Tab(content: EmptyTerminal()) }
        bar.reload(tabs: tabs, selectedID: tabs.last?.id)
        for width in [400.0, 600, 1100] {
            window.setContentSize(NSSize(width: width, height: 100))
            root.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(bar.subviews.compactMap { $0 as? NSScrollView }.first)
            let controls = bar.trailingControls.frame
            XCTAssertLessThanOrEqual(scroll.frame.maxX, controls.minX)
            XCTAssertGreaterThan(scroll.frame.width, 80)
            XCTAssertLessThanOrEqual(controls.maxX, bar.bounds.maxX)
            XCTAssertEqual(controls.midY, bar.bounds.midY, accuracy: 1)
            let scrollbarHeight = NSScroller.preferredScrollerStyle == .legacy
                ? NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy) : 0
            XCTAssertEqual(bar.bounds.height, 42 + scrollbarHeight, accuracy: 1,
                           "Controls must not add a second row; legacy scrollbars still need their own space")
            for button in [changes, ci] {
                XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width - 1)
            }
        }
    }
}

private final class EmptyTerminal: TabContent {
    let view = NSView()
    let title = "Demo terminal"
    let icon: NSImage? = nil
    var onTitleChange: ((String) -> Void)?
    var onIconChange: ((NSImage?) -> Void)?
    var onRequestClose: ((Bool) -> Void)?
    let closeConfirmationDetail = ""
    let isDisposable = true
    func takeFocus() {}
    func setFocused(_ focused: Bool) {}
    func setVisible(_ visible: Bool) {}
    func close() {}
}

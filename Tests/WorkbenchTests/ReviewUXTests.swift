import AppKit
import XCTest
@testable import TabTerm

final class ReviewUXTests: XCTestCase {
    private let patch = """
    diff --git a/Sources/Feature.swift b/Sources/Feature.swift
    index 1234567..abcdef0 100644
    --- a/Sources/Feature.swift
    +++ b/Sources/Feature.swift
    @@ -1,2 +1,2 @@
    -let title = "Old"
    +let title = "Review ✨"
     let enabled = true
    @@ -20 +20,2 @@
    -old()
    +new()
    +save()
    """

    func testDiffCountsExcludeHeadersAndUseUTF16HunkRanges() {
        let text = patch.replacingOccurrences(of: "Feature.swift", with: "✨Feature.swift")
        let presentation = ReviewDiffPresentation(text: text, isDiff: true)
        XCTAssertEqual(presentation.additions, 3)
        XCTAssertEqual(presentation.deletions, 2)
        XCTAssertEqual(presentation.hunks.count, 2)
        for range in presentation.hunks {
            XCTAssertTrue((text as NSString).substring(with: range).hasPrefix("@@"))
        }
        XCTAssertEqual(presentation.attributedText.string, text, "Copying must preserve the original patch")
        let header = (text as NSString).range(of: "+++ b/")
        XCTAssertNil(presentation.attributedText.attribute(.backgroundColor, at: header.location, effectiveRange: nil))
    }

    func testRawFilesAndCombinedConflictsDoNotGetMisleadingCounts() {
        let raw = ReviewDiffPresentation(text: "+ shopping\n- list\n@@ note", isDiff: false)
        XCTAssertEqual(raw.additions, 0)
        XCTAssertEqual(raw.deletions, 0)
        XCTAssertTrue(raw.hunks.isEmpty)
        XCTAssertNil(raw.attributedText.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        let conflict = ReviewDiffPresentation(text: "diff --cc file\n@@@ -1 -1 +1 @@@\n++merged\n- old", isDiff: true)
        XCTAssertEqual(conflict.hunks.count, 1)
        XCTAssertEqual(conflict.additions + conflict.deletions, 0)
    }

    @MainActor private func child<T: NSView>(_ id: String, in view: NSView, as type: T.Type = T.self) throws -> T {
        if view.accessibilityIdentifier() == id, let found = view as? T { return found }
        for subview in view.subviews {
            if let found = try? child(id, in: subview, as: type) { return found }
        }
        throw NSError(domain: "ReviewUXTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing view: \(id)"])
    }

    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Review did not finish updating")
    }

    @MainActor private func makePanel() -> (ReviewViewController, NSWindow) {
        let controller = ReviewViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 420, height: 720))
        controller.loadChanges = { _ in
            ChangelistSnapshot(files: [
                ChangedFile(path: "Sources/Feature.swift", status: "M", area: .staged),
                ChangedFile(path: "Sources/Feature.swift", status: "M", area: .unstaged),
                ChangedFile(path: "Sources/Views/ReviewPanel.swift", originalPath: "Sources/OldPanel.swift", status: "R", area: .staged),
                ChangedFile(path: "Tests/FeatureTests.swift", status: "?", area: .untracked),
            ], head: "abc12345")
        }
        controller.loadCI = { _, _ in CISnapshot(checks: []) }
        let patch = self.patch
        controller.loadFilePreview = { file, _ in file.area == .untracked ? "+ raw text\n- also raw" : patch }
        controller.select(directory: "/work/feature-review", automaticallyRefresh: false)
        controller.refresh()
        return (controller, window)
    }

    @MainActor func testFilteringGroupsAndModeSwitchPreserveSelectedStagingArea() async throws {
        let (controller, window) = makePanel()
        defer { window.contentViewController = nil }
        let table: NSTableView = try child("reviewList", in: controller.view)
        let preview: NSTextView = try child("changePreview", in: controller.view)
        let search: NSSearchField = try child("filterReviewFiles", in: controller.view)
        try await waitFor { preview.string == self.patch }
        XCTAssertEqual(table.numberOfRows, 7) // Four files, three section headers.
        XCTAssertFalse(controller.tableView(table, shouldSelectRow: 0))
        XCTAssertEqual(table.selectedRow, 1)
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        controller.showCI(true)
        controller.showCI(false)
        XCTAssertEqual(table.selectedRow, 4, "The unstaged version should remain selected")

        search.stringValue = "OldPanel"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(table.numberOfRows, 2, "Original paths of renamed files should be searchable")
        search.stringValue = "missing-file"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertTrue(preview.string.contains("No matching files"))
        let copy: NSButton = try child("copyReviewDiff", in: controller.view)
        XCTAssertFalse(copy.isEnabled)
        search.stringValue = "FeatureTests"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await waitFor { preview.string == "+ raw text\n- also raw" }
        let stats: NSTextField = try child("reviewDiffStatistics", in: controller.view)
        XCTAssertEqual(stats.stringValue, "")
        XCTAssertTrue(copy.isEnabled)
    }

    @MainActor func testHunkNavigationWrappingAndBackgroundRefreshKeepReadingPosition() async throws {
        let (controller, window) = makePanel()
        defer { window.contentViewController = nil }
        let preview: NSTextView = try child("changePreview", in: controller.view)
        try await waitFor { preview.string == self.patch }
        let next: NSButton = try child("nextReviewChange", in: controller.view)
        let previous: NSButton = try child("previousReviewChange", in: controller.view)
        next.performClick(nil)
        XCTAssertEqual(preview.selectedRange().location, (patch as NSString).range(of: "@@ -1").location)
        next.performClick(nil)
        XCTAssertEqual(preview.selectedRange().location, (patch as NSString).range(of: "@@ -20").location)
        previous.performClick(nil)
        XCTAssertEqual(preview.selectedRange().location, (patch as NSString).range(of: "@@ -1").location)
        let wrap: NSButton = try child("wrapReviewLines", in: controller.view)
        wrap.performClick(nil)
        XCTAssertEqual(wrap.state, .on)
        XCTAssertTrue(preview.textContainer!.widthTracksTextView)
        XCTAssertFalse(preview.enclosingScrollView!.hasHorizontalScroller)
        wrap.performClick(nil)
        XCTAssertFalse(preview.textContainer!.widthTracksTextView)
        XCTAssertTrue(preview.enclosingScrollView!.hasHorizontalScroller)

        let longLine = String(repeating: "wide content ", count: 40)
        let longPatch = patch + "\n " + longLine + "\n" + (0..<200).map { " context line \($0)" }.joined(separator: "\n")
        controller.loadFilePreview = { _, _ in longPatch }
        controller.refresh()
        try await waitFor { preview.string == longPatch }
        controller.view.layoutSubtreeIfNeeded()
        preview.layoutManager!.ensureLayout(for: preview.textContainer!)
        let scroll = try XCTUnwrap(preview.enclosingScrollView)
        XCTAssertGreaterThan(preview.frame.width, scroll.contentSize.width, "Unwrapped long lines must be horizontally scrollable")
        wrap.performClick(nil)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(preview.frame.width, scroll.contentSize.width + 1)
        wrap.performClick(nil)
        preview.layoutManager!.ensureLayout(for: preview.textContainer!)
        preview.setSelectedRange(NSRange(location: 80, length: 6))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 350))
        let origin = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(origin.y, 0)
        let updated = longPatch + "\n+one more line"
        controller.loadFilePreview = { _, _ in updated }
        controller.refresh()
        try await waitFor { preview.string == updated }
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 1)
        XCTAssertEqual(preview.selectedRange(), NSRange(location: 80, length: 6))
    }

    @MainActor func testLateFilePreviewCannotReplaceNewSelection() async throws {
        let (controller, window) = makePanel()
        defer { window.contentViewController = nil }
        let preview: NSTextView = try child("changePreview", in: controller.view)
        let table: NSTableView = try child("reviewList", in: controller.view)
        try await waitFor { preview.string == self.patch }
        let started = expectation(description: "slow file started")
        let gate = DispatchSemaphore(value: 0)
        controller.loadFilePreview = { file, _ in
            if file.area == .unstaged {
                started.fulfill()
                _ = gate.wait(timeout: .now() + 3)
                return "stale preview"
            }
            return "latest preview"
        }
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        await fulfillment(of: [started], timeout: 2)
        table.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        try await waitFor { preview.string == "latest preview" }
        gate.signal()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(preview.string, "latest preview")
    }

    @MainActor func testPanelKeepsUsableReadingAreaAtSupportedWidths() async throws {
        let (controller, window) = makePanel()
        defer { window.contentViewController = nil }
        let preview: NSTextView = try child("changePreview", in: controller.view)
        let table: NSTableView = try child("reviewList", in: controller.view)
        let heading: NSTextField = try child("reviewFileTitle", in: controller.view)
        try await waitFor { preview.string == self.patch }
        for width in [300.0, 420.0, 600.0] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                controller.view.appearance = NSAppearance(named: appearance)
                window.setContentSize(NSSize(width: width, height: 720))
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
                controller.view.displayIfNeeded()
                XCTAssertGreaterThan(preview.enclosingScrollView!.frame.height, 250)
                XCTAssertGreaterThan(table.enclosingScrollView!.frame.height, 140)
                XCTAssertLessThan(controller.view.convert(heading.bounds, from: heading).minX, 20)
                if let destination = ProcessInfo.processInfo.environment["WORKBENCH_REVIEW_PREVIEW_DIR"] {
                    let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent("review-\(Int(width))-\(appearance.rawValue).png"))
                }
            }
        }
    }
}

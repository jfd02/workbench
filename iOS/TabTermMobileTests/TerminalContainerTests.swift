import SwiftTerm
import TabTermKit
import UIKit
import XCTest
@testable import TabTermMobile

/// The keyboard rising must not resize the terminal: on the phone that size is
/// the Mac's pty size, and a resize makes the program on the Mac redraw.
@MainActor
final class TerminalContainerTests: XCTestCase {
    func testKeyboardKeepsTheTerminalsHeight() {
        let container = TerminalContainerView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let terminal = TerminalView(frame: .zero)
        container.host(terminal)
        container.layoutIfNeeded()
        XCTAssertEqual(terminal.frame, container.bounds)

        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        container.frame.size.height = 300
        container.layoutIfNeeded()
        XCTAssertEqual(terminal.frame.height, 600, "same height as before the keyboard")
        XCTAssertEqual(terminal.frame.maxY, 300, "pinned to the bottom, so the prompt stays in view")

        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        container.frame.size.height = 600
        container.layoutIfNeeded()
        XCTAssertEqual(terminal.frame, container.bounds)
    }

    func testRotationWhileLockedFollowsTheNewShape() {
        let container = TerminalContainerView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let terminal = TerminalView(frame: .zero)
        container.host(terminal)
        container.layoutIfNeeded()

        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        container.frame = CGRect(x: 0, y: 0, width: 800, height: 200)
        container.layoutIfNeeded()
        XCTAssertEqual(terminal.frame, container.bounds)

        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    func testClaudeStatusGlyphsAreDroppedFromTitles() {
        XCTAssertEqual(PaneInfo.strippingStatusGlyph("✳ Fix the tests"), "Fix the tests")
        XCTAssertEqual(PaneInfo.strippingStatusGlyph("⠂ Fix the tests"), "Fix the tests")
        XCTAssertEqual(PaneInfo.strippingStatusGlyph("~/code/myapp"), "~/code/myapp")
        XCTAssertEqual(PaneInfo.strippingStatusGlyph("zsh"), "zsh")
    }
}

import SwiftTerm
import TabTermKit
import UIKit
import XCTest
@testable import TabTermMobile

/// A program on the alternate screen keeps its own scrollback, so a drag has
/// to reach it as the Mac's Ghostty would send a scroll: wheel events when it
/// listens to the mouse (Claude Code's fullscreen mode), arrow keys when not.
@MainActor
final class AlternateScreenScrollTests: XCTestCase {
    private var terminal: RemoteTerminal!
    private var inputs: [Data] = []

    override func setUp() {
        super.setUp()
        inputs = []
        terminal = RemoteTerminal(session: UUID())
        terminal.terminalView.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        terminal.isLinkUp = { true }
        terminal.sendFrame = { [unowned self] frame in
            if frame.kind == .input { inputs.append(frame.payload) }
        }
        terminal.attach(visible: true)
    }

    func testWheelEventsForAProgramListeningToTheMouse() {
        // What Claude Code's fullscreen mode turns on.
        terminal.feedLocal("\u{1b}[?1049h\u{1b}[?1003h\u{1b}[?1006h")

        terminal.terminalView.onScroll?(2, 5, 3)
        terminal.terminalView.onScroll?(-1, 0, 0)

        XCTAssertEqual(inputs, [
            Data("\u{1b}[<64;6;4M\u{1b}[<64;6;4M".utf8),
            Data("\u{1b}[<65;1;1M".utf8),
        ])
    }

    func testArrowKeysForAProgramThatIsnt() {
        terminal.feedLocal("\u{1b}[?1049h")
        terminal.terminalView.onScroll?(-2, 0, 0)

        terminal.feedLocal("\u{1b}[?1h")
        terminal.terminalView.onScroll?(1, 0, 0)

        XCTAssertEqual(inputs, [
            Data("\u{1b}[B\u{1b}[B".utf8),
            Data("\u{1b}OA".utf8),
        ])
    }

    func testRepliesAreStillFilteredOut() {
        terminal.feedLocal("\u{1b}[?1049h\u{1b}[?1003h\u{1b}[?1006h")
        terminal.terminalView.onScroll?(1, 0, 0)
        inputs = []

        // A cursor position query: the Mac answers it, the phone mustn't.
        terminal.feedLocal("\u{1b}[6n")
        XCTAssertEqual(inputs, [])
    }

    func testTheDragIsNotTheScrollViewsOnTheAlternateScreen() {
        let view = terminal.terminalView
        terminal.feedLocal("\u{1b}[?1049h")
        XCTAssertFalse(view.gestureRecognizerShouldBegin(view.panGestureRecognizer))
    }
}

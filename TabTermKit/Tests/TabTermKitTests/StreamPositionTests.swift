import TabTermKit
import XCTest

/// The bookkeeping that decides whether a return to a terminal is caught up
/// exactly or starts over. Getting it wrong shows as a screen that is subtly
/// out of step with the Mac, so it is pinned down here.
final class StreamPositionTests: XCTestCase {
    private let session = UUID()

    private func synced(_ mode: Synced.Mode, epoch: String = "e1", seq: UInt64) -> Synced {
        Synced(session: session, epoch: epoch, seq: seq, mode: mode, size: TerminalSize(cols: 48, rows: 30))
    }

    func testFreshUntilSomethingIsOnScreen() {
        let position = StreamPosition()
        XCTAssertEqual(position.anchor, .fresh)
        XCTAssertFalse(position.isCounting)
    }

    func testCountsOnlyAfterSynced() {
        var position = StreamPosition()
        position.suspend()
        XCTAssertFalse(position.receiveOutput(count: 5), "bytes before synced can't be placed")

        position.apply(synced(.reset, seq: 100))
        XCTAssertTrue(position.receiveOutput(count: 20))
        XCTAssertTrue(position.receiveOutput(count: 5))
        XCTAssertEqual(position.anchor, .position(epoch: "e1", seq: 125))
    }

    func testSuspendKeepsThePositionToResumeFrom() {
        var position = StreamPosition()
        position.apply(synced(.reset, seq: 0))
        _ = position.receiveOutput(count: 42)

        position.suspend()
        XCTAssertFalse(position.isCounting)
        XCTAssertFalse(position.receiveOutput(count: 10), "stale bytes after a drop are ignored")
        XCTAssertEqual(position.anchor, .position(epoch: "e1", seq: 42))

        // An exact catch-up continues from where we were.
        position.suspend()
        position.apply(synced(.exact, seq: 42))
        XCTAssertTrue(position.receiveOutput(count: 8))
        XCTAssertEqual(position.anchor, .position(epoch: "e1", seq: 50))
    }

    func testResetMovesToTheNewStream() {
        var position = StreamPosition()
        position.apply(synced(.reset, epoch: "old", seq: 0))
        _ = position.receiveOutput(count: 1000)

        // The Mac restarted: a different epoch, served as a reset from its ring.
        position.suspend()
        position.apply(synced(.reset, epoch: "new", seq: 7_000))
        XCTAssertTrue(position.receiveOutput(count: 3))
        XCTAssertEqual(position.anchor, .position(epoch: "new", seq: 7_003))
    }
}

import XCTest
@testable import TabTermKit

final class WireTests: XCTestCase {
    func testFramesSurviveAnyChunking() throws {
        let session = UUID()
        let frames: [Frame] = [
            .control(ClientMessage.ping(Ping(id: 7))),
            .output(session, Data("hello\u{1b}[31mred".utf8)),
            .input(session, Data([0x03])),
            .synthesized(session, Data()),
        ]
        let stream = frames.map { $0.encoded() }.reduce(Data(), +)

        // Every split point, one byte at a time and all at once.
        for chunk in [1, 2, 3, 7, stream.count] {
            var decoder = FrameDecoder()
            var decoded: [Frame] = []
            var index = 0
            while index < stream.count {
                let end = min(index + chunk, stream.count)
                decoded += try decoder.append(stream[index..<end])
                index = end
            }
            XCTAssertEqual(decoded, frames, "chunk size \(chunk)")
            XCTAssertEqual(decoder.pendingBytes, 0)
        }
    }

    func testGarbageLengthPoisonsTheDecoder() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 1])))
        XCTAssertThrowsError(try decoder.append(Frame.control(Ping(id: 1)).encoded()))
    }

    func testControlMessagesRoundTrip() throws {
        let session = UUID()
        let messages: [ClientMessage] = [
            .hello(Hello(deviceName: "iPhone", deviceToken: nil, pairingCode: "abc")),
            .attach(Attach(session: session, anchor: .position(epoch: "e", seq: 42), size: TerminalSize(cols: 40, rows: 20))),
            .attach(Attach(session: session, anchor: .fresh, size: TerminalSize(cols: 40, rows: 20), visible: false)),
            .submit(Submit(session: session, text: "fix the tests")),
            .newTab(NewTab(workspace: "worktree:3", requestID: "r1")),
            .newWorktree(NewWorktree(workspace: "worktree:3", branch: "feature/auth", requestID: "r2")),
            .viewing(Viewing(session: nil)),
        ]
        for message in messages {
            let frame = Frame.control(message)
            XCTAssertEqual(try frame.decode(ClientMessage.self), message)
        }

        let state = HostState(
            hostName: "Mac",
            workspaces: [
                WorkspaceInfo(
                    id: "home", name: "Home", repository: nil, branch: nil, directory: nil,
                    isOpen: true, status: .blocked,
                    tabs: [TabInfo(id: UUID(), title: "~", isSelected: true, panes: [
                        PaneInfo(session: session, title: "claude", directory: "/tmp", isClaude: true, status: .blocked, isFocused: true),
                    ])]
                ),
            ],
            focus: HostState.Focus(workspace: "home", session: session)
        )
        let reply = ServerMessage.state(state)
        XCTAssertEqual(try Frame.control(reply).decode(ServerMessage.self), reply)
        XCTAssertEqual(state.locate(session)?.pane.title, "claude")

        let created = ServerMessage.worktreeCreated(WorktreeCreated(requestID: "r2", workspace: "worktree:4"))
        XCTAssertEqual(try Frame.control(created).decode(ServerMessage.self), created)
    }
}

final class ModeTrackerTests: XCTestCase {
    private func tracker(_ text: String) -> ModeTracker {
        var tracker = ModeTracker()
        tracker.feed(Data(text.utf8))
        return tracker
    }

    func testTracksTheModesThatMatter() {
        let t = tracker("\u{1b}[?1049h\u{1b}[?1;2004h\u{1b}[?25l\u{1b}[?1002h\u{1b}[?1006h\u{1b}=\u{1b}[5 q")
        XCTAssertEqual(t.modes.alternateScreen, 1049)
        XCTAssertTrue(t.modes.applicationCursor)
        XCTAssertTrue(t.modes.bracketedPaste)
        XCTAssertFalse(t.modes.cursorVisible)
        XCTAssertEqual(t.modes.mouseTracking, 1002)
        XCTAssertEqual(t.modes.mouseEncodings, [1006])
        XCTAssertTrue(t.modes.applicationKeypad)
        XCTAssertEqual(t.modes.cursorStyle, 5)
    }

    func testSequencesSplitAcrossFeedsStillCount() {
        var t = ModeTracker()
        for byte in "\u{1b}[?2004h".utf8 { t.feed([byte]) }
        XCTAssertTrue(t.modes.bracketedPaste)
    }

    func testTextInsideStringsIsNotAMode() {
        // A window title that happens to contain a mode sequence.
        let t = tracker("\u{1b}]0;\u{1b}[?2004h\u{7}")
        XCTAssertFalse(t.modes.bracketedPaste)
        // ...but only until the string ends.
        var u = t
        u.feed(Data("\u{1b}[?2004h".utf8))
        XCTAssertTrue(u.modes.bracketedPaste)
    }

    func testResetAndPreamble() {
        let t = tracker("\u{1b}[?1049h\u{1b}[?2004h\u{1b}[?25l")
        XCTAssertEqual(String(decoding: t.modes.preamble, as: UTF8.self), "\u{1b}[?1049h\u{1b}[?25l\u{1b}[?2004h")

        var u = t
        u.feed(Data("\u{1b}c".utf8))
        XCTAssertEqual(u.modes, TerminalModes())
        XCTAssertTrue(u.modes.preamble.isEmpty)
    }

    func testUndoTakesBackWhatThePreambleAsserts() {
        var t = tracker("\u{1b}[>1u\u{1b}[?1049h\u{1b}[>15u\u{1b}[?1h\u{1b}[?7l\u{1b}[?25l\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?1004h\u{1b}[?2004h\u{1b}=\u{1b}[5 q")
        XCTAssertFalse(t.modes.preamble.isEmpty)

        t.feed(t.modes.undo)
        XCTAssertNil(t.modes.alternateScreen)
        // The main screen's flags too, not only the alternate screen's.
        XCTAssertEqual(t.modes.keyboardFlags, 0)
        XCTAssertTrue(t.modes.preamble.isEmpty)

        XCTAssertTrue(TerminalModes().undo.isEmpty)
    }

    func testKittyKeyboardStacksArePerScreen() {
        var t = tracker("\u{1b}[>1u")
        XCTAssertEqual(t.modes.keyboardFlags, 1)
        t.feed(Data("\u{1b}[?1049h\u{1b}[>15u".utf8))
        XCTAssertEqual(t.modes.keyboardFlags, 15)
        t.feed(Data("\u{1b}[<u".utf8))
        XCTAssertEqual(t.modes.keyboardFlags, 0)
        t.feed(Data("\u{1b}[?1049l".utf8))
        XCTAssertEqual(t.modes.keyboardFlags, 1)
        t.feed(Data("\u{1b}[=4;2u".utf8))
        XCTAssertEqual(t.modes.keyboardFlags, 5)
    }
}

final class OutputRingTests: XCTestCase {
    func testKeepsTheTailAndKnowsPositions() {
        var ring = OutputRing(capacity: 10)
        ring.append(Data("abcdef".utf8))
        ring.append(Data("ghij".utf8))
        XCTAssertEqual(ring.startSeq, 0)
        XCTAssertEqual(ring.endSeq, 10)
        XCTAssertEqual(ring.bytes(from: 4), Data("efghij".utf8))

        ring.append(Data("kl".utf8))
        // The first chunk fell off whole.
        XCTAssertEqual(ring.startSeq, 6)
        XCTAssertNil(ring.bytes(from: 5))
        XCTAssertEqual(ring.bytes(from: 6), Data("ghijkl".utf8))
        XCTAssertEqual(ring.bytes(from: 12), Data())
        XCTAssertNil(ring.bytes(from: 13))
    }

    func testModesSurviveEviction() {
        var ring = OutputRing(capacity: 8)
        ring.append(Data("\u{1b}[?2004h".utf8))
        ring.append(Data("12345678".utf8))
        XCTAssertEqual(ring.startSeq, 8)
        XCTAssertTrue(ring.headModes.modes.bracketedPaste)
        XCTAssertTrue(ring.modes(at: ring.endSeq)?.modes.bracketedPaste == true)

        ring.append(Data("\u{1b}[?2004l".utf8))
        XCTAssertFalse(ring.modes(at: ring.endSeq)!.modes.bracketedPaste)
        XCTAssertTrue(ring.modes(at: 16)!.modes.bracketedPaste)
    }

    func testReplayStartsAfterALineBreakOnceTruncated() {
        var ring = OutputRing(capacity: 6)
        ring.append(Data("[?20".utf8))
        ring.append(Data("04h tail\nnext".utf8))
        XCTAssertGreaterThan(ring.startSeq, 0)
        let start = ring.replayStart(atOrAfter: 0)
        XCTAssertEqual(ring.bytes(from: start), Data("next".utf8))

        var fresh = OutputRing()
        fresh.append(Data("whole".utf8))
        XCTAssertEqual(fresh.replayStart(atOrAfter: 0), 0)
    }
}

final class ResponseFilterTests: XCTestCase {
    private func filter(_ text: String) -> String {
        String(decoding: ResponseFilter.keystrokes(from: Array(text.utf8)), as: UTF8.self)
    }

    func testDropsRepliesKeepsKeys() {
        XCTAssertEqual(filter("ls\u{1b}[24;1R -la"), "ls -la")
        XCTAssertEqual(filter("\u{1b}[?62;22c\u{1b}[>1;10;0c"), "")
        XCTAssertEqual(filter("\u{1b}]11;rgb:0000/0000/0000\u{1b}\\x"), "x")
        XCTAssertEqual(filter("\u{1b}P>|xterm\u{1b}\\"), "")
        XCTAssertEqual(filter("\u{1b}[?1u\u{1b}[I\u{1b}[O"), "")
        XCTAssertEqual(filter("\u{1b}[<0;10;5M"), "")

        // Keys that look a bit like replies but aren't.
        XCTAssertEqual(filter("\u{1b}[A\u{1b}OB\u{1b}[1;5C\u{1b}[5~\u{1b}[Z"), "\u{1b}[A\u{1b}OB\u{1b}[1;5C\u{1b}[5~\u{1b}[Z")
        XCTAssertEqual(filter("\u{1b}"), "\u{1b}")
        XCTAssertEqual(filter("héllo\r"), "héllo\r")
    }
}

final class PairingLinkTests: XCTestCase {
    func testRoundTrip() {
        let link = PairingLink(name: "Mac Studio", hosts: ["100.1.2.3", "mac.tail.ts.net"], port: 7766, code: SecureToken.make())
        XCTAssertEqual(PairingLink(url: link.url), link)
        XCTAssertNil(PairingLink(url: URL(string: "https://example.com")!))
        XCTAssertEqual(SecureToken.make(bytes: 32).count, 43)
    }

    func testKeys() {
        XCTAssertEqual(TerminalKey.up.bytes(), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(TerminalKey.up.bytes(applicationCursor: true), [0x1B, 0x4F, 0x41])
        XCTAssertEqual(TerminalKey.control("c"), [0x03])
        XCTAssertEqual(TerminalKey.control("["), [0x1B])
    }
}

import Foundation
import TabTermKit
import XCTest

final class AgentProgramStatusTests: XCTestCase {
    private func osc(_ body: String, bel: Bool = false) -> Data {
        Data(("\u{1b}]7501;" + body + (bel ? "\u{7}" : "\u{1b}\\")).utf8)
    }

    func testEveryPossibleChunkBoundary() {
        let bytes = osc("state=working:app=claude-code") + osc("state=idle:app=claude-code", bel: true)
        for split in 0...bytes.count {
            var parser = AgentProgramStatus()
            let events = parser.feed(bytes.prefix(split)) + parser.feed(bytes.suffix(bytes.count - split))
            XCTAssertEqual(events, [.claude(.working), .claude(.idle)], "split at \(split)")
        }
    }

    func testSubtasksStayActiveAndInheritTheirAgent() {
        var parser = AgentProgramStatus()
        XCTAssertEqual(parser.feed(osc("state=working:app=claude-code")), [.claude(.working)])
        XCTAssertEqual(parser.feed(osc("state=working:id=tool")), [])
        XCTAssertEqual(parser.feed(osc("state=idle:app=claude-code")), [], "a child is still running")
        XCTAssertEqual(parser.feed(osc("state=blocked:id=tool")), [.claude(.blocked)])
        XCTAssertEqual(parser.feed(osc("state=clear:id=tool")), [.claude(.idle)])
    }

    func testOtherProgramsAndOrdinaryOutputDoNotChangeAgentState() {
        var parser = AgentProgramStatus()
        XCTAssertEqual(parser.feed(osc("state=working:app=terraform")), [])
        XCTAssertEqual(parser.feed(Data("Claude finished\n> ".utf8)), [])
        XCTAssertEqual(parser.feed(osc("state=working:app=claude-code")), [.claude(.working)])
        XCTAssertEqual(parser.feed(Data()), [], "silence is not completion")
        XCTAssertEqual(parser.feed(osc("state=done:id=build:app=cargo")), [])
    }

    func testPromptAndResetEndNativeActivity() {
        var parser = AgentProgramStatus()
        _ = parser.feed(osc("state=working:app=claude-code"))
        XCTAssertEqual(parser.feed(Data("\u{1b}]133;A\u{7}".utf8)), [.claude(.idle), .shellPrompt])
        _ = parser.feed(osc("state=working:app=claude-code"))
        XCTAssertEqual(parser.feed(Data("\u{1b}c".utf8)), [.claude(.idle)])
        XCTAssertEqual(parser.feed(osc("?")), [.query])
    }

    func testMalformedAndOversizedReportsCannotFinishWork() {
        var parser = AgentProgramStatus()
        _ = parser.feed(osc("state=working:app=claude-code"))
        for body in [
            "state=future:app=claude-code", "state=idle:id=bad//id:app=claude-code",
            "state=idle:app=claude-code:msg=AA==", // NUL
            "state=idle:app=claude-code:title=not_base64",
            "state=idle:app=claude-code:msg=" + String(repeating: "a", count: 5000),
        ] {
            XCTAssertEqual(parser.feed(osc(body)), [])
        }
        XCTAssertEqual(parser.feed(osc("state=idle:app=claude-code")), [.claude(.idle)], "parser recovers after oversized input")
    }

    func testStatusInsideAnotherControlStringIsIgnored() {
        var parser = AgentProgramStatus()
        let embedded = Data("\u{1b}P".utf8) + osc("state=working:app=claude-code", bel: true) + Data("\u{1b}\\".utf8)
        XCTAssertEqual(parser.feed(embedded), [])
        XCTAssertEqual(parser.feed(osc("state=working:app=claude-code")), [.claude(.working)])
    }
}

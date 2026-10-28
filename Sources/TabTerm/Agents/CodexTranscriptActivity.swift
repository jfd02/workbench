import Foundation
import TabTermKit

/// A conservative backup for a missing hook. Only explicit lifecycle records
/// count: ordinary text, a quiet log, and unknown future formats prove nothing.
enum CodexTranscriptActivity {
    struct Observation {
        let state: AgentStatus
        let at: Date
        let turnID: String?

        func follows(_ report: AgentReport) -> Bool {
            if let expected = report.turnID, state == .idle {
                return turnID == expected && at >= report.at
            }
            // Hook timestamps have one-second precision. Do not let an older
            // task_started in that same second undo a permission request.
            return at >= report.at.addingTimeInterval(1)
        }
    }

    static func read(path: String) -> Observation? {
        let url = URL(fileURLWithPath: path)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd() else { return nil }
        let start = end > 256 * 1024 ? end - 256 * 1024 : 0
        do {
            try file.seek(toOffset: start)
            let bytes = try file.read(upToCount: 256 * 1024) ?? Data()
            return latest(in: bytes, droppingFirstLine: start > 0)
        } catch { return nil }
    }

    static func latest(in data: Data, droppingFirstLine: Bool = false) -> Observation? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        var lines = data.split(separator: 0x0a, omittingEmptySubsequences: false)
        if droppingFirstLine, !lines.isEmpty { lines.removeFirst() }
        // A writer may still be appending the last record.
        if data.last != 0x0a, !lines.isEmpty { lines.removeLast() }
        var result: Observation?
        for line in lines {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  row["type"] as? String == "event_msg",
                  let payload = row["payload"] as? [String: Any],
                  let event = payload["type"] as? String,
                  let timestamp = row["timestamp"] as? String,
                  let at = precise.date(from: timestamp) ?? seconds.date(from: timestamp) else { continue }
            let state: AgentStatus
            switch event {
            case "task_started": state = .working
            case "task_complete", "turn_complete", "turn_aborted": state = .idle
            default: continue
            }
            result = Observation(state: state, at: at, turnID: payload["turn_id"] as? String)
        }
        return result
    }
}

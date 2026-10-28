import Foundation

/// Reads explicit OSC 7501 activity without interpreting terminal text or silence.
/// Records and partial sequences are bounded; callers keep forwarding the original bytes.
public struct AgentProgramStatus {
    public enum Event: Equatable {
        case query
        case claude(AgentStatus)
        case shellPrompt
    }

    private enum ParseState { case text, escape, osc, oscEscape, discard, discardEscape, string, stringEscape }
    private struct Record { var state: String; var app: String? }
    private var parser: ParseState = .text
    private var buffer: [UInt8] = []
    private var records: [String: Record] = [:]
    private var order: [String] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [Event] {
        var events: [Event] = []
        for byte in data {
            switch parser {
            case .text:
                if byte == 0x1b { parser = .escape }
            case .escape:
                switch byte {
                case 0x5d: buffer.removeAll(keepingCapacity: true); parser = .osc
                case 0x50, 0x58, 0x5e, 0x5f: parser = .string
                case 0x63:
                    let was = claudeState
                    records.removeAll(); order.removeAll(); parser = .text
                    if was != .idle { events.append(.claude(.idle)) }
                case 0x1b: break
                default: parser = .text
                }
            case .osc:
                if byte == 0x07 {
                    events += consume(); parser = .text
                } else if byte == 0x1b {
                    parser = .oscEscape
                } else if buffer.count < 4092 {
                    buffer.append(byte)
                } else {
                    buffer.removeAll(keepingCapacity: true); parser = .discard
                }
            case .oscEscape:
                if byte == 0x5c { events += consume(); parser = .text }
                else { buffer.removeAll(keepingCapacity: true); parser = .discard }
            case .discard:
                if byte == 0x07 { parser = .text }
                else if byte == 0x1b { parser = .discardEscape }
            case .discardEscape:
                parser = byte == 0x5c || byte == 0x07 ? .text : .discard
            case .string:
                if byte == 0x1b { parser = .stringEscape }
            case .stringEscape:
                parser = byte == 0x5c ? .text : .string
            }
        }
        return events
    }

    private var claudeState: AgentStatus {
        var state = AgentStatus.idle
        for (id, record) in records where record.state == "working" || record.state == "blocked" {
            var ancestor = id
            var app = record.app
            while app == nil, !ancestor.isEmpty {
                ancestor = ancestor.split(separator: "/").dropLast().joined(separator: "/")
                app = records[ancestor]?.app
            }
            guard app?.lowercased() == "claude-code" else { continue }
            state = max(state, record.state == "blocked" ? .blocked : .working)
        }
        return state
    }

    private mutating func consume() -> [Event] {
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        let previous = claudeState
        if text == "133;A" || text.hasPrefix("133;A;") {
            records = records.filter { !["working", "blocked", "idle"].contains($0.value.state) }
            order.removeAll { records[$0] == nil }
            return (previous == .idle ? [] : [.claude(.idle)]) + [.shellPrompt]
        }
        guard text.hasPrefix("7501;") else { return [] }
        let body = String(text.dropFirst(5))
        if body == "?" { return [.query] }
        var fields: [String: String] = [:]
        for pair in body.split(separator: ":", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard key.utf8.count <= 16 else { return [] }
            guard key.range(of: "^[a-z]+$", options: .regularExpression) != nil,
                  value.isEmpty || value.range(of: "^[A-Za-z0-9_.,+/=-]+$", options: .regularExpression) != nil else { continue }
            // Even unused display text must obey the protocol's validation rules.
            if key == "msg" || key == "title" {
                let limit = key == "msg" ? 2048 : 192
                guard value.utf8.count <= (key == "msg" ? 2732 : 256) else { return [] }
                let padded = value + String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)
                guard let decoded = Data(base64Encoded: padded), decoded.count <= limit,
                      let string = String(data: decoded, encoding: .utf8),
                      !string.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { return [] }
            }
            if key == "app", value.utf8.count > 32 { return [] }
            fields[key] = value
        }
        guard let state = fields["state"], ["idle", "working", "blocked", "done", "error", "clear"].contains(state) else { return [] }
        let id = fields["id"] ?? ""
        if fields["id"] != nil {
            guard id.utf8.count <= 128, id.split(separator: "/", omittingEmptySubsequences: false).count <= 8,
                  id.range(of: "^[A-Za-z0-9_.+-]{1,32}(/[A-Za-z0-9_.+-]{1,32})*$", options: .regularExpression) != nil else { return [] }
        }
        if state == "clear" {
            records = records.filter { !(id.isEmpty || $0.key == id || $0.key.hasPrefix(id + "/")) }
            order.removeAll { records[$0] == nil }
        } else {
            order.removeAll { $0 == id }
            if records[id] == nil, order.count >= 256 { records.removeValue(forKey: order.removeFirst()) }
            let app = fields["app"].flatMap {
                $0.range(of: "^[A-Za-z0-9_.+-]{1,32}$", options: .regularExpression) != nil ? $0 : nil
            }
            records[id] = Record(state: state, app: app)
            order.append(id)
        }
        let current = claudeState
        return current == previous ? [] : [.claude(current)]
    }
}

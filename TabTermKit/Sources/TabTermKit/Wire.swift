import Foundation

/// Constants both ends of a connection have to agree on.
public enum TabTermProtocol {
    /// Bumped whenever a message changes shape. The Mac refuses a phone that
    /// speaks a different version rather than guessing at what it meant.
    public static let version = 1

    /// The port the Mac listens on for phones, on its Tailscale address only.
    public static let defaultPort: UInt16 = 7766

    /// The scheme of pairing links, which the phone registers.
    public static let urlScheme = "tabterm"

    /// Frames bigger than this are a protocol error, not a big frame: nothing
    /// either side sends comes close, so this only ever catches garbage.
    public static let maxFrameBytes = 16 * 1024 * 1024
}

/// What a frame carries.
///
/// Terminal bytes travel as raw binary frames rather than inside JSON, so the
/// data path never pays for base64 or a UTF-8 round trip — a terminal stream is
/// not guaranteed to be valid UTF-8 at every chunk boundary.
public enum FrameKind: UInt8, Sendable {
    /// A JSON control message.
    case control = 1
    /// Terminal output, counted towards the session's stream position.
    case output = 2
    /// Keyboard input for a session.
    case input = 3
    /// Output the host made up rather than read from the terminal — the mode
    /// preamble ahead of a replay. Shown like output, but not counted.
    case synthesized = 4

    /// Whether frames of this kind name the session they belong to.
    var carriesSession: Bool { self != .control }
}

/// One unit on the wire.
///
/// Layout: a 4-byte big-endian length, then a kind byte, then — for terminal
/// data — the 16 bytes of the session's UUID, then the payload. The length
/// counts everything after itself.
public struct Frame: Equatable, Sendable {
    public var kind: FrameKind
    public var session: UUID?
    public var payload: Data

    public init(kind: FrameKind, session: UUID? = nil, payload: Data) {
        self.kind = kind
        self.session = session
        self.payload = payload
    }

    public static func control<M: Encodable>(_ message: M) -> Frame {
        Frame(kind: .control, payload: (try? JSONEncoder().encode(message)) ?? Data())
    }

    public static func output(_ session: UUID, _ bytes: Data) -> Frame {
        Frame(kind: .output, session: session, payload: bytes)
    }

    public static func input(_ session: UUID, _ bytes: Data) -> Frame {
        Frame(kind: .input, session: session, payload: bytes)
    }

    public static func synthesized(_ session: UUID, _ bytes: Data) -> Frame {
        Frame(kind: .synthesized, session: session, payload: bytes)
    }

    /// The frame as bytes, ready to write.
    public func encoded() -> Data {
        let sessionBytes = kind.carriesSession ? 16 : 0
        let length = UInt32(1 + sessionBytes + payload.count)

        var data = Data(capacity: 4 + Int(length))
        withUnsafeBytes(of: length.bigEndian) { data.append(contentsOf: $0) }
        data.append(kind.rawValue)
        if kind.carriesSession {
            let id = (session ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))).uuid
            withUnsafeBytes(of: id) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }

    /// Decode a control frame's JSON.
    public func decode<M: Decodable>(_ type: M.Type) throws -> M {
        try JSONDecoder().decode(type, from: payload)
    }
}

public enum FrameError: Error, Equatable {
    case tooLarge(Int)
    case unknownKind(UInt8)
    case truncated
}

/// Turns a byte stream back into frames, however the stream was chunked.
///
/// Reads land wherever the kernel splits them: half a length prefix, three
/// frames and the start of a fourth. Bytes are kept until a whole frame is
/// there, and a malformed frame poisons the decoder for good, since nothing
/// after it can be trusted to be aligned.
public struct FrameDecoder {
    private var buffer = Data()
    private var offset = 0
    private var failure: FrameError?

    public init() {}

    /// Bytes received but not yet part of a whole frame.
    public var pendingBytes: Int { buffer.count - offset }

    public mutating func append(_ bytes: Data) throws -> [Frame] {
        if let failure { throw failure }
        buffer.append(bytes)

        var frames: [Frame] = []
        do {
            while let frame = try next() { frames.append(frame) }
        } catch let error as FrameError {
            failure = error
            throw error
        }

        // Drop what has been consumed once it is worth the copy.
        if offset > 0, offset >= buffer.count / 2 {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset))
            offset = 0
        }
        return frames
    }

    private mutating func next() throws -> Frame? {
        let available = buffer.count - offset
        guard available >= 4 else { return nil }

        let start = buffer.startIndex + offset
        let length = buffer[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }
        guard length >= 1, length <= TabTermProtocol.maxFrameBytes else {
            throw FrameError.tooLarge(length)
        }
        guard available >= 4 + length else { return nil }

        let kindByte = buffer[start + 4]
        guard let kind = FrameKind(rawValue: kindByte) else {
            throw FrameError.unknownKind(kindByte)
        }

        var body = start + 5
        let end = start + 4 + length
        var session: UUID?
        if kind.carriesSession {
            guard end - body >= 16 else { throw FrameError.truncated }
            var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutableBytes(of: &raw) { pointer in
                buffer.copyBytes(to: pointer.bindMemory(to: UInt8.self), from: body..<(body + 16))
            }
            session = UUID(uuid: raw)
            body += 16
        }

        let payload = Data(buffer[body..<end])
        offset += 4 + length
        return Frame(kind: kind, session: session, payload: payload)
    }
}

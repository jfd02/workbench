import Foundation

/// The recent tail of a terminal's output, addressed by stream position.
///
/// Every byte a terminal has ever written has a position: the first is 0, and
/// `endSeq` is one past the last. The ring keeps the most recent `capacity`
/// bytes of that stream, so a client that fell behind — a phone that dropped
/// off the network for ten seconds — can be sent exactly the bytes it missed,
/// by position, rather than a guess at the screen.
///
/// What falls off the front isn't forgotten entirely: it is fed to a
/// `ModeTracker`, so the ring always knows which modes were in force at its
/// first byte, and so at any byte it still holds.
public struct OutputRing {
    public let capacity: Int

    /// Position of the first byte still held.
    public private(set) var startSeq: UInt64 = 0
    /// Position one past the last byte written.
    public private(set) var endSeq: UInt64 = 0

    /// The modes in force at `startSeq`.
    public private(set) var headModes = ModeTracker()

    private var chunks: [Data] = []
    private var head = 0
    private var bytesHeld = 0

    public init(capacity: Int = 2 * 1024 * 1024) {
        self.capacity = capacity
    }

    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        chunks.append(data)
        bytesHeld += data.count
        endSeq += UInt64(data.count)

        // Evict whole chunks from the front, but always keep the newest one
        // even if it alone is over capacity.
        while bytesHeld > capacity, chunks.count - head > 1 {
            let evicted = chunks[head]
            head += 1
            bytesHeld -= evicted.count
            startSeq += UInt64(evicted.count)
            headModes.feed(evicted)
        }
        if head > 256, head * 2 > chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
    }

    /// The bytes from `seq` to the end, or nil when `seq` isn't held.
    public func bytes(from seq: UInt64) -> Data? {
        guard seq >= startSeq, seq <= endSeq else { return nil }
        var result = Data(capacity: Int(endSeq - seq))
        var position = startSeq
        for index in head..<chunks.count {
            let chunk = chunks[index]
            let chunkEnd = position + UInt64(chunk.count)
            if chunkEnd > seq {
                let skip = seq > position ? Int(seq - position) : 0
                result.append(chunk[(chunk.startIndex + skip)...])
            }
            position = chunkEnd
        }
        return result
    }

    /// The modes in force at `seq`, or nil when `seq` isn't held.
    public func modes(at seq: UInt64) -> ModeTracker? {
        guard seq >= startSeq, seq <= endSeq else { return nil }
        var tracker = headModes
        var position = startSeq
        for index in head..<chunks.count where position < seq {
            let chunk = chunks[index]
            let take = min(chunk.count, Int(seq - position))
            tracker.feed(chunk.prefix(take))
            position += UInt64(take)
        }
        return tracker
    }

    /// Where a replay starting at or after `seq` should begin.
    ///
    /// Once the ring has dropped bytes, its first byte may land in the middle
    /// of an escape sequence, and replaying from there prints the tail of it
    /// as text. Starting just after the next line break avoids that at the
    /// cost of a partial first line nobody would have wanted anyway.
    public func replayStart(atOrAfter seq: UInt64) -> UInt64 {
        let from = max(seq, startSeq)
        guard from == startSeq, startSeq > 0 else { return from }

        var position = startSeq
        for index in head..<chunks.count {
            let chunk = chunks[index]
            if let newline = chunk.firstIndex(of: 0x0A) {
                return position + UInt64(newline - chunk.startIndex + 1)
            }
            position += UInt64(chunk.count)
        }
        return endSeq
    }
}

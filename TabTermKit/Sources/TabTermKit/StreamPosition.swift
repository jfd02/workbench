import Foundation

/// A client's position in a session's output stream, used for exact catch-up
/// after reconnecting. Only output frames count; synthesized bytes are shown
/// but were never part of the stream.
public struct StreamPosition: Equatable {
    public private(set) var epoch: String?
    public private(set) var seq: UInt64 = 0
    public private(set) var isCounting = false

    public init() {}

    public var anchor: StreamAnchor {
        epoch.map { .position(epoch: $0, seq: seq) } ?? .fresh
    }

    /// Stop counting on disconnect or attach until the next `synced` arrives.
    /// Keep the position so the next attach can resume the existing screen.
    public mutating func suspend() {
        isCounting = false
    }

    public mutating func apply(_ synced: Synced) {
        epoch = synced.epoch
        seq = synced.seq
        isCounting = true
    }

    /// False means these bytes cannot be placed and must not be shown, or the
    /// screen and its stream position would disagree from then on.
    public mutating func receiveOutput(count: Int) -> Bool {
        guard isCounting else { return false }
        seq += UInt64(count)
        return true
    }
}

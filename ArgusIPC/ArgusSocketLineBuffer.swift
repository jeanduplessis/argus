import Foundation

/// Reassembles newline-delimited Socket frames from a byte stream.
///
/// The Socket Server and the Companion CLI read the same wire format from a
/// raw file descriptor but answer an oversized frame differently — one writes
/// a failure response, the other throws. This owns only the reassembly and
/// reports sizes as values, so each side keeps its own error handling.
public struct ArgusSocketLineBuffer {
    private static let newline: UInt8 = 0x0A

    private var buffered = Data()

    public init() {}

    /// Bytes held after the last complete frame was taken.
    public var pendingByteCount: Int { buffered.count }

    public mutating func append<Bytes: Sequence<UInt8>>(_ bytes: Bytes) {
        buffered.append(contentsOf: bytes)
    }

    /// Removes and returns the next complete frame, without its terminator.
    public mutating func nextFrame() -> Data? {
        guard let newline = buffered.firstIndex(of: Self.newline) else { return nil }
        let frame = Data(buffered[buffered.startIndex..<newline])
        buffered.removeSubrange(...newline)
        return frame
    }
}

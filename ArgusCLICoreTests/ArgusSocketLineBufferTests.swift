import ArgusIPC
import Foundation
import Testing

@Suite
struct ArgusSocketLineBufferTests {
    @Test
    func framesAreTakenInOrderWithoutTheirTerminator() {
        var buffer = ArgusSocketLineBuffer()
        buffer.append(Array(#"{"id":"1"}"#.utf8) + [0x0A] + Array(#"{"id":"2"}"#.utf8) + [0x0A])

        #expect(Self.text(buffer.nextFrame()) == #"{"id":"1"}"#)
        #expect(Self.text(buffer.nextFrame()) == #"{"id":"2"}"#)
        #expect(buffer.nextFrame() == nil)
        #expect(buffer.pendingByteCount == 0)
    }

    @Test
    func aFrameSplitAcrossReadsIsReassembled() {
        var buffer = ArgusSocketLineBuffer()
        buffer.append(Array(#"{"id":"#.utf8))
        #expect(buffer.nextFrame() == nil)
        buffer.append(Array(#""1"}"#.utf8) + [0x0A])

        #expect(Self.text(buffer.nextFrame()) == #"{"id":"1"}"#)
    }

    /// A frame taken mid-stream must decode on its own, so the buffer's
    /// remaining bytes cannot leak into it as a slice offset.
    @Test
    func aTakenFrameDecodesIndependentlyOfTheBytesBehindIt() throws {
        var buffer = ArgusSocketLineBuffer()
        buffer.append(Array(#"{"ok":true}"#.utf8) + [0x0A] + Array(#"{"ok":false}"#.utf8) + [0x0A])
        _ = buffer.nextFrame()

        let second = buffer.nextFrame()
        let decoded = try JSONDecoder().decode([String: Bool].self, from: try #require(second))
        #expect(decoded == ["ok": false])
    }

    @Test
    func pendingBytesCountOnlyWhatFollowsTheLastFrame() {
        var buffer = ArgusSocketLineBuffer()
        buffer.append(Array("ab".utf8) + [0x0A] + Array("cde".utf8))

        #expect(buffer.pendingByteCount == 6)
        _ = buffer.nextFrame()
        #expect(buffer.pendingByteCount == 3)
    }

    @Test
    func anEmptyFrameIsDistinctFromNoFrame() {
        var buffer = ArgusSocketLineBuffer()
        buffer.append([0x0A])

        #expect(buffer.nextFrame()?.isEmpty == true)
        #expect(buffer.nextFrame() == nil)
    }

    private static func text(_ frame: Data?) -> String? {
        frame.flatMap { String(data: $0, encoding: .utf8) }
    }
}

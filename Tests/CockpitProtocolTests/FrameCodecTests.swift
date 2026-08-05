import Foundation
import Testing
import CockpitTypes
@testable import CockpitProtocol

@Test func frameHeaderUsesSpecifiedNetworkByteLayout() {
    let header = FrameHeader(
        flags: 2,
        channel: ChannelID(rawValue: 7),
        sequence: 11,
        acknowledgement: 9,
        payloadLength: 3
    )

    #expect(Array(header.encoded()) == [
        0x43, 0x4B, 0x50, 0x54, 0x00, 0x01, 0x00, 0x02,
        0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x03,
    ])
}

@Test func frameHeaderIsExactlyThirtyTwoBytes() throws {
    let header = FrameHeader(
        flags: 2,
        channel: ChannelID(rawValue: 7),
        sequence: 11,
        acknowledgement: 9,
        payloadLength: 3
    )
    let encoded = header.encoded()
    #expect(encoded.count == 32)
    #expect(try FrameHeader(decoding: encoded) == header)
}

@Test func decoderHandlesArbitraryFragmentation() throws {
    let frame = try Frame(
        header: FrameHeader(
            flags: 0,
            channel: ChannelID(rawValue: 2),
            sequence: 1,
            acknowledgement: 0,
            payloadLength: 5
        ),
        payload: Data("hello".utf8)
    )
    let bytes = frame.encoded()
    var decoder = FrameDecoder()
    var output: [Frame] = []
    for byte in bytes {
        output += try decoder.append(Data([byte]))
    }
    #expect(output == [frame])
}

@Test func decoderRejectsOversizedPayload() {
    let header = FrameHeader(
        flags: 0,
        channel: ChannelID(rawValue: 1),
        sequence: 0,
        acknowledgement: 0,
        payloadLength: 16_777_217
    )
    #expect(throws: FrameCodecError.payloadTooLarge(16_777_217)) {
        _ = try FrameHeader(decoding: header.encoded())
    }
}

@Test func frameRejectsPayloadLengthMismatch() {
    let header = FrameHeader(
        flags: 0,
        channel: .control,
        sequence: 0,
        acknowledgement: 0,
        payloadLength: 4
    )
    #expect(throws: FrameCodecError.payloadLengthMismatch(expected: 4, actual: 3)) {
        _ = try Frame(header: header, payload: Data("bad".utf8))
    }
}

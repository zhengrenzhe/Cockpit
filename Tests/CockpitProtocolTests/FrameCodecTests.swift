import Foundation
import Darwin
import Testing
import CockpitTypes
@testable import CockpitProtocol

private let firstHeaderFixture: [UInt8] = [
    0x43, 0x4B, 0x50, 0x54, 0x00, 0x01, 0x00, 0x02,
    0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x03,
]
private let firstPayloadFixture: [UInt8] = [0x63, 0x61, 0x74]

private let secondHeaderFixture: [UInt8] = [
    0x43, 0x4B, 0x50, 0x54, 0x00, 0x01, 0x00, 0x04,
    0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x04,
]
private let secondPayloadFixture: [UInt8] = [0x6E, 0x65, 0x78, 0x74]

private func firstFixtureFrame() throws -> Frame {
    try Frame(
        header: FrameHeader(
            flags: 2,
            channel: ChannelID(rawValue: 7),
            sequence: 11,
            acknowledgement: 9,
            payloadLength: 3
        ),
        payload: Data(firstPayloadFixture)
    )
}

private func secondFixtureFrame() throws -> Frame {
    try Frame(
        header: FrameHeader(
            flags: 4,
            channel: ChannelID(rawValue: 8),
            sequence: 12,
            acknowledgement: 11,
            payloadLength: 4
        ),
        payload: Data(secondPayloadFixture)
    )
}

private func allocatedByteCount() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(malloc_default_zone(), &statistics)
    return statistics.size_in_use
}

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

@Test func frameHeaderDecodesSpecifiedNetworkByteLayout() throws {
    let header = try FrameHeader(decoding: Data(firstHeaderFixture))

    #expect(header.flags == 2)
    #expect(header.channel == ChannelID(rawValue: 7))
    #expect(header.sequence == 11)
    #expect(header.acknowledgement == 9)
    #expect(header.payloadLength == 3)
}

@Test func decoderDecodesSpecifiedNetworkByteFixture() throws {
    var decoder = FrameDecoder()
    let frames = try decoder.append(Data(firstHeaderFixture + firstPayloadFixture))

    #expect(frames == [try firstFixtureFrame()])
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

@Test func decoderEmitsMultipleFramesFromOneAppend() throws {
    var decoder = FrameDecoder()
    let input = Data(
        firstHeaderFixture + firstPayloadFixture
            + secondHeaderFixture + secondPayloadFixture
    )

    #expect(try decoder.append(input) == [firstFixtureFrame(), secondFixtureFrame()])
}

@Test func decoderPreservesPartialHeaderAfterCompleteFrame() throws {
    let prefixCount = 16
    var decoder = FrameDecoder()
    let firstInput = Data(
        firstHeaderFixture + firstPayloadFixture
            + secondHeaderFixture.prefix(prefixCount)
    )

    #expect(try decoder.append(firstInput) == [firstFixtureFrame()])
    let remainder = Data(
        secondHeaderFixture.dropFirst(prefixCount) + secondPayloadFixture
    )
    #expect(try decoder.append(remainder) == [secondFixtureFrame()])
}

@Test func decoderPreservesPartialPayloadAfterCompleteFrame() throws {
    let prefixCount = 2
    var decoder = FrameDecoder()
    let firstInput = Data(
        firstHeaderFixture + firstPayloadFixture
            + secondHeaderFixture + secondPayloadFixture.prefix(prefixCount)
    )

    #expect(try decoder.append(firstInput) == [firstFixtureFrame()])
    #expect(
        try decoder.append(Data(secondPayloadFixture.dropFirst(prefixCount)))
            == [secondFixtureFrame()]
    )
}

@Test func decoderPreservesTailAfterMoreThanSixtyFourKiBOfFrames() throws {
    let completeFrameCount = 1_873
    let tailPrefixCount = 17
    let firstFrameBytes = Data(firstHeaderFixture + firstPayloadFixture)
    var input = Data()
    for _ in 0..<completeFrameCount {
        input.append(firstFrameBytes)
    }
    input.append(contentsOf: secondHeaderFixture.prefix(tailPrefixCount))

    var decoder = FrameDecoder()
    #expect(
        try decoder.append(input)
            == Array(repeating: firstFixtureFrame(), count: completeFrameCount)
    )
    let remainder = Data(
        secondHeaderFixture.dropFirst(tailPrefixCount) + secondPayloadFixture
    )
    #expect(try decoder.append(remainder) == [secondFixtureFrame()])
}

@Suite(.serialized)
struct FrameDecoderResourceTests {
    @Test func decoderAcceptsLargeAppendContainingOnlyBoundedFrames() throws {
        let payloadLength = 8 * 1_024 * 1_024
        let firstFrame = try Frame(
            header: FrameHeader(
                flags: 0,
                channel: ChannelID(rawValue: 7),
                sequence: 11,
                acknowledgement: 9,
                payloadLength: UInt32(payloadLength)
            ),
            payload: Data(repeating: 0xA5, count: payloadLength)
        )
        let secondFrame = try Frame(
            header: FrameHeader(
                flags: 0,
                channel: ChannelID(rawValue: 8),
                sequence: 12,
                acknowledgement: 11,
                payloadLength: UInt32(payloadLength)
            ),
            payload: Data(repeating: 0x5A, count: payloadLength)
        )
        var input = firstFrame.encoded()
        input.append(secondFrame.encoded())
        #expect(input.count > 16 * 1_024 * 1_024)

        var decoder = FrameDecoder()
        #expect(try decoder.append(input) == [firstFrame, secondFrame])
    }

    @Test func decoderDoesNotRetainAnUnboundedCopyBeforeHeaderValidation() {
        let maliciousInput = Data(repeating: 0, count: 32 * 1_024 * 1_024)
        let allocatedBeforeAppend = allocatedByteCount()
        var decoder = FrameDecoder()
        var caughtError: FrameCodecError?

        do {
            _ = try decoder.append(maliciousInput)
        } catch let error as FrameCodecError {
            caughtError = error
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let allocatedAfterAppend = withExtendedLifetime(decoder) {
            allocatedByteCount()
        }
        let allocationGrowth = allocatedAfterAppend > allocatedBeforeAppend
            ? allocatedAfterAppend - allocatedBeforeAppend
            : 0
        #expect(caughtError == .invalidMagic(0))
        #expect(allocationGrowth < 4 * 1_024 * 1_024)
    }
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

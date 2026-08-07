import Foundation
import Testing
import CockpitHostCore
import CockpitProtocol
import CockpitTypes
@testable import CockpitWorkspace

@Test func documentCodecDecodesUTF8BOMAndPreservesMixedLineEndings() throws {
    let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("first\r\nsecond\nthird\r\nfourth".utf8)
    let decoded = try DocumentCodec.decode(
        DocumentFileSnapshot(data: bytes, fingerprint: try testFingerprint(bytes: bytes))
    )

    #expect(decoded.text == "first\nsecond\nthird\nfourth")
    #expect(decoded.signature == .bom)
    #expect(decoded.lineEndings.preferred == .crlf)
    #expect(decoded.lineEndings.originalByLineBreak == [.crlf, .lf, .crlf])
    #expect(
        try DocumentCodec.encode(
            text: decoded.text,
            signature: decoded.signature,
            lineEndings: decoded.lineEndings
        ) == bytes
    )
}

@Test func documentCodecChoosesFrozenPreferredLineEndingRules() throws {
    let cases: [(String, LineEnding)] = [
        ("no breaks", .lf),
        ("a\nb\r\nc", .lf),
        ("a\r\nb\nc", .crlf),
        ("a\nb\r\nc\nd", .lf),
        ("a\r\nb\nc\r\nd", .crlf),
    ]
    for (source, preferred) in cases {
        let data = Data(source.utf8)
        let decoded = try DocumentCodec.decode(
            DocumentFileSnapshot(data: data, fingerprint: try testFingerprint(bytes: data))
        )
        #expect(decoded.lineEndings.preferred == preferred)
        #expect(
            try DocumentCodec.encode(
                text: decoded.text,
                signature: decoded.signature,
                lineEndings: decoded.lineEndings
            ) == data
        )
    }
}

@Test func documentCodecRejectsInvalidUTF8NULAndIsolatedCarriageReturn() throws {
    let invalid: [Data] = [
        Data([0xC3, 0x28]),
        Data("left\0right".utf8),
        Data("left\rright".utf8),
    ]
    for data in invalid {
        #expect(throws: DocumentCodecError.self) {
            _ = try DocumentCodec.decode(
                DocumentFileSnapshot(data: data, fingerprint: try testFingerprint(bytes: data))
            )
        }
    }
}

@Test func documentTextBufferPreservesUntouchedBreaksAcrossInsertionsAndDeletions() throws {
    var buffer = try DocumentTextBuffer(
        validatingText: "a\nb\nc\nd",
        lineEndings: LineEndingProfile(
            preferred: .crlf,
            originalByLineBreak: [.lf, .crlf, .lf]
        )
    )

    try buffer.replaceUTF16(range: 0..<0, with: "head\n")
    try buffer.replaceUTF16(range: 7..<9, with: "middle\n")
    let end = buffer.text.utf16.count
    try buffer.replaceUTF16(range: end..<end, with: "\ntail")

    #expect(buffer.text == "head\na\nmiddle\nc\nd\ntail")
    #expect(buffer.lineEndings.originalByLineBreak == [.crlf, .lf, .crlf, .lf, .crlf])
}

@Test func documentTextBufferRejectsOutOfBoundsSurrogateSplitAndInvalidReplacement() throws {
    let profile = LineEndingProfile(preferred: .lf, originalByLineBreak: [])
    var buffer = try DocumentTextBuffer(validatingText: "A😀B", lineEndings: profile)

    for range in [-1..<0, 0..<5, 2..<3] {
        #expect(throws: DocumentTextBufferError.self) {
            try buffer.replaceUTF16(range: range, with: "x")
        }
    }
    #expect(throws: DocumentTextBufferError.self) {
        try buffer.replaceUTF16(range: 0..<1, with: "bad\rvalue")
    }
}

private func testFingerprint(bytes: Data) throws -> DiskFingerprint {
    DiskFingerprint(
        deviceID: 1,
        inode: 2,
        byteCount: UInt64(bytes.count),
        modificationTimeSeconds: 3,
        modificationTimeNanoseconds: 4,
        contentSHA256: try SHA256Digest(validating: Data(repeating: 0, count: 32))
    )
}

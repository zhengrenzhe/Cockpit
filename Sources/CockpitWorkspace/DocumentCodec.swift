import Foundation
import CockpitHostCore
import CockpitProtocol

public enum UTF8Signature: UInt8, Codable, Sendable {
    case none
    case bom
}

public enum LineEnding: UInt8, Codable, Sendable {
    case lf
    case crlf
}

public struct LineEndingProfile: Codable, Sendable {
    public let preferred: LineEnding
    public let originalByLineBreak: [LineEnding]

    public init(preferred: LineEnding, originalByLineBreak: [LineEnding]) {
        self.preferred = preferred
        self.originalByLineBreak = originalByLineBreak
    }
}

public struct DecodedDocument: Sendable {
    public let text: String
    public let signature: UTF8Signature
    public let lineEndings: LineEndingProfile
    public let diskFingerprint: DiskFingerprint

    public init(
        text: String,
        signature: UTF8Signature,
        lineEndings: LineEndingProfile,
        diskFingerprint: DiskFingerprint
    ) {
        self.text = text
        self.signature = signature
        self.lineEndings = lineEndings
        self.diskFingerprint = diskFingerprint
    }
}

public enum DocumentCodecError: Error, Hashable, Sendable {
    case invalidUTF8
    case nulByte
    case isolatedCarriageReturn
    case invalidLineEndingProfile
}

public enum DocumentTextBufferError: Error, Hashable, Sendable {
    case invalidText
    case invalidLineEndingProfile
    case invalidUTF16Range
}

public struct DocumentTextBuffer: Sendable {
    public private(set) var text: String
    public private(set) var lineEndings: LineEndingProfile

    public init(validatingText text: String, lineEndings: LineEndingProfile) throws {
        guard !text.contains("\r"), !text.contains("\0") else {
            throw DocumentTextBufferError.invalidText
        }
        guard text.utf8.filter({ $0 == 0x0A }).count == lineEndings.originalByLineBreak.count else {
            throw DocumentTextBufferError.invalidLineEndingProfile
        }
        self.text = text
        self.lineEndings = lineEndings
    }

    public mutating func replaceUTF16(
        range: Range<Int>,
        with replacement: String
    ) throws {
        guard !replacement.contains("\r"), !replacement.contains("\0"),
              range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              range.upperBound <= text.utf16.count,
              let lower = stringIndex(atUTF16Offset: range.lowerBound),
              let upper = stringIndex(atUTF16Offset: range.upperBound)
        else { throw DocumentTextBufferError.invalidUTF16Range }

        let removedBreakRange = lineBreakIndexRange(lower: lower, upper: upper)
        let inserted = replacement.utf8.filter { $0 == 0x0A }.count
        var mapping = lineEndings.originalByLineBreak
        mapping.replaceSubrange(
            removedBreakRange,
            with: repeatElement(lineEndings.preferred, count: inserted)
        )
        text.replaceSubrange(lower..<upper, with: replacement)
        lineEndings = LineEndingProfile(
            preferred: lineEndings.preferred,
            originalByLineBreak: mapping
        )
    }

    private func stringIndex(atUTF16Offset offset: Int) -> String.Index? {
        guard let utf16Index = text.utf16.index(
            text.utf16.startIndex,
            offsetBy: offset,
            limitedBy: text.utf16.endIndex
        ) else { return nil }
        return String.Index(utf16Index, within: text)
    }

    private func lineBreakIndexRange(
        lower: String.Index,
        upper: String.Index
    ) -> Range<Int> {
        let before = text[..<lower].utf8.filter { $0 == 0x0A }.count
        let removed = text[lower..<upper].utf8.filter { $0 == 0x0A }.count
        return before..<(before + removed)
    }
}

public enum DocumentCodec {
    public static func decode(_ snapshot: DocumentFileSnapshot) throws -> DecodedDocument {
        var data = snapshot.data
        let signature: UTF8Signature
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            signature = .bom
            data.removeFirst(3)
        } else {
            signature = .none
        }
        guard !data.contains(0) else { throw DocumentCodecError.nulByte }
        guard String(data: data, encoding: .utf8) != nil else {
            throw DocumentCodecError.invalidUTF8
        }

        var normalized = Data()
        var endings: [LineEnding] = []
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0x0D {
                let next = data.index(after: index)
                guard next < data.endIndex, data[next] == 0x0A else {
                    throw DocumentCodecError.isolatedCarriageReturn
                }
                normalized.append(0x0A)
                endings.append(.crlf)
                index = data.index(after: next)
            } else {
                normalized.append(byte)
                if byte == 0x0A { endings.append(.lf) }
                index = data.index(after: index)
            }
        }
        guard let text = String(data: normalized, encoding: .utf8) else {
            throw DocumentCodecError.invalidUTF8
        }

        let lfCount = endings.filter { $0 == .lf }.count
        let crlfCount = endings.count - lfCount
        let preferred: LineEnding
        if lfCount == crlfCount {
            preferred = endings.first ?? .lf
        } else {
            preferred = crlfCount > lfCount ? .crlf : .lf
        }
        return DecodedDocument(
            text: text,
            signature: signature,
            lineEndings: LineEndingProfile(
                preferred: preferred,
                originalByLineBreak: endings
            ),
            diskFingerprint: snapshot.fingerprint
        )
    }

    public static func encode(
        text: String,
        signature: UTF8Signature,
        lineEndings: LineEndingProfile
    ) throws -> Data {
        guard !text.contains("\r"), !text.contains("\0") else {
            throw DocumentCodecError.invalidLineEndingProfile
        }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count - 1 == lineEndings.originalByLineBreak.count else {
            throw DocumentCodecError.invalidLineEndingProfile
        }
        var result = signature == .bom ? Data([0xEF, 0xBB, 0xBF]) : Data()
        for index in parts.indices {
            result.append(contentsOf: parts[index].utf8)
            if index < lineEndings.originalByLineBreak.count {
                switch lineEndings.originalByLineBreak[index] {
                case .lf: result.append(0x0A)
                case .crlf: result.append(contentsOf: [0x0D, 0x0A])
                }
            }
        }
        return result
    }
}

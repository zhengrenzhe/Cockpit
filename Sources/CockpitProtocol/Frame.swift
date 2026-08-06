import Foundation
import CockpitTypes

public enum FrameCodecError: Error, Equatable {
    case invalidHeaderLength(Int)
    case invalidMagic(UInt32)
    case unsupportedVersion(UInt16)
    case payloadTooLarge(UInt32)
    case payloadLengthMismatch(expected: UInt32, actual: Int)
}

public struct FrameHeader: Equatable, Sendable {
    public static let magic: UInt32 = 0x434B5054
    /// The `UInt16` frame-format version, independent of handshake version 1.0.
    /// Its big-endian wire representation is `00 01`.
    public static let version: UInt16 = 1
    public static let encodedLength = 32
    public static let maximumPayloadLength: UInt32 = 16 * 1_024 * 1_024

    public let flags: UInt16
    public let channel: ChannelID
    public let sequence: UInt64
    public let acknowledgement: UInt64
    public let payloadLength: UInt32

    public init(
        flags: UInt16,
        channel: ChannelID,
        sequence: UInt64,
        acknowledgement: UInt64,
        payloadLength: UInt32
    ) {
        self.flags = flags
        self.channel = channel
        self.sequence = sequence
        self.acknowledgement = acknowledgement
        self.payloadLength = payloadLength
    }

    public init(decoding data: Data) throws {
        guard data.count == Self.encodedLength else {
            throw FrameCodecError.invalidHeaderLength(data.count)
        }
        try self.init(decoding: data, at: 0)
    }

    init(decoding data: Data, at offset: Int) throws {
        guard
            offset >= 0,
            offset <= data.count,
            data.count - offset >= Self.encodedLength
        else {
            throw FrameCodecError.invalidHeaderLength(data.count - offset)
        }

        let magic = Self.read(UInt32.self, from: data, at: offset)
        guard magic == Self.magic else { throw FrameCodecError.invalidMagic(magic) }
        let version = Self.read(UInt16.self, from: data, at: offset + 4)
        guard version == Self.version else { throw FrameCodecError.unsupportedVersion(version) }

        flags = Self.read(UInt16.self, from: data, at: offset + 6)
        channel = ChannelID(
            rawValue: Self.read(UInt32.self, from: data, at: offset + 8)
        )
        sequence = Self.read(UInt64.self, from: data, at: offset + 12)
        acknowledgement = Self.read(UInt64.self, from: data, at: offset + 20)
        payloadLength = Self.read(UInt32.self, from: data, at: offset + 28)
        guard payloadLength <= Self.maximumPayloadLength else { throw FrameCodecError.payloadTooLarge(payloadLength) }
    }

    public func encoded() -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.encodedLength)
        Self.append(Self.magic, to: &bytes)
        Self.append(Self.version, to: &bytes)
        Self.append(flags, to: &bytes)
        Self.append(channel.rawValue, to: &bytes)
        Self.append(sequence, to: &bytes)
        Self.append(acknowledgement, to: &bytes)
        Self.append(payloadLength, to: &bytes)
        return Data(bytes)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        let bigEndian = value.bigEndian
        withUnsafeBytes(of: bigEndian) { bytes.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(
        _ type: T.Type,
        from data: Data,
        at offset: Int
    ) -> T {
        let raw = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        return T(bigEndian: raw)
    }
}

public struct Frame: Equatable, Sendable {
    public let header: FrameHeader
    public let payload: Data

    public init(header: FrameHeader, payload: Data) throws {
        guard header.payloadLength <= FrameHeader.maximumPayloadLength else {
            throw FrameCodecError.payloadTooLarge(header.payloadLength)
        }
        guard payload.count == Int(header.payloadLength) else {
            throw FrameCodecError.payloadLengthMismatch(
                expected: header.payloadLength,
                actual: payload.count
            )
        }
        self.header = header
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = header.encoded()
        data.append(payload)
        return data
    }
}

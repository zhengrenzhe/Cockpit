import Foundation

public struct FrameDecoder: Sendable {
    private var buffer = Data()
    private var readOffset = 0

    public init() {}

    public mutating func append(_ data: Data) throws -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []

        while buffer.count - readOffset >= FrameHeader.encodedLength {
            let header = try FrameHeader(decoding: buffer, at: readOffset)
            let totalLength = FrameHeader.encodedLength + Int(header.payloadLength)
            guard buffer.count - readOffset >= totalLength else { break }

            let payloadStart = readOffset + FrameHeader.encodedLength
            let payloadEnd = readOffset + totalLength
            let payload = Data(buffer[payloadStart..<payloadEnd])
            guard payload.count == Int(header.payloadLength) else {
                throw FrameCodecError.payloadLengthMismatch(expected: header.payloadLength, actual: payload.count)
            }
            frames.append(try Frame(header: header, payload: payload))
            readOffset += totalLength
        }

        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset >= 64 * 1_024 {
            buffer = Data(buffer[readOffset...])
            readOffset = 0
        }

        return frames
    }
}

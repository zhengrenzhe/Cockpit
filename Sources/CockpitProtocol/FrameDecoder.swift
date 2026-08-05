import Foundation

public struct FrameDecoder: Sendable {
    // Retains only one incomplete frame, bounded by header plus maximum payload.
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Frame] {
        var frames: [Frame] = []
        var inputOffset = 0

        if !buffer.isEmpty {
            let missingHeaderLength = max(0, FrameHeader.encodedLength - buffer.count)
            let headerCopyLength = min(missingHeaderLength, data.count)
            appendBytes(from: data, at: inputOffset, count: headerCopyLength)
            inputOffset += headerCopyLength

            guard buffer.count >= FrameHeader.encodedLength else { return frames }
            let header = try FrameHeader(decoding: buffer, at: 0)
            let totalLength = FrameHeader.encodedLength + Int(header.payloadLength)
            let frameCopyLength = min(totalLength - buffer.count, data.count - inputOffset)
            appendBytes(from: data, at: inputOffset, count: frameCopyLength)
            inputOffset += frameCopyLength

            guard buffer.count == totalLength else { return frames }

            let payload = Data(buffer[FrameHeader.encodedLength..<totalLength])
            frames.append(try Frame(header: header, payload: payload))
            buffer.removeAll(keepingCapacity: true)
        }

        while inputOffset < data.count {
            let remainingLength = data.count - inputOffset
            guard remainingLength >= FrameHeader.encodedLength else {
                appendBytes(from: data, at: inputOffset, count: remainingLength)
                break
            }

            let header = try FrameHeader(decoding: data, at: inputOffset)
            let totalLength = FrameHeader.encodedLength + Int(header.payloadLength)
            guard remainingLength >= totalLength else {
                appendBytes(from: data, at: inputOffset, count: remainingLength)
                break
            }

            let payloadStart = data.index(
                data.startIndex,
                offsetBy: inputOffset + FrameHeader.encodedLength
            )
            let payloadEnd = data.index(payloadStart, offsetBy: Int(header.payloadLength))
            let payload = Data(data[payloadStart..<payloadEnd])
            frames.append(try Frame(header: header, payload: payload))
            inputOffset += totalLength
        }

        return frames
    }

    private mutating func appendBytes(from data: Data, at offset: Int, count: Int) {
        guard count > 0 else { return }
        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            buffer.append(bytes.baseAddress!.advanced(by: offset), count: count)
        }
    }
}

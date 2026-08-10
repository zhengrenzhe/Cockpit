import Darwin
import Foundation

public enum TerminalArchiveError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidChunk
    case invalidLayout
    case invalidManifest
    case integrityMismatch
    case manifestAlreadyPublished
    case io(operation: String, errno: Int32)
}

public struct TerminalArchiveChunkData: Hashable, Sendable {
    public let firstOutputSequence: UInt64
    public let lastOutputSequence: UInt64
    public let data: Data

    public init(
        firstOutputSequence: UInt64,
        lastOutputSequence: UInt64,
        data: Data
    ) throws {
        guard firstOutputSequence > 0,
              firstOutputSequence <= lastOutputSequence,
              !data.isEmpty else {
            throw TerminalArchiveError.invalidChunk
        }
        self.firstOutputSequence = firstOutputSequence
        self.lastOutputSequence = lastOutputSequence
        self.data = data
    }
}

public final class TerminalArchiveReadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }

    var fileDescriptor: Int32 { lock.withLock { descriptor } }

    public func readAll() throws -> Data {
        try lock.withLock {
            guard descriptor >= 0 else {
                throw TerminalArchiveError.io(operation: "read", errno: EBADF)
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_size >= 0,
                  status.st_size <= Int64(Int.max) else {
                throw TerminalArchiveError.io(operation: "fstat", errno: errno)
            }
            var result = Data(count: Int(status.st_size))
            try result.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = pread(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset,
                        off_t(offset)
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw TerminalArchiveError.io(
                            operation: "pread",
                            errno: count == 0 ? EIO : errno
                        )
                    }
                    offset += count
                }
            }
            return result
        }
    }

    deinit {
        lock.withLock {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            descriptor = -1
        }
    }
}

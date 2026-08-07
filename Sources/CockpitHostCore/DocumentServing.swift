import Foundation
import CockpitProtocol
import CockpitTypes

public struct DocumentFileSnapshot: Sendable {
    public let data: Data
    public let fingerprint: DiskFingerprint

    public init(data: Data, fingerprint: DiskFingerprint) {
        self.data = data
        self.fingerprint = fingerprint
    }
}

public enum DocumentWriteRecoveryState: Hashable, Sendable {
    case staged(RelativePath)
    case stagedLocationUnknown
    case committedButDurabilityUnknown(DiskFingerprint)
}

public struct DocumentWriteRecoveryRequiredError: Error, @unchecked Sendable {
    public let path: RelativePath
    public let state: DocumentWriteRecoveryState
    public let originalError: any Error

    public init(
        path: RelativePath,
        state: DocumentWriteRecoveryState,
        originalError: any Error
    ) {
        self.path = path
        self.state = state
        self.originalError = originalError
    }
}

public enum DocumentStorageError: Error, Hashable, Sendable {
    case fingerprintMismatch(expected: DiskFingerprint, actual: DiskFingerprint)
    case unsupportedFileType
    case unstableRead
}

public protocol DocumentServing: Sendable {
    func readDocument(at path: RelativePath) async throws -> DocumentFileSnapshot
    func atomicallyWriteDocument(
        _ data: Data,
        to path: RelativePath,
        expectedFingerprint: DiskFingerprint
    ) async throws -> DiskFingerprint
}

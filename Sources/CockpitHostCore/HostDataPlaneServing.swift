import CockpitProtocol
import CockpitTypes

public enum HostDataPlaneServiceError: Error, Hashable, Sendable {
    case contextMismatch
    case environmentMismatch
    case documentNotOpen
}

public enum HostDataPlaneDocumentError: Error, Hashable, Sendable {
    case committedRecoveryRequired(EditAcknowledgement)
}

public protocol HostDataPlaneServing: Sendable {
    func openDocument(
        binding: HostDataPlaneBinding,
        at path: RelativePath
    ) async throws -> DocumentSnapshot
    func snapshot(
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) async throws -> DocumentSnapshot
    func acquireEditLease(
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) async throws -> EditLease
    func transferEditLease(
        binding: HostDataPlaneBinding,
        documentID: DocumentID,
        from leaseID: EditLeaseID,
        to client: ClientInstanceID
    ) async throws -> EditLease
    func apply(
        binding: HostDataPlaneBinding,
        transaction: EditTransaction
    ) async throws -> EditAcknowledgement
    func flush(
        binding: HostDataPlaneBinding,
        documentID: DocumentID,
        through clientSequence: UInt64
    ) async throws -> UInt64
    func save(
        binding: HostDataPlaneBinding,
        documentID: DocumentID,
        expectedFingerprint: DiskFingerprint
    ) async throws -> DocumentSnapshot
    func discard(
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) async throws -> DocumentSnapshot
    func fileTreeChildren(
        binding: HostDataPlaneBinding,
        at directory: WorkspaceDirectory
    ) async throws -> FileTreeSnapshot
    func fileTreeChanges(
        binding: HostDataPlaneBinding,
        after revision: UInt64
    ) -> AsyncThrowingStream<FileTreeDelta, Error>
}

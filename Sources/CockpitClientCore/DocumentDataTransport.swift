import CockpitProtocol
import CockpitTypes

public protocol DocumentDataTransport: Sendable {
    func openDocument(
        in environmentID: EnvironmentID,
        at path: RelativePath
    ) async throws -> DocumentSnapshot
    func snapshot(documentID: DocumentID) async throws -> DocumentSnapshot
    func acquireEditLease(
        documentID: DocumentID,
        client: ClientInstanceID
    ) async throws -> EditLease
    func transferEditLease(
        documentID: DocumentID,
        from leaseID: EditLeaseID,
        to client: ClientInstanceID
    ) async throws -> EditLease
    func apply(_ transaction: EditTransaction) async throws -> EditAcknowledgement
    func flush(documentID: DocumentID, through clientSequence: UInt64) async throws -> UInt64
    func save(
        documentID: DocumentID,
        expectedFingerprint: DiskFingerprint
    ) async throws -> DocumentSnapshot
    func discard(documentID: DocumentID) async throws -> DocumentSnapshot
}

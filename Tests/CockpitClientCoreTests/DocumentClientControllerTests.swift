import Foundation
import Testing
import CockpitProtocol
import CockpitTypes
@testable import CockpitClientCore

@Test func documentClientControllerUsesStopAndWaitGlobalSequenceAndFlushBarrier() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(
        in: fixture.environmentID,
        at: fixture.path,
        requestWriteAccess: true
    )

    async let first = controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "a")
    ])
    async let second = controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "b")
    ])
    let acknowledgements = try await [first, second]
    #expect(acknowledgements.map(\.clientSequence) == [1, 2])
    #expect(await transport.maximumConcurrentApplyCount == 1)
    #expect(try await controller.flush() == 2)
    #expect(await transport.flushedSequences == [2])
}

@Test func documentClientControllerStopsOnAuthoritativeErrorUntilSnapshotReplacement() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    await transport.setApplyError(.sequenceGap(expected: 1, actual: 2))
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)

    await #expect(throws: DocumentProtocolError.sequenceGap(expected: 1, actual: 2)) {
        _ = try await controller.submit([
            try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x")
        ])
    }
    guard case .resynchronizing = await controller.state else {
        Issue.record("Expected resynchronizing state")
        return
    }
    await #expect(throws: DocumentProtocolError.resynchronizing) {
        _ = try await controller.submit([
            try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "blocked")
        ])
    }

    await transport.setApplyError(nil)
    let replaced = try await controller.resynchronize(requestWriteAccess: true)
    #expect(replaced == fixture.snapshot)
    guard case .ready = await controller.state else {
        Issue.record("Expected ready state")
        return
    }
    #expect(try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "accepted")
    ]).clientSequence == 1)
}

@Test func documentClientControllerOpensReadOnlyWithoutLease() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: false)
    guard case .readOnly = await controller.state else {
        Issue.record("Expected read-only state")
        return
    }
    await #expect(throws: DocumentProtocolError.readOnly) {
        _ = try await controller.submit([
            try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x")
        ])
    }
}

private struct ClientDocumentFixture {
    let clientID = ClientInstanceID()
    let environmentID = EnvironmentID()
    let path = try! RelativePath("document.txt")
    let lease: EditLease
    let snapshot: DocumentSnapshot

    init() throws {
        let documentID = DocumentID()
        lease = try EditLease(
            validatingID: EditLeaseID(), documentID: documentID,
            clientInstanceID: clientID
        )
        snapshot = try DocumentSnapshot(
            validatingDocumentID: documentID,
            environmentID: environmentID,
            relativePath: path,
            text: "",
            documentVersion: 0,
            persistedVersion: 0,
            lastAcceptedClientSequence: 0,
            dirtyState: .clean,
            observedDiskFingerprint: nil,
            currentLease: nil,
            maintenance: []
        )
    }
}

private actor RecordingDocumentDataTransport: DocumentDataTransport {
    private var authoritativeSnapshot: DocumentSnapshot
    private let lease: EditLease
    private var applyError: DocumentProtocolError?
    private var activeApplyCount = 0
    private(set) var maximumConcurrentApplyCount = 0
    private(set) var flushedSequences: [UInt64] = []

    init(snapshot: DocumentSnapshot, lease: EditLease) {
        authoritativeSnapshot = snapshot
        self.lease = lease
    }

    func openDocument(in environmentID: EnvironmentID, at path: RelativePath) -> DocumentSnapshot {
        authoritativeSnapshot
    }

    func snapshot(documentID: DocumentID) -> DocumentSnapshot { authoritativeSnapshot }

    func acquireEditLease(documentID: DocumentID, client: ClientInstanceID) -> EditLease { lease }

    func transferEditLease(documentID: DocumentID, from leaseID: EditLeaseID, to client: ClientInstanceID) -> EditLease {
        lease
    }

    func apply(_ transaction: EditTransaction) async throws -> EditAcknowledgement {
        if let applyError { throw applyError }
        activeApplyCount += 1
        maximumConcurrentApplyCount = max(maximumConcurrentApplyCount, activeApplyCount)
        await Task.yield()
        activeApplyCount -= 1
        let version = transaction.clientSequence
        authoritativeSnapshot = try DocumentSnapshot(
            validatingDocumentID: authoritativeSnapshot.documentID,
            environmentID: authoritativeSnapshot.environmentID,
            relativePath: authoritativeSnapshot.relativePath,
            text: authoritativeSnapshot.text,
            documentVersion: version,
            persistedVersion: authoritativeSnapshot.persistedVersion,
            lastAcceptedClientSequence: transaction.clientSequence,
            dirtyState: .dirty,
            observedDiskFingerprint: authoritativeSnapshot.observedDiskFingerprint,
            currentLease: lease,
            maintenance: authoritativeSnapshot.maintenance
        )
        return try EditAcknowledgement(
            validatingDocumentID: transaction.documentID,
            clientSequence: transaction.clientSequence,
            documentVersion: version
        )
    }

    func flush(documentID: DocumentID, through clientSequence: UInt64) -> UInt64 {
        flushedSequences.append(clientSequence)
        return authoritativeSnapshot.documentVersion
    }

    func save(documentID: DocumentID, expectedFingerprint: DiskFingerprint) -> DocumentSnapshot {
        authoritativeSnapshot
    }

    func discard(documentID: DocumentID) -> DocumentSnapshot { authoritativeSnapshot }

    func setApplyError(_ error: DocumentProtocolError?) { applyError = error }
}

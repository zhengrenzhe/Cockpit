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
    guard case let .ready(opened) = await controller.state else {
        Issue.record("Expected ready state")
        return
    }
    #expect(opened.currentLease == fixture.lease)

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
    guard case let .ready(ready) = await controller.state else {
        Issue.record("Expected ready state")
        return
    }
    #expect(ready.currentLease == fixture.lease)
    #expect(try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "accepted")
    ]).clientSequence == 1)
}

@Test func documentClientControllerPausesQueuedEditsUntilAuthoritativeResync() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)
    await transport.blockNextApply(error: .sequenceGap(expected: 1, actual: 2))

    let first = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "first")
    ]) }
    await transport.waitUntilApplyBlocks()
    let second = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "second")
    ]) }
    let third = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "third")
    ]) }
    for _ in 0..<20 { await Task.yield() }
    await transport.releaseBlockedApply()
    await #expect(throws: DocumentProtocolError.sequenceGap(expected: 1, actual: 2)) {
        _ = try await first.value
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(await transport.recordedTransactions.count == 1)
    await #expect(throws: DocumentProtocolError.resynchronizing) {
        _ = try await controller.discard()
    }
    #expect(await transport.discardCount == 0)

    _ = try await controller.resynchronize(requestWriteAccess: true)
    let acknowledgements = try await [second.value, third.value]
    #expect(acknowledgements.map(\.clientSequence) == [1, 2])
    #expect(await transport.recordedTransactions.count == 3)
}

@Test func documentClientControllerCancelsQueuedEditWithoutSendingIt() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)
    await transport.blockNextApply(error: nil)

    let first = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "first")
    ]) }
    await transport.waitUntilApplyBlocks()
    let cancelled = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "cancelled")
    ]) }
    let third = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "third")
    ]) }
    for _ in 0..<20 { await Task.yield() }
    cancelled.cancel()
    await transport.releaseBlockedApply()

    #expect(try await first.value.clientSequence == 1)
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    #expect(try await third.value.clientSequence == 2)
    #expect(await transport.recordedTransactions.flatMap(\.changes).map(\.replacement) == ["first", "third"])
}

@Test func documentClientControllerRetriesOneTransientApplyWithExactTransaction() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    await transport.failTransientApply(times: 1)
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)

    #expect(try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "retry")
    ]).clientSequence == 1)
    let transactions = await transport.recordedTransactions
    #expect(transactions.count == 2)
    #expect(transactions.first == transactions.last)
    guard case .ready = await controller.state else {
        Issue.record("Expected ready after transient retry")
        return
    }
}

@Test func documentClientControllerFlushRecoveryRequiredEntersResync() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)
    await transport.setFlushError(.recoveryRequired)

    await #expect(throws: DocumentProtocolError.recoveryRequired) { _ = try await controller.flush() }
    guard case .resynchronizing = await controller.state else {
        Issue.record("Expected flush recovery-required to resynchronize")
        return
    }
}

@Test func documentClientControllerSaveRecoveryRequiredEntersResync() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)
    await transport.setSaveError(.recoveryRequired)
    let fingerprint = DiskFingerprint(
        deviceID: 0,
        inode: 0,
        byteCount: 0,
        modificationTimeSeconds: 0,
        modificationTimeNanoseconds: 0,
        contentSHA256: try SHA256Digest(validating: Data(repeating: 0, count: 32))
    )

    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await controller.save(expectedFingerprint: fingerprint)
    }
    guard case .resynchronizing = await controller.state else {
        Issue.record("Expected save recovery-required to resynchronize")
        return
    }
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
    private var flushError: DocumentProtocolError?
    private var saveError: DocumentProtocolError?
    private var transientApplyFailures = 0
    private var shouldBlockNextApply = false
    private var blockedApplyError: DocumentProtocolError?
    private var applyBlockWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseApplyBlock: CheckedContinuation<Void, Never>?
    private var activeApplyCount = 0
    private(set) var maximumConcurrentApplyCount = 0
    private(set) var flushedSequences: [UInt64] = []
    private(set) var recordedTransactions: [EditTransaction] = []
    private(set) var discardCount = 0

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
        recordedTransactions.append(transaction)
        if shouldBlockNextApply {
            shouldBlockNextApply = false
            applyBlockWaiters.forEach { $0.resume() }
            applyBlockWaiters.removeAll()
            await withCheckedContinuation { releaseApplyBlock = $0 }
            if let blockedApplyError {
                self.blockedApplyError = nil
                throw blockedApplyError
            }
        }
        if transientApplyFailures > 0 {
            transientApplyFailures -= 1
            throw CocoaError(.fileReadUnknown)
        }
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

    func flush(documentID: DocumentID, through clientSequence: UInt64) throws -> UInt64 {
        if let flushError { throw flushError }
        flushedSequences.append(clientSequence)
        return authoritativeSnapshot.documentVersion
    }

    func save(documentID: DocumentID, expectedFingerprint: DiskFingerprint) throws -> DocumentSnapshot {
        if let saveError { throw saveError }
        return authoritativeSnapshot
    }

    func discard(documentID: DocumentID) -> DocumentSnapshot {
        discardCount += 1
        return authoritativeSnapshot
    }

    func setApplyError(_ error: DocumentProtocolError?) { applyError = error }
    func blockNextApply(error: DocumentProtocolError?) {
        shouldBlockNextApply = true
        blockedApplyError = error
    }
    func waitUntilApplyBlocks() async {
        if releaseApplyBlock != nil { return }
        await withCheckedContinuation { applyBlockWaiters.append($0) }
    }
    func releaseBlockedApply() { releaseApplyBlock?.resume(); releaseApplyBlock = nil }
    func failTransientApply(times: Int) { transientApplyFailures = times }
    func setFlushError(_ error: DocumentProtocolError?) { flushError = error }
    func setSaveError(_ error: DocumentProtocolError?) { saveError = error }
}

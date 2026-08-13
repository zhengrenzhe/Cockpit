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
    #expect(acknowledgements.map(\.clientSequence).sorted() == [1, 2])
    #expect(await transport.maximumConcurrentApplyCount == 1)
    #expect(try await controller.flush() == 2)
    #expect(await transport.flushedSequences == [2])
}

@Test func documentClientControllerRestoresExistingDocumentFromSnapshotWithoutOpeningPath() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    let controller = DocumentClientController(
        clientInstanceID: fixture.clientID,
        transport: transport
    )

    let restored = try await controller.restore(
        documentID: fixture.snapshot.documentID,
        in: fixture.environmentID,
        requestWriteAccess: true
    )

    #expect(restored == fixture.snapshot)
    #expect(await transport.snapshotRequests == [fixture.snapshot.documentID])
    #expect(await transport.openRequests.isEmpty)
    #expect(await transport.leaseRequests == [fixture.snapshot.documentID])
    guard case let .ready(ready) = await controller.state else {
        Issue.record("Expected restored writable document to be ready")
        return
    }
    #expect(ready.documentID == fixture.snapshot.documentID)
    #expect(ready.environmentID == fixture.environmentID)
    #expect(ready.relativePath == fixture.path)
    #expect(ready.currentLease == fixture.lease)
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
    #expect(await waitForPendingEditCount(2, in: controller))
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
    #expect(acknowledgements.map(\.clientSequence).sorted() == [1, 2])
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

@Test func documentClientControllerAmbiguousRetryExhaustionStopsOldAuthority() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    await transport.dropApplyRepliesAfterCommit(times: 2)
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)

    let first = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "first")
    ]) }
    let second = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "second")
    ]) }
    await #expect(throws: CocoaError.self) { _ = try await first.value }
    for _ in 0..<50 { await Task.yield() }
    let attempts = await transport.recordedTransactions
    #expect(attempts.count == 2)
    #expect(attempts.first == attempts.last)
    guard case .resynchronizing = await controller.state else {
        Issue.record("Expected ambiguous apply result to resynchronize")
        return
    }

    _ = try await controller.resynchronize(requestWriteAccess: true)
    #expect(try await second.value.clientSequence == 2)
}

@Test func documentClientControllerIssuedApplyCancellationRequiresResynchronization() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    await transport.dropNextCommittedApplyReplyAsCancellation()
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)

    let first = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "first")
    ]) }
    let second = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "second")
    ]) }
    await #expect(throws: CancellationError.self) { _ = try await first.value }
    for _ in 0..<50 { await Task.yield() }
    #expect(await transport.recordedTransactions.count == 1)
    guard case .resynchronizing = await controller.state else {
        Issue.record("Expected issued apply cancellation to resynchronize")
        second.cancel()
        return
    }

    _ = try await controller.resynchronize(requestWriteAccess: true)
    #expect(try await second.value.clientSequence == 2)
}

@Test func documentClientControllerCancelledDrainNeverCallsControlTransport() async throws {
    do {
        let fixture = try ClientDocumentFixture()
        let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
        let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
        _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)
        await transport.blockNextApply(error: nil)
        let edit = Task { try await controller.submit([
            try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "edit")
        ]) }
        await transport.waitUntilApplyBlocks()
        let flush = Task { try await controller.flush() }
        for _ in 0..<20 { await Task.yield() }
        flush.cancel()
        await transport.releaseBlockedApply()
        _ = try await edit.value
        await #expect(throws: CancellationError.self) { _ = try await flush.value }
        #expect(await transport.flushCount == 0)
    }

    do {
        let fixture = try ClientDocumentFixture()
        let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
        let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
        _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)
        await transport.blockNextApply(error: nil)
        let edit = Task { try await controller.submit([
            try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "edit")
        ]) }
        await transport.waitUntilApplyBlocks()
        let save = Task { try await controller.save(expectedFingerprint: try clientFingerprint()) }
        for _ in 0..<20 { await Task.yield() }
        save.cancel()
        await transport.releaseBlockedApply()
        _ = try await edit.value
        await #expect(throws: CancellationError.self) { _ = try await save.value }
        #expect(await transport.flushCount == 0)
        #expect(await transport.saveCount == 0)
    }

    do {
        let fixture = try ClientDocumentFixture()
        let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
        let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
        _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)
        await transport.blockNextApply(error: nil)
        let edit = Task { try await controller.submit([
            try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "edit")
        ]) }
        await transport.waitUntilApplyBlocks()
        let discard = Task { try await controller.discard() }
        for _ in 0..<20 { await Task.yield() }
        discard.cancel()
        await transport.releaseBlockedApply()
        _ = try await edit.value
        await #expect(throws: CancellationError.self) { _ = try await discard.value }
        #expect(await transport.discardCount == 0)
    }
}

@Test func documentClientControllerSerializesSaveBeforeLaterEdit() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)
    await transport.blockNextSave()

    let save = Task { try await controller.save(expectedFingerprint: try clientFingerprint()) }
    await transport.waitUntilSaveBlocks()
    let edit = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "after-save")
    ]) }
    for _ in 0..<50 { await Task.yield() }
    #expect(await transport.recordedTransactions.isEmpty)
    await transport.releaseBlockedSave()
    _ = try await save.value
    #expect(try await edit.value.clientSequence == 1)
}

@Test func documentClientControllerDiscardRecoveryPausesLaterEditUntilResync() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)
    await transport.blockNextDiscard(error: .recoveryRequired)

    let discard = Task { try await controller.discard() }
    await transport.waitUntilDiscardBlocks()
    let edit = Task { try await controller.submit([
        try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "after-discard")
    ]) }
    for _ in 0..<50 { await Task.yield() }
    #expect(await transport.recordedTransactions.isEmpty)
    await transport.releaseBlockedDiscard()
    await #expect(throws: DocumentProtocolError.recoveryRequired) { _ = try await discard.value }
    guard case .resynchronizing = await controller.state else {
        Issue.record("Expected discard recovery-required to resynchronize")
        return
    }
    #expect(await transport.recordedTransactions.isEmpty)

    _ = try await controller.resynchronize(requestWriteAccess: true)
    #expect(try await edit.value.clientSequence == 1)
}

@Test func documentClientControllerDroppedMutationRepliesRequireResynchronization() async throws {
    for droppedReply in ClientDroppedReply.allCases {
        do {
            let fixture = try ClientDocumentFixture()
            let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
            let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
            _ = try await controller.open(
                in: fixture.environmentID,
                at: fixture.path,
                requestWriteAccess: true
            )
            await transport.blockNextSaveAfterCommit(dropping: droppedReply)

            let save = Task { try await controller.save(expectedFingerprint: try clientFingerprint()) }
            await transport.waitUntilSaveBlocks()
            let edit = Task { try await controller.submit([
                try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "after-save")
            ]) }
            #expect(await waitForPendingEditCount(1, in: controller))
            await transport.releaseBlockedSave()
            await expectDroppedReply(droppedReply) { _ = try await save.value }
            guard case .resynchronizing = await controller.state else {
                Issue.record("Expected dropped save reply to resynchronize")
                edit.cancel()
                continue
            }
            #expect(await transport.recordedTransactions.isEmpty)

            _ = try await controller.resynchronize(requestWriteAccess: true)
            #expect(try await edit.value.clientSequence == 1)
        }

        do {
            let fixture = try ClientDocumentFixture()
            let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
            let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
            _ = try await controller.open(
                in: fixture.environmentID,
                at: fixture.path,
                requestWriteAccess: true
            )
            await transport.blockNextDiscardAfterCommit(dropping: droppedReply)

            let discard = Task { try await controller.discard() }
            await transport.waitUntilDiscardBlocks()
            let edit = Task { try await controller.submit([
                try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "after-discard")
            ]) }
            #expect(await waitForPendingEditCount(1, in: controller))
            await transport.releaseBlockedDiscard()
            await expectDroppedReply(droppedReply) { _ = try await discard.value }
            guard case .resynchronizing = await controller.state else {
                Issue.record("Expected dropped discard reply to resynchronize")
                edit.cancel()
                continue
            }
            #expect(await transport.recordedTransactions.isEmpty)

            _ = try await controller.resynchronize(requestWriteAccess: true)
            #expect(try await edit.value.clientSequence == 1)
        }
    }
}

@Test func documentClientControllerCompletedSubmitCancellationRetainsNoRequestIDs() async throws {
    let fixture = try ClientDocumentFixture()
    let transport = RecordingDocumentDataTransport(snapshot: fixture.snapshot, lease: fixture.lease)
    let controller = DocumentClientController(clientInstanceID: fixture.clientID, transport: transport)
    _ = try await controller.open(in: fixture.environmentID, at: fixture.path, requestWriteAccess: true)

    for sequence in 1...100 {
        let submit = Task(priority: .background) { try await controller.submit([
            try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x")
        ]) }
        while true {
            guard case let .ready(snapshot) = await controller.state else { break }
            if snapshot.lastAcceptedClientSequence == UInt64(sequence) { break }
            await Task.yield()
        }
        submit.cancel()
        _ = try await submit.value
    }
    for _ in 0..<50 { await Task.yield() }
    let requestStates = try #require(Mirror(reflecting: controller).children.first {
        $0.label == "submitRequestStates"
    })
    #expect(Mirror(reflecting: requestStates.value).children.isEmpty)
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

private enum ClientDroppedReply: CaseIterable, Sendable {
    case ordinaryError
    case cancellation
}

private func waitForPendingEditCount(
    _ expected: Int,
    in controller: DocumentClientController
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if await pendingEditCount(in: controller) == expected { return true }
        await Task.yield()
    }
    return await pendingEditCount(in: controller) == expected
}

private func pendingEditCount(
    in controller: isolated DocumentClientController
) -> Int {
    guard let pendingEdits = Mirror(reflecting: controller).children.first(where: {
        $0.label == "pendingEdits"
    }) else {
        return -1
    }
    return Mirror(reflecting: pendingEdits.value).children.count
}

private actor RecordingDocumentDataTransport: DocumentDataTransport {
    private var authoritativeSnapshot: DocumentSnapshot
    private let lease: EditLease
    private var applyError: DocumentProtocolError?
    private var flushError: DocumentProtocolError?
    private var saveError: DocumentProtocolError?
    private var transientApplyFailures = 0
    private var droppedCommittedApplyReplies = 0
    private var droppedCommittedApplyCancellationReplies = 0
    private var lastCommittedTransaction: EditTransaction?
    private var lastCommittedAcknowledgement: EditAcknowledgement?
    private var shouldBlockNextApply = false
    private var blockedApplyError: DocumentProtocolError?
    private var applyBlockWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseApplyBlock: CheckedContinuation<Void, Never>?
    private var activeApplyCount = 0
    private(set) var maximumConcurrentApplyCount = 0
    private(set) var flushedSequences: [UInt64] = []
    private(set) var recordedTransactions: [EditTransaction] = []
    private(set) var discardCount = 0
    private(set) var flushCount = 0
    private(set) var saveCount = 0
    private var shouldBlockNextSave = false
    private var droppedSaveReply: ClientDroppedReply?
    private var saveBlockWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseSaveBlock: CheckedContinuation<Void, Never>?
    private var shouldBlockNextDiscard = false
    private var blockedDiscardError: DocumentProtocolError?
    private var droppedDiscardReply: ClientDroppedReply?
    private var discardBlockWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseDiscardBlock: CheckedContinuation<Void, Never>?
    private(set) var openRequests: [(EnvironmentID, RelativePath)] = []
    private(set) var snapshotRequests: [DocumentID] = []
    private(set) var leaseRequests: [DocumentID] = []

    init(snapshot: DocumentSnapshot, lease: EditLease) {
        authoritativeSnapshot = snapshot
        self.lease = lease
    }

    func openDocument(in environmentID: EnvironmentID, at path: RelativePath) -> DocumentSnapshot {
        openRequests.append((environmentID, path))
        return authoritativeSnapshot
    }

    func snapshot(documentID: DocumentID) -> DocumentSnapshot {
        snapshotRequests.append(documentID)
        return authoritativeSnapshot
    }

    func acquireEditLease(documentID: DocumentID, client: ClientInstanceID) -> EditLease {
        leaseRequests.append(documentID)
        return lease
    }

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
        if transaction == lastCommittedTransaction, let acknowledgement = lastCommittedAcknowledgement {
            if droppedCommittedApplyCancellationReplies > 0 {
                droppedCommittedApplyCancellationReplies -= 1
                throw CancellationError()
            }
            if droppedCommittedApplyReplies > 0 {
                droppedCommittedApplyReplies -= 1
                throw CocoaError(.fileReadUnknown)
            }
            return acknowledgement
        }
        guard transaction.baseVersion == authoritativeSnapshot.documentVersion else {
            throw DocumentProtocolError.baseVersionMismatch(
                expected: authoritativeSnapshot.documentVersion,
                actual: transaction.baseVersion
            )
        }
        guard transaction.clientSequence == authoritativeSnapshot.lastAcceptedClientSequence + 1 else {
            throw DocumentProtocolError.sequenceGap(
                expected: authoritativeSnapshot.lastAcceptedClientSequence + 1,
                actual: transaction.clientSequence
            )
        }
        activeApplyCount += 1
        maximumConcurrentApplyCount = max(maximumConcurrentApplyCount, activeApplyCount)
        await Task.yield()
        activeApplyCount -= 1
        let version = authoritativeSnapshot.documentVersion + 1
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
        let acknowledgement = try EditAcknowledgement(
            validatingDocumentID: transaction.documentID,
            clientSequence: transaction.clientSequence,
            documentVersion: version
        )
        lastCommittedTransaction = transaction
        lastCommittedAcknowledgement = acknowledgement
        if droppedCommittedApplyCancellationReplies > 0 {
            droppedCommittedApplyCancellationReplies -= 1
            throw CancellationError()
        }
        if droppedCommittedApplyReplies > 0 {
            droppedCommittedApplyReplies -= 1
            throw CocoaError(.fileReadUnknown)
        }
        return acknowledgement
    }

    func flush(documentID: DocumentID, through clientSequence: UInt64) throws -> UInt64 {
        flushCount += 1
        if let flushError { throw flushError }
        flushedSequences.append(clientSequence)
        return authoritativeSnapshot.documentVersion
    }

    func save(documentID: DocumentID, expectedFingerprint: DiskFingerprint) async throws -> DocumentSnapshot {
        saveCount += 1
        if shouldBlockNextSave {
            shouldBlockNextSave = false
            saveBlockWaiters.forEach { $0.resume() }
            saveBlockWaiters.removeAll()
            await withCheckedContinuation { releaseSaveBlock = $0 }
        }
        if let saveError { throw saveError }
        if let droppedSaveReply {
            self.droppedSaveReply = nil
            authoritativeSnapshot = try DocumentSnapshot(
                validatingDocumentID: authoritativeSnapshot.documentID,
                environmentID: authoritativeSnapshot.environmentID,
                relativePath: authoritativeSnapshot.relativePath,
                text: authoritativeSnapshot.text,
                documentVersion: authoritativeSnapshot.documentVersion,
                persistedVersion: authoritativeSnapshot.documentVersion,
                lastAcceptedClientSequence: authoritativeSnapshot.lastAcceptedClientSequence,
                dirtyState: .clean,
                observedDiskFingerprint: authoritativeSnapshot.observedDiskFingerprint,
                currentLease: lease,
                maintenance: authoritativeSnapshot.maintenance
            )
            switch droppedSaveReply {
            case .ordinaryError: throw CocoaError(.fileReadUnknown)
            case .cancellation: throw CancellationError()
            }
        }
        return authoritativeSnapshot
    }

    func discard(documentID: DocumentID) async throws -> DocumentSnapshot {
        discardCount += 1
        if shouldBlockNextDiscard {
            shouldBlockNextDiscard = false
            discardBlockWaiters.forEach { $0.resume() }
            discardBlockWaiters.removeAll()
            await withCheckedContinuation { releaseDiscardBlock = $0 }
            if let blockedDiscardError {
                self.blockedDiscardError = nil
                throw blockedDiscardError
            }
        }
        if let droppedDiscardReply {
            self.droppedDiscardReply = nil
            let nextVersion = authoritativeSnapshot.documentVersion + 1
            authoritativeSnapshot = try DocumentSnapshot(
                validatingDocumentID: authoritativeSnapshot.documentID,
                environmentID: authoritativeSnapshot.environmentID,
                relativePath: authoritativeSnapshot.relativePath,
                text: "discarded",
                documentVersion: nextVersion,
                persistedVersion: nextVersion,
                lastAcceptedClientSequence: authoritativeSnapshot.lastAcceptedClientSequence,
                dirtyState: .clean,
                observedDiskFingerprint: authoritativeSnapshot.observedDiskFingerprint,
                currentLease: lease,
                maintenance: authoritativeSnapshot.maintenance
            )
            switch droppedDiscardReply {
            case .ordinaryError: throw CocoaError(.fileReadUnknown)
            case .cancellation: throw CancellationError()
            }
        }
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
    func dropApplyRepliesAfterCommit(times: Int) { droppedCommittedApplyReplies = times }
    func dropNextCommittedApplyReplyAsCancellation() {
        droppedCommittedApplyCancellationReplies = 1
    }
    func setFlushError(_ error: DocumentProtocolError?) { flushError = error }
    func setSaveError(_ error: DocumentProtocolError?) { saveError = error }
    func blockNextSave() { shouldBlockNextSave = true }
    func blockNextSaveAfterCommit(dropping reply: ClientDroppedReply) {
        shouldBlockNextSave = true
        droppedSaveReply = reply
    }
    func waitUntilSaveBlocks() async {
        if releaseSaveBlock != nil { return }
        await withCheckedContinuation { saveBlockWaiters.append($0) }
    }
    func releaseBlockedSave() { releaseSaveBlock?.resume(); releaseSaveBlock = nil }
    func blockNextDiscard(error: DocumentProtocolError?) {
        shouldBlockNextDiscard = true
        blockedDiscardError = error
    }
    func blockNextDiscardAfterCommit(dropping reply: ClientDroppedReply) {
        shouldBlockNextDiscard = true
        droppedDiscardReply = reply
    }
    func waitUntilDiscardBlocks() async {
        if releaseDiscardBlock != nil { return }
        await withCheckedContinuation { discardBlockWaiters.append($0) }
    }
    func releaseBlockedDiscard() { releaseDiscardBlock?.resume(); releaseDiscardBlock = nil }
}

private func expectDroppedReply(
    _ reply: ClientDroppedReply,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected dropped mutation reply")
    } catch {
        switch reply {
        case .ordinaryError:
            #expect(error is CocoaError)
        case .cancellation:
            #expect(error is CancellationError)
        }
    }
}

private func clientFingerprint() throws -> DiskFingerprint {
    DiskFingerprint(
        deviceID: 0,
        inode: 0,
        byteCount: 0,
        modificationTimeSeconds: 0,
        modificationTimeNanoseconds: 0,
        contentSHA256: try SHA256Digest(validating: Data(repeating: 0, count: 32))
    )
}

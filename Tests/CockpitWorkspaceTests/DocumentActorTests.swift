import Foundation
import Darwin
import Testing
import CockpitHostCore
import CockpitProtocol
import CockpitTypes
@testable import CockpitWorkspace

@Test func documentActorAppliesDurablyAndMakesOnlyLastRetryIdempotent() async throws {
    let fixture = try DocumentActorFixture(text: "a\r\nb")
    defer { fixture.remove() }
    let actor = try await fixture.openActor()
    let lease = try await actor.acquireEditLease(client: fixture.clientID)
    let transaction = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: lease.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 1, length: 0, replacement: "x\n")]
    )

    let acknowledgement = try await actor.apply(transaction)
    #expect(acknowledgement.documentVersion == 1)
    #expect(try await actor.apply(transaction) == acknowledgement)
    let snapshot = await actor.snapshot()
    #expect(snapshot.text == "ax\n\nb")
    #expect(snapshot.dirtyState == .dirty)
    #expect(snapshot.lastAcceptedClientSequence == 1)
    #expect(try await actor.flush(through: 1) == 1)
    await #expect(throws: DocumentProtocolError.sequenceGap(expected: 2, actual: 3)) {
        _ = try await actor.flush(through: 3)
    }

    let different = try EditTransaction(
        validatingDocumentID: transaction.documentID,
        editLeaseID: transaction.editLeaseID,
        baseVersion: transaction.baseVersion,
        clientSequence: transaction.clientSequence,
        changes: [try UTF16TextEdit(validatingOffset: 1, length: 0, replacement: "different")]
    )
    await #expect(throws: DocumentProtocolError.duplicateMismatch) {
        _ = try await actor.apply(different)
    }
    let recovered = try await fixture.recoveryLog.recover()
    #expect(recovered.records.count == 1)
    let expectedPayload = try DocumentEditing.encodeRecoveryPayload(transaction)
    #expect(recovered.records.first?.utf8EditPayload == expectedPayload)

    let wrongBase = try EditTransaction(
        validatingDocumentID: transaction.documentID,
        editLeaseID: transaction.editLeaseID,
        baseVersion: 0,
        clientSequence: 2,
        changes: [try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "z")]
    )
    await #expect(throws: DocumentProtocolError.baseVersionMismatch(expected: 1, actual: 0)) {
        _ = try await actor.apply(wrongBase)
    }
    let gap = try EditTransaction(
        validatingDocumentID: transaction.documentID,
        editLeaseID: transaction.editLeaseID,
        baseVersion: 1,
        clientSequence: 3,
        changes: wrongBase.changes
    )
    await #expect(throws: DocumentProtocolError.sequenceGap(expected: 2, actual: 3)) {
        _ = try await actor.apply(gap)
    }
}

@Test func documentActorRejectsWrongLeaseAndPreservesGlobalSequenceAcrossTransfer() async throws {
    let fixture = try DocumentActorFixture(text: "abc")
    defer { fixture.remove() }
    let actor = try await fixture.openActor()
    let first = try await actor.acquireEditLease(client: fixture.clientID)
    #expect(try await actor.acquireEditLease(client: fixture.clientID) == first)
    await #expect(throws: DocumentProtocolError.leaseHeld) {
        _ = try await actor.acquireEditLease(client: ClientInstanceID())
    }
    let secondClient = ClientInstanceID()
    let transferred = try await actor.transferEditLease(from: first.id, to: secondClient)
    #expect(transferred.id != first.id)

    let wrong = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: first.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x")]
    )
    await #expect(throws: DocumentProtocolError.invalidLease) { _ = try await actor.apply(wrong) }
    let accepted = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: transferred.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: wrong.changes
    )
    #expect(try await actor.apply(accepted).clientSequence == 1)
}

@Test func documentActorMetadataFailureIsFailClosedAfterDurableRecord() async throws {
    let fixture = try DocumentActorFixture(text: "abc")
    defer { fixture.remove() }
    let actor = try await fixture.openActor()
    let lease = try await actor.acquireEditLease(client: fixture.clientID)
    await fixture.repository.failNextCompareAndSet()
    let transaction = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: lease.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 0, length: 1, replacement: "z")]
    )

    do {
        _ = try await actor.apply(transaction)
        Issue.record("Expected recovery-required metadata failure")
    } catch let error as DocumentCommitRecoveryRequiredError {
        #expect(error.committedAcknowledgement.documentVersion == 1)
    }
    #expect((try await fixture.recoveryLog.recover()).records.count == 1)
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await actor.flush(through: 1)
    }
}

@Test func documentActorAppendFailureFailsClosedBeforeAnyAcknowledgement() async throws {
    let writeFailure = DocumentActorAppendWriteFailure()
    let fixture = try DocumentActorFixture(
        text: "abc",
        recoverySystemCalls: RecoveryLogSystemCalls(
            write: { writeFailure.call($0, $1, $2) },
            fsync: { Darwin.fsync($0) },
            rename: { Darwin.rename($0, $1) }
        )
    )
    defer { fixture.remove() }
    let actor = try await fixture.openActor()
    let lease = try await actor.acquireEditLease(client: fixture.clientID)
    let transaction = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: lease.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 3, length: 0, replacement: "d")]
    )
    writeFailure.failAfterNextPrefix()

    await #expect(throws: (any Error).self) { _ = try await actor.apply(transaction) }
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await actor.apply(transaction)
    }
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await actor.transferEditLease(from: lease.id, to: ClientInstanceID())
    }

    let restarted = try await fixture.openActor()
    let snapshot = await restarted.snapshot()
    #expect(snapshot.text == "abc")
    #expect(snapshot.documentVersion == 0)
    #expect(snapshot.lastAcceptedClientSequence == 0)
    #expect(snapshot.maintenance.contains(.truncatedRecoveryTail))
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await restarted.acquireEditLease(client: ClientInstanceID())
    }
}

@Test func documentActorSaveAndDiscardUseCheckpointedExactBytes() async throws {
    let fixture = try DocumentActorFixture(text: "a\r\nb")
    defer { fixture.remove() }
    let actor = try await fixture.openActor()
    let lease = try await actor.acquireEditLease(client: fixture.clientID)
    _ = try await actor.apply(EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: lease.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 1, length: 0, replacement: "x")]
    ))
    let dirty = await actor.snapshot()

    let saved = try await actor.save(expectedFingerprint: try #require(dirty.observedDiskFingerprint))
    #expect(saved.dirtyState == .clean)
    #expect(saved.persistedVersion == saved.documentVersion)
    #expect(try Data(contentsOf: fixture.documentURL) == Data("ax\r\nb".utf8))
    #expect((try await fixture.recoveryLog.recover()).checkpoint?.persistedDocumentBytes == Data("ax\r\nb".utf8))

    try Data("external\n".utf8).write(to: fixture.documentURL)
    let discarded = try await actor.discard()
    #expect(discarded.text == "external\n")
    #expect(discarded.documentVersion == 2)
    #expect(discarded.persistedVersion == 2)
    #expect(discarded.dirtyState == .clean)
}

@Test func documentActorRecoveryReplaysOnlyDurableAcceptedTransactionsAndClearsLease() async throws {
    let fixture = try DocumentActorFixture(text: "abc")
    defer { fixture.remove() }
    let first = try await fixture.openActor()
    let lease = try await first.acquireEditLease(client: fixture.clientID)
    let transaction = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: lease.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 3, length: 0, replacement: "d")]
    )
    _ = try await first.apply(transaction)

    let restarted = try await fixture.openActor()
    let snapshot = await restarted.snapshot()
    #expect(snapshot.text == "abcd")
    #expect(snapshot.documentVersion == 1)
    #expect(snapshot.currentLease == nil)
    #expect(snapshot.dirtyState == .dirty)
    let replacementLease = try await restarted.acquireEditLease(client: ClientInstanceID())
    #expect(replacementLease.id != lease.id)
    #expect(try await restarted.apply(EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: replacementLease.id,
        baseVersion: 1,
        clientSequence: 2,
        changes: [try UTF16TextEdit(validatingOffset: 4, length: 0, replacement: "e")]
    )).clientSequence == 2)
}

@Test func documentActorOperationGatePreventsLeaseTransferDuringAwaitingMetadataCommit() async throws {
    let fixture = try DocumentActorFixture(text: "abc")
    defer { fixture.remove() }
    let actor = try await fixture.openActor()
    let lease = try await actor.acquireEditLease(client: fixture.clientID)
    await fixture.repository.blockNextCompareAndSet()
    let apply = Task {
        try await actor.apply(EditTransaction(
            validatingDocumentID: fixture.metadata.documentID,
            editLeaseID: lease.id,
            baseVersion: 0,
            clientSequence: 1,
            changes: [try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x")]
        ))
    }
    await fixture.repository.waitUntilCompareAndSetBlocks()
    let transfer = Task { try await actor.transferEditLease(from: lease.id, to: ClientInstanceID()) }
    for _ in 0..<20 { await Task.yield() }
    #expect(!transfer.isCancelled)
    #expect(await fixture.repository.compareAndSetCount == 2)
    await fixture.repository.releaseCompareAndSet()
    _ = try await apply.value
    _ = try await transfer.value
    #expect(await fixture.repository.compareAndSetCount == 3)
}

@Test func documentActorSaveExposesDeferredCompactionMaintenance() async throws {
    let counter = DocumentActorRenameCounter(failAt: 4)
    let fixture = try DocumentActorFixture(
        text: "abc",
        recoverySystemCalls: RecoveryLogSystemCalls(
            write: { Darwin.write($0, $1, $2) },
            fsync: { Darwin.fsync($0) },
            rename: { source, destination in
                if counter.nextShouldFail() { errno = EIO; return -1 }
                return Darwin.rename(source, destination)
            }
        )
    )
    defer { fixture.remove() }
    let actor = try await fixture.openActor()
    let lease = try await actor.acquireEditLease(client: fixture.clientID)
    _ = try await actor.apply(EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: lease.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 3, length: 0, replacement: "d")]
    ))
    let dirty = await actor.snapshot()
    let saved = try await actor.save(expectedFingerprint: try #require(dirty.observedDiskFingerprint))
    #expect(saved.dirtyState == .clean)
    #expect(saved.maintenance.contains(.compactionDeferred))
}

@Test func documentActorDiscardMetadataFailureCommitsCheckpointStateAndFailsClosed() async throws {
    let fixture = try DocumentActorFixture(text: "disk")
    defer { fixture.remove() }
    let actor = try await fixture.openActor()
    let lease = try await actor.acquireEditLease(client: fixture.clientID)
    _ = try await actor.apply(EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: lease.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 4, length: 0, replacement: " dirty")]
    ))
    try Data("replacement".utf8).write(to: fixture.documentURL)
    await fixture.repository.failNextCompareAndSet()

    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await actor.discard()
    }
    let committed = await actor.snapshot()
    #expect(committed.text == "replacement")
    #expect(committed.documentVersion == 2)
    #expect(committed.persistedVersion == 2)
    #expect(committed.dirtyState == .clean)
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await actor.apply(EditTransaction(
            validatingDocumentID: fixture.metadata.documentID,
            editLeaseID: lease.id,
            baseVersion: 1,
            clientSequence: 2,
            changes: [try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "lost")]
        ))
    }

    let restarted = try await fixture.openActor()
    let repaired = await restarted.snapshot()
    #expect(repaired.text == "replacement")
    #expect(repaired.documentVersion == 2)
    #expect(repaired.persistedVersion == 2)
    #expect(repaired.dirtyState == .clean)
}

@Test func documentActorDiscardPostRenameCheckpointFailureFailsClosed() async throws {
    let fsyncFailure = DocumentActorDirectoryFsyncFailure()
    let fixture = try DocumentActorFixture(
        text: "disk",
        recoverySystemCalls: RecoveryLogSystemCalls(
            write: { Darwin.write($0, $1, $2) },
            fsync: { fsyncFailure.call($0) },
            rename: { Darwin.rename($0, $1) }
        )
    )
    defer { fixture.remove() }
    let actor = try await fixture.openActor()
    let lease = try await actor.acquireEditLease(client: fixture.clientID)
    _ = try await actor.apply(EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: lease.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 4, length: 0, replacement: " dirty")]
    ))
    try Data("replacement".utf8).write(to: fixture.documentURL)
    fsyncFailure.failNextDirectorySync()

    await #expect(throws: (any Error).self) { _ = try await actor.discard() }
    #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await actor.apply(EditTransaction(
            validatingDocumentID: fixture.metadata.documentID,
            editLeaseID: lease.id,
            baseVersion: 1,
            clientSequence: 2,
            changes: [try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "lost")]
        ))
    }

    let restarted = try await fixture.openActor()
    let snapshot = await restarted.snapshot()
    #expect(snapshot.text == "replacement")
    #expect(snapshot.documentVersion == 2)
    #expect(snapshot.lastAcceptedClientSequence == 1)
}

@Test func documentActorRejectsRecordsWithoutValidCheckpoint() async throws {
    for corruptCheckpoint in [false, true] {
        let fixture = try DocumentActorFixture(text: "disk")
        defer { fixture.remove() }
        if corruptCheckpoint {
            try Data("corrupt-checkpoint".utf8).write(to: fixture.checkpointURL)
        }
        let transaction = try EditTransaction(
            validatingDocumentID: fixture.metadata.documentID,
            editLeaseID: EditLeaseID(),
            baseVersion: 0,
            clientSequence: 1,
            changes: [try UTF16TextEdit(validatingOffset: 4, length: 0, replacement: " accepted")]
        )
        try await fixture.recoveryLog.append(
            documentVersion: 1,
            clientSequence: 1,
            utf8EditPayload: DocumentEditing.encodeRecoveryPayload(transaction)
        )
        await #expect(throws: DocumentProtocolError.recoveryRequired) {
            _ = try await fixture.openActor()
        }
        if corruptCheckpoint {
            #expect(try Data(contentsOf: fixture.checkpointURL) == Data("corrupt-checkpoint".utf8))
        } else {
            #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        }
    }
}

@Test func documentActorRecoveredLastRetryPrecedesReplacementLeaseValidation() async throws {
    let fixture = try DocumentActorFixture(text: "abc")
    defer { fixture.remove() }
    let first = try await fixture.openActor()
    let historicalLease = try await first.acquireEditLease(client: fixture.clientID)
    let transaction = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: historicalLease.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 3, length: 0, replacement: "d")]
    )
    let acknowledgement = try await first.apply(transaction)

    let restarted = try await fixture.openActor()
    #expect(try await restarted.apply(transaction) == acknowledgement)
    _ = try await restarted.acquireEditLease(client: ClientInstanceID())
    #expect(try await restarted.apply(transaction) == acknowledgement)
    await #expect(throws: DocumentProtocolError.invalidLease) {
        _ = try await restarted.apply(EditTransaction(
            validatingDocumentID: fixture.metadata.documentID,
            editLeaseID: historicalLease.id,
            baseVersion: 1,
            clientSequence: 2,
            changes: [try UTF16TextEdit(validatingOffset: 4, length: 0, replacement: "e")]
        ))
    }
    #expect((try await fixture.recoveryLog.recover()).records.count == 1)
}

@Test func documentActorRecoveryStopsAtSemanticCorruptionAndKeepsPrefix() async throws {
    let fixture = try DocumentActorFixture(text: "abc")
    defer { fixture.remove() }
    _ = try await fixture.openActor()
    let leaseID = EditLeaseID()
    let first = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: leaseID,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 3, length: 0, replacement: "d")]
    )
    let corrupt = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: leaseID,
        baseVersion: 0,
        clientSequence: 2,
        changes: [try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "bad")]
    )
    let later = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: leaseID,
        baseVersion: 1,
        clientSequence: 3,
        changes: [try UTF16TextEdit(validatingOffset: 4, length: 0, replacement: "later")]
    )
    for (version, transaction) in [(UInt64(1), first), (2, corrupt), (3, later)] {
        try await fixture.recoveryLog.append(
            documentVersion: version,
            clientSequence: transaction.clientSequence,
            utf8EditPayload: DocumentEditing.encodeRecoveryPayload(transaction)
        )
    }

    let recovered = try await fixture.openActor()
    let snapshot = await recovered.snapshot()
    #expect(snapshot.text == "abcd")
    #expect(snapshot.documentVersion == 1)
    #expect(snapshot.lastAcceptedClientSequence == 1)
    #expect(snapshot.maintenance.contains(.corruptRecoveryRecord))
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await recovered.acquireEditLease(client: ClientInstanceID())
    }

    let restarted = try await fixture.openActor()
    let restartedSnapshot = await restarted.snapshot()
    #expect(restartedSnapshot.text == "abcd")
    #expect(restartedSnapshot.maintenance.contains(.corruptRecoveryRecord))
}

@Test func documentActorFirstSemanticCorruptRecordFailsClosed() async throws {
    let fixture = try DocumentActorFixture(text: "abc")
    defer { fixture.remove() }
    _ = try await fixture.openActor()
    let leaseID = EditLeaseID()
    let corrupt = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: leaseID,
        baseVersion: 1,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "bad")]
    )
    let later = try EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: leaseID,
        baseVersion: 1,
        clientSequence: 2,
        changes: [try UTF16TextEdit(validatingOffset: 3, length: 0, replacement: "later")]
    )
    for (version, transaction) in [(UInt64(1), corrupt), (2, later)] {
        try await fixture.recoveryLog.append(
            documentVersion: version,
            clientSequence: transaction.clientSequence,
            utf8EditPayload: DocumentEditing.encodeRecoveryPayload(transaction)
        )
    }

    let recovered = try await fixture.openActor()
    let snapshot = await recovered.snapshot()
    #expect(snapshot.text == "abc")
    #expect(snapshot.documentVersion == 0)
    #expect(snapshot.maintenance.contains(.corruptRecoveryRecord))
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await recovered.acquireEditLease(client: ClientInstanceID())
    }
}

@Test func documentActorDiscardMapsMissingFile() async throws {
    let fixture = try DocumentActorFixture(text: "abc")
    defer { fixture.remove() }
    let actor = try await fixture.openActor()
    try FileManager.default.removeItem(at: fixture.documentURL)
    await #expect(throws: DocumentProtocolError.fileMissing) {
        _ = try await actor.discard()
    }
}

@Test func documentActorSaveMetadataFailureRestartsInConflict() async throws {
    let fixture = try DocumentActorFixture(text: "abc")
    defer { fixture.remove() }
    let actor = try await fixture.openActor()
    let lease = try await actor.acquireEditLease(client: fixture.clientID)
    _ = try await actor.apply(EditTransaction(
        validatingDocumentID: fixture.metadata.documentID,
        editLeaseID: lease.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 3, length: 0, replacement: "d")]
    ))
    let dirty = await actor.snapshot()
    await fixture.repository.failNextCompareAndSet()

    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await actor.save(expectedFingerprint: try #require(dirty.observedDiskFingerprint))
    }
    let restarted = try await fixture.openActor()
    let snapshot = await restarted.snapshot()
    #expect(snapshot.text == "abcd")
    #expect(snapshot.documentVersion == 1)
    #expect(snapshot.persistedVersion == 1)
    #expect(snapshot.dirtyState == .conflict)
}

private final class DocumentActorFixture: @unchecked Sendable {
    let root: URL
    let recoveryRoot: URL
    let documentURL: URL
    let path = try! RelativePath("document.txt")
    let clientID = ClientInstanceID()
    let metadata: DocumentMetadata
    let repository: TestDocumentMetadataRepository
    let serving: WorkspaceRootHandle
    let recoveryLog: DocumentRecoveryLog
    var checkpointURL: URL {
        recoveryRoot.appendingPathComponent("\(metadata.documentID.description).checkpoint.ckdr")
    }

    init(text: String, recoverySystemCalls: RecoveryLogSystemCalls? = nil) throws {
        root = URL(fileURLWithPath: "/private/tmp/cockpit-document-actor.\(UUID().uuidString)", isDirectory: true)
        recoveryRoot = root.appendingPathComponent("recovery", isDirectory: true)
        documentURL = root.appendingPathComponent(path.string)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: false)
        try Data(text.utf8).write(to: documentURL)
        metadata = try DocumentMetadata(
            validatingDocumentID: DocumentID(),
            environmentID: EnvironmentID(),
            relativePath: path,
            documentVersion: 0,
            persistedVersion: 0,
            dirtyState: .clean,
            editLeaseID: nil
        )
        repository = TestDocumentMetadataRepository(metadata)
        serving = WorkspaceRootHandle(rootURL: root)
        if let recoverySystemCalls {
            recoveryLog = DocumentRecoveryLog(
                rootURL: recoveryRoot,
                documentID: metadata.documentID,
                systemCalls: recoverySystemCalls
            )
        } else {
            recoveryLog = DocumentRecoveryLog(rootURL: recoveryRoot, documentID: metadata.documentID)
        }
    }

    func openActor() async throws -> DocumentActor {
        try await DocumentActor.open(
            metadata: try #require(await repository.loadDocument(id: metadata.documentID)),
            documentServing: serving,
            recoveryLog: recoveryLog,
            metadataRepository: repository
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

actor TestDocumentMetadataRepository: DocumentMetadataRepository {
    private var metadataByID: [DocumentID: DocumentMetadata]
    private var failNext = false
    private var blockNext = false
    private var blockStarted: [CheckedContinuation<Void, Never>] = []
    private var releaseBlock: CheckedContinuation<Void, Never>?
    private(set) var compareAndSetCount = 0
    private(set) var findOrCreateCount = 0
    private var blockNextFind = false
    private var findBlockStarted: [CheckedContinuation<Void, Never>] = []
    private var releaseFindBlock: CheckedContinuation<Void, Never>?
    private var relocationError: NSError?
    private var blockRelocation = false
    private var relocationBlockStarted: [CheckedContinuation<Void, Never>] = []
    private var releaseRelocationBlock: CheckedContinuation<Void, Never>?

    init(_ metadata: DocumentMetadata) { metadataByID = [metadata.documentID: metadata] }

    func findOrCreateDocument(in environmentID: EnvironmentID, at path: RelativePath) async throws -> DocumentMetadata {
        findOrCreateCount += 1
        if blockNextFind {
            blockNextFind = false
            findBlockStarted.forEach { $0.resume() }
            findBlockStarted.removeAll()
            await withCheckedContinuation { releaseFindBlock = $0 }
        }
        if let existing = metadataByID.values.first(where: {
            $0.environmentID == environmentID && $0.relativePath == path
        }) { return existing }
        let created = try DocumentMetadata(
            validatingDocumentID: DocumentID(), environmentID: environmentID,
            relativePath: path, documentVersion: 0, persistedVersion: 0,
            dirtyState: .clean, editLeaseID: nil
        )
        metadataByID[created.documentID] = created
        return created
    }

    func loadDocument(id: DocumentID) -> DocumentMetadata? { metadataByID[id] }

    func compareAndSetDocumentMetadata(
        _ metadata: DocumentMetadata,
        expectedDocumentVersion: UInt64,
        expectedEditLeaseID: EditLeaseID?
    ) async throws {
        compareAndSetCount += 1
        if blockNext {
            blockNext = false
            blockStarted.forEach { $0.resume() }
            blockStarted.removeAll()
            await withCheckedContinuation { releaseBlock = $0 }
        }
        if failNext {
            failNext = false
            throw CocoaError(.fileWriteUnknown)
        }
        guard let current = metadataByID[metadata.documentID],
              current.documentVersion == expectedDocumentVersion,
              current.editLeaseID == expectedEditLeaseID
        else { throw DocumentMetadataRepositoryError.stale }
        metadataByID[metadata.documentID] = metadata
    }

    func repairDocumentMetadata(_ metadata: DocumentMetadata) {
        metadataByID[metadata.documentID] = metadata
    }

    func relocateDocumentLocators(
        in environmentID: EnvironmentID,
        from source: RelativePath,
        to destination: RelativePath
    ) async throws {
        if blockRelocation {
            blockRelocation = false
            relocationBlockStarted.forEach { $0.resume() }
            relocationBlockStarted.removeAll()
            await withCheckedContinuation { releaseRelocationBlock = $0 }
        }
        if let relocationError {
            self.relocationError = nil
            throw relocationError
        }
        for (id, value) in metadataByID where value.environmentID == environmentID {
            let replacement: String
            if value.relativePath == source {
                replacement = destination.string
            } else if value.relativePath.string.hasPrefix(source.string + "/") {
                replacement = destination.string + value.relativePath.string.dropFirst(source.string.count)
            } else { continue }
            metadataByID[id] = try DocumentMetadata(
                validatingDocumentID: id,
                environmentID: environmentID,
                relativePath: RelativePath(replacement),
                documentVersion: value.documentVersion,
                persistedVersion: value.persistedVersion,
                dirtyState: value.dirtyState,
                editLeaseID: value.editLeaseID
            )
        }
    }

    func failNextCompareAndSet() { failNext = true }
    func blockNextCompareAndSet() { blockNext = true }
    func waitUntilCompareAndSetBlocks() async {
        if releaseBlock != nil { return }
        await withCheckedContinuation { blockStarted.append($0) }
    }
    func releaseCompareAndSet() { releaseBlock?.resume(); releaseBlock = nil }
    func blockNextFindOrCreate() { blockNextFind = true }
    func waitUntilFindOrCreateBlocks() async {
        if releaseFindBlock != nil { return }
        await withCheckedContinuation { findBlockStarted.append($0) }
    }
    func releaseFindOrCreate() { releaseFindBlock?.resume(); releaseFindBlock = nil }
    func blockNextRelocation(error: NSError) {
        blockRelocation = true
        relocationError = error
    }
    func waitUntilRelocationBlocks() async {
        if releaseRelocationBlock != nil { return }
        await withCheckedContinuation { relocationBlockStarted.append($0) }
    }
    func releaseRelocation() { releaseRelocationBlock?.resume(); releaseRelocationBlock = nil }
    var documentCount: Int { metadataByID.count }
}

private final class DocumentActorRenameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failAt: Int
    init(failAt: Int) { self.failAt = failAt }
    func nextShouldFail() -> Bool { lock.withLock { count += 1; return count == failAt } }
}

private final class DocumentActorDirectoryFsyncFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    func failNextDirectorySync() {
        lock.withLock { armed = true }
    }

    func call(_ descriptor: Int32) -> Int32 {
        lock.withLock {
            var status = stat()
            if armed,
               fstat(descriptor, &status) == 0,
               status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                armed = false
                errno = EIO
                return -1
            }
            return Darwin.fsync(descriptor)
        }
    }
}

private final class DocumentActorAppendWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldWritePrefix = false
    private var shouldFail = false

    func failAfterNextPrefix() {
        lock.withLock {
            shouldWritePrefix = true
            shouldFail = false
        }
    }

    func call(_ descriptor: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
        lock.withLock {
            if shouldWritePrefix {
                shouldWritePrefix = false
                shouldFail = true
                return Darwin.write(descriptor, pointer, min(3, count))
            }
            if shouldFail {
                shouldFail = false
                errno = EIO
                return -1
            }
            return Darwin.write(descriptor, pointer, count)
        }
    }
}

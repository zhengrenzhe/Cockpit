import Foundation
import Testing
import CockpitHostCore
import CockpitProtocol
import CockpitTypes
@testable import CockpitWorkspace

@Test func documentRegistrySharesActorByLocatorAndPreservesIdentityAcrossRelocation() async throws {
    let fixture = try DocumentRegistryFixture()
    defer { fixture.remove() }
    try Data("content".utf8).write(to: fixture.root.appendingPathComponent("old.txt"))
    let first = try await fixture.registry.open(at: RelativePath("old.txt"))
    let second = try await fixture.registry.open(at: RelativePath("old.txt"))
    #expect(first === second)
    let documentID = (await first.snapshot()).documentID

    try FileManager.default.moveItem(
        at: fixture.root.appendingPathComponent("old.txt"),
        to: fixture.root.appendingPathComponent("new.txt")
    )
    try await fixture.repository.relocateDocumentLocators(
        in: fixture.environmentID,
        from: RelativePath("old.txt"),
        to: RelativePath("new.txt")
    )
    await fixture.registry.relocateOpenDocuments(
        from: try RelativePath("old.txt"),
        to: try RelativePath("new.txt")
    )
    let moved = try await fixture.registry.open(at: RelativePath("new.txt"))
    #expect(moved === first)
    #expect((await moved.snapshot()).documentID == documentID)
    let expectedPath = try RelativePath("new.txt")
    #expect((await moved.snapshot()).relativePath == expectedPath)
}

@Test func documentRegistryInternalMutationLeaseQueuesExternalReconciliation() async throws {
    let fixture = try DocumentRegistryFixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("document.txt")
    try Data("before".utf8).write(to: file)
    let actor = try await fixture.registry.open(at: RelativePath("document.txt"))
    let lease = try await fixture.registry.acquireInternalMutationLease()
    try Data("after".utf8).write(to: file)

    await fixture.registry.handleExternalChanges(in: [.root])
    #expect((await actor.snapshot()).text == "before")
    await fixture.registry.releaseInternalMutationLease(lease)
    #expect((await actor.snapshot()).text == "after")
}

@Test func documentRegistryConcurrentOpenIsSingleFlight() async throws {
    let fixture = try DocumentRegistryFixture()
    defer { fixture.remove() }
    let path = try RelativePath("document.txt")
    try Data("content".utf8).write(to: fixture.root.appendingPathComponent(path.string))
    await fixture.repository.blockNextFindOrCreate()

    let first = Task { try await fixture.registry.open(at: path) }
    await fixture.repository.waitUntilFindOrCreateBlocks()
    let second = Task { try await fixture.registry.open(at: path) }
    for _ in 0..<20 { await Task.yield() }
    await fixture.repository.releaseFindOrCreate()

    let firstActor = try await first.value
    let secondActor = try await second.value
    #expect(firstActor === secondActor)
    #expect(await fixture.repository.findOrCreateCount == 1)
    _ = try await firstActor.acquireEditLease(client: ClientInstanceID())
    await #expect(throws: DocumentProtocolError.leaseHeld) {
        _ = try await secondActor.acquireEditLease(client: ClientInstanceID())
    }
}

@Test func documentRegistryCancelledOpenDoesNotPublishActor() async throws {
    let fixture = try DocumentRegistryFixture(blockActorOpen: true)
    defer { fixture.remove() }
    let path = try RelativePath("document.txt")
    try Data("content".utf8).write(to: fixture.root.appendingPathComponent(path.string))
    let serving = try #require(fixture.blockingServing)

    let cancelled = Task { try await fixture.registry.open(at: path) }
    await serving.waitUntilReadBlocks()
    cancelled.cancel()
    await serving.releaseRead()
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    #expect(await fixture.repository.findOrCreateCount == 1)
}

@Test func documentRegistryCancellationAwareFlightRetainsOneOwner() async throws {
    let fixture = try DocumentRegistryFixture(blockActorOpen: true)
    defer { fixture.remove() }
    let path = try RelativePath("document.txt")
    try Data("content".utf8).write(to: fixture.root.appendingPathComponent(path.string))
    let serving = try #require(fixture.blockingServing)

    let first = Task { try await fixture.registry.open(at: path) }
    await serving.waitUntilReadBlocks()
    let cancelled = Task { try await fixture.registry.open(at: path) }
    let third = Task { try await fixture.registry.open(at: path) }
    for _ in 0..<50 { await Task.yield() }
    cancelled.cancel()
    #expect(await fixture.repository.findOrCreateCount == 1)
    await serving.releaseRead()

    let firstActor = try await first.value
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    #expect(try await third.value === firstActor)
    #expect(await fixture.repository.findOrCreateCount == 1)
    #expect(await serving.readCount == 1)
}

@Test func documentRegistryActorFlightCancellationTracksLiveOwners() async throws {
    do {
        let fixture = try DocumentRegistryFixture(blockActorOpen: true)
        defer { fixture.remove() }
        let path = try RelativePath("document.txt")
        try Data("content".utf8).write(to: fixture.root.appendingPathComponent(path.string))
        let serving = try #require(fixture.blockingServing)

        let cancelled = Task { try await fixture.registry.open(at: path) }
        await serving.waitUntilReadBlocks()
        let live = Task { try await fixture.registry.open(at: path) }
        for _ in 0..<50 { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        for _ in 0..<50 { await Task.yield() }
        #expect(await serving.cancelledReadCount == 0)
        #expect(await serving.readCount == 1)

        await serving.releaseRead()
        _ = try await live.value
    }

    do {
        let fixture = try DocumentRegistryFixture(blockActorOpen: true)
        defer { fixture.remove() }
        let path = try RelativePath("document.txt")
        try Data("content".utf8).write(to: fixture.root.appendingPathComponent(path.string))
        let serving = try #require(fixture.blockingServing)

        let cancelled = Task { try await fixture.registry.open(at: path) }
        await serving.waitUntilReadBlocks()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        for _ in 0..<50 { await Task.yield() }
        #expect(await serving.cancelledReadCount == 1)

        for _ in 0..<3 {
            let lifetime = DocumentRegistryCompletionFlag()
            var token: DocumentRegistryTaskLifetimeToken? = DocumentRegistryTaskLifetimeToken(
                completion: lifetime
            )
            var cancelledReplacement: Task<DocumentActor, Error>? = documentRegistryProbedOpen(
                fixture.registry,
                at: path,
                token: try #require(token)
            )
            token = nil

            #expect(await waitForDocumentRegistryStoredCount(
                fixture.registry,
                label: "retirementWaiters",
                count: 1
            ))
            cancelledReplacement?.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await cancelledReplacement?.value
            }
            cancelledReplacement = nil

            #expect(await waitForDocumentRegistryCompletion(lifetime))
            #expect(await waitForDocumentRegistryStoredCount(
                fixture.registry,
                label: "retirementWaiters",
                count: 0
            ))
            #expect(await waitForDocumentRegistryStoredCount(
                fixture.registry,
                label: "locatorFlights",
                count: 0
            ))
            #expect(await waitForDocumentRegistryStoredCount(
                fixture.registry,
                label: "openRequestStates",
                count: 0
            ))
            #expect(documentRegistryStoredCount(fixture.registry, label: "actorFlights") == 1)
            #expect(documentRegistryStoredCount(fixture.registry, label: "activeActorOpenWork") == 1)
            #expect(await serving.readCount == 1)
        }

        let firstReplacement = Task { try await fixture.registry.open(at: path) }
        #expect(await waitForDocumentRegistryStoredCount(
            fixture.registry,
            label: "retirementWaiters",
            count: 1
        ))
        let secondReplacement = Task { try await fixture.registry.open(at: path) }
        #expect(await waitForDocumentRegistryStoredCount(
            fixture.registry,
            label: "openRequestStates",
            count: 2
        ))
        #expect(documentRegistryStoredCount(fixture.registry, label: "retirementWaiters") == 1)
        #expect(documentRegistryStoredCount(fixture.registry, label: "locatorFlights") == 1)
        #expect(documentRegistryStoredCount(fixture.registry, label: "actorFlights") == 1)
        #expect(documentRegistryStoredCount(fixture.registry, label: "activeActorOpenWork") == 1)
        #expect(await serving.readCount == 1)

        await serving.releaseRead()
        let actor = try await firstReplacement.value
        #expect(try await secondReplacement.value === actor)
        #expect(await serving.readCount == 2)

        let clientID = ClientInstanceID()
        let lease = try await actor.acquireEditLease(client: clientID)
        let beforeEdit = await actor.snapshot()
        let acknowledgement = try await actor.apply(EditTransaction(
            validatingDocumentID: beforeEdit.documentID,
            editLeaseID: lease.id,
            baseVersion: beforeEdit.documentVersion,
            clientSequence: beforeEdit.lastAcceptedClientSequence + 1,
            changes: [try UTF16TextEdit(
                validatingOffset: UInt64(beforeEdit.text.utf16.count),
                length: 0,
                replacement: "!"
            )]
        ))
        #expect(acknowledgement.documentVersion == 1)

        let restartedRegistry = DocumentRegistry(
            environmentID: fixture.environmentID,
            documentServing: WorkspaceRootHandle(rootURL: fixture.root),
            metadataRepository: fixture.repository,
            recoveryRoot: fixture.recoveryRoot
        )
        let restarted = try await restartedRegistry.open(at: path)
        let recovered = await restarted.snapshot()
        #expect(recovered.text == "content!")
        #expect(recovered.documentVersion == acknowledgement.documentVersion)
    }
}

@Test func documentRegistryPrecancelledOpenNeverStartsFlight() async throws {
    let fixture = try DocumentRegistryFixture()
    defer { fixture.remove() }
    let path = try RelativePath("document.txt")
    try Data("content".utf8).write(to: fixture.root.appendingPathComponent(path.string))
    let gate = DocumentRegistryStartGate()
    let cancelled = Task {
        await gate.wait()
        return try await fixture.registry.open(at: path)
    }
    await gate.waitUntilBlocked()
    cancelled.cancel()
    await gate.release()

    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    #expect(await fixture.repository.findOrCreateCount == 0)
}

@Test func documentRegistryMutationScopeDefersDestinationOpenUntilRelocation() async throws {
    let fixture = try DocumentRegistryFixture()
    defer { fixture.remove() }
    let source = try RelativePath("old.txt")
    let destination = try RelativePath("new.txt")
    try Data("content".utf8).write(to: fixture.root.appendingPathComponent(source.string))
    let original = try await fixture.registry.open(at: source)
    let originalID = (await original.snapshot()).documentID
    let findCountBeforeMutation = await fixture.repository.findOrCreateCount
    let lease = try await fixture.registry.acquireInternalMutationLease(
        from: source,
        to: destination
    )
    try FileManager.default.moveItem(
        at: fixture.root.appendingPathComponent(source.string),
        to: fixture.root.appendingPathComponent(destination.string)
    )

    let destinationOpen = Task { try await fixture.registry.open(at: destination) }
    for _ in 0..<50 { await Task.yield() }
    #expect(await fixture.repository.findOrCreateCount == findCountBeforeMutation)
    try await fixture.repository.relocateDocumentLocators(
        in: fixture.environmentID,
        from: source,
        to: destination
    )
    await fixture.registry.relocateOpenDocuments(from: source, to: destination)
    await fixture.registry.releaseInternalMutationLease(lease)

    let moved = try await destinationOpen.value
    #expect(moved === original)
    #expect((await moved.snapshot()).documentID == originalID)
    #expect(await fixture.repository.documentCount == 2)
}

@Test func documentRegistryMutationLeaseDrainsAlreadyStartedIntersectingOpen() async throws {
    let fixture = try DocumentRegistryFixture(blockActorOpen: true)
    defer { fixture.remove() }
    let source = try RelativePath("old.txt")
    let destination = try RelativePath("new.txt")
    try Data("destination".utf8).write(to: fixture.root.appendingPathComponent(destination.string))
    let serving = try #require(fixture.blockingServing)
    let startedOpen = Task { try await fixture.registry.open(at: destination) }
    await serving.waitUntilReadBlocks()
    let acquired = DocumentRegistryCompletionFlag()
    let lease = Task {
        let value = try await fixture.registry.acquireInternalMutationLease(
            from: source,
            to: destination
        )
        await acquired.markCompleted()
        return value
    }
    for _ in 0..<50 { await Task.yield() }
    #expect(await acquired.isCompleted == false)

    await serving.releaseRead()
    _ = try await startedOpen.value
    let heldLease = try await lease.value
    #expect(await acquired.isCompleted)
    await fixture.registry.releaseInternalMutationLease(heldLease)
}

@Test func documentRegistryCommittedMutationFailureRejectsIntersectingWaiters() async throws {
    let fixture = try DocumentRegistryFixture()
    defer { fixture.remove() }
    let source = try RelativePath("old.txt")
    let destination = try RelativePath("new.txt")
    let lease = try await fixture.registry.acquireInternalMutationLease(
        from: source,
        to: destination
    )
    let waiting = Task { try await fixture.registry.open(at: destination) }
    for _ in 0..<50 { await Task.yield() }

    await fixture.registry.failInternalMutationLease(lease)
    await #expect(throws: DocumentProtocolError.recoveryRequired) { _ = try await waiting.value }
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await fixture.registry.open(at: destination)
    }
    #expect(await fixture.repository.findOrCreateCount == 0)
}

@Test func documentRegistryMutationBarrierOwnsCancellationWorkAndPublication() async throws {
    do {
        let fixture = try DocumentRegistryFixture(blockActorOpen: true)
        defer { fixture.remove() }
        let source = try RelativePath("old.txt")
        let destination = try RelativePath("new.txt")
        try Data("destination".utf8).write(to: fixture.root.appendingPathComponent(destination.string))
        let serving = try #require(fixture.blockingServing)
        let blockedOpen = Task { try await fixture.registry.open(at: destination) }
        await serving.waitUntilReadBlocks()

        let acquisitionCompleted = DocumentRegistryCompletionFlag()
        let acquisition = Task {
            do {
                let lease = try await fixture.registry.acquireInternalMutationLease(
                    from: source,
                    to: destination
                )
                await acquisitionCompleted.markCompleted()
                return lease
            } catch {
                await acquisitionCompleted.markCompleted()
                throw error
            }
        }
        for _ in 0..<50 { await Task.yield() }
        acquisition.cancel()
        for _ in 0..<50 { await Task.yield() }
        #expect(await acquisitionCompleted.isCompleted)

        await serving.releaseRead()
        _ = try await blockedOpen.value
        var leakedLease: DocumentInternalMutationLease?
        do {
            leakedLease = try await acquisition.value
            Issue.record("Expected mutation acquisition cancellation")
        } catch {
            #expect(error is CancellationError)
        }

        let reopened = Task { try await fixture.registry.open(at: destination) }
        let reopenedCompleted = DocumentRegistryCompletionFlag()
        let observedReopen = Task {
            do {
                _ = try await reopened.value
                await reopenedCompleted.markCompleted()
            } catch {
                await reopenedCompleted.markCompleted()
                throw error
            }
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(await reopenedCompleted.isCompleted)
        if !(await reopenedCompleted.isCompleted) { reopened.cancel() }
        _ = try? await observedReopen.value
        if let leakedLease { await fixture.registry.releaseInternalMutationLease(leakedLease) }
    }

    do {
        let fixture = try DocumentRegistryFixture(blockActorOpen: true)
        defer { fixture.remove() }
        let path = try RelativePath("document.txt")
        let destination = try RelativePath("renamed.txt")
        try Data("content".utf8).write(to: fixture.root.appendingPathComponent(path.string))
        let serving = try #require(fixture.blockingServing)
        let cancelled = Task { try await fixture.registry.open(at: path) }
        await serving.waitUntilReadBlocks()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }

        let acquired = DocumentRegistryCompletionFlag()
        let writer = Task {
            let lease = try await fixture.registry.acquireInternalMutationLease(
                from: path,
                to: destination
            )
            await acquired.markCompleted()
            return lease
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(await acquired.isCompleted == false)

        await serving.releaseRead()
        let lease = try await writer.value
        await fixture.registry.releaseInternalMutationLease(lease)
    }

    do {
        let fixture = try DocumentRegistryFixture(blockActorOpen: true)
        defer { fixture.remove() }
        let path = try RelativePath("document.txt")
        try Data("content".utf8).write(to: fixture.root.appendingPathComponent(path.string))
        let serving = try #require(fixture.blockingServing)
        let opening = Task { try await fixture.registry.open(at: path) }
        await serving.waitUntilReadBlocks()
        let failureLease = try await fixture.registry.acquireInternalMutationLease(
            from: RelativePath("unrelated-old.txt"),
            to: RelativePath("unrelated-new.txt")
        )
        await fixture.registry.failInternalMutationLease(failureLease)
        await serving.releaseRead()

        await #expect(throws: DocumentProtocolError.recoveryRequired) {
            _ = try await opening.value
        }
    }
}

final class DocumentRegistryFixture: @unchecked Sendable {
    let root: URL
    let recoveryRoot: URL
    let environmentID = EnvironmentID()
    let repository: TestDocumentMetadataRepository
    let registry: DocumentRegistry
    fileprivate let blockingServing: BlockingDocumentServing?

    init(blockActorOpen: Bool = false) throws {
        root = URL(fileURLWithPath: "/private/tmp/cockpit-document-registry.\(UUID().uuidString)", isDirectory: true)
        recoveryRoot = root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: false)
        let seed = try DocumentMetadata(
            validatingDocumentID: DocumentID(), environmentID: environmentID,
            relativePath: RelativePath("seed.txt"), documentVersion: 0,
            persistedVersion: 0, dirtyState: .clean, editLeaseID: nil
        )
        repository = TestDocumentMetadataRepository(seed)
        let rootServing = WorkspaceRootHandle(rootURL: root)
        if blockActorOpen {
            let serving = BlockingDocumentServing(base: rootServing)
            blockingServing = serving
            registry = DocumentRegistry(
                environmentID: environmentID,
                documentServing: serving,
                metadataRepository: repository,
                recoveryRoot: recoveryRoot
            )
            return
        }
        blockingServing = nil
        registry = DocumentRegistry(
            environmentID: environmentID,
            documentServing: rootServing,
            metadataRepository: repository,
            recoveryRoot: recoveryRoot
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

fileprivate actor BlockingDocumentServing: DocumentServing {
    private let base: WorkspaceRootHandle
    private var shouldBlockNextRead = true
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var readRelease: CheckedContinuation<Void, Never>?
    private let cancellationProbe = DocumentRegistryCancellationProbe()
    private(set) var readCount = 0
    var cancelledReadCount: Int { cancellationProbe.count }

    init(base: WorkspaceRootHandle) { self.base = base }

    func readDocument(at path: RelativePath) async throws -> DocumentFileSnapshot {
        readCount += 1
        if shouldBlockNextRead {
            shouldBlockNextRead = false
            readWaiters.forEach { $0.resume() }
            readWaiters.removeAll()
            let cancellationProbe = cancellationProbe
            await withTaskCancellationHandler {
                await withCheckedContinuation { readRelease = $0 }
            } onCancel: {
                cancellationProbe.record()
            }
        }
        return try await base.readDocument(at: path)
    }

    func atomicallyWriteDocument(
        _ data: Data,
        to path: RelativePath,
        expectedFingerprint: DiskFingerprint
    ) async throws -> DiskFingerprint {
        try await base.atomicallyWriteDocument(data, to: path, expectedFingerprint: expectedFingerprint)
    }

    func blockNextRead() { shouldBlockNextRead = true }
    func waitUntilReadBlocks() async {
        if readRelease != nil { return }
        await withCheckedContinuation { readWaiters.append($0) }
    }
    func releaseRead() { readRelease?.resume(); readRelease = nil }
}

private actor DocumentRegistryStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters.removeAll()
        }
    }
    func waitUntilBlocked() async {
        if continuation != nil { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor DocumentRegistryCompletionFlag {
    private(set) var isCompleted = false
    func markCompleted() { isCompleted = true }
}

private enum DocumentRegistryTaskLifetime {
    @TaskLocal static var token: DocumentRegistryTaskLifetimeToken?
}

private final class DocumentRegistryTaskLifetimeToken: @unchecked Sendable {
    private let completion: DocumentRegistryCompletionFlag

    init(completion: DocumentRegistryCompletionFlag) {
        self.completion = completion
    }

    deinit {
        let completion = completion
        Task { await completion.markCompleted() }
    }
}

private func documentRegistryProbedOpen(
    _ registry: DocumentRegistry,
    at path: RelativePath,
    token: DocumentRegistryTaskLifetimeToken
) -> Task<DocumentActor, Error> {
    Task {
        try await DocumentRegistryTaskLifetime.$token.withValue(token) {
            try await registry.open(at: path)
        }
    }
}

private func waitForDocumentRegistryCompletion(
    _ completion: DocumentRegistryCompletionFlag
) async -> Bool {
    for _ in 0..<100 {
        if await completion.isCompleted { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await completion.isCompleted
}

private func waitForDocumentRegistryStoredCount(
    _ registry: DocumentRegistry,
    label: String,
    count: Int
) async -> Bool {
    for _ in 0..<100 {
        await registry.handleExternalChanges(in: [])
        if documentRegistryStoredCount(registry, label: label) == count { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return documentRegistryStoredCount(registry, label: label) == count
}

private func documentRegistryStoredCount(
    _ registry: DocumentRegistry,
    label: String
) -> Int? {
    guard let value = Mirror(reflecting: registry).children.first(where: { $0.label == label })?.value
    else { return nil }
    return Mirror(reflecting: value).children.count
}

private final class DocumentRegistryCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var count: Int { lock.withLock { storage } }
    func record() { lock.withLock { storage += 1 } }
}

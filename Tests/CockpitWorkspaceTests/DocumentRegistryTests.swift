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
    let lease = await fixture.registry.acquireInternalMutationLease()
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
    let lease = await fixture.registry.acquireInternalMutationLease(
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
        let value = await fixture.registry.acquireInternalMutationLease(from: source, to: destination)
        await acquired.markCompleted()
        return value
    }
    for _ in 0..<50 { await Task.yield() }
    #expect(await acquired.isCompleted == false)

    await serving.releaseRead()
    _ = try await startedOpen.value
    let heldLease = await lease.value
    #expect(await acquired.isCompleted)
    await fixture.registry.releaseInternalMutationLease(heldLease)
}

@Test func documentRegistryCommittedMutationFailureRejectsIntersectingWaiters() async throws {
    let fixture = try DocumentRegistryFixture()
    defer { fixture.remove() }
    let source = try RelativePath("old.txt")
    let destination = try RelativePath("new.txt")
    let lease = await fixture.registry.acquireInternalMutationLease(from: source, to: destination)
    let waiting = Task { try await fixture.registry.open(at: destination) }
    for _ in 0..<50 { await Task.yield() }

    await fixture.registry.failInternalMutationLease(lease)
    await #expect(throws: DocumentProtocolError.recoveryRequired) { _ = try await waiting.value }
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await fixture.registry.open(at: destination)
    }
    #expect(await fixture.repository.findOrCreateCount == 0)
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
    private(set) var readCount = 0

    init(base: WorkspaceRootHandle) { self.base = base }

    func readDocument(at path: RelativePath) async throws -> DocumentFileSnapshot {
        readCount += 1
        if shouldBlockNextRead {
            shouldBlockNextRead = false
            readWaiters.forEach { $0.resume() }
            readWaiters.removeAll()
            await withCheckedContinuation { readRelease = $0 }
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

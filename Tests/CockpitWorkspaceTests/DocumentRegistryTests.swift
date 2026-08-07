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

final class DocumentRegistryFixture: @unchecked Sendable {
    let root: URL
    let recoveryRoot: URL
    let environmentID = EnvironmentID()
    let repository: TestDocumentMetadataRepository
    let registry: DocumentRegistry

    init() throws {
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
        registry = DocumentRegistry(
            environmentID: environmentID,
            documentServing: WorkspaceRootHandle(rootURL: root),
            metadataRepository: repository,
            recoveryRoot: recoveryRoot
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

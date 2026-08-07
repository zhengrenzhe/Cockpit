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

final class DocumentRegistryFixture {
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

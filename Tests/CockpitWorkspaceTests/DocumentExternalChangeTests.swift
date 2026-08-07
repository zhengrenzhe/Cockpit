import Foundation
import Testing
import CockpitProtocol
import CockpitTypes
@testable import CockpitWorkspace

@Test func documentExternalChangeReloadsCleanConflictsDirtyAndPreservesMissingText() async throws {
    let fixture = try DocumentRegistryFixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("document.txt")
    try Data("clean".utf8).write(to: file)
    let actor = try await fixture.registry.open(at: RelativePath("document.txt"))

    try Data("reloaded".utf8).write(to: file)
    await fixture.registry.handleExternalChanges(in: [.root])
    var snapshot = await actor.snapshot()
    #expect(snapshot.text == "reloaded")
    #expect(snapshot.documentVersion == 1)
    #expect(snapshot.dirtyState == .clean)

    let lease = try await actor.acquireEditLease(client: ClientInstanceID())
    _ = try await actor.apply(EditTransaction(
        validatingDocumentID: snapshot.documentID,
        editLeaseID: lease.id,
        baseVersion: snapshot.documentVersion,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 8, length: 0, replacement: " host")]
    ))
    try Data("outside".utf8).write(to: file)
    await fixture.registry.handleExternalChanges(in: [.root])
    snapshot = await actor.snapshot()
    #expect(snapshot.text == "reloaded host")
    #expect(snapshot.dirtyState == .conflict)

    try FileManager.default.removeItem(at: file)
    await fixture.registry.handleExternalChanges(in: [.root])
    snapshot = await actor.snapshot()
    #expect(snapshot.text == "reloaded host")
    #expect(snapshot.dirtyState == .missing)
    #expect(snapshot.observedDiskFingerprint == nil)

    try Data("returned".utf8).write(to: file)
    await fixture.registry.handleExternalChanges(in: [.root])
    snapshot = await actor.snapshot()
    #expect(snapshot.text == "reloaded host")
    #expect(snapshot.dirtyState == .conflict)
}

@Test func documentExternalChangeReconcilerNotifiesUnexpandedContentOnlyAndAllExpanded() async throws {
    let fixture = try DocumentRegistryFixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("document.txt")
    try Data("one".utf8).write(to: file)
    let actor = try await fixture.registry.open(at: RelativePath("document.txt"))
    let stream = AsyncThrowingStream<FileSystemInvalidation, Error>.makeStream()
    let provider = FileTreeProvider(environmentID: fixture.environmentID, rootURL: fixture.root)
    let reconciler = FileTreeReconciler(
        provider: provider,
        invalidations: stream.stream,
        documentRegistry: fixture.registry
    )
    defer { reconciler.cancel() }

    try Data("two".utf8).write(to: file)
    stream.continuation.yield(.targeted([.root]))
    await waitForDocumentText("two", actor: actor)

    try Data("three".utf8).write(to: file)
    stream.continuation.yield(.allExpanded)
    await waitForDocumentText("three", actor: actor)
}

private func waitForDocumentText(_ expected: String, actor: DocumentActor) async {
    for _ in 0..<2_000 {
        if (await actor.snapshot()).text == expected { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for document text \(expected)")
}

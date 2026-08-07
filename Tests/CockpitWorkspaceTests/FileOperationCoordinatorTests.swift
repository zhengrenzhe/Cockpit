import Foundation
import Testing
import CockpitHostCore
import CockpitTypes
@testable import CockpitWorkspace

@Test func oneEnvironmentSerializesCompleteOperationsWithoutOverlap() async throws {
    let environmentID = EnvironmentID()
    let physical = ControlledPhysicalOperations()
    let provider = coordinatorProvider(environmentID: environmentID)
    let coordinator = FileOperationCoordinator(
        environmentID: environmentID,
        rootHandle: physical,
        documentLocatorUpdater: RecordingDocumentLocatorUpdater(),
        fileTreeProvider: provider
    )

    let first = Task { try await coordinator.perform(.createFile(parent: .root, name: "first")) }
    #expect(await physical.nextStarted() == 1)
    let second = Task { try await coordinator.perform(.createFile(parent: .root, name: "second")) }
    await coordinator.waitUntilOperationIsQueued()
    #expect(await physical.startedCount == 1)
    #expect(await physical.maximumOverlap == 1)

    await physical.releaseNext()
    #expect(try await first.value == .created(path: RelativePath("first"), kind: .file))
    #expect(await physical.nextStarted() == 2)
    await physical.releaseNext()
    #expect(try await second.value == .created(path: RelativePath("second"), kind: .file))
    #expect(await physical.maximumOverlap == 1)
}

@Test func registryKeepsOneCoordinatorPerEnvironmentAndDistinctCoordinatorsAcrossEnvironments() async throws {
    let firstRoot = try CoordinatorTemporaryDirectory()
    let secondRoot = try CoordinatorTemporaryDirectory()
    defer { firstRoot.remove(); secondRoot.remove() }
    let updater = RecordingDocumentLocatorUpdater()
    let registry = WorkspaceKernelRegistry(documentLocatorUpdater: updater)
    let firstID = EnvironmentID()
    let secondID = EnvironmentID()
    let firstResolved = coordinatorResolvedRoot(firstRoot.url)
    let secondResolved = coordinatorResolvedRoot(secondRoot.url)

    await registry.register(environmentID: firstID, root: firstResolved)
    let original = try #require(await registry.coordinator(for: firstID))
    await registry.register(environmentID: firstID, root: firstResolved)
    let duplicate = try #require(await registry.coordinator(for: firstID))
    await registry.register(environmentID: secondID, root: secondResolved)
    let distinct = try #require(await registry.coordinator(for: secondID))

    #expect(original === duplicate)
    #expect(original !== distinct)
    await #expect(throws: FileOperationError.environmentNotRegistered) {
        _ = try await registry.perform(.createFile(parent: .root, name: "missing"), in: EnvironmentID())
    }
}

@Test func physicalFailureLeavesMetadataTabsTreeCacheAndRevisionUntouched() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = MutableCoordinatorFileSystem(entries: [.root: [try coordinatorEntry("old.txt", .file)]])
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording"),
        fileSystem: fileSystem
    )
    let baseline = try await provider.children(environmentID: environmentID, at: .root, generation: 1)
    let updater = RecordingDocumentLocatorUpdater()
    let physical = FailingPhysicalOperations(error: NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(EACCES),
        userInfo: [NSFilePathErrorKey: "/recording/old.txt"]
    ))
    let coordinator = FileOperationCoordinator(
        environmentID: environmentID,
        rootHandle: physical,
        documentLocatorUpdater: updater,
        fileTreeProvider: provider
    )

    await #expect(throws: (any Error).self) {
        _ = try await coordinator.perform(.rename(source: RelativePath("old.txt"), newName: "new.txt"))
    }

    let after = try await provider.children(environmentID: environmentID, at: .root, generation: 2)
    #expect(baseline.revision == 0)
    #expect(after.revision == 0)
    #expect(after.children == baseline.children)
    #expect(await updater.relocations.isEmpty)
    #expect(await provider.expandedDirectories(affectedBy: .allExpanded) == [.root])
}

@Test func externalMutationLeaseBlocksReconciliationUntilMetadataCommit() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = MutableCoordinatorFileSystem(entries: [.root: [try coordinatorEntry("old.txt", .file)]])
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording"),
        fileSystem: fileSystem
    )
    _ = try await provider.children(environmentID: environmentID, at: .root, generation: 1)
    let changeStream = provider.changes(environmentID: environmentID, after: 0)
    let change = Task {
        var iterator = changeStream.makeAsyncIterator()
        return try await iterator.next()
    }
    await waitForCoordinatorSubscriberCount(1, provider: provider)
    let updater = MetadataBarrierUpdater()
    let physical = MutatingPhysicalOperations(fileSystem: fileSystem)
    let coordinator = FileOperationCoordinator(
        environmentID: environmentID,
        rootHandle: physical,
        documentLocatorUpdater: updater,
        fileTreeProvider: provider
    )

    let operation = Task {
        try await coordinator.perform(.rename(source: RelativePath("old.txt"), newName: "new.txt"))
    }
    await updater.waitUntilStarted()
    let duplicateReconciliation = Task { try await provider.reconcile(.root) }
    await provider.waitUntilOperationIsQueued()
    #expect(await updater.hasCompleted == false)

    await updater.release()
    #expect(
        try await operation.value
            == .relocated(from: RelativePath("old.txt"), to: RelativePath("new.txt"))
    )
    let delta = try #require(try await change.value)
    #expect(delta.revision == 1)
    #expect(delta.directory == .root)
    #expect(try await duplicateReconciliation.value == nil)
    #expect(await updater.hasCompleted)
}

@Test func successfulOperationsPublishDeterministicParentDeltasAndDiscardMovedAndTrashedSubtreeCache() async throws {
    let fixture = try CoordinatorTemporaryDirectory()
    defer { fixture.remove() }
    let manager = FileManager.default
    try manager.createDirectory(at: fixture.url.appendingPathComponent("a-source/sub/deep"), withIntermediateDirectories: true)
    try manager.createDirectory(at: fixture.url.appendingPathComponent("z-destination"), withIntermediateDirectories: false)
    try Data("move".utf8).write(to: fixture.url.appendingPathComponent("a-source/file.txt"))
    try Data("nested".utf8).write(to: fixture.url.appendingPathComponent("a-source/sub/deep/nested.txt"))
    let environmentID = EnvironmentID()
    let provider = FileTreeProvider(environmentID: environmentID, rootURL: fixture.url)
    _ = try await provider.children(environmentID: environmentID, at: .relative(RelativePath("a-source")), generation: 1)
    _ = try await provider.children(environmentID: environmentID, at: .relative(RelativePath("z-destination")), generation: 1)
    _ = try await provider.children(environmentID: environmentID, at: .relative(RelativePath("a-source/sub")), generation: 1)
    _ = try await provider.children(environmentID: environmentID, at: .relative(RelativePath("a-source/sub/deep")), generation: 1)
    let updater = RecordingDocumentLocatorUpdater()
    let coordinator = FileOperationCoordinator(
        environmentID: environmentID,
        rootHandle: WorkspaceRootHandle(rootURL: fixture.url),
        documentLocatorUpdater: updater,
        fileTreeProvider: provider
    )

    let changeStream = provider.changes(environmentID: environmentID, after: 0)
    let changes = Task {
        var iterator = changeStream.makeAsyncIterator()
        var deltas: [FileTreeDelta] = []
        for _ in 0..<4 {
            deltas.append(try #require(try await iterator.next()))
        }
        return deltas
    }
    await waitForCoordinatorSubscriberCount(1, provider: provider)
    #expect(
        try await coordinator.perform(
            .move(source: RelativePath("a-source/file.txt"), destinationDirectory: .relative(RelativePath("z-destination")))
        ) == .relocated(from: RelativePath("a-source/file.txt"), to: RelativePath("z-destination/file.txt"))
    )
    #expect(try await provider.reconcile(.relative(RelativePath("a-source"))) == nil)
    #expect(try await provider.reconcile(.relative(RelativePath("z-destination"))) == nil)

    #expect(
        try await coordinator.perform(.rename(source: RelativePath("a-source/sub"), newName: "renamed"))
            == .relocated(from: RelativePath("a-source/sub"), to: RelativePath("a-source/renamed"))
    )
    #expect(await provider.expandedDirectories(affectedBy: .targeted([
        .relative(try RelativePath("a-source/sub")),
        .relative(try RelativePath("a-source/sub/deep")),
    ])).isEmpty)

    _ = try await provider.children(environmentID: environmentID, at: .relative(RelativePath("a-source/renamed")), generation: 2)
    _ = try await provider.children(environmentID: environmentID, at: .relative(RelativePath("a-source/renamed/deep")), generation: 2)
    let trashPhysical = RemovingPhysicalOperations(rootURL: fixture.url)
    let trashCoordinator = FileOperationCoordinator(
        environmentID: environmentID,
        rootHandle: trashPhysical,
        documentLocatorUpdater: updater,
        fileTreeProvider: provider
    )
    #expect(
        try await trashCoordinator.perform(.trash(path: RelativePath("a-source/renamed")))
            == .trashed(path: RelativePath("a-source/renamed"))
    )
    let deltas = try await changes.value
    #expect(deltas.map(\.directory) == [
        .relative(try RelativePath("a-source")),
        .relative(try RelativePath("z-destination")),
        .relative(try RelativePath("a-source")),
        .relative(try RelativePath("a-source")),
    ])
    #expect(deltas.map(\.revision) == [1, 2, 3, 4])
    #expect(await provider.expandedDirectories(affectedBy: .targeted([
        .relative(try RelativePath("a-source/renamed")),
        .relative(try RelativePath("a-source/renamed/deep")),
    ])).isEmpty)
    #expect(try await provider.reconcile(.relative(RelativePath("a-source"))) == nil)
    #expect(await updater.relocations == [
        .init(environmentID: environmentID, from: try RelativePath("a-source/file.txt"), to: try RelativePath("z-destination/file.txt")),
        .init(environmentID: environmentID, from: try RelativePath("a-source/sub"), to: try RelativePath("a-source/renamed")),
    ])
}

private actor ControlledPhysicalOperations: FileOperationPhysicallyPerforming {
    private var active = 0
    private(set) var maximumOverlap = 0
    private(set) var startedCount = 0
    private var releases: [CheckedContinuation<Void, Never>] = []
    private var startedEvents: [Int] = []
    private var startedWaiters: [CheckedContinuation<Int, Never>] = []
    func perform(_ operation: FileOperation) async throws -> PhysicalFileOperationResult {
        active += 1
        maximumOverlap = max(maximumOverlap, active)
        startedCount += 1
        if startedWaiters.isEmpty { startedEvents.append(startedCount) }
        else { startedWaiters.removeFirst().resume(returning: startedCount) }
        await withCheckedContinuation { releases.append($0) }
        active -= 1
        let name: String
        if case let .createFile(_, value) = operation { name = value } else { name = "result" }
        return PhysicalFileOperationResult(
            result: .created(path: try RelativePath(name), kind: .file),
            affectedKind: .file,
            trashURL: nil
        )
    }
    func nextStarted() async -> Int {
        if !startedEvents.isEmpty { return startedEvents.removeFirst() }
        return await withCheckedContinuation { startedWaiters.append($0) }
    }
    func releaseNext() { releases.removeFirst().resume() }
}

private struct FailingPhysicalOperations: FileOperationPhysicallyPerforming {
    let error: NSError
    func perform(_ operation: FileOperation) async throws -> PhysicalFileOperationResult { throw error }
}

private struct RemovingPhysicalOperations: FileOperationPhysicallyPerforming {
    let rootURL: URL
    func perform(_ operation: FileOperation) async throws -> PhysicalFileOperationResult {
        guard case let .trash(path) = operation else { throw FileOperationError.invalidPath }
        let valid = try RelativePath(path.string)
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent(valid.string))
        return PhysicalFileOperationResult(result: .trashed(path: valid), affectedKind: .directory, trashURL: nil)
    }
}

private struct MutatingPhysicalOperations: FileOperationPhysicallyPerforming {
    let fileSystem: MutableCoordinatorFileSystem
    func perform(_ operation: FileOperation) async throws -> PhysicalFileOperationResult {
        guard case let .rename(source, newName) = operation else { throw FileOperationError.invalidPath }
        let validSource = try RelativePath(source.string)
        let destination = try RelativePath(newName)
        await fileSystem.set(entries: [.root: [FileSystemEntryRecord(relativePath: destination, kind: .file)]])
        return PhysicalFileOperationResult(
            result: .relocated(from: validSource, to: destination),
            affectedKind: .file,
            trashURL: nil
        )
    }
}

private actor RecordingDocumentLocatorUpdater: DocumentLocatorUpdating {
    struct Relocation: Equatable, Sendable {
        let environmentID: EnvironmentID
        let from: RelativePath
        let to: RelativePath
    }
    private(set) var relocations: [Relocation] = []
    func relocateDocumentLocators(in environmentID: EnvironmentID, from source: RelativePath, to destination: RelativePath) {
        relocations.append(.init(environmentID: environmentID, from: source, to: destination))
    }
}

private actor MetadataBarrierUpdater: DocumentLocatorUpdating {
    private var started = false
    private var completed = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    var hasCompleted: Bool { completed }
    func relocateDocumentLocators(in environmentID: EnvironmentID, from source: RelativePath, to destination: RelativePath) async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseWaiters.append($0) }
        completed = true
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor MutableCoordinatorFileSystem: FileTreeFileSystem {
    var entries: [WorkspaceDirectory: [FileSystemEntryRecord]]
    init(entries: [WorkspaceDirectory: [FileSystemEntryRecord]]) { self.entries = entries }
    func directChildren(rootURL: URL, directory: WorkspaceDirectory) -> [FileSystemEntryRecord] { entries[directory] ?? [] }
    func set(entries: [WorkspaceDirectory: [FileSystemEntryRecord]]) { self.entries = entries }
}

private func coordinatorProvider(environmentID: EnvironmentID) -> FileTreeProvider {
    FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording"),
        fileSystem: MutableCoordinatorFileSystem(entries: [:])
    )
}

private func waitForCoordinatorSubscriberCount(
    _ count: Int,
    provider: FileTreeProvider
) async {
    while await provider.subscriptionCount != count {
        await Task.yield()
    }
}

private func coordinatorEntry(_ path: String, _ kind: FileTreeEntryKind) throws -> FileSystemEntryRecord {
    FileSystemEntryRecord(relativePath: try RelativePath(path), kind: kind)
}

private final class CoordinatorAccessToken: ProjectRootAccessToken, @unchecked Sendable {}

private func coordinatorResolvedRoot(_ url: URL) -> ResolvedProjectRoot {
    ResolvedProjectRoot(
        canonicalAbsolutePath: url.path,
        canonicalRootIdentity: "identity:\(url.lastPathComponent)",
        gitCommonDirectory: nil,
        accessToken: CoordinatorAccessToken()
    )
}

private final class CoordinatorTemporaryDirectory {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: "/private/tmp/cockpit-file-coordinator-tests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

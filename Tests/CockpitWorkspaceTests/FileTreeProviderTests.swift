import Darwin
import Foundation
import Testing
import CockpitClientCore
import CockpitHostCore
import CockpitTypes
@testable import CockpitWorkspace

@Test func rootExpansionReadsOnlyRootAndSortsDirectoriesBeforeLeaves() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = RecordingFileTreeFileSystem(entries: [
        .root: try [
            entry("zeta.txt", .file),
            entry("Beta", .directory),
            entry("alpha-link", .symbolicLink),
            entry("alpha", .directory),
            entry("Alpha.txt", .file),
        ],
        .relative(try RelativePath("alpha")): try [entry("alpha/nested.txt", .file)],
    ])
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording-root", isDirectory: true),
        fileSystem: fileSystem
    )

    let snapshot = try await provider.children(
        environmentID: environmentID,
        at: .root,
        generation: 41
    )

    #expect(snapshot.environmentID == environmentID)
    #expect(snapshot.directory == .root)
    #expect(snapshot.generation == 41)
    #expect(snapshot.revision == 0)
    #expect(snapshot.children.map(\.identity.path.string) == [
        "alpha", "Beta", "alpha-link", "Alpha.txt", "zeta.txt",
    ])
    #expect(snapshot.children.map(\.kind) == [
        .directory, .directory, .symbolicLink, .file, .file,
    ])
    #expect(await fileSystem.recordedReads() == [.root])
}

@Test func relativeExpansionReadsExactlyTheRequestedDirectory() async throws {
    let environmentID = EnvironmentID()
    let sources = WorkspaceDirectory.relative(try RelativePath("Sources"))
    let fileSystem = RecordingFileTreeFileSystem(entries: [
        sources: try [entry("Sources/main.swift", .file)],
    ])
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording-root", isDirectory: true),
        fileSystem: fileSystem
    )

    let snapshot = try await provider.children(
        environmentID: environmentID,
        at: sources,
        generation: 7
    )

    #expect(snapshot.children.map(\.identity.path.string) == ["Sources/main.swift"])
    #expect(await fileSystem.recordedReads() == [sources])
}

@Test func symbolicLinkDirectoryIsALeafAndTraversalIsRejectedWithoutScanningTarget() async throws {
    let environmentID = EnvironmentID()
    let link = WorkspaceDirectory.relative(try RelativePath("linked-directory"))
    let fileSystem = RecordingFileTreeFileSystem(
        entries: [.root: try [entry("linked-directory", .symbolicLink)]],
        errors: [link: .symbolicLinkTraversal]
    )
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording-root", isDirectory: true),
        fileSystem: fileSystem
    )

    let root = try await provider.children(environmentID: environmentID, at: .root, generation: 1)
    #expect(root.children == [try treeEntry(environmentID, "linked-directory", .symbolicLink)])
    await #expect(throws: FileTreeProviderError.symbolicLinkTraversal) {
        _ = try await provider.children(environmentID: environmentID, at: link, generation: 2)
    }
    #expect(await fileSystem.recordedReads() == [.root, link])
}

@Test func providerRejectsEnvironmentMismatchAndZeroGeneration() async throws {
    let environmentID = EnvironmentID()
    let otherEnvironmentID = EnvironmentID()
    let fileSystem = RecordingFileTreeFileSystem(entries: [.root: []])
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording-root", isDirectory: true),
        fileSystem: fileSystem
    )

    await #expect(throws: FileTreeProviderError.environmentMismatch) {
        _ = try await provider.children(environmentID: otherEnvironmentID, at: .root, generation: 1)
    }
    await #expect(throws: FileTreeProviderError.zeroGeneration) {
        _ = try await provider.children(environmentID: environmentID, at: .root, generation: 0)
    }
    #expect(await fileSystem.recordedReads().isEmpty)
}

@Test func snapshotGenerationIsRejectedAfterRepeatedContextSelection() async throws {
    let projectID = ProjectID()
    let environmentID = EnvironmentID()
    let context = try ResolvedWorkspaceContext(
        validating: .project(projectID),
        projectID: projectID,
        conversationID: nil,
        environmentID: environmentID,
        workspaceRootIdentity: "root"
    )
    let controller = ActiveContextController()
    let selected = await controller.select(context)
    let provider = FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording-root", isDirectory: true),
        fileSystem: RecordingFileTreeFileSystem(entries: [.root: []])
    )
    let snapshot = try await provider.children(
        environmentID: environmentID,
        at: .root,
        generation: selected.generation
    )

    _ = await controller.select(context)

    #expect(snapshot.generation == 1)
    #expect(await controller.accepts(generation: snapshot.generation) == false)
}

@Test func duplicateEnvironmentRegistrationKeepsTheSameProviderIdentity() async throws {
    let environmentID = EnvironmentID()
    let firstDirectory = try TemporaryDirectory()
    let secondDirectory = try TemporaryDirectory()
    defer {
        firstDirectory.remove()
        secondDirectory.remove()
    }
    let registry = WorkspaceKernelRegistry()
    await registry.register(
        environmentID: environmentID,
        root: resolvedRoot(path: firstDirectory.url.path, identity: "first")
    )
    let first = try #require(await registry.kernel(for: environmentID))

    await registry.register(
        environmentID: environmentID,
        root: resolvedRoot(path: secondDirectory.url.path, identity: "second")
    )
    let second = try #require(await registry.kernel(for: environmentID))

    #expect(first === second)
    #expect(first.fileTreeProvider === second.fileTreeProvider)
    #expect(first.root.canonicalRootIdentity == "first")
}

@Test func productionFilesystemNeverFollowsAnAncestorSwappedToASymbolicLink() async throws {
    let root = try TemporaryDirectory()
    let outside = try TemporaryDirectory()
    defer { root.remove(); outside.remove() }
    let safe = root.url.appendingPathComponent("safe", isDirectory: true)
    try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: false)
    try Data("outside".utf8).write(to: outside.url.appendingPathComponent("secret.txt"))
    let rootURL = root.url
    let outsideURL = outside.url
    let swap = OneShotAction {
        try! FileManager.default.moveItem(at: safe, to: rootURL.appendingPathComponent("safe-old"))
        try! FileManager.default.createSymbolicLink(at: safe, withDestinationURL: outsideURL)
    }
    let fileSystem = FoundationFileTreeFileSystem(beforeOpeningComponent: { _ in swap.run() })

    await #expect(throws: FileTreeProviderError.symbolicLinkTraversal) {
        _ = try await fileSystem.directChildren(
            rootURL: root.url,
            directory: .relative(RelativePath("safe"))
        )
    }
    #expect(swap.didRun)
}

@Test func repeatedChildrenPublishesChangeBeforeReturningSnapshotAtTheNewRevision() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = RecordingFileTreeFileSystem(entries: [.root: try [entry("old", .file)]])
    let provider = FileTreeProvider(environmentID: environmentID, rootURL: URL(fileURLWithPath: "/recording"), fileSystem: fileSystem)
    _ = try await provider.children(environmentID: environmentID, at: .root, generation: 1)
    var iterator = provider.changes(environmentID: environmentID, after: 0).makeAsyncIterator()
    await fileSystem.setEntries(try [entry("new", .file)], for: .root)

    let snapshot = try await provider.children(environmentID: environmentID, at: .root, generation: 2)
    let delta = try #require(try await iterator.next())

    #expect(snapshot.revision == 1)
    #expect(snapshot.children.map(\.identity.path.string) == ["new"])
    #expect(delta.revision == snapshot.revision)
}

@Test func publicFileTreeValuesRejectInvalidConstructionAndTamperedDecoding() async throws {
    let environmentID = EnvironmentID()
    let otherEnvironmentID = EnvironmentID()
    let child = try treeEntry(environmentID, "dir/child", .file)
    #expect(throws: CockpitDomainValidationError.invalidFileTreeGeneration) {
        _ = try FileTreeSnapshot(validating: environmentID, directory: .relative(RelativePath("dir")), generation: 0, revision: 0, children: [child])
    }
    #expect(throws: CockpitDomainValidationError.invalidFileTreeEnvelope) {
        _ = try FileTreeSnapshot(validating: environmentID, directory: .root, generation: 1, revision: 0, children: [child])
    }
    #expect(throws: CockpitDomainValidationError.invalidFileTreeEnvelope) {
        _ = try FileTreeSnapshot(validating: environmentID, directory: .relative(RelativePath("dir")), generation: 1, revision: 0, children: [try treeEntry(otherEnvironmentID, "dir/child", .file)])
    }
    #expect(throws: CockpitDomainValidationError.invalidFileTreeEnvelope) {
        _ = try FileTreeSnapshot(validating: environmentID, directory: .relative(RelativePath("dir")), generation: 1, revision: 0, children: [child, child])
    }
    #expect(throws: CockpitDomainValidationError.invalidFileTreeDelta) {
        _ = try FileTreeDelta(validating: environmentID, directory: .relative(RelativePath("dir")), revision: 0, mutations: [])
    }
    #expect(throws: CockpitDomainValidationError.invalidFileTreeEnvelope) {
        _ = try FileTreeDelta(validating: environmentID, directory: .relative(RelativePath("dir")), revision: 1, mutations: [.insert(try treeEntry(otherEnvironmentID, "dir/child", .file))])
    }
    #expect(throws: CockpitDomainValidationError.invalidFileTreeEnvelope) {
        _ = try FileTreeDelta(validating: environmentID, directory: .relative(RelativePath("dir")), revision: 1, mutations: [.insert(child), .update(child)])
    }

    let valid = try FileTreeSnapshot(validating: environmentID, directory: .relative(RelativePath("dir")), generation: 1, revision: 0, children: [child])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
    object["generation"] = 0
    let tampered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: CockpitDomainValidationError.invalidFileTreeGeneration) {
        _ = try JSONDecoder().decode(FileTreeSnapshot.self, from: tampered)
    }

    let invalidDirectoryJSON = Data(#"{"relative":{"string":""}}"#.utf8)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(WorkspaceDirectory.self, from: invalidDirectoryJSON)
    }

    let invalidPath = try JSONDecoder().decode(RelativePath.self, from: Data(#"{"string":""}"#.utf8))
    let invalidDirectory = WorkspaceDirectory.relative(invalidPath)
    #expect(throws: (any Error).self) {
        _ = try FileTreeSnapshot(validating: environmentID, directory: invalidDirectory, generation: 1, revision: 0, children: [])
    }
    #expect(throws: (any Error).self) {
        _ = try FileTreeDelta(validating: environmentID, directory: invalidDirectory, revision: 1, mutations: [.insert(try treeEntry(environmentID, "child", .file))])
    }
    #expect(throws: (any Error).self) {
        _ = try JSONEncoder().encode(invalidDirectory)
    }
}

@Test func gateCancellationAfterOwnershipNeverLeaksTheLock() async throws {
    let controller = GateCancellationController(cancelOnGrant: 1)
    let freeGate = FileTreeOperationGate(onOwnershipGranted: { controller.ownershipGranted() })
    let freeTask = controller.task {
        try await freeGate.acquire()
        do { try Task.checkCancellation() }
        catch { await freeGate.release(); throw error }
        await freeGate.release()
    }
    await #expect(throws: CancellationError.self) { try await freeTask.value }
    #expect(await freeGate.hasOwner == false)

    let handoffController = GateCancellationController(cancelOnGrant: 2)
    let handoffGate = FileTreeOperationGate(onOwnershipGranted: { handoffController.ownershipGranted() })
    try await handoffGate.acquire()
    let waiter = handoffController.task {
        try await handoffGate.acquire()
        do { try Task.checkCancellation() }
        catch { await handoffGate.release(); throw error }
        await handoffGate.release()
    }
    while await handoffGate.waiterCount != 1 { await Task.yield() }
    await handoffGate.release()
    await #expect(throws: CancellationError.self) { try await waiter.value }
    #expect(await handoffGate.hasOwner == false)

    try await handoffGate.acquire()
    await handoffGate.release()
}

@Test func fdopendirFailureClosesTheSuccessfulDuplicateExactlyOnce() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let api = RecordingDirectoryStreamAPI(duplicatedFD: 71, stream: nil)
    let fileSystem = FoundationFileTreeFileSystem(directoryStreamAPI: api)

    await #expect(throws: (any Error).self) {
        _ = try await fileSystem.directChildren(rootURL: root.url, directory: .root)
    }
    #expect(api.duplicatedInputs.count == 1)
    #expect(api.closedFDs == [71])
}

@Test func snapshotCapturesItsRevisionBeforeAWaitingReconcileRuns() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = ControlledFileTreeFileSystem(responses: [
        try [entry("old", .file)], try [entry("old", .file)], try [entry("new", .file)],
    ])
    let provider = FileTreeProvider(environmentID: environmentID, rootURL: URL(fileURLWithPath: "/recording"), fileSystem: fileSystem)
    let first = Task { try await provider.children(environmentID: environmentID, at: .root, generation: 1) }
    _ = await fileSystem.nextStarted(); await fileSystem.releaseNext(); _ = try await first.value

    let repeated = Task { try await provider.children(environmentID: environmentID, at: .root, generation: 2) }
    _ = await fileSystem.nextStarted()
    let reconcile = Task { try await provider.reconcile(.root) }
    await fileSystem.releaseNext()
    _ = await fileSystem.nextStarted(); await fileSystem.releaseNext()

    let snapshot = try await repeated.value
    let delta = try #require(try await reconcile.value)
    #expect(snapshot.revision == 0)
    #expect(delta.revision == 1)
}

@Test func invalidationDuringFirstExpansionForcesOneFreshScan() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = ControlledFileTreeFileSystem(responses: [
        try [entry("stale", .file)], try [entry("fresh", .file)],
    ])
    let provider = FileTreeProvider(environmentID: environmentID, rootURL: URL(fileURLWithPath: "/recording"), fileSystem: fileSystem)
    var changes = provider.changes(environmentID: environmentID, after: 0).makeAsyncIterator()
    let expansion = Task { try await provider.children(environmentID: environmentID, at: .root, generation: 1) }
    _ = await fileSystem.nextStarted()
    #expect(await provider.expandedDirectories(affectedBy: .targeted([.root])).isEmpty)
    await fileSystem.releaseNext()
    _ = await fileSystem.nextStarted(); await fileSystem.releaseNext()

    let snapshot = try await expansion.value
    let delta = try #require(try await changes.next())
    #expect(snapshot.children.map(\.identity.path.string) == ["fresh"])
    #expect(snapshot.revision == 1)
    #expect(delta.revision == 1)
}

@Test func cancelledScanDoesNotCommitAndProviderRetainsRootToken() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = ControlledFileTreeFileSystem(responses: [
        try [entry("old", .file)], try [entry("cancelled", .file)], try [entry("old", .file)],
    ])
    var weakToken: WeakToken!
    do {
        var token: TestLifetimeToken? = TestLifetimeToken()
        weakToken = WeakToken(token)
        let provider = FileTreeProvider(environmentID: environmentID, rootURL: URL(fileURLWithPath: "/recording"), rootAccessToken: token, fileSystem: fileSystem)
        token = nil
        let first = Task { try await provider.children(environmentID: environmentID, at: .root, generation: 1) }
        _ = await fileSystem.nextStarted(); await fileSystem.releaseNext(); _ = try await first.value
        let pair = AsyncThrowingStream<FileSystemInvalidation, Error>.makeStream()
        let reconciler = FileTreeReconciler(provider: provider, invalidations: pair.stream)
        pair.continuation.yield(.targeted([.root]))
        _ = await fileSystem.nextStarted()
        let join = BlockingJoinProbe { reconciler.cancelAndWait() }
        join.start()
        await join.waitUntilStarted()
        #expect(join.hasCompleted == false)
        await fileSystem.releaseNext()
        await join.waitUntilCompleted()
        #expect(weakToken.value != nil)
        let snapshotTask = Task { try await provider.children(environmentID: environmentID, at: .root, generation: 2) }
        _ = await fileSystem.nextStarted(); await fileSystem.releaseNext()
        #expect(try await snapshotTask.value.revision == 0)
        pair.continuation.finish()
    }
    #expect(weakToken.value == nil)
}

private actor ControlledFileTreeFileSystem: FileTreeFileSystem {
    private let responses: [[FileSystemEntryRecord]]
    private var index = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startedEvents: [Int] = []
    private var startedWaiters: [CheckedContinuation<Int, Never>] = []

    init(responses: [[FileSystemEntryRecord]]) {
        self.responses = responses
    }
    func directChildren(rootURL: URL, directory: WorkspaceDirectory) async throws -> [FileSystemEntryRecord] {
        let current = index; index += 1
        if startedWaiters.isEmpty { startedEvents.append(current + 1) }
        else { startedWaiters.removeFirst().resume(returning: current + 1) }
        await withCheckedContinuation { waiters.append($0) }
        return responses[current]
    }
    func nextStarted() async -> Int {
        if !startedEvents.isEmpty { return startedEvents.removeFirst() }
        return await withCheckedContinuation { startedWaiters.append($0) }
    }
    func releaseNext() { waiters.removeFirst().resume() }
}

private final class TestLifetimeToken: ProjectRootAccessToken, @unchecked Sendable {}
private final class WeakToken: @unchecked Sendable {
    weak var value: TestLifetimeToken?
    init(_ value: TestLifetimeToken?) { self.value = value }
}

private final class GateCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelOnGrant: Int
    private var grants = 0
    private var cancellation: (@Sendable () -> Void)?
    init(cancelOnGrant: Int) { self.cancelOnGrant = cancelOnGrant }
    func task(_ operation: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        let pair = AsyncStream<Void>.makeStream()
        let task = Task { var iterator = pair.stream.makeAsyncIterator(); _ = await iterator.next(); try await operation() }
        lock.withLock { cancellation = { task.cancel() } }
        pair.continuation.yield(); pair.continuation.finish()
        return task
    }
    func ownershipGranted() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            grants += 1
            return grants == cancelOnGrant ? cancellation : nil
        }
        action?()
    }
}

private final class RecordingDirectoryStreamAPI: DirectoryStreamAPI, @unchecked Sendable {
    let duplicatedFD: Int32
    let stream: UnsafeMutablePointer<DIR>?
    private let lock = NSLock()
    private(set) var duplicatedInputs: [Int32] = []
    private(set) var closedFDs: [Int32] = []
    init(duplicatedFD: Int32, stream: UnsafeMutablePointer<DIR>?) { self.duplicatedFD = duplicatedFD; self.stream = stream }
    func duplicate(_ fd: Int32) -> Int32 { lock.withLock { duplicatedInputs.append(fd) }; return duplicatedFD }
    func openStream(_ fd: Int32) -> UnsafeMutablePointer<DIR>? { stream }
    func close(_ fd: Int32) { lock.withLock { closedFDs.append(fd) } }
}

private final class BlockingJoinProbe: @unchecked Sendable {
    private let operation: @Sendable () -> Void
    private let started = AsyncStream<Void>.makeStream()
    private let completed = AsyncStream<Void>.makeStream()
    private let lock = NSLock()
    private var startedIterator: AsyncStream<Void>.Iterator
    private var completedIterator: AsyncStream<Void>.Iterator
    private(set) var hasCompleted = false
    init(operation: @escaping @Sendable () -> Void) {
        self.operation = operation
        startedIterator = started.stream.makeAsyncIterator()
        completedIterator = completed.stream.makeAsyncIterator()
    }
    func start() {
        DispatchQueue.global().async { [self] in
            started.continuation.yield()
            operation()
            lock.withLock { hasCompleted = true }
            completed.continuation.yield()
        }
    }
    func waitUntilStarted() async { _ = await startedIterator.next() }
    func waitUntilCompleted() async { _ = await completedIterator.next() }
}

private final class OneShotAction: @unchecked Sendable {
    private let lock = NSLock()
    private let action: @Sendable () -> Void
    private(set) var didRun = false
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    func run() {
        lock.lock(); defer { lock.unlock() }
        guard !didRun else { return }
        didRun = true
        action()
    }
}

func entry(_ path: String, _ kind: FileTreeEntryKind) throws -> FileSystemEntryRecord {
    FileSystemEntryRecord(relativePath: try RelativePath(path), kind: kind)
}

func treeEntry(
    _ environmentID: EnvironmentID,
    _ path: String,
    _ kind: FileTreeEntryKind
) throws -> FileTreeEntry {
    try FileTreeEntry(
        validating: FileTreeEntryIdentity(
            validating: environmentID,
            path: try RelativePath(path)
        ),
        kind: kind
    )
}

actor RecordingFileTreeFileSystem: FileTreeFileSystem {
    private var entries: [WorkspaceDirectory: [FileSystemEntryRecord]]
    private var errors: [WorkspaceDirectory: FileTreeProviderError]
    private var reads: [WorkspaceDirectory] = []

    init(
        entries: [WorkspaceDirectory: [FileSystemEntryRecord]],
        errors: [WorkspaceDirectory: FileTreeProviderError] = [:]
    ) {
        self.entries = entries
        self.errors = errors
    }

    func directChildren(
        rootURL: URL,
        directory: WorkspaceDirectory
    ) async throws -> [FileSystemEntryRecord] {
        reads.append(directory)
        if let error = errors[directory] {
            throw error
        }
        return entries[directory, default: []]
    }

    func setEntries(_ newEntries: [FileSystemEntryRecord], for directory: WorkspaceDirectory) {
        entries[directory] = newEntries
    }

    func setError(_ error: FileTreeProviderError, for directory: WorkspaceDirectory) {
        errors[directory] = error
    }

    func recordedReads() -> [WorkspaceDirectory] {
        reads
    }

    func clearReads() {
        reads.removeAll()
    }
}

private final class TestProjectRootAccessToken: ProjectRootAccessToken, @unchecked Sendable {}

private func resolvedRoot(path: String, identity: String) -> ResolvedProjectRoot {
    ResolvedProjectRoot(
        canonicalAbsolutePath: path,
        canonicalRootIdentity: identity,
        gitCommonDirectory: nil,
        accessToken: TestProjectRootAccessToken()
    )
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

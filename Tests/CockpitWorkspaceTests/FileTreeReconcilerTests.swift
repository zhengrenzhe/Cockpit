import CoreServices
import Foundation
import Testing
import CockpitHostCore
import CockpitTypes
@testable import CockpitWorkspace

@Test func targetedInvalidationRescansOnlyAffectedExpandedDirectories() async throws {
    let environmentID = EnvironmentID()
    let affected = WorkspaceDirectory.relative(try RelativePath("affected"))
    let unaffected = WorkspaceDirectory.relative(try RelativePath("unaffected"))
    let unexpanded = WorkspaceDirectory.relative(try RelativePath("unexpanded"))
    let fileSystem = RecordingFileTreeFileSystem(entries: [
        affected: try [entry("affected/old.txt", .file)],
        unaffected: try [entry("unaffected/stable.txt", .file)],
        unexpanded: try [entry("unexpanded/hidden.txt", .file)],
    ])
    let provider = testProvider(environmentID, fileSystem)
    _ = try await provider.children(environmentID: environmentID, at: affected, generation: 1)
    _ = try await provider.children(environmentID: environmentID, at: unaffected, generation: 1)
    await fileSystem.clearReads()
    await fileSystem.setEntries(try [entry("affected/new.txt", .file)], for: affected)
    let source = FakeFileSystemEventSource()
    let reconciler = FileTreeReconciler(provider: provider, invalidations: source.invalidations)
    defer { reconciler.cancel() }
    var iterator = provider.changes(environmentID: environmentID, after: 0).makeAsyncIterator()
    await waitForSubscriberCount(1, provider: provider)

    source.send(.targeted([unexpanded, affected]))
    let delta = try #require(try await iterator.next())

    #expect(delta.directory == affected)
    #expect(delta.revision == 1)
    #expect(await fileSystem.recordedReads() == [affected])
}

@Test func dropInvalidationRescansEveryExpandedDirectoryOnceInDeterministicOrder() async throws {
    let environmentID = EnvironmentID()
    let a = WorkspaceDirectory.relative(try RelativePath("a"))
    let z = WorkspaceDirectory.relative(try RelativePath("z"))
    let unexpanded = WorkspaceDirectory.relative(try RelativePath("middle"))
    let fileSystem = RecordingFileTreeFileSystem(entries: [
        .root: try [entry("root-old", .file)],
        a: try [entry("a/old", .file)],
        z: try [entry("z/old", .file)],
        unexpanded: try [entry("middle/old", .file)],
    ])
    let provider = testProvider(environmentID, fileSystem)
    _ = try await provider.children(environmentID: environmentID, at: z, generation: 1)
    _ = try await provider.children(environmentID: environmentID, at: .root, generation: 1)
    _ = try await provider.children(environmentID: environmentID, at: a, generation: 1)
    await fileSystem.clearReads()
    await fileSystem.setEntries(try [entry("root-new", .file)], for: .root)
    await fileSystem.setEntries(try [entry("a/new", .file)], for: a)
    await fileSystem.setEntries(try [entry("z/new", .file)], for: z)
    let source = FakeFileSystemEventSource()
    let reconciler = FileTreeReconciler(provider: provider, invalidations: source.invalidations)
    defer { reconciler.cancel() }
    var iterator = provider.changes(environmentID: environmentID, after: 0).makeAsyncIterator()
    await waitForSubscriberCount(1, provider: provider)

    source.send(.allExpanded)
    let first = try #require(try await iterator.next())
    let second = try #require(try await iterator.next())
    let third = try #require(try await iterator.next())

    #expect([first.directory, second.directory, third.directory] == [.root, a, z])
    #expect([first.revision, second.revision, third.revision] == [1, 2, 3])
    #expect(await fileSystem.recordedReads() == [.root, a, z])
}

@Test func freshFilesystemTruthEmitsDeterministicMutationsAndMonotonicRevisions() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = RecordingFileTreeFileSystem(entries: [
        .root: try [
            entry("a", .file),
            entry("b", .directory),
            entry("c", .file),
        ],
    ])
    let provider = testProvider(environmentID, fileSystem)
    _ = try await provider.children(environmentID: environmentID, at: .root, generation: 1)
    await fileSystem.setEntries(try [
        entry("a", .symbolicLink),
        entry("c", .file),
        entry("d", .file),
    ], for: .root)

    let first = try #require(try await provider.reconcile(.root))
    let unchanged = try await provider.reconcile(.root)
    await fileSystem.setEntries(try [
        entry("a", .symbolicLink),
        entry("c", .file),
        entry("d", .file),
        entry("e", .file),
    ], for: .root)
    let second = try #require(try await provider.reconcile(.root))

    let expectedFirstMutations: [FileTreeMutation] = try [
        .remove(FileTreeEntryIdentity(validating: environmentID, path: RelativePath("b"))),
        .update(treeEntry(environmentID, "a", .symbolicLink)),
        .insert(treeEntry(environmentID, "d", .file)),
    ]
    let expectedSecondMutations: [FileTreeMutation] = try [
        .insert(treeEntry(environmentID, "e", .file)),
    ]
    #expect(first.revision == 1)
    #expect(first.mutations == expectedFirstMutations)
    #expect(unchanged == nil)
    #expect(second.revision == 2)
    #expect(second.mutations == expectedSecondMutations)
}

@Test func unavailableRevisionsFailClosedAndCancellationRemovesSubscriber() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = RecordingFileTreeFileSystem(entries: [.root: []])
    let provider = testProvider(environmentID, fileSystem)

    var stale = provider.changes(environmentID: environmentID, after: 1).makeAsyncIterator()
    await #expect(throws: FileTreeProviderError.revisionUnavailable(requested: 1, current: 0)) {
        _ = try await stale.next()
    }
    var wrongEnvironment = provider.changes(environmentID: EnvironmentID(), after: 0).makeAsyncIterator()
    await #expect(throws: FileTreeProviderError.environmentMismatch) {
        _ = try await wrongEnvironment.next()
    }

    let task = Task {
        var current = provider.changes(environmentID: environmentID, after: 0).makeAsyncIterator()
        return try await current.next()
    }
    await waitForSubscriberCount(1, provider: provider)
    task.cancel()
    _ = await task.result
    await waitForSubscriberCount(0, provider: provider)
    #expect(await provider.subscriptionCount == 0)
}

@Test func subscriberThatFallsBehindTerminatesWithRevisionUnavailable() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = RecordingFileTreeFileSystem(entries: [.root: []])
    let provider = testProvider(environmentID, fileSystem)
    _ = try await provider.children(environmentID: environmentID, at: .root, generation: 1)
    var iterator = provider.changes(environmentID: environmentID, after: 0).makeAsyncIterator()
    await waitForSubscriberCount(1, provider: provider)

    for name in ["one", "two", "three"] {
        await fileSystem.setEntries(try [entry(name, .file)], for: .root)
        _ = try #require(try await provider.reconcile(.root))
    }

    _ = try await iterator.next()
    await #expect(throws: FileTreeProviderError.revisionUnavailable(requested: 0, current: 2)) {
        _ = try await iterator.next()
    }
}

@Test func eventFlagAndPathMappingCoversTargetedAndConservativeInvalidations() throws {
    let root = URL(fileURLWithPath: "/workspace", isDirectory: true)
    let nestedFile = FileSystemEventSource.map(
        rootURL: root,
        paths: ["/workspace/Sources/App/main.swift"],
        flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)]
    )
    let directory = FileSystemEventSource.map(
        rootURL: root,
        paths: ["/workspace/Sources"],
        flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)]
    )
    let drop = FileSystemEventSource.map(
        rootURL: root,
        paths: ["/workspace"],
        flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)]
    )
    let mustScan = FileSystemEventSource.map(
        rootURL: root,
        paths: ["/workspace"],
        flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)]
    )
    let rootChanged = FileSystemEventSource.map(
        rootURL: root,
        paths: ["/workspace"],
        flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)]
    )

    #expect(nestedFile == .targeted([
        .relative(try RelativePath("Sources/App")),
    ]))
    #expect(directory == .targeted([
        .root,
        .relative(try RelativePath("Sources")),
    ]))
    #expect(drop == .allExpanded)
    #expect(mustScan == .allExpanded)
    #expect(rootChanged == .allExpanded)
}

@Test func eventSourceStartFailureTerminatesCurrentAndFutureSubscribers() async throws {
    let environmentID = EnvironmentID()
    let provider = testProvider(environmentID, RecordingFileTreeFileSystem(entries: [.root: []]))
    var current = provider.changes(environmentID: environmentID, after: 0).makeAsyncIterator()
    let driver = RecordingEventStreamDriver(startResult: false)
    let source = FileSystemEventSource(rootURL: URL(fileURLWithPath: "/recording"), driver: driver)
    let reconciler = FileTreeReconciler(provider: provider, invalidations: source.invalidations)
    defer { reconciler.cancel(); source.cancel() }

    await #expect(throws: FileTreeProviderError.eventSourceUnavailable) { _ = try await current.next() }
    var future = provider.changes(environmentID: environmentID, after: 0).makeAsyncIterator()
    await #expect(throws: FileTreeProviderError.eventSourceUnavailable) { _ = try await future.next() }
}

@Test func reconciliationEnumerationFailureEndsCurrentSubscriberExplicitly() async throws {
    let environmentID = EnvironmentID()
    let fileSystem = RecordingFileTreeFileSystem(entries: [.root: []])
    let provider = testProvider(environmentID, fileSystem)
    _ = try await provider.children(environmentID: environmentID, at: .root, generation: 1)
    await fileSystem.setError(.filesystemEnumerationFailed, for: .root)
    var iterator = provider.changes(environmentID: environmentID, after: 0).makeAsyncIterator()
    let source = FakeFileSystemEventSource()
    let reconciler = FileTreeReconciler(provider: provider, invalidations: source.invalidations)
    defer { reconciler.cancel() }

    source.send(.targeted([.root]))
    await #expect(throws: FileTreeProviderError.filesystemEnumerationFailed) { _ = try await iterator.next() }
}

@Test func eventDriverOwnsCallbackUntilBalancedCancellation() async throws {
    let driver = RecordingEventStreamDriver(startResult: true)
    var source: FileSystemEventSource? = FileSystemEventSource(rootURL: URL(fileURLWithPath: "/recording"), driver: driver)
    driver.send(paths: ["/recording/file"], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)])
    var iterator = source!.invalidations.makeAsyncIterator()
    #expect(try await iterator.next() == .targeted([.root]))
    source?.cancel()
    source = nil
    #expect(driver.startCount == 1)
    #expect(driver.cancelCount == 1)
    #expect(driver.callbackReleased)
}

@Test func coreServicesDriverExercisesBalancedContextAndLifecycleThroughLowLevelAPI() async throws {
    let successAPI = RecordingFSEventStreamAPI(startResult: true)
    let successDriver = CoreServicesEventStreamDriver(api: successAPI)
    let received = AsyncStream<[String]>.makeStream()
    #expect(successDriver.start(rootURL: URL(fileURLWithPath: "/recording")) { paths, _ in received.continuation.yield(paths) })
    successAPI.emit(paths: ["/recording/file"], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)])
    var iterator = received.stream.makeAsyncIterator()
    #expect(await iterator.next() == ["/recording/file"])
    successDriver.cancel()
    #expect(successAPI.operations == ["create", "setQueue", "start", "stop", "invalidate", "release"])
    #expect(successAPI.retainCount == 1)
    #expect(successAPI.releaseCount == 1)

    let failureAPI = RecordingFSEventStreamAPI(startResult: false)
    let failureDriver = CoreServicesEventStreamDriver(api: failureAPI)
    #expect(failureDriver.start(rootURL: URL(fileURLWithPath: "/recording")) { _, _ in } == false)
    #expect(failureAPI.operations == ["create", "setQueue", "start", "invalidate", "release"])
    #expect(failureAPI.retainCount == 1)
    #expect(failureAPI.releaseCount == 1)
}

private func testProvider(
    _ environmentID: EnvironmentID,
    _ fileSystem: RecordingFileTreeFileSystem
) -> FileTreeProvider {
    FileTreeProvider(
        environmentID: environmentID,
        rootURL: URL(fileURLWithPath: "/recording-root", isDirectory: true),
        fileSystem: fileSystem
    )
}

private func waitForSubscriberCount(_ count: Int, provider: FileTreeProvider) async {
    while await provider.subscriptionCount != count {
        await Task.yield()
    }
}

private final class FakeFileSystemEventSource: @unchecked Sendable {
    let invalidations: AsyncThrowingStream<FileSystemInvalidation, Error>
    private let continuation: AsyncThrowingStream<FileSystemInvalidation, Error>.Continuation

    init() {
        (invalidations, continuation) = AsyncThrowingStream.makeStream()
    }

    func send(_ invalidation: FileSystemInvalidation) {
        continuation.yield(invalidation)
    }

    deinit {
        continuation.finish()
    }
}

private final class RecordingEventStreamDriver: FileSystemEventDriving, @unchecked Sendable {
    private let startResult: Bool
    private let lock = NSLock()
    private var callback: (@Sendable ([String], [FSEventStreamEventFlags]) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    var callbackReleased: Bool { lock.withLock { callback == nil } }

    init(startResult: Bool) { self.startResult = startResult }
    func start(rootURL: URL, callback: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void) -> Bool {
        lock.withLock { startCount += 1; self.callback = callback }
        return startResult
    }
    func cancel() { lock.withLock { cancelCount += 1; callback = nil } }
    func send(paths: [String], flags: [FSEventStreamEventFlags]) { lock.withLock { callback }?(paths, flags) }
}

private final class RecordingFSEventStreamAPI: FSEventStreamAPI, @unchecked Sendable {
    private let handle = OpaquePointer(bitPattern: 1)!
    private let startResult: Bool
    private let lock = NSLock()
    private var callback: FSEventStreamCallback?
    private var context: FSEventStreamContext?
    private(set) var operations: [String] = []
    private(set) var retainCount = 0
    private(set) var releaseCount = 0
    init(startResult: Bool) { self.startResult = startResult }
    func create(callback: @escaping FSEventStreamCallback, context: inout FSEventStreamContext, paths: CFArray, sinceWhen: FSEventStreamEventId, latency: CFTimeInterval, flags: FSEventStreamCreateFlags) -> FSEventStreamRef? {
        operations.append("create")
        self.callback = callback
        if let retain = context.retain, let info = context.info {
            context.info = UnsafeMutableRawPointer(mutating: retain(info))
            retainCount += 1
        }
        self.context = context
        return handle
    }
    func setDispatchQueue(_ stream: FSEventStreamRef, queue: DispatchQueue) { operations.append("setQueue") }
    func start(_ stream: FSEventStreamRef) -> Bool { operations.append("start"); return startResult }
    func stop(_ stream: FSEventStreamRef) { operations.append("stop") }
    func invalidate(_ stream: FSEventStreamRef) { operations.append("invalidate") }
    func release(_ stream: FSEventStreamRef) {
        operations.append("release")
        if let release = context?.release, let info = context?.info { release(info); releaseCount += 1 }
        context = nil
    }
    func emit(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard let callback, let info = context?.info else { return }
        let array = paths as NSArray
        flags.withUnsafeBufferPointer { flagBuffer in
            var ids = Array(repeating: FSEventStreamEventId(1), count: paths.count)
            ids.withUnsafeMutableBufferPointer { idBuffer in
                callback(handle, info, paths.count, unsafeBitCast(array, to: UnsafeMutableRawPointer.self), flagBuffer.baseAddress!, idBuffer.baseAddress!)
            }
        }
    }
}

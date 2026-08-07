import Darwin
import Foundation
import CockpitHostCore
import CockpitTypes

struct FileSystemEntryRecord: Hashable, Sendable {
    let relativePath: RelativePath
    let kind: FileTreeEntryKind

    init(relativePath: RelativePath, kind: FileTreeEntryKind) {
        self.relativePath = relativePath
        self.kind = kind
    }
}

protocol FileTreeFileSystem: Sendable {
    func directChildren(
        rootURL: URL,
        directory: WorkspaceDirectory
    ) async throws -> [FileSystemEntryRecord]
}

struct FoundationFileTreeFileSystem: FileTreeFileSystem {
    func directChildren(
        rootURL: URL,
        directory: WorkspaceDirectory
    ) async throws -> [FileSystemEntryRecord] {
        try await Task.detached {
            try Self.directChildrenSynchronously(rootURL: rootURL, directory: directory)
        }.value
    }

    private static func directChildrenSynchronously(
        rootURL: URL,
        directory: WorkspaceDirectory
    ) throws -> [FileSystemEntryRecord] {
        let directoryURL = try validatedDirectoryURL(rootURL: rootURL, directory: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        return try names.map { name in
            let childURL = directoryURL.appendingPathComponent(name, isDirectory: false)
            let kind = try kindWithoutFollowingSymbolicLink(atPath: childURL.path)
            let relativePath: RelativePath
            switch directory {
            case .root:
                relativePath = try RelativePath(name)
            case let .relative(parent):
                relativePath = try RelativePath(parent.string + "/" + name)
            }
            return FileSystemEntryRecord(relativePath: relativePath, kind: kind)
        }
    }

    private static func validatedDirectoryURL(
        rootURL: URL,
        directory: WorkspaceDirectory
    ) throws -> URL {
        var current = rootURL.standardizedFileURL
        try requireDirectoryWithoutFollowingSymbolicLink(atPath: current.path)
        guard case let .relative(path) = directory else { return current }

        for component in path.string.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            try requireDirectoryWithoutFollowingSymbolicLink(atPath: current.path)
        }
        return current
    }

    private static func requireDirectoryWithoutFollowingSymbolicLink(atPath path: String) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let fileType = metadata.st_mode & mode_t(S_IFMT)
        guard fileType != mode_t(S_IFLNK) else {
            throw FileTreeProviderError.symbolicLinkTraversal
        }
        guard fileType == mode_t(S_IFDIR) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }

    private static func kindWithoutFollowingSymbolicLink(atPath path: String) throws -> FileTreeEntryKind {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        switch metadata.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFLNK): return .symbolicLink
        case mode_t(S_IFDIR): return .directory
        default: return .file
        }
    }
}

private actor FileTreeOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private final class FileTreeSubscriptionHub: @unchecked Sendable {
    private struct Subscriber {
        let requestedRevision: UInt64
        let continuation: AsyncThrowingStream<FileTreeDelta, Error>.Continuation
    }

    private let environmentID: EnvironmentID
    private let lock = NSLock()
    private var currentRevision: UInt64 = 0
    private var subscribers: [UUID: Subscriber] = [:]

    init(environmentID: EnvironmentID) {
        self.environmentID = environmentID
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribers.count
    }

    func stream(
        environmentID: EnvironmentID,
        after requestedRevision: UInt64
    ) -> AsyncThrowingStream<FileTreeDelta, Error> {
        let subscriberID = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1)) { continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.remove(id: subscriberID)
            }

            lock.lock()
            let revision = currentRevision
            if environmentID == self.environmentID, requestedRevision == revision {
                subscribers[subscriberID] = Subscriber(
                    requestedRevision: requestedRevision,
                    continuation: continuation
                )
                lock.unlock()
                return
            }
            lock.unlock()

            if environmentID != self.environmentID {
                continuation.finish(throwing: FileTreeProviderError.environmentMismatch)
            } else {
                continuation.finish(
                    throwing: FileTreeProviderError.revisionUnavailable(
                        requested: requestedRevision,
                        current: revision
                    )
                )
            }
        }
    }

    func publish(_ delta: FileTreeDelta) {
        lock.lock()
        currentRevision = delta.revision
        let currentSubscribers = subscribers
        lock.unlock()

        for (id, subscriber) in currentSubscribers {
            switch subscriber.continuation.yield(delta) {
            case .enqueued:
                continue
            case .dropped:
                remove(id: id)
                subscriber.continuation.finish(
                    throwing: FileTreeProviderError.revisionUnavailable(
                        requested: subscriber.requestedRevision,
                        current: delta.revision
                    )
                )
            case .terminated:
                remove(id: id)
            @unknown default:
                remove(id: id)
            }
        }
    }

    private func remove(id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }
}

actor FileTreeProvider: FileTreeProviding {
    private let environmentID: EnvironmentID
    private let rootURL: URL
    private let fileSystem: any FileTreeFileSystem
    private let operationGate = FileTreeOperationGate()
    nonisolated private let subscriptionHub: FileTreeSubscriptionHub
    private var revision: UInt64 = 0
    private var expanded: [WorkspaceDirectory: [FileTreeEntry]] = [:]

    init(
        environmentID: EnvironmentID,
        rootURL: URL,
        fileSystem: any FileTreeFileSystem = FoundationFileTreeFileSystem()
    ) {
        self.environmentID = environmentID
        self.rootURL = rootURL
        self.fileSystem = fileSystem
        subscriptionHub = FileTreeSubscriptionHub(environmentID: environmentID)
    }

    var subscriptionCount: Int { subscriptionHub.count }

    func children(
        environmentID: EnvironmentID,
        at directory: WorkspaceDirectory,
        generation: UInt64
    ) async throws -> FileTreeSnapshot {
        guard environmentID == self.environmentID else {
            throw FileTreeProviderError.environmentMismatch
        }
        guard generation > 0 else {
            throw FileTreeProviderError.zeroGeneration
        }

        await operationGate.acquire()
        do {
            let children = try await enumerate(directory)
            expanded[directory] = children
            await operationGate.release()
            return FileTreeSnapshot(
                environmentID: environmentID,
                directory: directory,
                generation: generation,
                revision: revision,
                children: children
            )
        } catch {
            await operationGate.release()
            throw error
        }
    }

    nonisolated func changes(
        environmentID: EnvironmentID,
        after revision: UInt64
    ) -> AsyncThrowingStream<FileTreeDelta, Error> {
        subscriptionHub.stream(environmentID: environmentID, after: revision)
    }

    func expandedDirectories(affectedBy invalidation: FileSystemInvalidation) -> [WorkspaceDirectory] {
        let candidates: [WorkspaceDirectory]
        switch invalidation {
        case .allExpanded:
            candidates = Array(expanded.keys)
        case let .targeted(directories):
            candidates = directories.filter { expanded[$0] != nil }
        }
        return Array(Set(candidates)).sorted(by: Self.directoryPrecedes)
    }

    func reconcile(_ directory: WorkspaceDirectory) async throws -> FileTreeDelta? {
        guard expanded[directory] != nil else { return nil }
        await operationGate.acquire()
        do {
            guard let previous = expanded[directory] else {
                await operationGate.release()
                return nil
            }
            let current = try await enumerate(directory)
            let mutations = Self.mutations(from: previous, to: current)
            expanded[directory] = current
            guard !mutations.isEmpty else {
                await operationGate.release()
                return nil
            }
            precondition(revision < UInt64.max, "File tree revision exhausted")
            revision += 1
            let delta = FileTreeDelta(
                environmentID: environmentID,
                directory: directory,
                revision: revision,
                mutations: mutations
            )
            subscriptionHub.publish(delta)
            await operationGate.release()
            return delta
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func enumerate(_ directory: WorkspaceDirectory) async throws -> [FileTreeEntry] {
        try await fileSystem.directChildren(rootURL: rootURL, directory: directory)
            .map {
                FileTreeEntry(
                    identity: FileTreeEntryIdentity(
                        environmentID: environmentID,
                        path: $0.relativePath
                    ),
                    kind: $0.kind
                )
            }
            .sorted(by: Self.entryPrecedes)
    }

    private static func mutations(
        from previous: [FileTreeEntry],
        to current: [FileTreeEntry]
    ) -> [FileTreeMutation] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.identity, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.identity, $0) })
        let removals = previous
            .filter { currentByID[$0.identity] == nil }
            .sorted(by: rawPathPrecedes)
            .map { FileTreeMutation.remove($0.identity) }
        let updates = current
            .filter { entry in
                guard let old = previousByID[entry.identity] else { return false }
                return old != entry
            }
            .sorted(by: rawPathPrecedes)
            .map(FileTreeMutation.update)
        let inserts = current
            .filter { previousByID[$0.identity] == nil }
            .sorted(by: rawPathPrecedes)
            .map(FileTreeMutation.insert)
        return removals + updates + inserts
    }

    private static func entryPrecedes(_ lhs: FileTreeEntry, _ rhs: FileTreeEntry) -> Bool {
        let lhsDirectory = lhs.kind == .directory
        let rhsDirectory = rhs.kind == .directory
        if lhsDirectory != rhsDirectory { return lhsDirectory }
        let lhsPath = lhs.identity.path.string
        let rhsPath = rhs.identity.path.string
        let comparison = lhsPath.localizedStandardCompare(rhsPath)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhsPath < rhsPath
    }

    private static func rawPathPrecedes(_ lhs: FileTreeEntry, _ rhs: FileTreeEntry) -> Bool {
        lhs.identity.path.string < rhs.identity.path.string
    }

    private static func directoryPrecedes(_ lhs: WorkspaceDirectory, _ rhs: WorkspaceDirectory) -> Bool {
        switch (lhs, rhs) {
        case (.root, .root): return false
        case (.root, _): return true
        case (_, .root): return false
        case let (.relative(lhsPath), .relative(rhsPath)):
            let comparison = lhsPath.string.localizedStandardCompare(rhsPath.string)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhsPath.string < rhsPath.string
        }
    }
}

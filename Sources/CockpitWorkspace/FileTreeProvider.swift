import Darwin
import Foundation
import CockpitHostCore
import CockpitTypes

struct FileSystemEntryRecord: Hashable, Sendable {
    let relativePath: RelativePath
    let kind: FileTreeEntryKind
    init(relativePath: RelativePath, kind: FileTreeEntryKind) { self.relativePath = relativePath; self.kind = kind }
}

protocol FileTreeFileSystem: Sendable {
    func directChildren(rootURL: URL, directory: WorkspaceDirectory) async throws -> [FileSystemEntryRecord]
}

protocol DirectoryStreamAPI: Sendable {
    func duplicate(_ fd: Int32) -> Int32
    func openStream(_ fd: Int32) -> UnsafeMutablePointer<DIR>?
    func close(_ fd: Int32)
}

private struct DarwinDirectoryStreamAPI: DirectoryStreamAPI {
    func duplicate(_ fd: Int32) -> Int32 { Darwin.dup(fd) }
    func openStream(_ fd: Int32) -> UnsafeMutablePointer<DIR>? { Darwin.fdopendir(fd) }
    func close(_ fd: Int32) { Darwin.close(fd) }
}

final class FoundationFileTreeFileSystem: FileTreeFileSystem, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.openai.cockpit.file-tree-io")
    private let beforeOpeningComponent: @Sendable (String) -> Void
    private let directoryStreamAPI: any DirectoryStreamAPI

    init(
        directoryStreamAPI: any DirectoryStreamAPI = DarwinDirectoryStreamAPI(),
        beforeOpeningComponent: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.directoryStreamAPI = directoryStreamAPI
        self.beforeOpeningComponent = beforeOpeningComponent
    }

    func directChildren(rootURL: URL, directory: WorkspaceDirectory) async throws -> [FileSystemEntryRecord] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [beforeOpeningComponent, directoryStreamAPI] in
                continuation.resume(with: Result { try Self.scan(rootURL: rootURL, directory: directory, directoryStreamAPI: directoryStreamAPI, beforeOpeningComponent: beforeOpeningComponent) })
            }
        }
    }

    private static func scan(rootURL: URL, directory: WorkspaceDirectory, directoryStreamAPI: any DirectoryStreamAPI, beforeOpeningComponent: @Sendable (String) -> Void) throws -> [FileSystemEntryRecord] {
        var directoryFD = open(rootURL.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw fileOpenError() }
        defer { close(directoryFD) }
        if case let .relative(path) = directory {
            for component in path.string.split(separator: "/").map(String.init) {
                beforeOpeningComponent(component)
                let next = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else {
                    var metadata = stat()
                    if fstatat(directoryFD, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                       metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                        throw FileTreeProviderError.symbolicLinkTraversal
                    }
                    throw fileOpenError()
                }
                close(directoryFD); directoryFD = next
            }
        }
        let duplicatedFD = directoryStreamAPI.duplicate(directoryFD)
        guard duplicatedFD >= 0 else { throw CocoaError(.fileReadUnknown) }
        guard let stream = directoryStreamAPI.openStream(duplicatedFD) else {
            directoryStreamAPI.close(duplicatedFD)
            throw CocoaError(.fileReadUnknown)
        }
        defer { closedir(stream) }
        var result: [FileSystemEntryRecord] = []
        while let raw = readdir(stream) {
            let name = withUnsafePointer(to: &raw.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            var metadata = stat()
            guard fstatat(directoryFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw CocoaError(.fileReadUnknown) }
            let kind: FileTreeEntryKind
            switch metadata.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFLNK): kind = .symbolicLink
            case mode_t(S_IFDIR): kind = .directory
            default: kind = .file
            }
            let path: RelativePath
            switch directory {
            case .root: path = try RelativePath(name)
            case let .relative(parent): path = try RelativePath(parent.string + "/" + name)
            }
            result.append(FileSystemEntryRecord(relativePath: path, kind: kind))
        }
        return result
    }

    private static func fileOpenError() -> Error {
        errno == ELOOP ? FileTreeProviderError.symbolicLinkTraversal : CocoaError(.fileReadNoSuchFile)
    }
}

actor FileTreeOperationGate {
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Bool, Never> }
    private var locked = false
    private var waiters: [Waiter] = []
    private let onOwnershipGranted: @Sendable () -> Void
    init(onOwnershipGranted: @escaping @Sendable () -> Void = {}) { self.onOwnershipGranted = onOwnershipGranted }
    var hasOwner: Bool { locked }
    var waiterCount: Int { waiters.count }
    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if !locked { locked = true; onOwnershipGranted(); continuation.resume(returning: true) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        guard acquired else { throw CancellationError() }
    }
    func release() {
        guard !waiters.isEmpty else { locked = false; return }
        let waiter = waiters.removeFirst()
        onOwnershipGranted()
        waiter.continuation.resume(returning: true)
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

private final class FileTreeSubscriptionHub: @unchecked Sendable {
    private struct Subscriber { let requestedRevision: UInt64; let continuation: AsyncThrowingStream<FileTreeDelta, Error>.Continuation }
    private let environmentID: EnvironmentID
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var terminalError: FileTreeProviderError?
    private var subscribers: [UUID: Subscriber] = [:]
    init(environmentID: EnvironmentID) { self.environmentID = environmentID }
    var count: Int { lock.withLock { subscribers.count } }
    func stream(environmentID: EnvironmentID, after requested: UInt64) -> AsyncThrowingStream<FileTreeDelta, Error> {
        let id = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1)) { continuation in
            continuation.onTermination = { @Sendable [weak self] _ in self?.remove(id) }
            let error: FileTreeProviderError? = lock.withLock {
                if let terminalError { return terminalError }
                guard environmentID == self.environmentID else { return .environmentMismatch }
                guard requested == revision else { return .revisionUnavailable(requested: requested, current: revision) }
                subscribers[id] = Subscriber(requestedRevision: requested, continuation: continuation); return nil
            }
            if let error { continuation.finish(throwing: error) }
        }
    }
    func publish(_ delta: FileTreeDelta) {
        let targets = lock.withLock { revision = delta.revision; return subscribers }
        for (id, subscriber) in targets {
            switch subscriber.continuation.yield(delta) {
            case .enqueued: break
            case .dropped:
                remove(id); subscriber.continuation.finish(throwing: FileTreeProviderError.revisionUnavailable(requested: subscriber.requestedRevision, current: delta.revision))
            case .terminated: remove(id)
            @unknown default: remove(id)
            }
        }
    }
    func failCurrent(_ error: FileTreeProviderError) {
        let targets = lock.withLock { let value = subscribers; subscribers.removeAll(); return value }
        targets.values.forEach { $0.continuation.finish(throwing: error) }
    }
    func terminate(_ error: FileTreeProviderError) {
        let targets = lock.withLock { terminalError = error; let value = subscribers; subscribers.removeAll(); return value }
        targets.values.forEach { $0.continuation.finish(throwing: error) }
    }
    private func remove(_ id: UUID) { lock.withLock { _ = subscribers.removeValue(forKey: id) } }
}

actor FileTreeProvider: FileTreeProviding {
    struct ExternalMutationLease: Hashable, Sendable {
        let id: UUID
    }
    private let environmentID: EnvironmentID
    private let rootURL: URL
    private let rootAccessToken: (any ProjectRootAccessToken)?
    private let fileSystem: any FileTreeFileSystem
    private let gate = FileTreeOperationGate()
    nonisolated private let hub: FileTreeSubscriptionHub
    private var revision: UInt64 = 0
    private var expanded: [WorkspaceDirectory: [FileTreeEntry]] = [:]
    private var inFlight: Set<WorkspaceDirectory> = []
    private var pendingInvalidations: Set<WorkspaceDirectory> = []
    private var activeExternalMutation: UUID?

    init(environmentID: EnvironmentID, rootURL: URL, rootAccessToken: (any ProjectRootAccessToken)? = nil, fileSystem: any FileTreeFileSystem = FoundationFileTreeFileSystem()) {
        self.environmentID = environmentID; self.rootURL = rootURL; self.rootAccessToken = rootAccessToken; self.fileSystem = fileSystem
        hub = FileTreeSubscriptionHub(environmentID: environmentID)
    }
    var subscriptionCount: Int { hub.count }

    func children(environmentID: EnvironmentID, at directory: WorkspaceDirectory, generation: UInt64) async throws -> FileTreeSnapshot {
        guard environmentID == self.environmentID else { throw FileTreeProviderError.environmentMismatch }
        guard generation > 0 else { throw FileTreeProviderError.zeroGeneration }
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            inFlight.insert(directory)
            var current = try await enumerate(directory); try Task.checkCancellation()
            if let previous = expanded[directory] { try commit(previous: previous, current: current, directory: directory) }
            else { expanded[directory] = current }
            while pendingInvalidations.remove(directory) != nil {
                let fresh = try await enumerate(directory); try Task.checkCancellation()
                try commit(previous: current, current: fresh, directory: directory); current = fresh
            }
            inFlight.remove(directory)
            let snapshot = try FileTreeSnapshot(validating: environmentID, directory: directory, generation: generation, revision: revision, children: current)
            await gate.release(); return snapshot
        } catch { inFlight.remove(directory); await gate.release(); throw error }
    }

    nonisolated func changes(environmentID: EnvironmentID, after revision: UInt64) -> AsyncThrowingStream<FileTreeDelta, Error> { hub.stream(environmentID: environmentID, after: revision) }

    func expandedDirectories(affectedBy invalidation: FileSystemInvalidation) -> [WorkspaceDirectory] {
        let requested: Set<WorkspaceDirectory>
        switch invalidation { case .allExpanded: requested = Set(expanded.keys).union(inFlight); case let .targeted(values): requested = Set(values) }
        pendingInvalidations.formUnion(requested.intersection(inFlight))
        return requested.filter { expanded[$0] != nil && !inFlight.contains($0) }.sorted(by: Self.directoryPrecedes)
    }

    func reconcile(_ directory: WorkspaceDirectory) async throws -> FileTreeDelta? {
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            guard let previous = expanded[directory] else { await gate.release(); return nil }
            let current = try await enumerate(directory); try Task.checkCancellation()
            let delta = try commit(previous: previous, current: current, directory: directory)
            await gate.release(); return delta
        } catch { await gate.release(); throw error }
    }

    func acquireExternalMutationLease() async throws -> ExternalMutationLease {
        try await gate.acquire()
        let lease = ExternalMutationLease(id: UUID())
        precondition(activeExternalMutation == nil)
        activeExternalMutation = lease.id
        return lease
    }

    func cancelExternalMutation(_ lease: ExternalMutationLease) async {
        guard activeExternalMutation == lease.id else { return }
        activeExternalMutation = nil
        await gate.release()
    }

    func completeExternalMutation(
        operation: FileOperation,
        physical: PhysicalFileOperationResult,
        lease: ExternalMutationLease
    ) async throws {
        guard activeExternalMutation == lease.id else {
            throw FileOperationError.invalidPath
        }
        do {
            if physical.affectedKind == .directory {
                let staleRoot: RelativePath?
                switch physical.result {
                case let .relocated(source, _): staleRoot = source
                case let .trashed(path): staleRoot = path
                case .created: staleRoot = nil
                }
                if let staleRoot {
                    let staleDirectories = expanded.keys.filter {
                        guard case let .relative(path) = $0 else { return false }
                        return path.string == staleRoot.string || path.string.hasPrefix(staleRoot.string + "/")
                    }
                    staleDirectories.forEach {
                        expanded.removeValue(forKey: $0)
                        pendingInvalidations.remove($0)
                    }
                }
            }

            let parents = Set(affectedParents(for: operation, result: physical.result))
                .sorted(by: Self.directoryPrecedes)
            for directory in parents where expanded[directory] != nil {
                let previous = expanded[directory]!
                let current = try await enumerate(directory)
                try commit(previous: previous, current: current, directory: directory)
            }
            activeExternalMutation = nil
            await gate.release()
        } catch {
            activeExternalMutation = nil
            await gate.release()
            throw error
        }
    }

    func waitUntilOperationIsQueued() async {
        while await gate.waiterCount == 0 {
            await Task.yield()
        }
    }
    func failCurrentSubscribers(_ error: FileTreeProviderError) { hub.failCurrent(error) }
    func terminateChanges(_ error: FileTreeProviderError) { hub.terminate(error) }

    private func enumerate(_ directory: WorkspaceDirectory) async throws -> [FileTreeEntry] {
        try await fileSystem.directChildren(rootURL: rootURL, directory: directory).map {
            try FileTreeEntry(validating: FileTreeEntryIdentity(validating: environmentID, path: $0.relativePath), kind: $0.kind)
        }.sorted(by: Self.entryPrecedes)
    }
    @discardableResult private func commit(previous: [FileTreeEntry], current: [FileTreeEntry], directory: WorkspaceDirectory) throws -> FileTreeDelta? {
        let mutations = Self.mutations(from: previous, to: current); expanded[directory] = current
        guard !mutations.isEmpty else { return nil }
        precondition(revision < .max); revision += 1
        let delta = try FileTreeDelta(validating: environmentID, directory: directory, revision: revision, mutations: mutations)
        hub.publish(delta); return delta
    }
    private static func mutations(from old: [FileTreeEntry], to new: [FileTreeEntry]) -> [FileTreeMutation] {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.identity, $0) }); let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.identity, $0) })
        let removes = old.filter { newByID[$0.identity] == nil }.sorted(by: rawPathPrecedes).map { FileTreeMutation.remove($0.identity) }
        let updates = new.filter { entry in oldByID[entry.identity].map { $0 != entry } ?? false }.sorted(by: rawPathPrecedes).map(FileTreeMutation.update)
        let inserts = new.filter { oldByID[$0.identity] == nil }.sorted(by: rawPathPrecedes).map(FileTreeMutation.insert)
        return removes + updates + inserts
    }
    private static func entryPrecedes(_ l: FileTreeEntry, _ r: FileTreeEntry) -> Bool {
        if (l.kind == .directory) != (r.kind == .directory) { return l.kind == .directory }
        let a = l.identity.path.string, b = r.identity.path.string, c = a.localizedStandardCompare(b); return c == .orderedSame ? a < b : c == .orderedAscending
    }
    private static func rawPathPrecedes(_ l: FileTreeEntry, _ r: FileTreeEntry) -> Bool { l.identity.path.string < r.identity.path.string }
    private static func directoryPrecedes(_ l: WorkspaceDirectory, _ r: WorkspaceDirectory) -> Bool {
        switch (l, r) { case (.root, .root): return false; case (.root, _): return true; case (_, .root): return false; case let (.relative(a), .relative(b)): let c = a.string.localizedStandardCompare(b.string); return c == .orderedSame ? a.string < b.string : c == .orderedAscending }
    }

    private func affectedParents(
        for operation: FileOperation,
        result: FileOperationResult
    ) -> [WorkspaceDirectory] {
        switch (operation, result) {
        case let (.createFile(parent, _), .created),
             let (.createDirectory(parent, _), .created):
            return [parent]
        case let (.rename(source, _), .relocated):
            return [Self.parentDirectory(of: source)]
        case let (.move(source, destinationDirectory), .relocated):
            return [Self.parentDirectory(of: source), destinationDirectory]
        case let (.trash(path), .trashed):
            return [Self.parentDirectory(of: path)]
        default:
            return []
        }
    }

    private static func parentDirectory(of path: RelativePath) -> WorkspaceDirectory {
        let components = path.string.split(separator: "/")
        guard components.count > 1 else { return .root }
        return .relative(try! RelativePath(components.dropLast().joined(separator: "/")))
    }
}

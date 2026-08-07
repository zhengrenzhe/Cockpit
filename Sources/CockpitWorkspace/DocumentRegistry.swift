import Foundation
import CockpitHostCore
import CockpitTypes

public struct DocumentInternalMutationLease: Hashable, Sendable {
    fileprivate let id: UUID
}

private enum DocumentMutationScope: Sendable {
    case all
    case relocation(source: RelativePath, destination: RelativePath)
}

private struct DocumentOpenWaiter {
    let id: UUID
    let path: RelativePath
    let continuation: CheckedContinuation<Bool, Never>
}

public actor DocumentRegistry {
    private let environmentID: EnvironmentID
    private let documentServing: any DocumentServing
    private let metadataRepository: any DocumentMetadataRepository
    private let recoveryRoot: URL
    private var byPath: [RelativePath: DocumentActor] = [:]
    private var byID: [DocumentID: DocumentActor] = [:]
    private var internalMutationLeases: [UUID: DocumentMutationScope] = [:]
    private var queuedScopes: Set<WorkspaceDirectory> = []
    private var metadataLoads: [RelativePath: Task<DocumentMetadata, Error>] = [:]
    private var actorOpens: [DocumentID: Task<DocumentActor, Error>] = [:]
    private var openWaiters: [DocumentOpenWaiter] = []

    public init(
        environmentID: EnvironmentID,
        documentServing: any DocumentServing,
        metadataRepository: any DocumentMetadataRepository,
        recoveryRoot: URL
    ) {
        self.environmentID = environmentID
        self.documentServing = documentServing
        self.metadataRepository = metadataRepository
        self.recoveryRoot = recoveryRoot.standardizedFileURL
    }

    public func open(at path: RelativePath) async throws -> DocumentActor {
        try await waitForInternalMutation(at: path)
        if let actor = byPath[path] { return actor }
        let metadataLoad: Task<DocumentMetadata, Error>
        if let existing = metadataLoads[path] {
            metadataLoad = existing
        } else {
            let environmentID = environmentID
            let metadataRepository = metadataRepository
            let created = Task {
                try await metadataRepository.findOrCreateDocument(in: environmentID, at: path)
            }
            metadataLoads[path] = created
            metadataLoad = created
        }
        let metadata: DocumentMetadata
        do {
            metadata = try await metadataLoad.value
            metadataLoads.removeValue(forKey: path)
        } catch {
            metadataLoads.removeValue(forKey: path)
            throw error
        }
        if let actor = byPath[path] { return actor }
        if let actor = byID[metadata.documentID] {
            byPath[path] = actor
            return actor
        }
        let actorOpen: Task<DocumentActor, Error>
        if let existing = actorOpens[metadata.documentID] {
            actorOpen = existing
        } else {
            let documentServing = documentServing
            let metadataRepository = metadataRepository
            let recoveryRoot = recoveryRoot
            let created = Task {
                try await DocumentActor.open(
                    metadata: metadata,
                    documentServing: documentServing,
                    recoveryLog: DocumentRecoveryLog(
                        rootURL: recoveryRoot,
                        documentID: metadata.documentID
                    ),
                    metadataRepository: metadataRepository
                )
            }
            actorOpens[metadata.documentID] = created
            actorOpen = created
        }
        let actor: DocumentActor
        do {
            actor = try await actorOpen.value
            actorOpens.removeValue(forKey: metadata.documentID)
        } catch {
            actorOpens.removeValue(forKey: metadata.documentID)
            throw error
        }
        byPath[path] = actor
        byID[metadata.documentID] = actor
        return actor
    }

    public func acquireInternalMutationLease() -> DocumentInternalMutationLease {
        let lease = DocumentInternalMutationLease(id: UUID())
        internalMutationLeases[lease.id] = .all
        return lease
    }

    public func acquireInternalMutationLease(
        from source: RelativePath,
        to destination: RelativePath
    ) -> DocumentInternalMutationLease {
        let lease = DocumentInternalMutationLease(id: UUID())
        internalMutationLeases[lease.id] = .relocation(
            source: source,
            destination: destination
        )
        return lease
    }

    public func releaseInternalMutationLease(_ lease: DocumentInternalMutationLease) async {
        guard internalMutationLeases.removeValue(forKey: lease.id) != nil else { return }
        resumeUnblockedOpens()
        guard internalMutationLeases.isEmpty, !queuedScopes.isEmpty else { return }
        let scopes = queuedScopes
        queuedScopes.removeAll()
        await reconcile(scopes: scopes)
    }

    public func handleExternalChanges(in scopes: Set<WorkspaceDirectory>) async {
        guard !scopes.isEmpty else { return }
        guard internalMutationLeases.isEmpty else {
            queuedScopes.formUnion(scopes)
            return
        }
        await reconcile(scopes: scopes)
    }

    public func relocateOpenDocuments(from source: RelativePath, to destination: RelativePath) async {
        let moves = byPath.compactMap { path, actor -> (RelativePath, RelativePath, DocumentActor)? in
            let replacement: String
            if path == source {
                replacement = destination.string
            } else if path.string.hasPrefix(source.string + "/") {
                replacement = destination.string + path.string.dropFirst(source.string.count)
            } else {
                return nil
            }
            guard let relocated = try? RelativePath(replacement) else { return nil }
            return (path, relocated, actor)
        }
        for (old, new, actor) in moves {
            byPath.removeValue(forKey: old)
            byPath[new] = actor
            await actor.updateRelativePath(new)
        }
    }

    private func reconcile(scopes: Set<WorkspaceDirectory>) async {
        let actors = byPath.filter { path, _ in
            scopes.contains(.root) || scopes.contains { scope in
                guard case let .relative(directory) = scope else { return false }
                return path == directory || path.string.hasPrefix(directory.string + "/")
            }
        }
        for (path, actor) in actors {
            do {
                let file = try await documentServing.readDocument(at: path)
                _ = try? await actor.handleExternalChange(.present(file))
            } catch {
                let value = error as NSError
                guard (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
                    || (value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoSuchFileError)
                else { continue }
                _ = try? await actor.handleExternalChange(.missing)
            }
        }
    }

    private func waitForInternalMutation(at path: RelativePath) async throws {
        while intersectsInternalMutation(path) {
            try Task.checkCancellation()
            let id = UUID()
            let resumed = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    openWaiters.append(DocumentOpenWaiter(
                        id: id,
                        path: path,
                        continuation: continuation
                    ))
                }
            } onCancel: {
                Task { await self.cancelOpenWaiter(id) }
            }
            guard resumed else { throw CancellationError() }
        }
    }

    private func cancelOpenWaiter(_ id: UUID) {
        guard let index = openWaiters.firstIndex(where: { $0.id == id }) else { return }
        openWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func resumeUnblockedOpens() {
        var remaining: [DocumentOpenWaiter] = []
        for waiter in openWaiters {
            if intersectsInternalMutation(waiter.path) {
                remaining.append(waiter)
            } else {
                waiter.continuation.resume(returning: true)
            }
        }
        openWaiters = remaining
    }

    private func intersectsInternalMutation(_ path: RelativePath) -> Bool {
        internalMutationLeases.values.contains { scope in
            switch scope {
            case .all:
                true
            case let .relocation(source, destination):
                Self.isWithin(path, scope: source) || Self.isWithin(path, scope: destination)
            }
        }
    }

    private static func isWithin(_ path: RelativePath, scope: RelativePath) -> Bool {
        path == scope || path.string.hasPrefix(scope.string + "/")
    }
}

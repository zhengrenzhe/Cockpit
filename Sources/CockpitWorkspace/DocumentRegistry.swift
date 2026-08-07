import Foundation
import CockpitHostCore
import CockpitTypes

public struct DocumentInternalMutationLease: Hashable, Sendable {
    fileprivate let id: UUID
}

public actor DocumentRegistry {
    private let environmentID: EnvironmentID
    private let documentServing: any DocumentServing
    private let metadataRepository: any DocumentMetadataRepository
    private let recoveryRoot: URL
    private var byPath: [RelativePath: DocumentActor] = [:]
    private var byID: [DocumentID: DocumentActor] = [:]
    private var internalMutationLeases: Set<UUID> = []
    private var queuedScopes: Set<WorkspaceDirectory> = []

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
        if let actor = byPath[path] { return actor }
        let metadata = try await metadataRepository.findOrCreateDocument(
            in: environmentID,
            at: path
        )
        if let actor = byID[metadata.documentID] {
            byPath[path] = actor
            return actor
        }
        let actor = try await DocumentActor.open(
            metadata: metadata,
            documentServing: documentServing,
            recoveryLog: DocumentRecoveryLog(
                rootURL: recoveryRoot,
                documentID: metadata.documentID
            ),
            metadataRepository: metadataRepository
        )
        byPath[path] = actor
        byID[metadata.documentID] = actor
        return actor
    }

    public func acquireInternalMutationLease() -> DocumentInternalMutationLease {
        let lease = DocumentInternalMutationLease(id: UUID())
        internalMutationLeases.insert(lease.id)
        return lease
    }

    public func releaseInternalMutationLease(_ lease: DocumentInternalMutationLease) async {
        guard internalMutationLeases.remove(lease.id) != nil,
              internalMutationLeases.isEmpty,
              !queuedScopes.isEmpty
        else { return }
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
}

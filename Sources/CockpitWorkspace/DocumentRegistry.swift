import Foundation
import CockpitHostCore
import CockpitProtocol
import CockpitTypes

public struct DocumentInternalMutationLease: Hashable, Sendable {
    fileprivate let id: UUID
}

private enum DocumentMutationScope: Sendable {
    case all
    case relocation(source: RelativePath, destination: RelativePath)

    func contains(_ path: RelativePath) -> Bool {
        switch self {
        case .all:
            true
        case let .relocation(source, destination):
            Self.isWithin(path, scope: source) || Self.isWithin(path, scope: destination)
        }
    }

    private static func isWithin(_ path: RelativePath, scope: RelativePath) -> Bool {
        path == scope || path.string.hasPrefix(scope.string + "/")
    }
}

private struct DocumentOpenWaiter {
    let id: UUID
    let path: RelativePath
    let continuation: CheckedContinuation<Void, Error>
}

private struct LocatorOpenFlight {
    let id: UUID
    var task: Task<Void, Never>?
    var waiters: [UUID: CheckedContinuation<DocumentActor, Error>]
}

private struct ActorOpenFlight {
    let id: UUID
    let task: Task<DocumentActor, Error>
}

private enum OpenRequestState {
    case registering
    case waiting(RelativePath)
    case completed
    case cancelled
}

public actor DocumentRegistry {
    private let environmentID: EnvironmentID
    private let documentServing: any DocumentServing
    private let metadataRepository: any DocumentMetadataRepository
    private let recoveryRoot: URL
    private var byPath: [RelativePath: DocumentActor] = [:]
    private var byID: [DocumentID: DocumentActor] = [:]
    private var internalMutationLeases: [UUID: DocumentMutationScope] = [:]
    private var mutationAcquisitionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var queuedScopes: Set<WorkspaceDirectory> = []
    private var locatorFlights: [RelativePath: LocatorOpenFlight] = [:]
    private var actorFlights: [DocumentID: ActorOpenFlight] = [:]
    private var openRequestStates: [UUID: OpenRequestState] = [:]
    private var openWaiters: [DocumentOpenWaiter] = []
    private var recoveryRequired = false

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
        try Task.checkCancellation()
        try requireOperational()
        try await waitForInternalMutation(at: path)
        try Task.checkCancellation()
        try requireOperational()
        if let actor = byPath[path] { return actor }

        let requestID = UUID()
        openRequestStates[requestID] = .registering
        defer { openRequestStates.removeValue(forKey: requestID) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerOpenRequest(requestID, path: path, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelOpenRequest(requestID) }
        }
    }

    public func acquireInternalMutationLease() async -> DocumentInternalMutationLease {
        await acquireInternalMutationLease(scope: .all)
    }

    public func acquireInternalMutationLease(
        from source: RelativePath,
        to destination: RelativePath
    ) async -> DocumentInternalMutationLease {
        await acquireInternalMutationLease(scope: .relocation(
            source: source,
            destination: destination
        ))
    }

    public func releaseInternalMutationLease(_ lease: DocumentInternalMutationLease) async {
        guard internalMutationLeases.removeValue(forKey: lease.id) != nil else { return }
        resumeMutationAcquisitions()
        resumeUnblockedOpens()
        guard internalMutationLeases.isEmpty, !queuedScopes.isEmpty else { return }
        let scopes = queuedScopes
        queuedScopes.removeAll()
        await reconcile(scopes: scopes)
    }

    public func failInternalMutationLease(_ lease: DocumentInternalMutationLease) {
        guard internalMutationLeases.removeValue(forKey: lease.id) != nil else { return }
        recoveryRequired = true
        let acquisitionWaiters = mutationAcquisitionWaiters.values
        mutationAcquisitionWaiters.removeAll()
        acquisitionWaiters.forEach { $0.resume() }
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(throwing: DocumentProtocolError.recoveryRequired) }
    }

    public func handleExternalChanges(in scopes: Set<WorkspaceDirectory>) async {
        guard !scopes.isEmpty else { return }
        guard !recoveryRequired, internalMutationLeases.isEmpty else {
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

    private func registerOpenRequest(
        _ requestID: UUID,
        path: RelativePath,
        continuation: CheckedContinuation<DocumentActor, Error>
    ) {
        if case .cancelled = openRequestStates[requestID] {
            continuation.resume(throwing: CancellationError())
            return
        }
        if recoveryRequired {
            openRequestStates[requestID] = .completed
            continuation.resume(throwing: DocumentProtocolError.recoveryRequired)
            return
        }
        if let actor = byPath[path] {
            openRequestStates[requestID] = .completed
            continuation.resume(returning: actor)
            return
        }
        openRequestStates[requestID] = .waiting(path)
        if var flight = locatorFlights[path] {
            flight.waiters[requestID] = continuation
            locatorFlights[path] = flight
            return
        }

        let flightID = UUID()
        locatorFlights[path] = LocatorOpenFlight(
            id: flightID,
            task: nil,
            waiters: [requestID: continuation]
        )
        let task = Task { await self.runLocatorFlight(path: path, flightID: flightID) }
        locatorFlights[path]?.task = task
    }

    private func cancelOpenRequest(_ requestID: UUID) {
        guard let state = openRequestStates[requestID] else { return }
        switch state {
        case .registering:
            openRequestStates[requestID] = .cancelled
        case let .waiting(path):
            guard var flight = locatorFlights[path],
                  let continuation = flight.waiters.removeValue(forKey: requestID)
            else { return }
            openRequestStates[requestID] = .completed
            continuation.resume(throwing: CancellationError())
            if flight.waiters.isEmpty {
                locatorFlights.removeValue(forKey: path)
                flight.task?.cancel()
                resumeMutationAcquisitions()
            } else {
                locatorFlights[path] = flight
            }
        case .completed, .cancelled:
            return
        }
    }

    private func runLocatorFlight(path: RelativePath, flightID: UUID) async {
        let result: Result<DocumentActor, Error>
        do {
            result = .success(try await performOpen(path: path, flightID: flightID))
        } catch {
            result = .failure(error)
        }
        completeLocatorFlight(path: path, flightID: flightID, result: result)
    }

    private func performOpen(path: RelativePath, flightID: UUID) async throws -> DocumentActor {
        let metadata = try await metadataRepository.findOrCreateDocument(
            in: environmentID,
            at: path
        )
        try Task.checkCancellation()
        guard locatorFlights[path]?.id == flightID else { throw CancellationError() }
        if let actor = byPath[path] { return actor }
        if let actor = byID[metadata.documentID] { return actor }

        let actorFlight: ActorOpenFlight
        if let existing = actorFlights[metadata.documentID] {
            actorFlight = existing
        } else {
            let documentServing = documentServing
            let metadataRepository = metadataRepository
            let recoveryRoot = recoveryRoot
            let id = UUID()
            let task = Task {
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
            actorFlight = ActorOpenFlight(id: id, task: task)
            actorFlights[metadata.documentID] = actorFlight
        }
        let actor: DocumentActor
        do {
            actor = try await actorFlight.task.value
        } catch {
            if actorFlights[metadata.documentID]?.id == actorFlight.id {
                actorFlights.removeValue(forKey: metadata.documentID)
            }
            throw error
        }
        if actorFlights[metadata.documentID]?.id == actorFlight.id {
            actorFlights.removeValue(forKey: metadata.documentID)
        }
        try Task.checkCancellation()
        guard locatorFlights[path]?.id == flightID else { throw CancellationError() }
        if let existing = byPath[path] { return existing }
        if let existing = byID[metadata.documentID] { return existing }
        byPath[path] = actor
        byID[metadata.documentID] = actor
        return actor
    }

    private func completeLocatorFlight(
        path: RelativePath,
        flightID: UUID,
        result: Result<DocumentActor, Error>
    ) {
        guard let flight = locatorFlights[path], flight.id == flightID else { return }
        locatorFlights.removeValue(forKey: path)
        for (requestID, continuation) in flight.waiters {
            openRequestStates[requestID] = .completed
            continuation.resume(with: result)
        }
        resumeMutationAcquisitions()
    }

    private func acquireInternalMutationLease(
        scope: DocumentMutationScope
    ) async -> DocumentInternalMutationLease {
        let lease = DocumentInternalMutationLease(id: UUID())
        internalMutationLeases[lease.id] = scope
        if hasActiveFlight(intersecting: scope) {
            await withCheckedContinuation { mutationAcquisitionWaiters[lease.id] = $0 }
        }
        return lease
    }

    private func resumeMutationAcquisitions() {
        for (leaseID, continuation) in mutationAcquisitionWaiters {
            guard let scope = internalMutationLeases[leaseID],
                  !hasActiveFlight(intersecting: scope)
            else { continue }
            mutationAcquisitionWaiters.removeValue(forKey: leaseID)
            continuation.resume()
        }
    }

    private func hasActiveFlight(intersecting scope: DocumentMutationScope) -> Bool {
        locatorFlights.keys.contains { scope.contains($0) }
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
        try requireOperational()
        while intersectsInternalMutation(path) {
            try Task.checkCancellation()
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    openWaiters.append(DocumentOpenWaiter(
                        id: id,
                        path: path,
                        continuation: continuation
                    ))
                }
            } onCancel: {
                Task { await self.cancelOpenWaiter(id) }
            }
            try requireOperational()
        }
    }

    private func cancelOpenWaiter(_ id: UUID) {
        guard let index = openWaiters.firstIndex(where: { $0.id == id }) else { return }
        openWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resumeUnblockedOpens() {
        var remaining: [DocumentOpenWaiter] = []
        for waiter in openWaiters {
            if intersectsInternalMutation(waiter.path) {
                remaining.append(waiter)
            } else {
                waiter.continuation.resume()
            }
        }
        openWaiters = remaining
    }

    private func intersectsInternalMutation(_ path: RelativePath) -> Bool {
        internalMutationLeases.values.contains { $0.contains(path) }
    }

    private func requireOperational() throws {
        if recoveryRequired { throw DocumentProtocolError.recoveryRequired }
    }
}

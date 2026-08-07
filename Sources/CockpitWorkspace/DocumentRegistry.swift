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
    let barrierEpoch: UInt64
    var task: Task<Void, Never>?
    var waiters: [UUID: CheckedContinuation<DocumentActor, Error>]
    var actorFlight: ActorFlightReference?
}

private struct ActorOpenFlight {
    let id: UUID
    let task: Task<DocumentActor, Error>
    var owners: Set<LocatorFlightIdentity>
}

private struct ActorRetirementWaiter {
    let reference: ActorFlightReference
    let continuation: CheckedContinuation<Void, Error>
}

private struct LocatorFlightIdentity: Hashable, Sendable {
    let path: RelativePath
    let id: UUID
}

private struct ActorFlightReference: Hashable, Sendable {
    let documentID: DocumentID
    let id: UUID
}

private struct ActiveActorOpenWork: Sendable {
    var paths: Set<RelativePath>
}

private struct InternalMutationLeaseState: Sendable {
    let scope: DocumentMutationScope
    let epoch: UInt64
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
    private var internalMutationLeases: [UUID: InternalMutationLeaseState] = [:]
    private var mutationAcquisitionWaiters: [
        UUID: CheckedContinuation<DocumentInternalMutationLease, Error>
    ] = [:]
    private var mutationEpoch: UInt64 = 0
    private var queuedScopes: Set<WorkspaceDirectory> = []
    private var locatorFlights: [RelativePath: LocatorOpenFlight] = [:]
    private var actorFlights: [DocumentID: ActorOpenFlight] = [:]
    private var retirementWaiters: [LocatorFlightIdentity: ActorRetirementWaiter] = [:]
    private var activeActorOpenWork: [UUID: ActiveActorOpenWork] = [:]
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

    public func document(id: DocumentID) -> DocumentActor? {
        byID[id]
    }

    public func acquireInternalMutationLease() async throws -> DocumentInternalMutationLease {
        try await acquireInternalMutationLease(scope: .all)
    }

    public func acquireInternalMutationLease(
        from source: RelativePath,
        to destination: RelativePath
    ) async throws -> DocumentInternalMutationLease {
        try await acquireInternalMutationLease(scope: .relocation(
            source: source,
            destination: destination
        ))
    }

    public func releaseInternalMutationLease(_ lease: DocumentInternalMutationLease) async {
        guard internalMutationLeases.removeValue(forKey: lease.id) != nil else { return }
        await finishInternalMutationLeaseRemoval()
    }

    public func failInternalMutationLease(_ lease: DocumentInternalMutationLease) {
        guard internalMutationLeases.removeValue(forKey: lease.id) != nil else { return }
        recoveryRequired = true
        let acquisitionWaiters = mutationAcquisitionWaiters
        mutationAcquisitionWaiters.removeAll()
        for (leaseID, continuation) in acquisitionWaiters {
            internalMutationLeases.removeValue(forKey: leaseID)
            continuation.resume(throwing: DocumentProtocolError.recoveryRequired)
        }
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
            barrierEpoch: mutationEpoch,
            task: nil,
            waiters: [requestID: continuation],
            actorFlight: nil
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
                if let actorFlight = flight.actorFlight {
                    detachActorFlightOwner(
                        LocatorFlightIdentity(path: path, id: flight.id),
                        from: actorFlight
                    )
                }
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
        let owner = LocatorFlightIdentity(path: path, id: flightID)
        while true {
            try Task.checkCancellation()
            try requireOperational()
            guard let locatorFlight = locatorFlights[path], locatorFlight.id == flightID else {
                throw CancellationError()
            }
            try validatePublication(at: path, locatorBarrierEpoch: locatorFlight.barrierEpoch)
            if let actor = byPath[path] { return actor }
            if let actor = byID[metadata.documentID] { return actor }

            var actorFlight: ActorOpenFlight
            if var existing = actorFlights[metadata.documentID] {
                if existing.owners.isEmpty {
                    let retiringReference = ActorFlightReference(
                        documentID: metadata.documentID,
                        id: existing.id
                    )
                    guard var currentLocatorFlight = locatorFlights[path],
                          currentLocatorFlight.id == flightID
                    else { throw CancellationError() }
                    currentLocatorFlight.actorFlight = retiringReference
                    locatorFlights[path] = currentLocatorFlight
                    try await waitForActorRetirement(owner, from: retiringReference)
                    continue
                }
                existing.owners.insert(owner)
                actorFlights[metadata.documentID] = existing
                activeActorOpenWork[existing.id]?.paths.insert(path)
                actorFlight = existing
            } else {
                let documentServing = documentServing
                let metadataRepository = metadataRepository
                let recoveryRoot = recoveryRoot
                let id = UUID()
                let task = Task {
                    try Task.checkCancellation()
                    let actor = try await DocumentActor.open(
                        metadata: metadata,
                        documentServing: documentServing,
                        recoveryLog: DocumentRecoveryLog(
                            rootURL: recoveryRoot,
                            documentID: metadata.documentID
                        ),
                        metadataRepository: metadataRepository
                    )
                    try Task.checkCancellation()
                    return actor
                }
                actorFlight = ActorOpenFlight(id: id, task: task, owners: [owner])
                actorFlights[metadata.documentID] = actorFlight
                activeActorOpenWork[id] = ActiveActorOpenWork(paths: [path])
            }
            guard var currentLocatorFlight = locatorFlights[path],
                  currentLocatorFlight.id == flightID
            else {
                detachActorFlightOwner(
                    owner,
                    from: ActorFlightReference(documentID: metadata.documentID, id: actorFlight.id)
                )
                throw CancellationError()
            }
            let actorReference = ActorFlightReference(
                documentID: metadata.documentID,
                id: actorFlight.id
            )
            currentLocatorFlight.actorFlight = actorReference
            locatorFlights[path] = currentLocatorFlight

            let actor: DocumentActor
            do {
                actor = try await actorFlight.task.value
            } catch {
                finishActorOpenWork(actorReference)
                throw error
            }
            finishActorOpenWork(actorReference)
            try Task.checkCancellation()
            try requireOperational()
            guard let publishingFlight = locatorFlights[path], publishingFlight.id == flightID else {
                throw CancellationError()
            }
            try validatePublication(
                at: path,
                locatorBarrierEpoch: publishingFlight.barrierEpoch
            )
            if let existing = byPath[path] { return existing }
            if let existing = byID[metadata.documentID] { return existing }
            byPath[path] = actor
            byID[metadata.documentID] = actor
            return actor
        }
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
    ) async throws -> DocumentInternalMutationLease {
        try Task.checkCancellation()
        try requireOperational()
        mutationEpoch += 1
        let lease = DocumentInternalMutationLease(id: UUID())
        internalMutationLeases[lease.id] = InternalMutationLeaseState(
            scope: scope,
            epoch: mutationEpoch
        )
        guard hasActiveFlight(intersecting: scope) else {
            do {
                try Task.checkCancellation()
                return lease
            } catch {
                await abandonInternalMutationLease(lease.id)
                throw error
            }
        }
        do {
            let acquired = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    mutationAcquisitionWaiters[lease.id] = continuation
                }
            } onCancel: {
                Task { await self.cancelMutationAcquisition(lease.id) }
            }
            try Task.checkCancellation()
            try requireOperational()
            return acquired
        } catch {
            await abandonInternalMutationLease(lease.id)
            throw error
        }
    }

    private func resumeMutationAcquisitions() {
        guard !recoveryRequired else { return }
        let ready = mutationAcquisitionWaiters.compactMap {
            leaseID, continuation -> (UUID, CheckedContinuation<DocumentInternalMutationLease, Error>)? in
            guard let state = internalMutationLeases[leaseID],
                  !hasActiveFlight(intersecting: state.scope)
            else { return nil }
            return (leaseID, continuation)
        }
        for (leaseID, continuation) in ready {
            mutationAcquisitionWaiters.removeValue(forKey: leaseID)
            continuation.resume(returning: DocumentInternalMutationLease(id: leaseID))
        }
    }

    private func hasActiveFlight(intersecting scope: DocumentMutationScope) -> Bool {
        locatorFlights.keys.contains { scope.contains($0) }
            || activeActorOpenWork.values.contains { work in
                work.paths.contains { scope.contains($0) }
            }
    }

    private func detachActorFlightOwner(
        _ owner: LocatorFlightIdentity,
        from reference: ActorFlightReference
    ) {
        cancelActorRetirementWaiter(owner, from: reference)
        guard var actorFlight = actorFlights[reference.documentID],
              actorFlight.id == reference.id
        else { return }
        let removedOwner = actorFlight.owners.remove(owner) != nil
        actorFlights[reference.documentID] = actorFlight
        guard removedOwner, actorFlight.owners.isEmpty else { return }

        actorFlight.task.cancel()
        let task = actorFlight.task
        Task {
            _ = await task.result
            self.completeActorRetirement(reference)
        }
    }

    private func finishActorOpenWork(_ reference: ActorFlightReference) {
        guard let actorFlight = actorFlights[reference.documentID],
              actorFlight.id == reference.id
        else {
            activeActorOpenWork.removeValue(forKey: reference.id)
            resumeMutationAcquisitions()
            return
        }
        guard !actorFlight.owners.isEmpty else { return }
        actorFlights.removeValue(forKey: reference.documentID)
        activeActorOpenWork.removeValue(forKey: reference.id)
        resumeMutationAcquisitions()
    }

    private func waitForActorRetirement(
        _ owner: LocatorFlightIdentity,
        from reference: ActorFlightReference
    ) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerActorRetirementWaiter(
                    owner,
                    from: reference,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelActorRetirementWaiter(owner, from: reference) }
        }
        try Task.checkCancellation()
    }

    private func registerActorRetirementWaiter(
        _ owner: LocatorFlightIdentity,
        from reference: ActorFlightReference,
        continuation: CheckedContinuation<Void, Error>
    ) {
        guard let locatorFlight = locatorFlights[owner.path],
              locatorFlight.id == owner.id
        else {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard let actorFlight = actorFlights[reference.documentID],
              actorFlight.id == reference.id,
              actorFlight.owners.isEmpty
        else {
            continuation.resume()
            return
        }
        guard retirementWaiters[owner] == nil else {
            continuation.resume(throwing: CancellationError())
            return
        }
        retirementWaiters[owner] = ActorRetirementWaiter(
            reference: reference,
            continuation: continuation
        )
    }

    private func cancelActorRetirementWaiter(
        _ owner: LocatorFlightIdentity,
        from reference: ActorFlightReference
    ) {
        guard retirementWaiters[owner]?.reference == reference,
              let waiter = retirementWaiters.removeValue(forKey: owner)
        else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func completeActorRetirement(_ reference: ActorFlightReference) {
        guard let actorFlight = actorFlights[reference.documentID],
              actorFlight.id == reference.id,
              actorFlight.owners.isEmpty
        else { return }

        actorFlights.removeValue(forKey: reference.documentID)
        activeActorOpenWork.removeValue(forKey: reference.id)
        let waiters = retirementWaiters.filter { $0.value.reference == reference }
        for (owner, waiter) in waiters {
            retirementWaiters.removeValue(forKey: owner)
            waiter.continuation.resume()
        }
        resumeMutationAcquisitions()
    }

    private func validatePublication(
        at path: RelativePath,
        locatorBarrierEpoch: UInt64
    ) throws {
        let predatesFlight = internalMutationLeases.values.contains { state in
            state.scope.contains(path) && state.epoch <= locatorBarrierEpoch
        }
        if predatesFlight { throw CancellationError() }
    }

    private func cancelMutationAcquisition(_ leaseID: UUID) async {
        guard let continuation = mutationAcquisitionWaiters.removeValue(forKey: leaseID) else {
            return
        }
        let removed = internalMutationLeases.removeValue(forKey: leaseID) != nil
        continuation.resume(throwing: CancellationError())
        if removed { await finishInternalMutationLeaseRemoval() }
    }

    private func abandonInternalMutationLease(_ leaseID: UUID) async {
        guard internalMutationLeases.removeValue(forKey: leaseID) != nil else { return }
        await finishInternalMutationLeaseRemoval()
    }

    private func finishInternalMutationLeaseRemoval() async {
        resumeMutationAcquisitions()
        resumeUnblockedOpens()
        guard !recoveryRequired,
              internalMutationLeases.isEmpty,
              !queuedScopes.isEmpty
        else { return }
        let scopes = queuedScopes
        queuedScopes.removeAll()
        await reconcile(scopes: scopes)
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
        internalMutationLeases.values.contains { $0.scope.contains(path) }
    }

    private func requireOperational() throws {
        if recoveryRequired { throw DocumentProtocolError.recoveryRequired }
    }
}

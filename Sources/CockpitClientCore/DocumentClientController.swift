import Foundation
import CockpitProtocol
import CockpitTypes

public enum DocumentClientControllerState: Hashable, Sendable {
    case closed
    case ready(DocumentSnapshot)
    case readOnly(DocumentSnapshot)
    case resynchronizing
}

public actor DocumentClientController {
    private struct PendingEdit {
        let id: UUID
        let order: UInt64
        let changes: [UTF16TextEdit]
        let continuation: CheckedContinuation<EditAcknowledgement, Error>
    }

    private struct InFlightEdit {
        let pending: PendingEdit
        let transaction: EditTransaction
    }

    private struct ControlWaiter {
        let id: UUID
        let order: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private enum SubmitRequestState {
        case registering
        case queued
        case inFlight
        case completed
        case cancelled
    }

    private enum ControlRequestState {
        case registering
        case queued
        case active
        case completed
        case cancelled
    }

    public private(set) var state: DocumentClientControllerState = .closed

    private let clientInstanceID: ClientInstanceID
    private let transport: any DocumentDataTransport
    private var environmentID: EnvironmentID?
    private var path: RelativePath?
    private var authoritativeSnapshot: DocumentSnapshot?
    private var lease: EditLease?
    private var pendingEdits: [PendingEdit] = []
    private var inFlight: InFlightEdit?
    private var sendTask: Task<Void, Never>?
    private var controlWaiters: [ControlWaiter] = []
    private var activeControlID: UUID?
    private var submitRequestStates: [UUID: SubmitRequestState] = [:]
    private var controlRequestStates: [UUID: ControlRequestState] = [:]
    private var nextOperationOrder: UInt64 = 0

    public init(
        clientInstanceID: ClientInstanceID,
        transport: any DocumentDataTransport
    ) {
        self.clientInstanceID = clientInstanceID
        self.transport = transport
    }

    @discardableResult
    public func open(
        in environmentID: EnvironmentID,
        at path: RelativePath,
        requestWriteAccess: Bool
    ) async throws -> DocumentSnapshot {
        let controlID = try await acquireControl()
        defer { releaseControl(controlID) }
        try Task.checkCancellation()
        let snapshot = try await transport.openDocument(in: environmentID, at: path)
        try Task.checkCancellation()
        self.environmentID = environmentID
        self.path = path
        authoritativeSnapshot = snapshot
        if requestWriteAccess {
            let acquired = try await transport.acquireEditLease(
                documentID: snapshot.documentID,
                client: clientInstanceID
            )
            try Task.checkCancellation()
            lease = acquired
            let ready = try snapshotWithLease(snapshot, lease: acquired)
            authoritativeSnapshot = ready
            state = .ready(ready)
        } else {
            lease = nil
            state = .readOnly(snapshot)
        }
        return snapshot
    }

    public func submit(_ changes: [UTF16TextEdit]) async throws -> EditAcknowledgement {
        try Task.checkCancellation()
        let id = UUID()
        submitRequestStates[id] = .registering
        defer { submitRequestStates.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EditAcknowledgement, Error>) in
                enqueue(PendingEdit(
                    id: id,
                    order: takeOperationOrder(),
                    changes: changes,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelSubmit(id) }
        }
    }

    public func flush() async throws -> UInt64 {
        try requireReady()
        let controlID = try await acquireControl()
        defer { releaseControl(controlID) }
        try Task.checkCancellation()
        try requireReady()
        return try await flushTransport()
    }

    @discardableResult
    public func resynchronize(requestWriteAccess: Bool) async throws -> DocumentSnapshot {
        guard let current = authoritativeSnapshot else {
            throw DocumentProtocolError.invalidValue
        }
        let controlID = try await acquireControl()
        defer { releaseControl(controlID) }
        try Task.checkCancellation()
        let replacement = try await transport.snapshot(documentID: current.documentID)
        try Task.checkCancellation()
        if requestWriteAccess {
            let acquired = try await transport.acquireEditLease(
                documentID: replacement.documentID,
                client: clientInstanceID
            )
            try Task.checkCancellation()
            lease = acquired
            let ready = try snapshotWithLease(replacement, lease: acquired)
            authoritativeSnapshot = ready
            state = .ready(ready)
        } else {
            lease = nil
            authoritativeSnapshot = replacement
            state = .readOnly(replacement)
        }
        return replacement
    }

    @discardableResult
    public func save(expectedFingerprint: DiskFingerprint) async throws -> DocumentSnapshot {
        try requireReady()
        let controlID = try await acquireControl()
        defer { releaseControl(controlID) }
        try Task.checkCancellation()
        try requireReady()
        _ = try await flushTransport()
        try Task.checkCancellation()
        guard let current = authoritativeSnapshot else { throw DocumentProtocolError.invalidValue }
        do {
            let replacement = try await transport.save(
                documentID: current.documentID,
                expectedFingerprint: expectedFingerprint
            )
            if Task.isCancelled {
                enterResynchronizing()
                throw CancellationError()
            }
            let ready = try snapshotWithLease(replacement, lease: lease)
            authoritativeSnapshot = ready
            state = .ready(ready)
            return replacement
        } catch {
            enterResynchronizing()
            throw error
        }
    }

    @discardableResult
    public func discard() async throws -> DocumentSnapshot {
        if case .resynchronizing = state { throw DocumentProtocolError.resynchronizing }
        if case .closed = state { throw DocumentProtocolError.invalidValue }
        let controlID = try await acquireControl()
        defer { releaseControl(controlID) }
        try Task.checkCancellation()
        if case .resynchronizing = state { throw DocumentProtocolError.resynchronizing }
        guard let current = authoritativeSnapshot else { throw DocumentProtocolError.invalidValue }
        do {
            let replacement = try await transport.discard(documentID: current.documentID)
            if Task.isCancelled {
                enterResynchronizing()
                throw CancellationError()
            }
            if let lease {
                let ready = try snapshotWithLease(replacement, lease: lease)
                authoritativeSnapshot = ready
                state = .ready(ready)
            } else {
                authoritativeSnapshot = replacement
                state = .readOnly(replacement)
            }
            return replacement
        } catch {
            enterResynchronizing()
            throw error
        }
    }

    private func enqueue(_ pending: PendingEdit) {
        if case .cancelled = submitRequestStates[pending.id] {
            submitRequestStates[pending.id] = .completed
            pending.continuation.resume(throwing: CancellationError())
            return
        }
        do {
            try requireReady()
        } catch {
            submitRequestStates[pending.id] = .completed
            pending.continuation.resume(throwing: error)
            return
        }
        submitRequestStates[pending.id] = .queued
        pendingEdits.append(pending)
        scheduleNextOperation()
    }

    private func scheduleNextOperation() {
        guard sendTask == nil, inFlight == nil, activeControlID == nil else { return }
        let nextEdit = pendingEdits.first
        let nextControl = controlWaiters.first

        if let nextControl,
           nextEdit == nil
            || nextControl.order < nextEdit!.order
            || !isReadyState {
            controlWaiters.removeFirst()
            activeControlID = nextControl.id
            controlRequestStates[nextControl.id] = .active
            nextControl.continuation.resume()
            return
        }
        guard nextEdit != nil, isReadyState else { return }
        sendTask = Task { await self.sendNext() }
    }

    private func sendNext() async {
        guard inFlight == nil,
              !pendingEdits.isEmpty,
              activeControlID == nil,
              case .ready = state,
              let snapshot = authoritativeSnapshot,
              let lease
        else {
            sendTask = nil
            scheduleNextOperation()
            return
        }
        let pending = pendingEdits.removeFirst()
        submitRequestStates[pending.id] = .inFlight
        let transaction: EditTransaction
        do {
            transaction = try EditTransaction(
                validatingDocumentID: snapshot.documentID,
                editLeaseID: lease.id,
                baseVersion: snapshot.documentVersion,
                clientSequence: snapshot.lastAcceptedClientSequence + 1,
                changes: pending.changes
            )
        } catch {
            submitRequestStates[pending.id] = .completed
            pending.continuation.resume(throwing: error)
            sendTask = nil
            scheduleNextOperation()
            return
        }
        let current = InFlightEdit(pending: pending, transaction: transaction)
        inFlight = current
        var retriedAfterTransientFailure = false
        do {
            let acknowledgement: EditAcknowledgement
            do {
                acknowledgement = try await transport.apply(transaction)
            } catch {
                guard !Self.isAuthoritative(error), !(error is CancellationError) else {
                    throw error
                }
                retriedAfterTransientFailure = true
                acknowledgement = try await transport.apply(transaction)
            }
            let updated = try DocumentSnapshot(
                validatingDocumentID: snapshot.documentID,
                environmentID: snapshot.environmentID,
                relativePath: snapshot.relativePath,
                text: snapshot.text,
                documentVersion: acknowledgement.documentVersion,
                persistedVersion: snapshot.persistedVersion,
                lastAcceptedClientSequence: acknowledgement.clientSequence,
                dirtyState: .dirty,
                observedDiskFingerprint: snapshot.observedDiskFingerprint,
                currentLease: lease,
                maintenance: snapshot.maintenance
            )
            authoritativeSnapshot = updated
            state = .ready(updated)
            inFlight = nil
            submitRequestStates[current.pending.id] = .completed
            current.pending.continuation.resume(returning: acknowledgement)
        } catch {
            inFlight = nil
            submitRequestStates[current.pending.id] = .completed
            current.pending.continuation.resume(throwing: error)
            if Self.isAuthoritative(error)
                || retriedAfterTransientFailure
                || error is CancellationError {
                enterResynchronizing()
            }
        }
        sendTask = nil
        scheduleNextOperation()
    }

    private func cancelSubmit(_ id: UUID) {
        guard let requestState = submitRequestStates[id] else { return }
        switch requestState {
        case .registering:
            submitRequestStates[id] = .cancelled
        case .queued:
            guard let index = pendingEdits.firstIndex(where: { $0.id == id }) else { return }
            let pending = pendingEdits.remove(at: index)
            submitRequestStates[id] = .completed
            pending.continuation.resume(throwing: CancellationError())
            scheduleNextOperation()
        case .inFlight, .completed, .cancelled:
            return
        }
    }

    private func acquireControl() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        controlRequestStates[id] = .registering
        defer { controlRequestStates.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if case .cancelled = controlRequestStates[id] {
                    controlRequestStates[id] = .completed
                    continuation.resume(throwing: CancellationError())
                    return
                }
                controlRequestStates[id] = .queued
                controlWaiters.append(ControlWaiter(
                    id: id,
                    order: takeOperationOrder(),
                    continuation: continuation
                ))
                scheduleNextOperation()
            }
        } onCancel: {
            Task { await self.cancelControl(id) }
        }
        return id
    }

    private func cancelControl(_ id: UUID) {
        guard let requestState = controlRequestStates[id] else { return }
        switch requestState {
        case .registering:
            controlRequestStates[id] = .cancelled
        case .queued:
            guard let index = controlWaiters.firstIndex(where: { $0.id == id }) else { return }
            let waiter = controlWaiters.remove(at: index)
            controlRequestStates[id] = .completed
            waiter.continuation.resume(throwing: CancellationError())
            scheduleNextOperation()
        case .active, .completed, .cancelled:
            return
        }
    }

    private func releaseControl(_ id: UUID) {
        guard activeControlID == id else { return }
        activeControlID = nil
        scheduleNextOperation()
    }

    private func flushTransport() async throws -> UInt64 {
        try requireReady()
        guard let snapshot = authoritativeSnapshot else { throw DocumentProtocolError.invalidValue }
        do {
            return try await transport.flush(
                documentID: snapshot.documentID,
                through: snapshot.lastAcceptedClientSequence
            )
        } catch {
            if Self.isAuthoritative(error) { enterResynchronizing() }
            throw error
        }
    }

    private func enterResynchronizing() {
        state = .resynchronizing
    }

    private func requireReady() throws {
        switch state {
        case .ready:
            guard lease != nil, authoritativeSnapshot != nil else {
                throw DocumentProtocolError.invalidLease
            }
        case .readOnly:
            throw DocumentProtocolError.readOnly
        case .resynchronizing:
            throw DocumentProtocolError.resynchronizing
        case .closed:
            throw DocumentProtocolError.invalidValue
        }
    }

    private var isReadyState: Bool {
        if case .ready = state { return true }
        return false
    }

    private func takeOperationOrder() -> UInt64 {
        let value = nextOperationOrder
        nextOperationOrder += 1
        return value
    }

    private func snapshotWithLease(
        _ snapshot: DocumentSnapshot,
        lease: EditLease?
    ) throws -> DocumentSnapshot {
        try DocumentSnapshot(
            validatingDocumentID: snapshot.documentID,
            environmentID: snapshot.environmentID,
            relativePath: snapshot.relativePath,
            text: snapshot.text,
            documentVersion: snapshot.documentVersion,
            persistedVersion: snapshot.persistedVersion,
            lastAcceptedClientSequence: snapshot.lastAcceptedClientSequence,
            dirtyState: snapshot.dirtyState,
            observedDiskFingerprint: snapshot.observedDiskFingerprint,
            currentLease: lease,
            maintenance: snapshot.maintenance
        )
    }

    private static func isAuthoritative(_ error: any Error) -> Bool {
        guard let error = error as? DocumentProtocolError else { return false }
        switch error {
        case .invalidLease, .leaseHeld, .baseVersionMismatch, .sequenceGap,
             .duplicateMismatch, .staleSequence, .recoveryRequired:
            return true
        case .invalidValue, .unknownFields, .resynchronizing, .readOnly, .fileMissing:
            return false
        }
    }
}

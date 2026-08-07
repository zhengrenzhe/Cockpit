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
        let changes: [UTF16TextEdit]
        let continuation: CheckedContinuation<EditAcknowledgement, Error>
    }

    private struct InFlightEdit {
        let pending: PendingEdit
        let transaction: EditTransaction
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
    private var cancelledRequestIDs: Set<UUID> = []
    private var drainWaiters: [CheckedContinuation<Void, Error>] = []

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
        let snapshot = try await transport.openDocument(in: environmentID, at: path)
        self.environmentID = environmentID
        self.path = path
        authoritativeSnapshot = snapshot
        if requestWriteAccess {
            let acquired = try await transport.acquireEditLease(
                documentID: snapshot.documentID,
                client: clientInstanceID
            )
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
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(PendingEdit(id: id, changes: changes, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelQueuedEdit(id) }
        }
    }

    public func flush() async throws -> UInt64 {
        try requireReady()
        try await waitForDrain()
        return try await flushTransport()
    }

    @discardableResult
    public func resynchronize(requestWriteAccess: Bool) async throws -> DocumentSnapshot {
        guard let current = authoritativeSnapshot else {
            throw DocumentProtocolError.invalidValue
        }
        let replacement = try await transport.snapshot(documentID: current.documentID)
        if requestWriteAccess {
            let acquired = try await transport.acquireEditLease(
                documentID: replacement.documentID,
                client: clientInstanceID
            )
            lease = acquired
            let ready = try snapshotWithLease(replacement, lease: acquired)
            authoritativeSnapshot = ready
            state = .ready(ready)
            startSendingIfPossible()
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
        try await waitForDrain()
        _ = try await flushTransport()
        guard let current = authoritativeSnapshot else { throw DocumentProtocolError.invalidValue }
        do {
            let replacement = try await transport.save(
                documentID: current.documentID,
                expectedFingerprint: expectedFingerprint
            )
            let ready = try snapshotWithLease(replacement, lease: lease)
            authoritativeSnapshot = ready
            state = .ready(ready)
            return replacement
        } catch {
            if Self.isAuthoritative(error) { enterResynchronizing() }
            throw error
        }
    }

    @discardableResult
    public func discard() async throws -> DocumentSnapshot {
        if case .resynchronizing = state { throw DocumentProtocolError.resynchronizing }
        if case .closed = state { throw DocumentProtocolError.invalidValue }
        if case .ready = state { try await waitForDrain() }
        guard let current = authoritativeSnapshot else { throw DocumentProtocolError.invalidValue }
        let replacement = try await transport.discard(documentID: current.documentID)
        if let lease {
            let ready = try snapshotWithLease(replacement, lease: lease)
            authoritativeSnapshot = ready
            state = .ready(ready)
        } else {
            authoritativeSnapshot = replacement
            state = .readOnly(replacement)
        }
        return replacement
    }

    private func enqueue(_ pending: PendingEdit) {
        if cancelledRequestIDs.remove(pending.id) != nil {
            pending.continuation.resume(throwing: CancellationError())
            return
        }
        do {
            try requireReady()
        } catch {
            pending.continuation.resume(throwing: error)
            return
        }
        pendingEdits.append(pending)
        startSendingIfPossible()
    }

    private func startSendingIfPossible() {
        guard sendTask == nil,
              inFlight == nil,
              !pendingEdits.isEmpty,
              case .ready = state
        else { return }
        sendTask = Task { await self.sendNext() }
    }

    private func sendNext() async {
        guard inFlight == nil,
              !pendingEdits.isEmpty,
              case .ready = state,
              let snapshot = authoritativeSnapshot,
              let lease
        else {
            sendTask = nil
            finishDrainIfPossible()
            return
        }
        let pending = pendingEdits.removeFirst()
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
            pending.continuation.resume(throwing: error)
            sendTask = nil
            startSendingIfPossible()
            return
        }
        let current = InFlightEdit(pending: pending, transaction: transaction)
        inFlight = current
        do {
            let acknowledgement: EditAcknowledgement
            do {
                acknowledgement = try await transport.apply(transaction)
            } catch {
                guard !Self.isAuthoritative(error), !(error is CancellationError) else {
                    throw error
                }
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
            current.pending.continuation.resume(returning: acknowledgement)
        } catch {
            inFlight = nil
            current.pending.continuation.resume(throwing: error)
            if Self.isAuthoritative(error) { enterResynchronizing() }
        }
        sendTask = nil
        finishDrainIfPossible()
        startSendingIfPossible()
    }

    private func cancelQueuedEdit(_ id: UUID) {
        if let index = pendingEdits.firstIndex(where: { $0.id == id }) {
            pendingEdits.remove(at: index).continuation.resume(throwing: CancellationError())
            finishDrainIfPossible()
        } else if inFlight?.pending.id != id {
            cancelledRequestIDs.insert(id)
        }
    }

    private func waitForDrain() async throws {
        if pendingEdits.isEmpty, inFlight == nil { return }
        try await withCheckedThrowingContinuation { drainWaiters.append($0) }
    }

    private func finishDrainIfPossible() {
        guard pendingEdits.isEmpty, inFlight == nil else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func failDrainWaitersForResynchronization() {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: DocumentProtocolError.resynchronizing) }
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
        failDrainWaitersForResynchronization()
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

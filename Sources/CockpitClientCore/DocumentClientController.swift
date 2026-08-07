import CockpitProtocol
import CockpitTypes

public enum DocumentClientControllerState: Hashable, Sendable {
    case closed
    case ready(DocumentSnapshot)
    case readOnly(DocumentSnapshot)
    case resynchronizing
}

public actor DocumentClientController {
    public private(set) var state: DocumentClientControllerState = .closed

    private let clientInstanceID: ClientInstanceID
    private let transport: any DocumentDataTransport
    private var environmentID: EnvironmentID?
    private var path: RelativePath?
    private var authoritativeSnapshot: DocumentSnapshot?
    private var lease: EditLease?
    private var operationBusy = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

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
        await enterOperation()
        defer { leaveOperation() }
        let snapshot = try await transport.openDocument(in: environmentID, at: path)
        self.environmentID = environmentID
        self.path = path
        authoritativeSnapshot = snapshot
        if requestWriteAccess {
            lease = try await transport.acquireEditLease(
                documentID: snapshot.documentID,
                client: clientInstanceID
            )
            state = .ready(snapshot)
        } else {
            lease = nil
            state = .readOnly(snapshot)
        }
        return snapshot
    }

    public func submit(_ changes: [UTF16TextEdit]) async throws -> EditAcknowledgement {
        await enterOperation()
        defer { leaveOperation() }
        guard case .ready = state,
              let snapshot = authoritativeSnapshot,
              let lease
        else {
            switch state {
            case .readOnly: throw DocumentProtocolError.readOnly
            case .resynchronizing: throw DocumentProtocolError.resynchronizing
            case .closed: throw DocumentProtocolError.invalidValue
            case .ready: throw DocumentProtocolError.invalidLease
            }
        }
        let transaction = try EditTransaction(
            validatingDocumentID: snapshot.documentID,
            editLeaseID: lease.id,
            baseVersion: snapshot.documentVersion,
            clientSequence: snapshot.lastAcceptedClientSequence + 1,
            changes: changes
        )
        do {
            let acknowledgement = try await transport.apply(transaction)
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
            return acknowledgement
        } catch {
            state = .resynchronizing
            throw error
        }
    }

    public func flush() async throws -> UInt64 {
        await enterOperation()
        defer { leaveOperation() }
        guard case .ready = state, let snapshot = authoritativeSnapshot else {
            if case .resynchronizing = state { throw DocumentProtocolError.resynchronizing }
            if case .readOnly = state { throw DocumentProtocolError.readOnly }
            throw DocumentProtocolError.invalidValue
        }
        return try await transport.flush(
            documentID: snapshot.documentID,
            through: snapshot.lastAcceptedClientSequence
        )
    }

    @discardableResult
    public func resynchronize(requestWriteAccess: Bool) async throws -> DocumentSnapshot {
        await enterOperation()
        defer { leaveOperation() }
        guard let current = authoritativeSnapshot else {
            throw DocumentProtocolError.invalidValue
        }
        let replacement = try await transport.snapshot(documentID: current.documentID)
        authoritativeSnapshot = replacement
        if requestWriteAccess {
            lease = try await transport.acquireEditLease(
                documentID: replacement.documentID,
                client: clientInstanceID
            )
            state = .ready(replacement)
        } else {
            lease = nil
            state = .readOnly(replacement)
        }
        return replacement
    }

    @discardableResult
    public func save(expectedFingerprint: DiskFingerprint) async throws -> DocumentSnapshot {
        await enterOperation()
        defer { leaveOperation() }
        guard case .ready = state, let current = authoritativeSnapshot else {
            throw DocumentProtocolError.readOnly
        }
        _ = try await transport.flush(
            documentID: current.documentID,
            through: current.lastAcceptedClientSequence
        )
        let replacement = try await transport.save(
            documentID: current.documentID,
            expectedFingerprint: expectedFingerprint
        )
        authoritativeSnapshot = replacement
        state = .ready(replacement)
        return replacement
    }

    @discardableResult
    public func discard() async throws -> DocumentSnapshot {
        await enterOperation()
        defer { leaveOperation() }
        guard let current = authoritativeSnapshot else { throw DocumentProtocolError.invalidValue }
        let replacement = try await transport.discard(documentID: current.documentID)
        authoritativeSnapshot = replacement
        state = lease == nil ? .readOnly(replacement) : .ready(replacement)
        return replacement
    }

    private func enterOperation() async {
        if !operationBusy { operationBusy = true; return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func leaveOperation() {
        if operationWaiters.isEmpty { operationBusy = false }
        else { operationWaiters.removeFirst().resume() }
    }
}

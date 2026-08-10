import Foundation
import CockpitHostCore
import CockpitTerminalCore
import CockpitTypes

@_spi(CockpitTerminalSupervisorComposition)
public final class TerminalSupervisorSessionOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied: Set<TerminalSessionID> = []
    private var waiters: [TerminalSessionID: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func acquire(_ sessionID: TerminalSessionID) async {
        await withCheckedContinuation { continuation in
            let acquired = lock.withLock { () -> Bool in
                guard occupied.contains(sessionID) else {
                    occupied.insert(sessionID)
                    return true
                }
                waiters[sessionID, default: []].append(continuation)
                return false
            }
            if acquired { continuation.resume() }
        }
    }

    public func release(_ sessionID: TerminalSessionID) {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard var queued = waiters[sessionID], !queued.isEmpty else {
                occupied.remove(sessionID)
                waiters.removeValue(forKey: sessionID)
                return nil
            }
            let next = queued.removeFirst()
            if queued.isEmpty { waiters.removeValue(forKey: sessionID) }
            else { waiters[sessionID] = queued }
            return next
        }
        next?.resume()
    }
}

@_spi(CockpitTerminalSupervisorComposition)
public final class TerminalSupervisorIdempotencyOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied: Set<RequestID> = []
    private var waiters: [RequestID: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func acquire(_ requestID: RequestID) async {
        await withCheckedContinuation { continuation in
            let acquired = lock.withLock { () -> Bool in
                guard occupied.contains(requestID) else {
                    occupied.insert(requestID)
                    return true
                }
                waiters[requestID, default: []].append(continuation)
                return false
            }
            if acquired { continuation.resume() }
        }
    }

    public func release(_ requestID: RequestID) {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard var queued = waiters[requestID], !queued.isEmpty else {
                occupied.remove(requestID)
                waiters.removeValue(forKey: requestID)
                return nil
            }
            let next = queued.removeFirst()
            if queued.isEmpty { waiters.removeValue(forKey: requestID) }
            else { waiters[requestID] = queued }
            return next
        }
        next?.resume()
    }
}

@_spi(CockpitTerminalSupervisorComposition)
public enum TerminalSupervisorStartupSynchronization {
    public static func run(
        _ sessionIDs: [TerminalSessionID],
        synchronize: @escaping @Sendable (TerminalSessionID) async throws -> Void,
        installRetryWatcher: @escaping @Sendable (TerminalSessionID) async -> Void
    ) async {
        for sessionID in sessionIDs {
            do { try await synchronize(sessionID) }
            catch { await installRetryWatcher(sessionID) }
        }
    }
}

@_spi(CockpitTerminalSupervisorComposition)
public enum TerminalSupervisorCreatedSessionActivation {
    public static func run<Value: Sendable>(
        idempotencyGate: TerminalSupervisorIdempotencyOperationGate,
        idempotencyKey: RequestID,
        operationGate: TerminalSupervisorSessionOperationGate,
        create: @escaping @Sendable () async throws -> Value,
        sessionID: @escaping @Sendable (Value) -> TerminalSessionID,
        synchronizeAndStartWatcher: @escaping @Sendable (TerminalSessionID) async throws -> Void
    ) async throws -> Value {
        await idempotencyGate.acquire(idempotencyKey)
        defer { idempotencyGate.release(idempotencyKey) }
        let value = try await create()
        let createdSessionID = sessionID(value)
        await operationGate.acquire(createdSessionID)
        defer { operationGate.release(createdSessionID) }
        try await synchronizeAndStartWatcher(createdSessionID)
        return value
    }
}

@_spi(CockpitTerminalSupervisorComposition)
public enum TerminalSupervisorCompletionRecovery {
    public static func reconcileAfterDisconnect(
        sessionID: TerminalSessionID,
        reconcile: @escaping @Sendable () async throws -> Void,
        activeRecords: @escaping @Sendable () async throws -> [TerminalSessionID]
    ) async throws -> Bool {
        do { try await reconcile() }
        catch TerminalSessionRepositoryError.recordNotFound { return true }
        return try await !activeRecords().contains(sessionID)
    }
}

public actor TerminalSupervisorControlTransport: TerminalSupervisorControlling {
    private let client: TerminalSupervisorXPCClient

    public init(client: TerminalSupervisorXPCClient = TerminalSupervisorXPCClient()) {
        self.client = client
    }

    public func createResolved(
        _ request: ResolvedTerminalCreateRequest
    ) async throws -> TerminalSessionRecord {
        try await client.createResolved(request)
    }

    public func list(contextID: WorkspaceContextID) async throws -> [TerminalSessionRecord] {
        guard case let .sessions(values) = try await client.command(.list(contextID: contextID)) else {
            throw CocoaError(.coderInvalidValue)
        }
        return values
    }

    public func issueAttachTicket(
        _ request: TerminalAttachTicketRequest
    ) async throws -> TerminalAttachAuthorization {
        guard case let .attachAuthorization(value) = try await client.command(
            .issueAttachTicket(request)
        ) else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    public func acquireInputLease(
        _ request: TerminalInputLeaseRequest
    ) async throws -> InputLeaseGrant {
        guard case let .inputLease(value) = try await client.command(
            .acquireInputLease(request)
        ) else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    public func transferInputLease(
        _ request: TerminalInputLeaseTransferRequest
    ) async throws -> InputLeaseGrant {
        guard case let .inputLease(value) = try await client.command(
            .transferInputLease(request)
        ) else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    public func releaseInputLease(
        sessionID: TerminalSessionID,
        leaseID: InputLeaseID
    ) async throws {
        guard case .empty = try await client.command(
            .releaseInputLease(sessionID: sessionID, leaseID: leaseID)
        ) else { throw CocoaError(.coderInvalidValue) }
    }

    public func signal(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        signal: TerminalSignal
    ) async throws -> Int32 {
        guard case let .processGroup(value) = try await client.command(
            .signal(
                sessionID: sessionID,
                viewerID: viewerID,
                leaseID: leaseID,
                signal: signal
            )
        ) else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    public func terminate(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        force: Bool
    ) async throws {
        guard case .empty = try await client.command(
            .terminate(
                sessionID: sessionID,
                viewerID: viewerID,
                leaseID: leaseID,
                force: force
            )
        ) else { throw CocoaError(.coderInvalidValue) }
    }

    public func purgeFinishedRecords() async throws -> Int {
        guard case let .purged(value) = try await client.command(.purgeFinishedRecords) else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    public func reconcile() async throws {
        guard case .empty = try await client.command(.reconcile) else {
            throw CocoaError(.coderInvalidValue)
        }
    }

    public func openArchive(sessionID: TerminalSessionID) async throws -> FileHandle {
        try await client.openArchive(sessionID: sessionID)
    }
}

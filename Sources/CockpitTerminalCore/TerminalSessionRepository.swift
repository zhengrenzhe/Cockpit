import CockpitTypes

public enum TerminalSessionRepositoryError: Error, Equatable, Sendable {
    case recordNotFound
    case recordMustBePreparing
    case invalidTransition(current: TerminalLifecycleState, requested: TerminalLifecycleState)
    case workerMismatch
    case processIdentityMismatch
    case invalidFinalState
    case sequenceRegression
    case invalidCanonicalExecutablePath
    case corruptRecord
    case contextDeleting
    case deletionOperationMismatch
    case activeSessionsRemain
    case contextDeletionUnsupported
}

public enum TerminalContextDeletionState: String, Codable, Hashable, Sendable {
    case deleting
    case purged
}

public struct TerminalContextDeletion: Hashable, Codable, Sendable {
    public let contextID: WorkspaceContextID
    public let operationID: DeletionOperationID
    public let state: TerminalContextDeletionState

    public init(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID,
        state: TerminalContextDeletionState
    ) {
        self.contextID = contextID
        self.operationID = operationID
        self.state = state
    }
}

public enum ContextTerminationResult: Hashable, Codable, Sendable {
    case complete
    case forceConfirmationRequired(activeSessionIDs: [TerminalSessionID])
}

public enum AgentProfileID: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public protocol AgentExecutableRepository: Sendable {
    func storeCanonicalExecutable(_ path: String, for profileID: AgentProfileID) async throws
    func canonicalExecutable(for profileID: AgentProfileID) async throws -> String?
}

public protocol TerminalSessionRepository: Sendable {
    @discardableResult
    func insertPreparing(
        _ record: TerminalSessionRecord,
        idempotencyKey: RequestID
    ) async throws -> TerminalSessionRecord
    func markCommitted(sessionID: TerminalSessionID, workerID: WorkerInstanceID) async throws
    func markRunning(sessionID: TerminalSessionID, identity: CLIProcessIdentity) async throws
    func finish(
        sessionID: TerminalSessionID,
        state: TerminalLifecycleState,
        exitStatus: Int32?,
        latestSequence: UInt64,
        archiveManifest: RelativeArchivePath?
    ) async throws
    func activeRecords() async throws -> [TerminalSessionRecord]
    func record(sessionID: TerminalSessionID) async throws -> TerminalSessionRecord
    func records(contextID: WorkspaceContextID) async throws -> [TerminalSessionRecord]
    func purgeFinishedRecords() async throws -> Int
    func beginContextDeletion(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws
    func contextDeletion(
        contextID: WorkspaceContextID
    ) async throws -> TerminalContextDeletion?
    func purgeDeletedContext(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws
}

public extension TerminalSessionRepository {
    func beginContextDeletion(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws {
        throw TerminalSessionRepositoryError.contextDeletionUnsupported
    }

    func contextDeletion(
        contextID: WorkspaceContextID
    ) async throws -> TerminalContextDeletion? {
        nil
    }

    func purgeDeletedContext(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws {
        throw TerminalSessionRepositoryError.contextDeletionUnsupported
    }
}

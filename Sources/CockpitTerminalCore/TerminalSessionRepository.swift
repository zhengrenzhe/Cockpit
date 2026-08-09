import CockpitTypes

public enum TerminalSessionRepositoryError: Error, Equatable, Sendable {
    case recordNotFound
    case recordMustBePreparing
    case invalidTransition(current: TerminalLifecycleState, requested: TerminalLifecycleState)
    case workerMismatch
    case processIdentityMismatch
    case invalidFinalState
    case sequenceRegression
    case corruptRecord
}

public protocol TerminalSessionRepository: Sendable {
    func insertPreparing(_ record: TerminalSessionRecord, idempotencyKey: RequestID) async throws
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
    func records(contextID: WorkspaceContextID) async throws -> [TerminalSessionRecord]
}

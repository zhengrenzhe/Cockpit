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
    func records(contextID: WorkspaceContextID) async throws -> [TerminalSessionRecord]
}

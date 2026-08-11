import CockpitTerminalCore
import CockpitTypes

public typealias ContextTerminationResult = CockpitTerminalCore.ContextTerminationResult

public protocol ContextTerminalDeletionControlling: Sendable {
    func beginContextDeletion(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws
    func terminateSessions(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID,
        force: Bool
    ) async throws -> ContextTerminationResult
    func purgeDeletedContext(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws
}

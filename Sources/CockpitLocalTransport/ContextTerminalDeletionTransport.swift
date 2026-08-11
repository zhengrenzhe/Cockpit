import Foundation
import CockpitHostCore
import CockpitTypes

public actor ContextTerminalDeletionTransport: ContextTerminalDeletionControlling {
    private let client: TerminalSupervisorXPCClient

    public init(
        client: TerminalSupervisorXPCClient = TerminalSupervisorXPCClient()
    ) {
        self.client = client
    }

    public func beginContextDeletion(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws {
        guard case .empty = try await client.command(
            .beginContextDeletion(contextID: contextID, operationID: operationID)
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
    }

    public func terminateSessions(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID,
        force: Bool
    ) async throws -> ContextTerminationResult {
        do {
            guard case let .contextTermination(result) = try await client.command(
                .terminateContextSessions(
                    contextID: contextID,
                    operationID: operationID,
                    force: force
                )
            ) else {
                throw CocoaError(.coderInvalidValue)
            }
            if result == .complete || !force { return result }
        } catch {
            guard force else { throw error }
        }
        for attempt in 0..<200 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(50)) }
            guard case let .contextTermination(result) = try await client.command(
                .contextTerminationStatus(
                    contextID: contextID,
                    operationID: operationID
                )
            ) else {
                throw CocoaError(.coderInvalidValue)
            }
            if result == .complete { return result }
        }
        throw CocoaError(.xpcConnectionReplyInvalid)
    }

    public func purgeDeletedContext(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws {
        guard case .empty = try await client.command(
            .purgeDeletedContext(contextID: contextID, operationID: operationID)
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
    }
}

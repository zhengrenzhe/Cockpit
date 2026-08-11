import Foundation
import CockpitTerminalCore
import CockpitTypes

public enum WorkspaceTerminalServiceError: Error, Equatable, Sendable {
    case contextEnvironmentMismatch
    case sessionBindingMismatch
    case invalidResponse
}

public actor WorkspaceTerminalService {
    public typealias ContextResolver = @Sendable (
        WorkspaceContextID
    ) async throws -> ResolvedWorkspaceContext
    public typealias WorkspaceRootResolver = @Sendable (
        ResolvedWorkspaceContext
    ) async throws -> String
    public typealias AgentExecutableBookmarkResolver = @Sendable (Data) throws -> String

    private let resolveContext: ContextResolver
    private let resolveWorkspaceRoot: WorkspaceRootResolver
    private let resolveAgentExecutableBookmark: AgentExecutableBookmarkResolver
    private let supervisor: any TerminalSupervisorControlling

    public init(
        resolveContext: @escaping ContextResolver,
        resolveWorkspaceRoot: @escaping WorkspaceRootResolver,
        resolveAgentExecutableBookmark: @escaping AgentExecutableBookmarkResolver = { _ in
            throw CocoaError(.fileReadInvalidFileName)
        },
        supervisor: any TerminalSupervisorControlling
    ) {
        self.resolveContext = resolveContext
        self.resolveWorkspaceRoot = resolveWorkspaceRoot
        self.resolveAgentExecutableBookmark = resolveAgentExecutableBookmark
        self.supervisor = supervisor
    }

    public func perform(
        _ command: HostTerminalCommandRequest
    ) async throws -> HostTerminalCommandResponse {
        switch command {
        case let .create(request):
            let context = try await validatedContext(
                request.contextID,
                environmentID: request.environmentID
            )
            let root = try await resolveWorkspaceRoot(context)
            let selectedExecutablePath: String?
            if let bookmark = request.selectedExecutableBookmark {
                guard case .agent = request.kind else {
                    throw WorkspaceTerminalServiceError.invalidResponse
                }
                selectedExecutablePath = try resolveAgentExecutableBookmark(bookmark)
            } else {
                selectedExecutablePath = nil
            }
            let record: TerminalSessionRecord
            do {
                record = try await supervisor.createResolved(
                    ResolvedTerminalCreateRequest(
                        contextID: request.contextID,
                        environmentID: request.environmentID,
                        kind: request.kind,
                        arguments: request.arguments,
                        workspaceRoot: root,
                        terminalSize: request.terminalSize,
                        environmentOverrides: request.environmentOverrides,
                        idempotencyKey: request.idempotencyKey,
                        selectedExecutablePath: selectedExecutablePath
                    )
                )
            } catch let error as TerminalSupervisorCreateError {
                guard case let .agentExecutableSelectionRequired(profileID) = error else {
                    throw error
                }
                return .agentExecutableSelectionRequired(profileID)
            }
            guard record.contextID == request.contextID,
                  record.environmentID == request.environmentID else {
                throw WorkspaceTerminalServiceError.sessionBindingMismatch
            }
            return .session(try ClientTerminalSession(validating: record))
        case let .list(contextID):
            let context = try await resolveContext(contextID)
            guard context.contextID == contextID else {
                throw WorkspaceTerminalServiceError.contextEnvironmentMismatch
            }
            let records = try await supervisor.list(contextID: contextID)
            guard records.allSatisfy({
                $0.contextID == contextID && $0.environmentID == context.environmentID
            }) else {
                throw WorkspaceTerminalServiceError.sessionBindingMismatch
            }
            return .sessions(try records.map(ClientTerminalSession.init(validating:)))
        case let .issueAttachTicket(contextID, environmentID, request):
            let record = try await validateSession(
                request.sessionID,
                contextID: contextID,
                environmentID: environmentID
            )
            guard request.clientInstanceID.rawValue == request.viewerID.rawValue else {
                throw WorkspaceTerminalServiceError.invalidResponse
            }
            let authorization = try await supervisor.issueAttachTicket(request)
            guard authorization.binding.sessionID == request.sessionID,
                  authorization.binding.clientInstanceID == request.clientInstanceID,
                  authorization.viewerID == request.viewerID,
                  authorization.capabilities == request.capabilities,
                  let workerID = record.workerID,
                  authorization.binding.workerID == workerID,
                  authorization.endpoint.sessionID == request.sessionID,
                  authorization.endpoint.workerID == workerID else {
                throw WorkspaceTerminalServiceError.invalidResponse
            }
            return .attachAuthorization(
                ClientTerminalAttachAuthorization(authorization)
            )
        case let .acquireInputLease(contextID, environmentID, request):
            _ = try await validateSession(
                request.sessionID,
                contextID: contextID,
                environmentID: environmentID
            )
            let grant = try await supervisor.acquireInputLease(request)
            guard grant.holderViewerID == request.viewerID,
                  grant.capabilities == request.capabilities else {
                throw WorkspaceTerminalServiceError.invalidResponse
            }
            return .inputLease(grant)
        case let .transferInputLease(contextID, environmentID, request):
            _ = try await validateSession(
                request.sessionID,
                contextID: contextID,
                environmentID: environmentID
            )
            let grant = try await supervisor.transferInputLease(request)
            guard grant.leaseID != request.leaseID,
                  grant.holderViewerID == request.toViewerID,
                  grant.capabilities == request.capabilities else {
                throw WorkspaceTerminalServiceError.invalidResponse
            }
            return .inputLease(grant)
        case let .releaseInputLease(contextID, environmentID, sessionID, leaseID):
            _ = try await validateSession(
                sessionID,
                contextID: contextID,
                environmentID: environmentID
            )
            try await supervisor.releaseInputLease(sessionID: sessionID, leaseID: leaseID)
            return .empty
        case let .signal(contextID, environmentID, sessionID, viewerID, leaseID, signal):
            _ = try await validateSession(
                sessionID,
                contextID: contextID,
                environmentID: environmentID
            )
            return .processGroup(
                try await supervisor.signal(
                    sessionID: sessionID,
                    viewerID: viewerID,
                    leaseID: leaseID,
                    signal: signal
                )
            )
        case let .terminate(contextID, environmentID, sessionID, viewerID, leaseID, force):
            _ = try await validateSession(
                sessionID,
                contextID: contextID,
                environmentID: environmentID
            )
            try await supervisor.terminate(
                sessionID: sessionID,
                viewerID: viewerID,
                leaseID: leaseID,
                force: force
            )
            return .empty
        }
    }

    public func openArchive(_ request: HostTerminalArchiveRequest) async throws -> FileHandle {
        _ = try await validateSession(
            request.sessionID,
            contextID: request.contextID,
            environmentID: request.environmentID
        )
        return try await supervisor.openArchive(sessionID: request.sessionID)
    }

    private func validatedContext(
        _ contextID: WorkspaceContextID,
        environmentID: EnvironmentID
    ) async throws -> ResolvedWorkspaceContext {
        let context = try await resolveContext(contextID)
        guard context.contextID == contextID,
              context.environmentID == environmentID else {
            throw WorkspaceTerminalServiceError.contextEnvironmentMismatch
        }
        return context
    }

    private func validateSession(
        _ sessionID: TerminalSessionID,
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID
    ) async throws -> TerminalSessionRecord {
        _ = try await validatedContext(contextID, environmentID: environmentID)
        let records = try await supervisor.list(contextID: contextID)
        guard let record = records.first(where: {
            $0.sessionID == sessionID
                && $0.contextID == contextID
                && $0.environmentID == environmentID
        }) else {
            throw WorkspaceTerminalServiceError.sessionBindingMismatch
        }
        return record
    }
}

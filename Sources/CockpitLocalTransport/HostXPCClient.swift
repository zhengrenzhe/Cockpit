import Foundation
import CockpitHostCore
import CockpitTypes

public actor HostXPCClient: WorkspaceServing {
    private struct ActiveConnection: Sendable {
        let value: any XPCConnectionBoundary
        let generation: UInt64
    }

    private let connectionFactory: XPCConnectionFactory
    private var activeConnection: ActiveConnection?
    private var nextGeneration: UInt64 = 0

    public init() {
        connectionFactory = { FoundationXPCConnection(endpoint: $0) }
    }

    init(connectionFactory: @escaping XPCConnectionFactory) {
        self.connectionFactory = connectionFactory
    }

    public func connect() {
        guard activeConnection == nil else { return }
        nextGeneration &+= 1
        let generation = nextGeneration
        let connection = connectionFactory(.host)
        connection.configureRemoteObjectInterface(
            NSXPCInterface(with: HostXPCProtocol.self)
        )
        connection.setInvalidationHandler { [weak self] in
            Task { await self?.connectionWasInvalidated(generation: generation) }
        }
        connection.setInterruptionHandler { [weak self] in
            Task { await self?.connectionWasInterrupted(generation: generation) }
        }
        activeConnection = ActiveConnection(value: connection, generation: generation)
        connection.resume()
    }

    public func addProject(
        bookmark: Data,
        displayName: String
    ) async throws -> ProjectSnapshot {
        guard case let .projectSnapshot(value) = try await send(
            .addProject(bookmark: bookmark, displayName: displayName)
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    public func listWorkspace() async throws -> WorkspaceSnapshot {
        guard case let .workspaceSnapshot(value) = try await send(.listWorkspace) else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    public func createDirectConversation(
        projectID: ProjectID
    ) async throws -> Conversation {
        guard case let .conversation(value) = try await send(
            .createDirectConversation(projectID: projectID)
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    public func renameConversation(id: ConversationID, title: String) async throws {
        guard case .empty = try await send(.renameConversation(id: id, title: title)) else {
            throw CocoaError(.coderInvalidValue)
        }
    }

    public func resolveContext(
        _ id: WorkspaceContextID
    ) async throws -> ResolvedWorkspaceContext {
        guard case let .resolvedContext(value) = try await send(.resolveContext(id)) else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    public func disconnect() {
        guard let connection = activeConnection else { return }
        activeConnection = nil
        connection.value.invalidate()
    }

    private func send(
        _ request: WorkspaceCommandRequest
    ) async throws -> WorkspaceCommandResponse {
        connect()
        guard let connection = activeConnection?.value else {
            throw CocoaError(.xpcConnectionInvalid)
        }
        let data = try JSONEncoder().encode(request)
        let reply = XPCReplyContinuation<Data>()
        let responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard reply.install(continuation) else { return }
                let remote = connection.remoteObjectProxy { error in
                    reply.resume(throwing: error)
                }
                guard let proxy = remote as? HostXPCProtocol else {
                    reply.resume(throwing: CocoaError(.coderInvalidValue))
                    return
                }
                proxy.workspaceCommand(data) { data, error in
                    if let error {
                        reply.resume(throwing: error)
                    } else if let data {
                        reply.resume(returning: data)
                    } else {
                        reply.resume(throwing: CocoaError(.coderInvalidValue))
                    }
                }
            }
        } onCancel: {
            reply.cancel()
        }
        return try JSONDecoder().decode(WorkspaceCommandResponse.self, from: responseData)
    }

    private func connectionWasInvalidated(generation: UInt64) {
        guard activeConnection?.generation == generation else { return }
        activeConnection = nil
    }

    private func connectionWasInterrupted(generation: UInt64) {
        guard let connection = activeConnection,
              connection.generation == generation else {
            return
        }
        activeConnection = nil
        connection.value.invalidate()
    }
}

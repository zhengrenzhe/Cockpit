import Foundation
import CockpitHostCore
import CockpitProtocol
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

    public func performFileOperation(
        context: RequestContext,
        operation: FileOperation
    ) async throws -> FileOperationResult {
        guard case let .fileOperationResult(value) = try await send(
            .performFileOperation(context: context, operation: operation)
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    public func issueHostDataPlaneTicket(
        context: RequestContext
    ) async throws -> CPHostDataPlaneTicketResponse {
        connect()
        guard let connection = activeConnection?.value else {
            throw CocoaError(.xpcConnectionInvalid)
        }
        var request = CPHostDataPlaneTicketRequest()
        request.context = try WorkspaceMessages.encode(context, negotiatedVersion: .current)
        let requestData = try request.serializedData()
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
                proxy.issueHostDataPlaneTicket(requestData) { data, error in
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
        let response = try CPHostDataPlaneTicketResponse(serializedBytes: responseData)
        guard response.unknownFields.data.isEmpty,
              response.validForMilliseconds == 30_000,
              !response.socketPath.isEmpty,
              (try? UnixDomainSocketAddress(path: response.socketPath)) != nil,
              canonicalHostDataPlaneTicket(response.ticket)
        else {
            throw CocoaError(.coderInvalidValue)
        }
        return response
    }

    public func disconnect() {
        guard let connection = activeConnection else { return }
        activeConnection = nil
        connection.value.invalidate()
    }

    public func terminalCommand(
        _ request: HostTerminalCommandRequest
    ) async throws -> HostTerminalCommandResponse {
        connect()
        guard let connection = activeConnection?.value else {
            throw CocoaError(.xpcConnectionInvalid)
        }
        let requestData = try JSONEncoder().encode(request)
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
                proxy.terminalCommand(requestData) { data, error in
                    if let error { reply.resume(throwing: error) }
                    else if let data { reply.resume(returning: data) }
                    else { reply.resume(throwing: CocoaError(.coderInvalidValue)) }
                }
            }
        } onCancel: {
            reply.cancel()
        }
        return try JSONDecoder().decode(HostTerminalCommandResponse.self, from: responseData)
    }

    public func openTerminalArchive(
        _ request: HostTerminalArchiveRequest
    ) async throws -> FileHandle {
        connect()
        guard let connection = activeConnection?.value else {
            throw CocoaError(.xpcConnectionInvalid)
        }
        let requestData = try JSONEncoder().encode(request)
        let reply = XPCReplyContinuation<FileHandle>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard reply.install(continuation) else { return }
                let remote = connection.remoteObjectProxy { error in
                    reply.resume(throwing: error)
                }
                guard let proxy = remote as? HostXPCProtocol else {
                    reply.resume(throwing: CocoaError(.coderInvalidValue))
                    return
                }
                proxy.openTerminalArchive(requestData) { handle, error in
                    if let error { reply.resume(throwing: error) }
                    else if let handle { reply.resume(returning: handle) }
                    else { reply.resume(throwing: CocoaError(.coderInvalidValue)) }
                }
            }
        } onCancel: { reply.cancel() }
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

private func canonicalHostDataPlaneTicket(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 43,
          bytes.allSatisfy({
              (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95
          })
    else { return false }
    let base64 = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/") + "="
    guard let raw = Data(base64Encoded: base64), raw.count == 32 else { return false }
    return raw.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "") == value
}

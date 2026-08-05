import Foundation
import CockpitTerminalCore

public actor TerminalSupervisorXPCClient {
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
        let connection = connectionFactory(.terminal)
        connection.configureRemoteObjectInterface(
            NSXPCInterface(with: TerminalSupervisorXPCProtocol.self)
        )
        connection.setInvalidationHandler { [weak self] in
            Task {
                await self?.connectionWasInvalidated(generation: generation)
            }
        }
        connection.setInterruptionHandler { [weak self] in
            Task {
                await self?.connectionWasInterrupted(generation: generation)
            }
        }
        activeConnection = ActiveConnection(value: connection, generation: generation)
        connection.resume()
    }

    public func spawnKeeperProbe(
        _ request: KeeperProbeRequest
    ) async throws -> KeeperLaunchReceipt {
        connect()
        guard let connection = activeConnection?.value else {
            throw CocoaError(.xpcConnectionInvalid)
        }
        let data = try JSONEncoder().encode(request)
        let reply = XPCReplyContinuation<KeeperLaunchReceipt>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard reply.install(continuation) else { return }
                let remote = connection.remoteObjectProxy { error in
                    reply.resume(throwing: error)
                }
                guard let proxy = remote as? TerminalSupervisorXPCProtocol else {
                    reply.resume(throwing: CocoaError(.coderInvalidValue))
                    return
                }
                proxy.spawnKeeperProbe(data) { data, error in
                    if let error {
                        reply.resume(throwing: error)
                    } else if let data {
                        do {
                            reply.resume(returning: try JSONDecoder().decode(
                                KeeperLaunchReceipt.self,
                                from: data
                            ))
                        } catch {
                            reply.resume(throwing: error)
                        }
                    } else {
                        reply.resume(throwing: CocoaError(.coderInvalidValue))
                    }
                }
            }
        } onCancel: {
            reply.cancel()
        }
    }

    public func disconnect() {
        guard let connection = activeConnection else { return }
        activeConnection = nil
        connection.value.invalidate()
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

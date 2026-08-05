import Foundation
import CockpitClientCore

final class XPCReplyContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var isCompleted = false

    @discardableResult
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if isCompleted {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func cancel() {
        resume(throwing: CancellationError())
    }

    func resume(returning value: sending Value) {
        let continuation = takeContinuation()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        let continuation = takeContinuation()
        continuation?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return nil
        }
        isCompleted = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        return continuation
    }
}

public actor XPCHandshakeClient: CockpitTransport {
    private struct ActiveConnection: Sendable {
        let value: any XPCConnectionBoundary
        let generation: UInt64
    }

    private let endpoint: XPCServiceEndpoint
    private let connectionFactory: XPCConnectionFactory
    private var activeConnection: ActiveConnection?
    private var nextGeneration: UInt64 = 0

    public init(endpoint: XPCServiceEndpoint = .host) {
        self.endpoint = endpoint
        connectionFactory = { FoundationXPCConnection(endpoint: $0) }
    }

    init(
        endpoint: XPCServiceEndpoint = .host,
        connectionFactory: @escaping XPCConnectionFactory
    ) {
        self.endpoint = endpoint
        self.connectionFactory = connectionFactory
    }

    public func connect() async throws {
        guard activeConnection == nil else { return }
        nextGeneration &+= 1
        let generation = nextGeneration
        let connection = connectionFactory(endpoint)
        connection.configureRemoteObjectInterface(
            NSXPCInterface(with: XPCHandshakeProtocol.self)
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

    public func exchangeHandshake(_ request: Data) async throws -> Data {
        guard let connection = activeConnection?.value else {
            throw CocoaError(.xpcConnectionInvalid)
        }
        let reply = XPCReplyContinuation<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard reply.install(continuation) else { return }
                let remote = connection.remoteObjectProxy { error in
                    reply.resume(throwing: error)
                }
                guard let proxy = remote as? XPCHandshakeProtocol else {
                    reply.resume(throwing: CocoaError(.coderInvalidValue))
                    return
                }
                proxy.exchangeHandshake(request) { data, error in
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
    }

    public func disconnect() async {
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

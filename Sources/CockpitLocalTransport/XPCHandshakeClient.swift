import Foundation
import CockpitClientCore

final class XPCReplyContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: sending Value) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

public actor XPCHandshakeClient: CockpitTransport {
    private let serviceName: String
    private var connection: NSXPCConnection?

    public init(serviceName: String) {
        self.serviceName = serviceName
    }

    public func connect() async throws {
        guard connection == nil else { return }
        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: XPCHandshakeProtocol.self)
        connection.resume()
        self.connection = connection
    }

    public func exchangeHandshake(_ request: Data) async throws -> Data {
        guard let connection else {
            throw CocoaError(.xpcConnectionInvalid)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReplyContinuation(continuation)
            let remote = connection.remoteObjectProxyWithErrorHandler { error in
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
    }

    public func disconnect() async {
        connection?.invalidate()
        connection = nil
    }
}

import Foundation
import CockpitTerminalCore

public actor TerminalSupervisorXPCClient {
    private let serviceName: String
    private var connection: NSXPCConnection?

    public init(serviceName: String = "dev.cockpit.terminal") {
        self.serviceName = serviceName
    }

    public func connect() {
        guard connection == nil else { return }
        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(
            with: TerminalSupervisorXPCProtocol.self
        )
        connection.resume()
        self.connection = connection
    }

    public func spawnKeeperProbe(
        _ request: KeeperProbeRequest
    ) async throws -> KeeperLaunchReceipt {
        connect()
        guard let connection else {
            throw CocoaError(.xpcConnectionInvalid)
        }
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReplyContinuation(continuation)
            let remote = connection.remoteObjectProxyWithErrorHandler { error in
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
    }

    public func disconnect() {
        connection?.invalidate()
        connection = nil
    }
}

import Foundation

public enum XPCServiceEndpoint: Sendable {
    case host
    case terminal

    public var machServiceName: String {
        switch self {
        case .host:
            "dev.cockpit.host"
        case .terminal:
            "dev.cockpit.terminal"
        }
    }
}

protocol XPCConnectionBoundary: AnyObject, Sendable {
    func configureRemoteObjectInterface(_ interface: NSXPCInterface)
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void)
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void)
    func resume()
    func invalidate()
    func remoteObjectProxy(
        errorHandler: @escaping @Sendable (any Error) -> Void
    ) -> Any
}

typealias XPCConnectionFactory =
    @Sendable (XPCServiceEndpoint) -> any XPCConnectionBoundary

final class FoundationXPCConnection: XPCConnectionBoundary, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(endpoint: XPCServiceEndpoint) {
        connection = NSXPCConnection(machServiceName: endpoint.machServiceName)
    }

    func configureRemoteObjectInterface(_ interface: NSXPCInterface) {
        connection.remoteObjectInterface = interface
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        connection.invalidationHandler = handler
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        connection.interruptionHandler = handler
    }

    func resume() {
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }

    func remoteObjectProxy(
        errorHandler: @escaping @Sendable (any Error) -> Void
    ) -> Any {
        connection.remoteObjectProxyWithErrorHandler(errorHandler)
    }
}

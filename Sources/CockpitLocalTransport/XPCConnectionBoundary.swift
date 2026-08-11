import Foundation

public enum XPCServiceNamespaceError: Error, Equatable, Sendable {
    case invalidValue
}

public struct XPCServiceNamespace: Hashable, Sendable, CustomStringConvertible {
    public static let production = try! XPCServiceNamespace("")

    public let description: String

    public init(_ value: String) throws {
        if value.isEmpty {
            description = value
            return
        }
        guard value.utf8.count <= 32,
              value.utf8.allSatisfy({ byte in
                  (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
              })
        else { throw XPCServiceNamespaceError.invalidValue }
        description = value
    }
}

public enum XPCServiceEndpoint: Sendable {
    case host
    case terminal

    public var machServiceName: String {
        machServiceName(in: .production)
    }

    public func machServiceName(in namespace: XPCServiceNamespace) -> String {
        let base: String
        switch self {
        case .host:
            base = "dev.cockpit.host"
        case .terminal:
            base = "dev.cockpit.terminal"
        }
        return namespace.description.isEmpty
            ? base
            : "\(base).\(namespace.description)"
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

    init(
        endpoint: XPCServiceEndpoint,
        serviceNamespace: XPCServiceNamespace = .production
    ) {
        connection = NSXPCConnection(
            machServiceName: endpoint.machServiceName(in: serviceNamespace)
        )
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

public extension HostXPCClient {
    init(serviceNamespace: XPCServiceNamespace) {
        self.init(connectionFactory: { endpoint in
            FoundationXPCConnection(
                endpoint: endpoint,
                serviceNamespace: serviceNamespace
            )
        })
    }
}

public extension TerminalSupervisorXPCClient {
    init(serviceNamespace: XPCServiceNamespace) {
        self.init(connectionFactory: { endpoint in
            FoundationXPCConnection(
                endpoint: endpoint,
                serviceNamespace: serviceNamespace
            )
        })
    }
}

public extension XPCHandshakeClient {
    init(
        endpoint: XPCServiceEndpoint = .host,
        serviceNamespace: XPCServiceNamespace
    ) {
        self.init(endpoint: endpoint, connectionFactory: { endpoint in
            FoundationXPCConnection(
                endpoint: endpoint,
                serviceNamespace: serviceNamespace
            )
        })
    }
}

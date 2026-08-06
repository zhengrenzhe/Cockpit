import Foundation

protocol IncomingXPCConnectionBoundary: AnyObject {
    var effectiveUserIdentifier: uid_t { get }
    var exportedInterface: NSXPCInterface? { get set }
    var exportedObject: Any? { get set }
    func resume()
}

extension NSXPCConnection: IncomingXPCConnectionBoundary {}

public final class MachServiceListenerDelegate:
    NSObject,
    NSXPCListenerDelegate,
    @unchecked Sendable
{
    private let exportedObject: Any
    private let exportedInterface: NSXPCInterface
    private let peerValidator: XPCPeerValidator

    public init(
        exportedObject: Any,
        exportedInterface: NSXPCInterface,
        peerValidator: XPCPeerValidator = .currentUser
    ) {
        self.exportedObject = exportedObject
        self.exportedInterface = exportedInterface
        self.peerValidator = peerValidator
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        shouldAccept(connection)
    }

    func shouldAccept(_ connection: any IncomingXPCConnectionBoundary) -> Bool {
        guard peerValidator.accepts(
            effectiveUserIdentifier: connection.effectiveUserIdentifier
        ) else {
            return false
        }
        connection.exportedInterface = exportedInterface
        connection.exportedObject = exportedObject
        connection.resume()
        return true
    }
}

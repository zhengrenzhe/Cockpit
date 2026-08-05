import Foundation

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

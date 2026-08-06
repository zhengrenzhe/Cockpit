import Foundation

@objc public protocol HostXPCProtocol: XPCHandshakeProtocol {
    func workspaceCommand(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
}

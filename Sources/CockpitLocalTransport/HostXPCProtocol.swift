import Foundation

@objc public protocol HostXPCProtocol: XPCHandshakeProtocol {
    func issueHostDataPlaneTicket(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )

    func workspaceCommand(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
}

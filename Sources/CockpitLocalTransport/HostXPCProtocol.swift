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

    func terminalCommand(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )

    func openTerminalArchive(
        _ request: Data,
        withReply reply: @escaping (FileHandle?, NSError?) -> Void
    )
}

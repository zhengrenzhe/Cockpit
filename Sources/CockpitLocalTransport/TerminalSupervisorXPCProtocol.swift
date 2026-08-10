import Foundation

@objc public protocol TerminalSupervisorXPCProtocol: XPCHandshakeProtocol {
    func terminalCommand(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )

    func openTerminalArchive(
        _ request: Data,
        withReply reply: @escaping (FileHandle?, NSError?) -> Void
    )
}

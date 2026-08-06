import Foundation

@objc public protocol TerminalSupervisorXPCProtocol: XPCHandshakeProtocol {
    func spawnKeeperProbe(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
}

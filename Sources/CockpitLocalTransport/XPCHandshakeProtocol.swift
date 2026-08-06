import Foundation

@objc public protocol XPCHandshakeProtocol {
    func exchangeHandshake(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
}

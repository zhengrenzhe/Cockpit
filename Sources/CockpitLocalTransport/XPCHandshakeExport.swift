import Foundation
import CockpitProtocol

public final class XPCHandshakeExport: NSObject, XPCHandshakeProtocol, @unchecked Sendable {
    public typealias Handler = @Sendable (CPHandshakeRequest) throws -> CPHandshakeResponse

    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func exchangeHandshake(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        do {
            let decoded = try HandshakeCodec.decodeRequest(request)
            reply(try HandshakeCodec.encode(handler(decoded)), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }
}

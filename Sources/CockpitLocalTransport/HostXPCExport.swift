import Foundation
import CockpitHostCore
import CockpitProtocol

public final class HostXPCExport: NSObject, HostXPCProtocol, @unchecked Sendable {
    public typealias HandshakeHandler =
        @Sendable (CPHandshakeRequest) throws -> CPHandshakeResponse

    private let handshakeHandler: HandshakeHandler
    private let workspaceRouter: WorkspaceCommandRouter

    public init(
        handshakeHandler: @escaping HandshakeHandler,
        workspaceRouter: WorkspaceCommandRouter
    ) {
        self.handshakeHandler = handshakeHandler
        self.workspaceRouter = workspaceRouter
    }

    public func exchangeHandshake(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        do {
            let decoded = try HandshakeCodec.decodeRequest(request)
            reply(try HandshakeCodec.encode(handshakeHandler(decoded)), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    public func workspaceCommand(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let reply = XPCWorkspaceReply(reply)
        Task {
            do {
                reply.complete(data: try await workspaceRouter.route(request), error: nil)
            } catch {
                reply.complete(data: nil, error: error as NSError)
            }
        }
    }
}

private final class XPCWorkspaceReply: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data?, NSError?) -> Void)?

    init(_ callback: @escaping (Data?, NSError?) -> Void) {
        self.callback = callback
    }

    func complete(data: Data?, error: NSError?) {
        let callback = lock.withLock {
            defer { self.callback = nil }
            return self.callback
        }
        callback?(data, error)
    }
}

import Foundation
import CockpitHostCore
import CockpitProtocol
import CockpitTypes

public final class HostXPCExport: NSObject, HostXPCProtocol, @unchecked Sendable {
    public typealias HandshakeHandler =
        @Sendable (CPHandshakeRequest) throws -> CPHandshakeResponse

    private let handshakeHandler: HandshakeHandler
    private let workspaceRouter: WorkspaceCommandRouter
    private let hostDataPlaneTicketIssuer: HostDataPlaneTicketIssuer?

    public init(
        handshakeHandler: @escaping HandshakeHandler,
        workspaceRouter: WorkspaceCommandRouter,
        hostDataPlaneTicketIssuer: HostDataPlaneTicketIssuer? = nil
    ) {
        self.handshakeHandler = handshakeHandler
        self.workspaceRouter = workspaceRouter
        self.hostDataPlaneTicketIssuer = hostDataPlaneTicketIssuer
    }

    public func issueHostDataPlaneTicket(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let reply = XPCWorkspaceReply(reply)
        guard let issuer = hostDataPlaneTicketIssuer else {
            reply.complete(data: nil, error: ticketError(code: 1))
            return
        }
        let context: RequestContext
        do {
            let message = try CPHostDataPlaneTicketRequest(serializedBytes: request)
            guard message.unknownFields.data.isEmpty, message.hasContext else {
                throw CocoaError(.coderInvalidValue)
            }
            context = try WorkspaceMessages.decode(message.context, negotiatedVersion: .current)
        } catch {
            reply.complete(data: nil, error: ticketError(code: 2))
            return
        }
        Task {
            do {
                try await issuer.issue(for: context) { response in
                    reply.complete(data: try response.serializedData(), error: nil)
                }
            } catch is HostDataPlaneTicketIssueError {
                reply.complete(data: nil, error: ticketError(code: 1))
            } catch HostDataPlaneTicketError.randomGenerationFailed {
                reply.complete(data: nil, error: ticketError(code: 3))
            } catch {
                reply.complete(data: nil, error: ticketError(code: 1))
            }
        }
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

private func ticketError(code: Int) -> NSError {
    NSError(domain: "dev.cockpit.host-data-plane-ticket", code: code, userInfo: [:])
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

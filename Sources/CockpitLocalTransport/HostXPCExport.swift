import Foundation
import CockpitHostCore
import CockpitProtocol
import CockpitTypes

package final class HostShutdownCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let ticketIssuer: HostDataPlaneTicketIssuer
    private let dataPlaneServer: HostDataPlaneServer
    private let invalidateListener: () -> Void
    private let stopProcess: () -> Void

    package init(
        ticketIssuer: HostDataPlaneTicketIssuer,
        dataPlaneServer: HostDataPlaneServer,
        invalidateListener: @escaping () -> Void,
        stopProcess: @escaping () -> Void
    ) {
        self.ticketIssuer = ticketIssuer
        self.dataPlaneServer = dataPlaneServer
        self.invalidateListener = invalidateListener
        self.stopProcess = stopProcess
    }

    package func shutdown() async {
        let begins = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard begins else { return }
        await ticketIssuer.stopIssuingTickets()
        await dataPlaneServer.shutdown()
        invalidateListener()
        stopProcess()
    }

    package func handleTermination() {
        Task { await shutdown() }
    }

    package var eventHandler: @Sendable () -> Void {
        { [weak self] in self?.handleTermination() }
    }
}

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
            context = try exactTicketRequestContext(message.context)
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

private func exactTicketRequestContext(_ wire: CPRequestContext) throws -> RequestContext {
    guard wire.activeContextGeneration > 0,
          wire.activeContextGeneration <= documentJavaScriptMaximum else {
        throw CocoaError(.coderInvalidValue)
    }
    let decoded = try WorkspaceMessages.decode(wire, negotiatedVersion: .current)
    let canonical = try WorkspaceMessages.encode(decoded, negotiatedVersion: .current)
    guard wire.clientInstanceID == canonical.clientInstanceID,
          wire.windowID == canonical.windowID,
          wire.workspaceContextID.kind == canonical.workspaceContextID.kind,
          wire.environmentID == canonical.environmentID,
          wire.requestID == canonical.requestID else {
        throw CocoaError(.coderInvalidValue)
    }
    return decoded
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

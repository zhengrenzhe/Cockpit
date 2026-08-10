import CockpitTerminalCore
import CockpitTypes

public protocol TerminalControlTransport: Sendable {
    func issueAttachTicket(
        sessionID: TerminalSessionID,
        clientInstanceID: ClientInstanceID,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) async throws -> TerminalAttachAuthorization

    func acquireInputLease(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) async throws -> InputLeaseGrant

    func releaseInputLease(
        sessionID: TerminalSessionID,
        leaseID: InputLeaseID
    ) async throws

    func signal(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        signal: TerminalSignal
    ) async throws -> Int32

    func terminate(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        force: Bool
    ) async throws
}

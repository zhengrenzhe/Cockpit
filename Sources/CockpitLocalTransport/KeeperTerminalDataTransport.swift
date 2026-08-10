import CockpitTerminalClient
import CockpitTerminalCore

public struct KeeperTerminalDataTransport: TerminalDataTransport, Sendable {
    public init() {}

    public func attach(
        authorization: TerminalAttachAuthorization,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> any TerminalDataConnection {
        try await KeeperUDSClient(endpoint: authorization.endpoint).attach(
            AttachRequest(
                viewerID: authorization.viewerID,
                wireTicket: authorization.wireTicket,
                binding: authorization.binding,
                requestedCapabilities: authorization.capabilities,
                lastAcknowledgedOutputSequence: lastAcknowledgedSequence
            )
        )
    }
}

extension KeeperViewerConnection: TerminalDataConnection {}

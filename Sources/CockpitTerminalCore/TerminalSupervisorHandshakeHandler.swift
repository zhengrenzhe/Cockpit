import CockpitProtocol
import CockpitTypes

public struct TerminalSupervisorHandshakeHandler: Sendable {
    private let negotiator = ProtocolNegotiator(
        serviceKind: "terminal",
        supportedFeatures: [.terminalControl, .terminalFrames]
    )

    public init() {}

    public func handle(_ request: CPHandshakeRequest) throws -> CPHandshakeResponse {
        try negotiator.negotiate(request)
    }
}

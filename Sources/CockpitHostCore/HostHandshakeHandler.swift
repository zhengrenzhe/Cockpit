import CockpitProtocol
import CockpitTypes

public struct HostHandshakeHandler: Sendable {
    private let negotiator = ProtocolNegotiator(
        serviceKind: "host",
        supportedFeatures: [.workspaceControl, .remoteDirect]
    )

    public init() {}

    public func handle(_ request: CPHandshakeRequest) throws -> CPHandshakeResponse {
        try negotiator.negotiate(request)
    }
}

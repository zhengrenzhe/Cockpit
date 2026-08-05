import Foundation
import CockpitTypes

public protocol CockpitTransport: Sendable {
    func connect() async throws
    func exchangeHandshake(_ request: Data) async throws -> Data
    func disconnect() async
}

public struct NegotiatedSession: Equatable, Sendable {
    public let connectionID: ConnectionID
    public let version: ProtocolVersion
    public let acceptedFeatures: Set<ProtocolFeature>
    public let serviceKind: String

    public init(
        connectionID: ConnectionID,
        version: ProtocolVersion,
        acceptedFeatures: Set<ProtocolFeature>,
        serviceKind: String
    ) {
        self.connectionID = connectionID
        self.version = version
        self.acceptedFeatures = acceptedFeatures
        self.serviceKind = serviceKind
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case ready(NegotiatedSession)
}

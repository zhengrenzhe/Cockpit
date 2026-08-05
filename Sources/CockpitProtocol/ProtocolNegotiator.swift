import Foundation
import CockpitTypes

public enum ProtocolNegotiationError: Error, Equatable {
    case incompatibleMajor(client: UInt32, service: UInt16)
    case invalidDeviceID(String)
    case invalidConnectionID(String)
    case invalidProtocolVersion(major: UInt32, minor: UInt32)
}

public struct ProtocolNegotiator: Sendable {
    public let serviceKind: String
    public let supportedVersion: ProtocolVersion
    public let supportedFeatures: Set<ProtocolFeature>

    public init(
        serviceKind: String,
        supportedVersion: ProtocolVersion = .current,
        supportedFeatures: Set<ProtocolFeature>
    ) {
        self.serviceKind = serviceKind
        self.supportedVersion = supportedVersion
        self.supportedFeatures = supportedFeatures
    }

    public func negotiate(_ request: CPHandshakeRequest) throws -> CPHandshakeResponse {
        guard request.protocolMajor == UInt32(supportedVersion.major) else {
            throw ProtocolNegotiationError.incompatibleMajor(
                client: request.protocolMajor,
                service: supportedVersion.major
            )
        }
        guard UUID(uuidString: request.deviceID) != nil else {
            throw ProtocolNegotiationError.invalidDeviceID(request.deviceID)
        }

        let requested = Set(request.requestedFeatures.map { ProtocolFeature(rawValue: $0) })
        let clientMinor = UInt16(clamping: request.protocolMinor)
        var response = CPHandshakeResponse()
        response.protocolMajor = UInt32(supportedVersion.major)
        response.protocolMinor = UInt32(min(clientMinor, supportedVersion.minor))
        response.connectionID = ConnectionID().description
        response.acceptedFeatures = requested.intersection(supportedFeatures).map(\.rawValue).sorted()
        response.serviceKind = serviceKind
        return response
    }
}

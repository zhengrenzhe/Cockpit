import Foundation
import SwiftProtobuf
import CockpitTypes

public enum HandshakeCodec {
    public static func encode(_ request: CPHandshakeRequest) throws -> Data {
        try request.serializedData()
    }

    public static func encode(_ response: CPHandshakeResponse) throws -> Data {
        try response.serializedData()
    }

    public static func decodeRequest(_ data: Data) throws -> CPHandshakeRequest {
        try CPHandshakeRequest(serializedBytes: data)
    }

    public static func decodeResponse(_ data: Data) throws -> CPHandshakeResponse {
        try CPHandshakeResponse(serializedBytes: data)
    }
}

public extension CPHandshakeRequest {
    static func cockpit(
        version: ProtocolVersion = .current,
        deviceID: DeviceID,
        features: Set<ProtocolFeature>
    ) -> Self {
        var value = Self()
        value.protocolMajor = UInt32(version.major)
        value.protocolMinor = UInt32(version.minor)
        value.deviceID = deviceID.description
        value.requestedFeatures = features.map(\.rawValue).sorted()
        return value
    }
}

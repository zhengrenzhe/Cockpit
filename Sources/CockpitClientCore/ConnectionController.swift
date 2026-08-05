import Foundation
import CockpitTypes
import CockpitProtocol

public actor ConnectionController {
    public private(set) var state: ConnectionState = .disconnected
    private let transport: any CockpitTransport
    private let deviceID: DeviceID

    public init(transport: any CockpitTransport, deviceID: DeviceID) {
        self.transport = transport
        self.deviceID = deviceID
    }

    public func connect(requestedFeatures: Set<ProtocolFeature>) async throws -> NegotiatedSession {
        state = .connecting
        do {
            try await transport.connect()
            let request = CPHandshakeRequest.cockpit(deviceID: deviceID, features: requestedFeatures)
            let responseData = try await transport.exchangeHandshake(HandshakeCodec.encode(request))
            let response = try HandshakeCodec.decodeResponse(responseData)
            guard let uuid = UUID(uuidString: response.connectionID) else {
                throw ProtocolNegotiationError.invalidConnectionID(response.connectionID)
            }
            guard
                response.protocolMajor <= UInt32(UInt16.max),
                response.protocolMinor <= UInt32(UInt16.max)
            else {
                throw ProtocolNegotiationError.invalidProtocolVersion(
                    major: response.protocolMajor,
                    minor: response.protocolMinor
                )
            }
            let negotiatedVersion = ProtocolVersion(
                major: UInt16(response.protocolMajor),
                minor: UInt16(response.protocolMinor)
            )
            guard negotiatedVersion.major == ProtocolVersion.current.major else {
                throw ProtocolNegotiationError.incompatibleMajor(
                    client: response.protocolMajor,
                    service: ProtocolVersion.current.major
                )
            }
            let session = NegotiatedSession(
                connectionID: ConnectionID(uuid),
                version: negotiatedVersion,
                acceptedFeatures: Set(response.acceptedFeatures.map { ProtocolFeature(rawValue: $0) }),
                serviceKind: response.serviceKind
            )
            state = .ready(session)
            return session
        } catch {
            state = .disconnected
            await transport.disconnect()
            throw error
        }
    }
}

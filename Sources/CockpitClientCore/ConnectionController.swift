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
        switch state {
        case .disconnected:
            state = .connecting
        case .connecting:
            throw ConnectionControllerError.alreadyConnecting
        case .ready:
            throw ConnectionControllerError.alreadyReady
        }

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
            guard response.protocolMinor <= request.protocolMinor else {
                throw ProtocolNegotiationError.responseMinorExceedsRequest(
                    response: response.protocolMinor,
                    request: request.protocolMinor
                )
            }
            let acceptedFeatures = Set(
                response.acceptedFeatures.map { ProtocolFeature(rawValue: $0) }
            )
            let requestedFeatures = Set(
                request.requestedFeatures.map { ProtocolFeature(rawValue: $0) }
            )
            let unrequestedFeatures = acceptedFeatures
                .subtracting(requestedFeatures)
                .map(\.rawValue)
                .sorted()
            guard unrequestedFeatures.isEmpty else {
                throw ProtocolNegotiationError.unrequestedAcceptedFeatures(unrequestedFeatures)
            }
            let session = NegotiatedSession(
                connectionID: ConnectionID(uuid),
                version: negotiatedVersion,
                acceptedFeatures: acceptedFeatures,
                serviceKind: response.serviceKind
            )
            state = .ready(session)
            return session
        } catch {
            await transport.disconnect()
            state = .disconnected
            throw error
        }
    }
}

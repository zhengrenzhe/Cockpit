import Foundation
import Testing
import CockpitTypes
import CockpitProtocol
@testable import CockpitClientCore

private actor FakeTransport: CockpitTransport {
    let response: Data
    private(set) var disconnected = false

    init(response: Data) {
        self.response = response
    }

    func connect() async throws {}

    func exchangeHandshake(_ request: Data) async throws -> Data {
        response
    }

    func disconnect() async {
        disconnected = true
    }
}

@Test func controllerReachesReadyWithNegotiatedSession() async throws {
    let request = CPHandshakeRequest.cockpit(deviceID: DeviceID(), features: [.workspaceControl])
    let response = try HostHandshakeHandlerFixture.response(for: request)
    let transport = FakeTransport(response: try HandshakeCodec.encode(response))
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    let session = try await controller.connect(requestedFeatures: [.workspaceControl])

    #expect(session.serviceKind == "host")
    #expect(session.acceptedFeatures == [.workspaceControl])
    let state = await controller.state
    #expect(state == .ready(session))
}

@Test func controllerDisconnectsAndResetsForInvalidConnectionID() async throws {
    var response = CPHandshakeResponse()
    response.protocolMajor = 1
    response.protocolMinor = 0
    response.connectionID = "invalid-connection-id"
    response.serviceKind = "host"
    let transport = FakeTransport(response: try HandshakeCodec.encode(response))
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    await #expect(throws: ProtocolNegotiationError.invalidConnectionID("invalid-connection-id")) {
        _ = try await controller.connect(requestedFeatures: [])
    }

    #expect(await controller.state == .disconnected)
    #expect(await transport.disconnected)
}

@Test func controllerDisconnectsAndResetsForOverflowedProtocolVersion() async throws {
    var response = CPHandshakeResponse()
    response.protocolMajor = UInt32(UInt16.max) + 1
    response.protocolMinor = 0
    response.connectionID = UUID().uuidString
    response.serviceKind = "host"
    let transport = FakeTransport(response: try HandshakeCodec.encode(response))
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    await #expect(throws: ProtocolNegotiationError.invalidProtocolVersion(major: 65_536, minor: 0)) {
        _ = try await controller.connect(requestedFeatures: [])
    }

    #expect(await controller.state == .disconnected)
    #expect(await transport.disconnected)
}

@Test func controllerDisconnectsAndResetsForIncompatibleMajor() async throws {
    var response = CPHandshakeResponse()
    response.protocolMajor = 2
    response.protocolMinor = 0
    response.connectionID = UUID().uuidString
    response.serviceKind = "host"
    let transport = FakeTransport(response: try HandshakeCodec.encode(response))
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    await #expect(throws: ProtocolNegotiationError.incompatibleMajor(client: 2, service: 1)) {
        _ = try await controller.connect(requestedFeatures: [])
    }

    #expect(await controller.state == .disconnected)
    #expect(await transport.disconnected)
}

private enum HostHandshakeHandlerFixture {
    static func response(for request: CPHandshakeRequest) throws -> CPHandshakeResponse {
        try ProtocolNegotiator(
            serviceKind: "host",
            supportedFeatures: [.workspaceControl]
        ).negotiate(request)
    }
}

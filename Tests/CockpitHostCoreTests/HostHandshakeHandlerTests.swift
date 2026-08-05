import Foundation
import Testing
import CockpitTypes
import CockpitProtocol
@testable import CockpitHostCore

@Test func hostAcceptsIntersectionOfFeatures() throws {
    let handler = HostHandshakeHandler()
    let deviceUUID = try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000020")
    )
    let request = CPHandshakeRequest.cockpit(
        deviceID: DeviceID(deviceUUID),
        features: [.workspaceControl, .terminalFrames]
    )
    let response = try handler.handle(request)
    #expect(response.serviceKind == "host")
    #expect(response.acceptedFeatures == ["workspace-control"])
}

@Test func hostRejectsAnotherMajorVersion() {
    var request = CPHandshakeRequest()
    request.protocolMajor = 2
    request.protocolMinor = 0
    request.deviceID = UUID().uuidString
    #expect(throws: ProtocolNegotiationError.incompatibleMajor(client: 2, service: 1)) {
        _ = try HostHandshakeHandler().handle(request)
    }
}

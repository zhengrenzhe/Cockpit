import Foundation
import Testing
import CockpitTypes
import CockpitProtocol
@testable import CockpitTerminalCore

@Test func terminalAdvertisesTerminalFeaturesOnly() throws {
    let request = CPHandshakeRequest.cockpit(
        deviceID: DeviceID(),
        features: [.workspaceControl, .terminalControl, .terminalFrames]
    )
    let response = try TerminalSupervisorHandshakeHandler().handle(request)
    #expect(response.serviceKind == "terminal")
    #expect(response.acceptedFeatures == ["terminal-control", "terminal-frames"])
}

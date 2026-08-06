import Foundation
import CockpitClientCore
import CockpitLocalTransport
import CockpitTypes

@MainActor
final class ServiceStatusViewModel {
    func statusText() async -> String {
        var rows: [String] = []
        for endpoint in [XPCServiceEndpoint.host, .terminal] {
            do {
                let controller = ConnectionController(
                    transport: XPCHandshakeClient(endpoint: endpoint),
                    deviceID: DeviceID()
                )
                let session = try await controller.connect(
                    requestedFeatures: [.workspaceControl, .terminalControl, .terminalFrames]
                )
                rows.append(
                    "\(session.serviceKind): protocol "
                        + "\(session.version.major).\(session.version.minor)"
                )
            } catch {
                rows.append("\(endpoint.machServiceName): unavailable")
            }
        }
        return rows.joined(separator: "\n")
    }
}

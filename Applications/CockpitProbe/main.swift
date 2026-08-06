import Foundation
import CockpitClientCore
import CockpitLocalTransport
import CockpitTerminalCore
import CockpitTypes

enum ProbeError: Error {
    case invalidCommand
}

@main
enum CockpitProbe {
    static func main() async throws {
        switch CommandLine.arguments.dropFirst().first {
        case "services":
            try await probeServices()
        case "spawn-keeper":
            try await spawnKeeper()
        default:
            throw ProbeError.invalidCommand
        }
    }

    private static func probeServices() async throws {
        for endpoint in [XPCServiceEndpoint.host, .terminal] {
            let controller = ConnectionController(
                transport: XPCHandshakeClient(endpoint: endpoint),
                deviceID: DeviceID()
            )
            let session = try await controller.connect(
                requestedFeatures: [
                    .workspaceControl,
                    .terminalControl,
                    .terminalFrames,
                ]
            )
            print(
                "\(endpoint.machServiceName) \(session.serviceKind) "
                    + "\(session.version.major).\(session.version.minor)"
            )
        }
    }

    private static func spawnKeeper() async throws {
        let client = TerminalSupervisorXPCClient()
        let receipt = try await client.spawnKeeperProbe(
            KeeperProbeRequest(
                sessionID: TerminalSessionID(),
                workerInstanceID: WorkerInstanceID()
            )
        )
        await client.disconnect()
        print(
            [
                String(receipt.processID),
                receipt.sessionID.description,
                receipt.workerInstanceID.description,
                receipt.runtimeDescriptorPath,
            ].joined(separator: "\t")
        )
    }
}

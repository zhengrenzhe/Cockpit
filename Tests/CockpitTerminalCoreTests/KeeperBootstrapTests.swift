import Foundation
import Testing
import CockpitTypes
@testable import CockpitTerminalCore

@Test func terminalLifecycleRawValuesRemainStable() {
    #expect(TerminalLifecycleState.allCases.map(\.rawValue) == [
        "preparing", "committed", "running", "exited", "terminated", "interrupted",
    ])
}

@Test func keeperBootstrapRoundTripsWithoutArgvState() throws {
    let sessionUUID = try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000031")
    )
    let workerUUID = try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000032")
    )
    let bootstrap = KeeperBootstrap(
        sessionID: TerminalSessionID(sessionUUID),
        workerInstanceID: WorkerInstanceID(workerUUID),
        runtimeDirectory: "/private/tmp/cockpit.501/terminal"
    )
    let encoded = try JSONEncoder().encode(bootstrap)
    #expect(try JSONDecoder().decode(KeeperBootstrap.self, from: encoded) == bootstrap)
    #expect(KeeperBootstrap.inheritedFileDescriptor == 3)
    #expect(KeeperBootstrap.bootstrapTimeoutNanoseconds == 30_000_000_000)
}

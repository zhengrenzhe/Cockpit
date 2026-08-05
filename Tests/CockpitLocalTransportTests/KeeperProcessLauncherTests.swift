import Darwin
import Testing
@testable import CockpitLocalTransport

@Test func keeperSpawnFlagsCreateIndependentSessionAndCloseUndeclaredDescriptors() {
    #expect(
        KeeperProcessLauncher.spawnFlags
            == Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
    )
}

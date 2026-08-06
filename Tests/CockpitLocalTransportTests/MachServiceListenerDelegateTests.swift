import Foundation
import Testing
@testable import CockpitLocalTransport

private final class FakeIncomingXPCConnection: IncomingXPCConnectionBoundary {
    let effectiveUserIdentifier: uid_t
    var exportedInterface: NSXPCInterface?
    var exportedObject: Any?
    private(set) var resumeCount = 0

    init(effectiveUserIdentifier: uid_t) {
        self.effectiveUserIdentifier = effectiveUserIdentifier
    }

    func resume() {
        resumeCount += 1
    }
}

@Test func listenerRejectsWrongUIDBeforeConfigurationOrResume() {
    let delegate = MachServiceListenerDelegate(
        exportedObject: NSObject(),
        exportedInterface: NSXPCInterface(with: XPCHandshakeProtocol.self),
        peerValidator: XPCPeerValidator(expectedEffectiveUserIdentifier: 501)
    )
    let connection = FakeIncomingXPCConnection(effectiveUserIdentifier: 502)

    #expect(!delegate.shouldAccept(connection))
    #expect(connection.exportedInterface == nil)
    #expect(connection.exportedObject == nil)
    #expect(connection.resumeCount == 0)
}

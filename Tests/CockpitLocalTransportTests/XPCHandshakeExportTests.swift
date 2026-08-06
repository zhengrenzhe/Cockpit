import Foundation
import Testing
import CockpitProtocol
import CockpitTypes
import CockpitHostCore
import CockpitTerminalCore
@testable import CockpitLocalTransport

@Test func exportedObjectReturnsEncodedHandshake() async throws {
    let exported = XPCHandshakeExport { request in
        try HostHandshakeHandler().handle(request)
    }
    let request = CPHandshakeRequest.cockpit(
        deviceID: DeviceID(),
        features: [.workspaceControl]
    )

    let encodedRequest = try HandshakeCodec.encode(request)
    let responseData: Data = try await withCheckedThrowingContinuation { continuation in
        exported.exchangeHandshake(encodedRequest) { data, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: CocoaError(.coderInvalidValue))
            }
        }
    }

    let response = try HandshakeCodec.decodeResponse(responseData)
    #expect(response.serviceKind == "host")
}

@Test func peerValidatorAcceptsOnlyTheConfiguredEffectiveUser() {
    let validator = XPCPeerValidator(expectedEffectiveUserIdentifier: 501)
    #expect(validator.accepts(effectiveUserIdentifier: 501))
    #expect(!validator.accepts(effectiveUserIdentifier: 502))
}

@Test func handshakeExportRejectsMalformedProtobufWithoutData() {
    let exported = XPCHandshakeExport { request in
        try HostHandshakeHandler().handle(request)
    }
    var replies: [(Data?, NSError?)] = []

    exported.exchangeHandshake(Data([0xFF])) { data, error in
        replies.append((data, error))
    }

    #expect(replies.count == 1)
    #expect(replies[0].0 == nil)
    #expect(replies[0].1 != nil)
}

@Test func terminalSupervisorExportEncodesKeeperLaunchReceiptAsJSON() throws {
    let sessionID = TerminalSessionID(try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000041")
    ))
    let workerInstanceID = WorkerInstanceID(try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000042")
    ))
    let request = KeeperProbeRequest(
        sessionID: sessionID,
        workerInstanceID: workerInstanceID
    )
    let exported = TerminalSupervisorXPCExport(
        handshakeHandler: { request in try HostHandshakeHandler().handle(request) },
        spawnHandler: { probe in
            KeeperLaunchReceipt(
                sessionID: probe.sessionID,
                workerInstanceID: probe.workerInstanceID,
                processID: 4242,
                runtimeDescriptorPath: "/private/tmp/cockpit.501/terminal/receipt.json"
            )
        }
    )
    var replies: [(Data?, NSError?)] = []

    exported.spawnKeeperProbe(try JSONEncoder().encode(request)) { data, error in
        replies.append((data, error))
    }

    #expect(replies.count == 1)
    #expect(replies[0].1 == nil)
    let data = try #require(replies[0].0)
    #expect(try JSONDecoder().decode(KeeperLaunchReceipt.self, from: data) == KeeperLaunchReceipt(
        sessionID: sessionID,
        workerInstanceID: workerInstanceID,
        processID: 4242,
        runtimeDescriptorPath: "/private/tmp/cockpit.501/terminal/receipt.json"
    ))
}

@Test func terminalSupervisorExportRejectsMalformedJSONWithoutData() {
    let exported = TerminalSupervisorXPCExport(
        handshakeHandler: { request in try HostHandshakeHandler().handle(request) },
        spawnHandler: { _ in
            fatalError("malformed JSON must not reach the spawn handler")
        }
    )
    var replies: [(Data?, NSError?)] = []

    exported.spawnKeeperProbe(Data("not-json".utf8)) { data, error in
        replies.append((data, error))
    }

    #expect(replies.count == 1)
    #expect(replies[0].0 == nil)
    #expect(replies[0].1 != nil)
}

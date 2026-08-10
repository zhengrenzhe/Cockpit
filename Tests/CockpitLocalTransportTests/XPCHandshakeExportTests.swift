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

@Test func terminalSupervisorExportReturnsArchiveAsFileHandle() async throws {
    let sessionID = TerminalSessionID(try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000041")
    ))
    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cockpit-terminal-archive-\(UUID().uuidString)")
    let archiveBytes = Data([0x43, 0x4B, 0x47, 0x46])
    try archiveBytes.write(to: archiveURL)
    defer { try? FileManager.default.removeItem(at: archiveURL) }
    let exported = TerminalSupervisorXPCExport(
        handshakeHandler: { request in try HostHandshakeHandler().handle(request) },
        archiveHandler: { requestedSessionID in
            guard requestedSessionID == sessionID else {
                throw CocoaError(.coderInvalidValue)
            }
            return try FileHandle(forReadingFrom: archiveURL)
        }
    )
    let handle: FileHandle = try await withCheckedThrowingContinuation { continuation in
        exported.openTerminalArchive(try! JSONEncoder().encode(sessionID)) { handle, error in
            if let error { continuation.resume(throwing: error) }
            else if let handle { continuation.resume(returning: handle) }
            else { continuation.resume(throwing: CocoaError(.coderInvalidValue)) }
        }
    }

    #expect(try handle.readToEnd() == archiveBytes)
    try handle.close()
}

@Test func terminalSupervisorArchiveExportRejectsMalformedJSONWithoutHandle() {
    let exported = TerminalSupervisorXPCExport(
        handshakeHandler: { request in try HostHandshakeHandler().handle(request) },
        archiveHandler: { _ in
            fatalError("malformed JSON must not reach the archive handler")
        }
    )
    var replies: [(FileHandle?, NSError?)] = []

    exported.openTerminalArchive(Data("not-json".utf8)) { handle, error in
        replies.append((handle, error))
    }

    #expect(replies.count == 1)
    #expect(replies[0].0 == nil)
    #expect(replies[0].1 != nil)
}

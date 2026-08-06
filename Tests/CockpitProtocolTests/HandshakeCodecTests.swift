import Testing
@testable import CockpitProtocol

@Test func handshakeRequestRoundTrips() throws {
    var request = CPHandshakeRequest()
    request.protocolMajor = 1
    request.protocolMinor = 0
    request.deviceID = "00000000-0000-0000-0000-000000000010"
    request.requestedFeatures = ["workspace-control", "terminal-frames"]

    let data = try HandshakeCodec.encode(request)
    let decoded = try HandshakeCodec.decodeRequest(data)
    #expect(decoded == request)
}

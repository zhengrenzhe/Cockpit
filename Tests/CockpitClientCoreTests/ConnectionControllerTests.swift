import Foundation
import Testing
import CockpitTypes
import CockpitProtocol
@testable import CockpitClientCore

private enum TestTransportFailure: Error, Equatable, Sendable {
    case connect
    case exchange
}

private enum TestTransportFailurePoint: Sendable {
    case none
    case connect
    case exchange
}

private struct TransportSnapshot: Sendable {
    let calls: [String]
    let handshakeRequests: [Data]
}

private actor RecordingTransport: CockpitTransport {
    let response: Data
    let failurePoint: TestTransportFailurePoint
    private var calls: [String] = []
    private var handshakeRequests: [Data] = []

    init(response: Data, failurePoint: TestTransportFailurePoint = .none) {
        self.response = response
        self.failurePoint = failurePoint
    }

    func connect() async throws {
        calls.append("connect")
        if case .connect = failurePoint {
            throw TestTransportFailure.connect
        }
    }

    func exchangeHandshake(_ request: Data) async throws -> Data {
        calls.append("exchange")
        handshakeRequests.append(request)
        if case .exchange = failurePoint {
            throw TestTransportFailure.exchange
        }
        return response
    }

    func disconnect() async {
        calls.append("disconnect")
    }

    func snapshot() -> TransportSnapshot {
        TransportSnapshot(calls: calls, handshakeRequests: handshakeRequests)
    }
}

private actor BarrierTransport: CockpitTransport {
    let response: Data
    private var calls: [String] = []
    private var handshakeRequests: [Data] = []
    private var exchangeStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseExchangeContinuation: CheckedContinuation<Void, Never>?

    init(response: Data) {
        self.response = response
    }

    func connect() async throws {
        calls.append("connect")
    }

    func exchangeHandshake(_ request: Data) async throws -> Data {
        calls.append("exchange")
        handshakeRequests.append(request)
        let waiters = exchangeStartedWaiters
        exchangeStartedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseExchangeContinuation = continuation
        }
        return response
    }

    func disconnect() async {
        calls.append("disconnect")
    }

    func waitUntilExchangeStarts() async {
        guard !calls.contains("exchange") else { return }
        await withCheckedContinuation { continuation in
            exchangeStartedWaiters.append(continuation)
        }
    }

    func releaseExchange() {
        releaseExchangeContinuation?.resume()
        releaseExchangeContinuation = nil
    }

    func snapshot() -> TransportSnapshot {
        TransportSnapshot(calls: calls, handshakeRequests: handshakeRequests)
    }
}

private actor DisconnectBarrierTransport: CockpitTransport {
    private var calls: [String] = []
    private var disconnectStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseDisconnectContinuation: CheckedContinuation<Void, Never>?

    func connect() async throws {
        calls.append("connect")
    }

    func exchangeHandshake(_ request: Data) async throws -> Data {
        calls.append("exchange")
        throw TestTransportFailure.exchange
    }

    func disconnect() async {
        calls.append("disconnect")
        let waiters = disconnectStartedWaiters
        disconnectStartedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseDisconnectContinuation = continuation
        }
    }

    func waitUntilDisconnectStarts() async {
        guard !calls.contains("disconnect") else { return }
        await withCheckedContinuation { continuation in
            disconnectStartedWaiters.append(continuation)
        }
    }

    func releaseDisconnect() {
        releaseDisconnectContinuation?.resume()
        releaseDisconnectContinuation = nil
    }

    func snapshot() -> TransportSnapshot {
        TransportSnapshot(calls: calls, handshakeRequests: [])
    }
}

@Test func controllerSendsTheRequestedHandshakeAndReachesReady() async throws {
    let deviceUUID = try #require(
        UUID(uuidString: "00000000-0000-0000-0000-000000000041")
    )
    let transport = RecordingTransport(
        response: try encodedResponse(acceptedFeatures: ["workspace-control"])
    )
    let controller = ConnectionController(
        transport: transport,
        deviceID: DeviceID(deviceUUID)
    )

    let session = try await controller.connect(
        requestedFeatures: [.workspaceControl, .terminalFrames]
    )

    #expect(session.serviceKind == "host")
    #expect(session.acceptedFeatures == [.workspaceControl])
    #expect(await controller.state == .ready(session))
    let snapshot = await transport.snapshot()
    #expect(snapshot.calls == ["connect", "exchange"])
    let requestData = try #require(snapshot.handshakeRequests.first)
    let request = try HandshakeCodec.decodeRequest(requestData)
    #expect(request.protocolMajor == 1)
    #expect(request.protocolMinor == 0)
    #expect(request.deviceID == "00000000-0000-0000-0000-000000000041")
    #expect(request.requestedFeatures == ["terminal-frames", "workspace-control"])
}

@Test func concurrentConnectIsRejectedWithoutDisturbingTheFirstConnection() async throws {
    let transport = BarrierTransport(response: try encodedResponse())
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())
    let firstConnect = Task {
        try await controller.connect(requestedFeatures: [.workspaceControl])
    }
    await transport.waitUntilExchangeStarts()

    await #expect(throws: ConnectionControllerError.alreadyConnecting) {
        _ = try await controller.connect(requestedFeatures: [.terminalFrames])
    }
    let blockedSnapshot = await transport.snapshot()
    #expect(blockedSnapshot.calls == ["connect", "exchange"])

    await transport.releaseExchange()
    let session = try await firstConnect.value
    #expect(await controller.state == .ready(session))
    let finalSnapshot = await transport.snapshot()
    #expect(finalSnapshot.calls == ["connect", "exchange"])
    #expect(finalSnapshot.handshakeRequests.count == 1)
}

@Test func readyControllerRejectsReconnectAndPreservesSession() async throws {
    let transport = RecordingTransport(response: try encodedResponse())
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())
    let session = try await controller.connect(requestedFeatures: [.workspaceControl])

    await #expect(throws: ConnectionControllerError.alreadyReady) {
        _ = try await controller.connect(requestedFeatures: [.terminalFrames])
    }

    #expect(await controller.state == .ready(session))
    let snapshot = await transport.snapshot()
    #expect(snapshot.calls == ["connect", "exchange"])
    #expect(snapshot.handshakeRequests.count == 1)
}

@Test func controllerRemainsConnectingUntilTransportDisconnectCompletes() async throws {
    let transport = DisconnectBarrierTransport()
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())
    let connect = Task {
        try await controller.connect(requestedFeatures: [])
    }
    await transport.waitUntilDisconnectStarts()

    #expect(await controller.state == .connecting)

    await transport.releaseDisconnect()
    await #expect(throws: TestTransportFailure.exchange) {
        _ = try await connect.value
    }
    #expect(await controller.state == .disconnected)
    #expect(await transport.snapshot().calls == ["connect", "exchange", "disconnect"])
}

@Test func controllerRejectsResponseMinorAboveRequestedMinor() async throws {
    let transport = RecordingTransport(response: try encodedResponse(minor: 1))
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    await #expect(
        throws: ProtocolNegotiationError.responseMinorExceedsRequest(response: 1, request: 0)
    ) {
        _ = try await controller.connect(requestedFeatures: [.workspaceControl])
    }

    #expect(await controller.state == .disconnected)
    #expect(await transport.snapshot().calls == ["connect", "exchange", "disconnect"])
}

@Test func controllerRejectsFeaturesThatWereNotRequested() async throws {
    let transport = RecordingTransport(
        response: try encodedResponse(
            acceptedFeatures: ["terminal-frames", "workspace-control"]
        )
    )
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    await #expect(
        throws: ProtocolNegotiationError.unrequestedAcceptedFeatures(["terminal-frames"])
    ) {
        _ = try await controller.connect(requestedFeatures: [.workspaceControl])
    }

    #expect(await controller.state == .disconnected)
    #expect(await transport.snapshot().calls == ["connect", "exchange", "disconnect"])
}

@Test func controllerDisconnectsAndResetsWhenTransportConnectThrows() async throws {
    let transport = RecordingTransport(
        response: try encodedResponse(),
        failurePoint: .connect
    )
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    await #expect(throws: TestTransportFailure.connect) {
        _ = try await controller.connect(requestedFeatures: [])
    }

    #expect(await controller.state == .disconnected)
    #expect(await transport.snapshot().calls == ["connect", "disconnect"])
}

@Test func controllerDisconnectsAndResetsWhenHandshakeExchangeThrows() async throws {
    let transport = RecordingTransport(
        response: try encodedResponse(),
        failurePoint: .exchange
    )
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    await #expect(throws: TestTransportFailure.exchange) {
        _ = try await controller.connect(requestedFeatures: [])
    }

    #expect(await controller.state == .disconnected)
    #expect(await transport.snapshot().calls == ["connect", "exchange", "disconnect"])
}

@Test func controllerDisconnectsAndResetsForMalformedHandshakeResponse() async {
    let transport = RecordingTransport(response: Data([0xFF]))
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    await #expect(throws: (any Error).self) {
        _ = try await controller.connect(requestedFeatures: [])
    }

    #expect(await controller.state == .disconnected)
    #expect(await transport.snapshot().calls == ["connect", "exchange", "disconnect"])
}

@Test func controllerDisconnectsAndResetsForInvalidConnectionID() async throws {
    let transport = RecordingTransport(
        response: try encodedResponse(connectionID: "invalid-connection-id")
    )
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    await #expect(throws: ProtocolNegotiationError.invalidConnectionID("invalid-connection-id")) {
        _ = try await controller.connect(requestedFeatures: [])
    }

    #expect(await controller.state == .disconnected)
    #expect(await transport.snapshot().calls == ["connect", "exchange", "disconnect"])
}

@Test func controllerDisconnectsAndResetsForOverflowedProtocolVersion() async throws {
    let transport = RecordingTransport(response: try encodedResponse(major: 65_536))
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    await #expect(
        throws: ProtocolNegotiationError.invalidProtocolVersion(major: 65_536, minor: 0)
    ) {
        _ = try await controller.connect(requestedFeatures: [])
    }

    #expect(await controller.state == .disconnected)
    #expect(await transport.snapshot().calls == ["connect", "exchange", "disconnect"])
}

@Test func controllerDisconnectsAndResetsForIncompatibleMajor() async throws {
    let transport = RecordingTransport(response: try encodedResponse(major: 2))
    let controller = ConnectionController(transport: transport, deviceID: DeviceID())

    await #expect(throws: ProtocolNegotiationError.incompatibleMajor(client: 2, service: 1)) {
        _ = try await controller.connect(requestedFeatures: [])
    }

    #expect(await controller.state == .disconnected)
    #expect(await transport.snapshot().calls == ["connect", "exchange", "disconnect"])
}

private func encodedResponse(
    major: UInt32 = 1,
    minor: UInt32 = 0,
    connectionID: String = "00000000-0000-0000-0000-000000000042",
    acceptedFeatures: [String] = ["workspace-control"]
) throws -> Data {
    var response = CPHandshakeResponse()
    response.protocolMajor = major
    response.protocolMinor = minor
    response.connectionID = connectionID
    response.acceptedFeatures = acceptedFeatures
    response.serviceKind = "host"
    return try HandshakeCodec.encode(response)
}

import Foundation
import Network
import Security
import Testing
import CockpitTypes
import CockpitProtocol
import CockpitHostCore
@testable import CockpitRemoteTransport

private enum TestTimeoutError: Error {
    case exceeded
}

private func withTimeout<T: Sendable>(
    _ duration: Duration = .seconds(5),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: duration)
            throw TestTimeoutError.exceeded
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw TestTimeoutError.exceeded }
        return value
    }
}

@Test func remoteTransportNegotiatesOverTLS13() async throws {
    let fixture = try TLSFixture.load()
    let server = try RemoteHandshakeLoopbackServer(identity: fixture.identity)
    try await withTimeout { try await server.start() }
    defer { server.stop() }
    let serverPort = try #require(server.port)

    let transport = try RemoteDirectTransport(
        host: "127.0.0.1",
        port: serverPort.rawValue,
        pinnedCertificateDER: SecCertificateCopyData(fixture.certificate) as Data
    )
    try await withTimeout { try await transport.connect() }
    #expect(await transport.negotiatedTLSVersion() == .TLSv13)
    let request = CPHandshakeRequest.cockpit(deviceID: DeviceID(), features: [.workspaceControl, .remoteDirect])
    let responseData = try await withTimeout {
        try await transport.exchangeHandshake(HandshakeCodec.encode(request))
    }
    let response = try HandshakeCodec.decodeResponse(responseData)

    #expect(response.serviceKind == "host")
    #expect(response.acceptedFeatures == ["remote-direct", "workspace-control"])
    await transport.disconnect()
}

@Test func remoteTransportRejectsPortZero() {
    #expect(throws: RemoteTransportError.invalidPort(0)) {
        _ = try RemoteDirectTransport(host: "127.0.0.1", port: 0, pinnedCertificateDER: Data())
    }
}

@Test func remoteTransportRejectsWrongLeafPin() async throws {
    let fixture = try TLSFixture.load()
    let server = try RemoteHandshakeLoopbackServer(identity: fixture.identity)
    try await withTimeout { try await server.start() }
    defer { server.stop() }
    let port = try #require(server.port)
    let transport = try RemoteDirectTransport(
        host: "127.0.0.1",
        port: port.rawValue,
        pinnedCertificateDER: Data(repeating: 0xA5, count: 32)
    )

    do {
        try await withTimeout { try await transport.connect() }
        Issue.record("TLS connection accepted a non-matching leaf DER pin")
    } catch is TestTimeoutError {
        Issue.record("TLS pin rejection timed out")
    } catch {
        await transport.disconnect()
    }
}

@Test func remoteTransportRejectsHandshakeBeforeConnect() async throws {
    let transport = try RemoteDirectTransport(host: "127.0.0.1", port: 1, pinnedCertificateDER: Data())
    do {
        _ = try await transport.exchangeHandshake(Data())
        Issue.record("Handshake exchange succeeded before connect")
    } catch let error as RemoteTransportError {
        #expect(error == .notConnected)
    } catch {
        Issue.record("Unexpected pre-connect error: \(error)")
    }
}

@Test func remoteTransportDisconnectIsIdempotent() async throws {
    let transport = try RemoteDirectTransport(host: "127.0.0.1", port: 1, pinnedCertificateDER: Data())
    await transport.disconnect()
    await transport.disconnect()
    do {
        _ = try await transport.exchangeHandshake(Data())
        Issue.record("Disconnected transport accepted a handshake")
    } catch let error as RemoteTransportError {
        #expect(error == .notConnected)
    } catch {
        Issue.record("Unexpected idempotent-disconnect error: \(error)")
    }
}

@Test func staleConnectionAttemptCannotDisconnectNewConnection() async throws {
    let fixture = try TLSFixture.load()
    let server = try RemoteHandshakeLoopbackServer(identity: fixture.identity)
    try await withTimeout { try await server.start() }
    defer { server.stop() }
    let port = try #require(server.port)
    let gate = FirstAttemptGate()
    let transport = try RemoteDirectTransport(
        host: "127.0.0.1",
        port: port.rawValue,
        pinnedCertificateDER: SecCertificateCopyData(fixture.certificate) as Data,
        beforeStart: { await gate.waitOnFirstAttempt() }
    )

    let first = Task { try? await withTimeout { try await transport.connect() } }
    await gate.waitUntilFirstAttemptIsBlocked()
    await transport.disconnect()
    let second = Task { try? await withTimeout { try await transport.connect() } }
    await gate.releaseFirstAttempt()
    _ = await first.value
    _ = await second.value

    let request = CPHandshakeRequest.cockpit(deviceID: DeviceID(), features: [.workspaceControl, .remoteDirect])
    let responseData = try await withTimeout { try await transport.exchangeHandshake(HandshakeCodec.encode(request)) }
    #expect(try HandshakeCodec.decodeResponse(responseData).serviceKind == "host")
    await transport.disconnect()
}

@Test func remoteTransportAllowsOnlyOneConcurrentConnectionAttempt() async throws {
    let fixture = try TLSFixture.load()
    let server = try RemoteHandshakeLoopbackServer(identity: fixture.identity)
    try await withTimeout { try await server.start() }
    defer { server.stop() }
    let port = try #require(server.port)
    let transport = try RemoteDirectTransport(
        host: "127.0.0.1",
        port: port.rawValue,
        pinnedCertificateDER: SecCertificateCopyData(fixture.certificate) as Data
    )

    async let first = connectionResult(transport)
    async let second = connectionResult(transport)
    let results = await [first, second]
    #expect(results.filter { $0 == nil }.count == 1)
    #expect(results.contains(.alreadyConnecting) || results.contains(.alreadyConnected))

    await transport.disconnect()
}

@Test func byteStreamRejectsInvalidMaximumLengthBeforeReceive() async {
    let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
    let stream = NWConnectionByteStream(connection: connection)
    do {
        _ = try await stream.receiveLengthPrefixed(maximumLength: -1)
        Issue.record("Negative maximum length was accepted")
    } catch let error as NetworkByteStreamError {
        #expect(error == .invalidMaximumLength(-1))
    } catch {
        Issue.record("Unexpected maximum length error: \(error)")
    }
}

private func connectionResult(_ transport: RemoteDirectTransport) async -> RemoteTransportError? {
    do {
        try await withTimeout { try await transport.connect() }
        return nil
    } catch let error as RemoteTransportError {
        return error
    } catch {
        Issue.record("Unexpected connect error: \(error)")
        return .connectionFailed
    }
}

private actor FirstAttemptGate {
    private var first = true
    private var isBlocked = false
    private var blockedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitOnFirstAttempt() async {
        guard first else { return }
        first = false
        isBlocked = true
        blockedWaiter?.resume()
        blockedWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilFirstAttemptIsBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { blockedWaiter = $0 }
    }

    func releaseFirstAttempt() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class RemoteHandshakeLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.cockpit.tests.remote-listener")

    var port: NWEndpoint.Port? { listener.port }

    init(identity: SecIdentity) throws {
        let parameters = NWParameters(tls: try TLSOptionsFactory.server(identity: identity))
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handle(connection) }
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) async {
        let stream = NWConnectionByteStream(connection: connection)
        do {
            try await stream.start()
            let requestData = try await stream.receiveLengthPrefixed()
            let request = try HandshakeCodec.decodeRequest(requestData)
            let response = try HostHandshakeHandler().handle(request)
            try await stream.sendLengthPrefixed(HandshakeCodec.encode(response))
        } catch {
        }
        await stream.cancel()
    }
}

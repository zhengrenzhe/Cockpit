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

@Test func remoteTransportRejectsConcurrentHandshakeExchange() async throws {
    let fixture = try TLSFixture.load()
    let server = try RemoteHandshakeLoopbackServer(identity: fixture.identity, behavior: .stallFirstRequest)
    try await withTimeout { try await server.start() }
    defer { server.stop() }
    let port = try #require(server.port)
    let transport = try RemoteDirectTransport(
        host: "127.0.0.1",
        port: port.rawValue,
        pinnedCertificateDER: SecCertificateCopyData(fixture.certificate) as Data
    )
    try await withTimeout { try await transport.connect() }

    let first = Task { try? await withTimeout(.seconds(1)) { try await transport.exchangeHandshake(Data([1])) } }
    try await withTimeout { await server.waitUntilFirstRequestIsStalled() }
    do {
        _ = try await withTimeout { try await transport.exchangeHandshake(Data([2])) }
        Issue.record("A second handshake exchange was accepted while the first was active")
    } catch let error as RemoteTransportError {
        #expect(error == .exchangeInProgress)
    }

    try await withTimeout { await transport.disconnect() }
    _ = await first.value
    server.stop()
    try await withTimeout { try await server.waitUntilIdle() }
}

@Test func remoteTransportReconnectsAfterPeerClosesMidHandshake() async throws {
    let fixture = try TLSFixture.load()
    let server = try RemoteHandshakeLoopbackServer(identity: fixture.identity, behavior: .dropFirstConnection)
    try await withTimeout { try await server.start() }
    defer { server.stop() }
    let port = try #require(server.port)
    let transport = try RemoteDirectTransport(
        host: "127.0.0.1",
        port: port.rawValue,
        pinnedCertificateDER: SecCertificateCopyData(fixture.certificate) as Data
    )
    let request = try HandshakeCodec.encode(.cockpit(deviceID: DeviceID(), features: [.workspaceControl, .remoteDirect]))

    try await withTimeout { try await transport.connect() }
    do {
        _ = try await withTimeout { try await transport.exchangeHandshake(request) }
        Issue.record("The peer closed the first connection without failing the handshake")
    } catch is TestTimeoutError {
        Issue.record("The first handshake did not finish after the peer closed it")
    } catch {
    }

    try await withTimeout { try await transport.connect() }
    let response = try await withTimeout { try await transport.exchangeHandshake(request) }
    #expect(try HandshakeCodec.decodeResponse(response).serviceKind == "host")
    try await withTimeout { await transport.disconnect() }
    server.stop()
    try await withTimeout { try await server.waitUntilIdle() }
}

@Test func stalledPeerTimeoutCleansUpConnectionsAndHandlers() async throws {
    let fixture = try TLSFixture.load()
    let server = try RemoteHandshakeLoopbackServer(identity: fixture.identity, behavior: .stallFirstRequest)
    try await withTimeout { try await server.start() }
    let port = try #require(server.port)
    let transport = try RemoteDirectTransport(
        host: "127.0.0.1",
        port: port.rawValue,
        pinnedCertificateDER: SecCertificateCopyData(fixture.certificate) as Data
    )
    defer { server.stop() }
    try await withTimeout { try await transport.connect() }

    let startedAt = Date()
    do {
        _ = try await withTimeout(.milliseconds(250)) { try await transport.exchangeHandshake(Data([1])) }
        Issue.record("A stalled peer returned a handshake response")
    } catch is TestTimeoutError {
    } catch {
    }
    #expect(Date().timeIntervalSince(startedAt) < 1)

    try await withTimeout { await transport.disconnect() }
    server.stop()
    try await withTimeout { try await server.waitUntilIdle() }
    #expect(server.activeConnectionCount == 0)
    #expect(server.activeHandlerCount == 0)
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

@Test func byteStreamRejectsOperationsBeforeStartAndAfterCancel() async {
    let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
    let stream = NWConnectionByteStream(connection: connection)
    do {
        try await stream.sendLengthPrefixed(Data())
        Issue.record("A byte stream sent data before it was ready")
    } catch let error as NetworkByteStreamError {
        #expect(error == .notReady)
    } catch {
        Issue.record("Unexpected pre-start send error: \(error)")
    }
    do {
        _ = try await stream.receiveLengthPrefixed()
        Issue.record("A byte stream received data before it was ready")
    } catch let error as NetworkByteStreamError {
        #expect(error == .notReady)
    } catch {
        Issue.record("Unexpected pre-start receive error: \(error)")
    }
    await stream.cancel()
    do {
        try await stream.sendLengthPrefixed(Data())
        Issue.record("A cancelled byte stream sent data")
    } catch let error as NetworkByteStreamError {
        #expect(error == .closed)
    } catch {
        Issue.record("Unexpected cancelled send error: \(error)")
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
    enum Behavior: Sendable {
        case normal
        case dropFirstConnection
        case stallFirstRequest
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.cockpit.tests.remote-listener")
    private let lock = NSLock()
    private let behavior: Behavior
    private var stopped = false
    private var connectionCount = 0
    private var firstRequestStalled = false
    private var stalledWaiter: CheckedContinuation<Void, Never>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var handlers: [ObjectIdentifier: Task<Void, Never>] = [:]

    var port: NWEndpoint.Port? { listener.port }
    var activeConnectionCount: Int { withLock { connections.count } }
    var activeHandlerCount: Int { withLock { handlers.count } }

    init(identity: SecIdentity, behavior: Behavior = .normal) throws {
        let parameters = NWParameters(tls: try TLSOptionsFactory.server(identity: identity))
        listener = try NWListener(using: parameters, on: .any)
        self.behavior = behavior
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.add(connection)
        }

        let completion = ListenerStartCompletion()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
                completion.install(continuation)
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    completion.resolve(.success(()))
                case .failed(let error):
                    listener?.stateUpdateHandler = nil
                    completion.resolve(.failure(error))
                case .cancelled:
                    listener?.stateUpdateHandler = nil
                    completion.resolve(.failure(NetworkByteStreamError.closed))
                default:
                    break
                }
            }
            listener.start(queue: queue)
            }
        }, onCancel: {
            self.listener.cancel()
            completion.resolve(.failure(CancellationError()))
        })
    }

    func stop() {
        let pending: ([NWConnection], [Task<Void, Never>]) = withLock {
            guard !stopped else { return ([], []) }
            stopped = true
            let pending = (Array(connections.values), Array(handlers.values))
            connections.removeAll()
            handlers.removeAll()
            stalledWaiter?.resume()
            stalledWaiter = nil
            return pending
        }
        listener.cancel()
        pending.0.forEach { $0.cancel() }
        pending.1.forEach { $0.cancel() }
    }

    func waitUntilFirstRequestIsStalled() async {
        if withLock({ firstRequestStalled }) { return }
        await withCheckedContinuation { continuation in
            let resume = withLock { () -> Bool in
                if firstRequestStalled { return true }
                stalledWaiter = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func waitUntilIdle() async throws {
        for _ in 0 ..< 50 {
            if activeConnectionCount == 0, activeHandlerCount == 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestTimeoutError.exceeded
    }

    private func add(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        let shouldCancel = withLock { () -> Bool in
            if stopped { return true }
            connections[identifier] = connection
            return false
        }
        guard !shouldCancel else {
            connection.cancel()
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.handle(connection)
            self.remove(identifier)
        }
        withLock {
            if connections[identifier] != nil {
                handlers[identifier] = task
            } else {
                task.cancel()
            }
        }
    }

    private func remove(_ identifier: ObjectIdentifier) {
        withLock {
            connections.removeValue(forKey: identifier)
            handlers.removeValue(forKey: identifier)
        }
    }

    private func handle(_ connection: NWConnection) async {
        let stream = NWConnectionByteStream(connection: connection)
        defer { connection.cancel() }
        do {
            try await stream.start()
            let requestData = try await stream.receiveLengthPrefixed()
            let shouldDrop = withLock { () -> Bool in
                connectionCount += 1
                return behavior == .dropFirstConnection && connectionCount == 1
            }
            if shouldDrop { return }
            let shouldStall = withLock { () -> Bool in
                guard behavior == .stallFirstRequest, !firstRequestStalled else { return false }
                firstRequestStalled = true
                stalledWaiter?.resume()
                stalledWaiter = nil
                return true
            }
            if shouldStall {
                try await Task.sleep(for: .seconds(60))
                return
            }
            let request = try HandshakeCodec.decodeRequest(requestData)
            let response = try HostHandshakeHandler().handle(request)
            try await stream.sendLengthPrefixed(HandshakeCodec.encode(response))
        } catch {
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class ListenerStartCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        let result = self.result
        if result == nil { self.continuation = continuation }
        lock.unlock()
        result.map { continuation.resume(with: $0) }
    }

    func resolve(_ result: Result<Void, any Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

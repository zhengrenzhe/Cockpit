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

@Test func staleDisconnectCannotCancelNewConnection() async throws {
    let fixture = try TLSFixture.load()
    let server = try RemoteHandshakeLoopbackServer(identity: fixture.identity, behavior: .holdFirstRequest)
    try await withTimeout { try await server.start() }
    defer { server.stop() }
    let port = try #require(server.port)
    let disconnectGate = DisconnectGate()
    let transport = try RemoteDirectTransport(
        host: "127.0.0.1",
        port: port.rawValue,
        pinnedCertificateDER: SecCertificateCopyData(fixture.certificate) as Data,
        beforeDisconnect: { await disconnectGate.wait() }
    )
    let request = try HandshakeCodec.encode(.cockpit(deviceID: DeviceID(), features: [.workspaceControl, .remoteDirect]))

    try await withTimeout { try await transport.connect() }
    let firstExchange = Task { try? await withTimeout { try await transport.exchangeHandshake(request) } }
    try await withTimeout { await server.waitUntilFirstRequestIsHeld() }
    let staleDisconnect = Task { await transport.disconnect() }
    try await withTimeout { await disconnectGate.waitUntilBlocked() }
    try await withTimeout { await server.releaseFirstRequest() }
    _ = try await withTimeout { await firstExchange.value }

    try await withTimeout { try await transport.connect() }
    try await withTimeout { await disconnectGate.release() }
    try await withTimeout { await staleDisconnect.value }
    let response = try await withTimeout { try await transport.exchangeHandshake(request) }
    #expect(try HandshakeCodec.decodeResponse(response).serviceKind == "host")
    try await withTimeout { await transport.disconnect() }
    server.stop()
    try await withTimeout { try await server.waitUntilIdle() }
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
        Issue.record("A stalled handshake produced an unexpected error: \(error)")
    }
    #expect(Date().timeIntervalSince(startedAt) < 1)

    try await withTimeout { await transport.disconnect() }
    server.stop()
    try await withTimeout { try await server.waitUntilIdle() }
    #expect(server.activeConnectionCount == 0)
    #expect(server.activeHandlerCount == 0)
    #expect(server.exitedHandlerCount > 0)
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

@Test func byteStreamTaskCancellationClosesStartSendAndReceive() async throws {
    let preCancelledStart = NWConnectionByteStream(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp))
    let startTask = Task { try await preCancelledStart.start() }
    startTask.cancel()
    do {
        try await withTimeout { try await startTask.value }
        Issue.record("A pre-cancelled start succeeded")
    } catch is CancellationError {
    } catch {
        Issue.record("Pre-cancelled start returned unexpected error: \(error)")
    }
    try await withTimeout { await assertStreamClosed(preCancelledStart) }

    let fixture = try TLSFixture.load()
    let server = try RemoteHandshakeLoopbackServer(identity: fixture.identity, behavior: .stallFirstRequest)
    try await withTimeout { try await server.start() }
    defer { server.stop() }
    let port = try #require(server.port)
    let parameters = NWParameters(tls: TLSOptionsFactory.client(pinnedCertificateDER: SecCertificateCopyData(fixture.certificate) as Data))

    let sendStream = NWConnectionByteStream(connection: NWConnection(host: "127.0.0.1", port: port, using: parameters))
    try await withTimeout { try await sendStream.start() }
    let sendTask = Task { try await sendStream.sendLengthPrefixed(Data([1])) }
    sendTask.cancel()
    do {
        try await withTimeout { try await sendTask.value }
        Issue.record("A pre-cancelled send succeeded")
    } catch is CancellationError {
    } catch {
        Issue.record("Pre-cancelled send returned unexpected error: \(error)")
    }
    try await withTimeout { await assertStreamClosed(sendStream) }

    let receiveStream = NWConnectionByteStream(connection: NWConnection(host: "127.0.0.1", port: port, using: parameters))
    try await withTimeout { try await receiveStream.start() }
    let receiveTask = Task { try await receiveStream.receiveLengthPrefixed() }
    receiveTask.cancel()
    do {
        _ = try await withTimeout { try await receiveTask.value }
        Issue.record("A pre-cancelled receive succeeded")
    } catch is CancellationError {
    } catch {
        Issue.record("Pre-cancelled receive returned unexpected error: \(error)")
    }
    try await withTimeout { await assertStreamClosed(receiveStream) }
    server.stop()
    try await withTimeout { try await server.waitUntilIdle() }
}

private func assertStreamClosed(_ stream: NWConnectionByteStream) async {
    do {
        try await stream.sendLengthPrefixed(Data())
        Issue.record("A cancelled byte stream accepted a send")
    } catch let error as NetworkByteStreamError {
        #expect(error == .closed)
    } catch {
        Issue.record("Cancelled byte stream send returned unexpected error: \(error)")
    }
    do {
        _ = try await stream.receiveLengthPrefixed()
        Issue.record("A cancelled byte stream accepted a receive")
    } catch let error as NetworkByteStreamError {
        #expect(error == .closed)
    } catch {
        Issue.record("Cancelled byte stream receive returned unexpected error: \(error)")
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

private actor DisconnectGate {
    private var blocked = false
    private var released = false
    private var blockedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        blocked = true
        blockedWaiter?.resume()
        blockedWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class RemoteHandshakeLoopbackServer: @unchecked Sendable {
    enum Behavior: Sendable {
        case normal
        case dropFirstConnection
        case stallFirstRequest
        case holdFirstRequest
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.cockpit.tests.remote-listener")
    private let lock = NSLock()
    private let behavior: Behavior
    private var stopped = false
    private var connectionCount = 0
    private var firstRequestStalled = false
    private var stalledWaiter: CheckedContinuation<Void, Never>?
    private var firstRequestHeld = false
    private var firstRequestReleased = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var heldReleaseWaiter: CheckedContinuation<Void, Never>?
    private var records: [ObjectIdentifier: HandlerRecord] = [:]
    private var handlerExitCount = 0

    var port: NWEndpoint.Port? { listener.port }
    var activeConnectionCount: Int { withLock { records.count } }
    var activeHandlerCount: Int { withLock { records.count } }
    var exitedHandlerCount: Int { withLock { handlerExitCount } }

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
        let pending: [HandlerRecord] = withLock {
            guard !stopped else { return [] }
            stopped = true
            let pending = Array(records.values)
            stalledWaiter?.resume()
            stalledWaiter = nil
            heldWaiter?.resume()
            heldWaiter = nil
            firstRequestReleased = true
            heldReleaseWaiter?.resume()
            heldReleaseWaiter = nil
            return pending
        }
        listener.cancel()
        pending.forEach { $0.connection.cancel() }
        pending.compactMap(\.task).forEach { $0.cancel() }
        pending.forEach { record in Task { await record.startGate.open() } }
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

    func waitUntilFirstRequestIsHeld() async {
        if withLock({ firstRequestHeld }) { return }
        await withCheckedContinuation { continuation in
            let resume = withLock { () -> Bool in
                if firstRequestHeld { return true }
                heldWaiter = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func releaseFirstRequest() async {
        let waiter = withLock { () -> CheckedContinuation<Void, Never>? in
            firstRequestReleased = true
            let waiter = heldReleaseWaiter
            heldReleaseWaiter = nil
            return waiter
        }
        waiter?.resume()
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
        let record = HandlerRecord(connection: connection)
        let shouldCancel = withLock { () -> Bool in
            if stopped { return true }
            records[identifier] = record
            return false
        }
        guard !shouldCancel else {
            connection.cancel()
            return
        }
        let task = Task { [weak self] in
            await record.startGate.wait()
            guard let self else { return }
            defer { self.remove(identifier, record: record) }
            guard !Task.isCancelled else { return }
            await self.handle(connection)
        }
        let cancelTask = withLock { () -> Bool in
            record.task = task
            return stopped
        }
        if cancelTask {
            connection.cancel()
            task.cancel()
        }
        Task { await record.startGate.open() }
    }

    private func remove(_ identifier: ObjectIdentifier, record: HandlerRecord) {
        withLock {
            guard records[identifier] === record else { return }
            records.removeValue(forKey: identifier)
            handlerExitCount += 1
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
            let shouldHold = withLock { () -> Bool in
                guard behavior == .holdFirstRequest, !firstRequestHeld else { return false }
                firstRequestHeld = true
                heldWaiter?.resume()
                heldWaiter = nil
                return true
            }
            if shouldHold {
                await withCheckedContinuation { continuation in
                    let resume = withLock { () -> Bool in
                        if stopped || firstRequestReleased { return true }
                        heldReleaseWaiter = continuation
                        return false
                    }
                    if resume { continuation.resume() }
                }
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

private final class HandlerRecord: @unchecked Sendable {
    let connection: NWConnection
    let startGate = HandlerStartGate()
    var task: Task<Void, Never>?

    init(connection: NWConnection) {
        self.connection = connection
    }
}

private actor HandlerStartGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        guard !opened else { return }
        opened = true
        waiter?.resume()
        waiter = nil
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

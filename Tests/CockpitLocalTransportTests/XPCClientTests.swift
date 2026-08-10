import Foundation
import Testing
import CockpitHostCore
import CockpitTerminalCore
import CockpitTypes
@testable import CockpitLocalTransport

private enum TestXPCError: Error, Equatable, Sendable {
    case remote
}

private struct FakeConnectionSnapshot: Sendable {
    let configuredInterfaceCount: Int
    let resumeCount: Int
    let invalidateCount: Int
    let proxyRequestCount: Int
}

private final class FakeXPCConnection: XPCConnectionBoundary, @unchecked Sendable {
    private let lock = NSLock()
    private let proxy: Any
    private let onProxyRequest: (@Sendable () -> Void)?
    private var invalidationHandler: (@Sendable () -> Void)?
    private var interruptionHandler: (@Sendable () -> Void)?
    private var remoteErrorHandler: (@Sendable (any Error) -> Void)?
    private var configuredInterfaceCount = 0
    private var resumeCount = 0
    private var invalidateCount = 0
    private var proxyRequestCount = 0

    init(proxy: Any, onProxyRequest: (@Sendable () -> Void)? = nil) {
        self.proxy = proxy
        self.onProxyRequest = onProxyRequest
    }

    func configureRemoteObjectInterface(_ interface: NSXPCInterface) {
        lock.withLock { configuredInterfaceCount += 1 }
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { invalidationHandler = handler }
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { interruptionHandler = handler }
    }

    func resume() {
        lock.withLock { resumeCount += 1 }
    }

    func invalidate() {
        lock.withLock { invalidateCount += 1 }
    }

    func remoteObjectProxy(
        errorHandler: @escaping @Sendable (any Error) -> Void
    ) -> Any {
        lock.withLock {
            proxyRequestCount += 1
            remoteErrorHandler = errorHandler
        }
        onProxyRequest?()
        return proxy
    }

    func fireInvalidation() {
        let handler = lock.withLock { invalidationHandler }
        handler?()
    }

    func fireInterruption() {
        let handler = lock.withLock { interruptionHandler }
        handler?()
    }

    func fireRemoteError(_ error: any Error) {
        let handler = lock.withLock { remoteErrorHandler }
        handler?(error)
    }

    func snapshot() -> FakeConnectionSnapshot {
        lock.withLock {
            FakeConnectionSnapshot(
                configuredInterfaceCount: configuredInterfaceCount,
                resumeCount: resumeCount,
                invalidateCount: invalidateCount,
                proxyRequestCount: proxyRequestCount
            )
        }
    }
}

private final class ConnectionFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let connections: [FakeXPCConnection]
    private var nextIndex = 0
    private var endpoints: [XPCServiceEndpoint] = []

    init(_ connections: [FakeXPCConnection]) {
        self.connections = connections
    }

    func make(endpoint: XPCServiceEndpoint) -> any XPCConnectionBoundary {
        lock.withLock {
            endpoints.append(endpoint)
            let connection = connections[min(nextIndex, connections.count - 1)]
            nextIndex += 1
            return connection
        }
    }

    func recordedEndpoints() -> [XPCServiceEndpoint] {
        lock.withLock { endpoints }
    }
}

private final class HandshakeProxy: NSObject, XPCHandshakeProtocol, @unchecked Sendable {
    typealias Behavior = (Data, @escaping (Data?, NSError?) -> Void) -> Void
    private let behavior: Behavior

    init(behavior: @escaping Behavior) {
        self.behavior = behavior
    }

    func exchangeHandshake(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        behavior(request, reply)
    }
}

private final class TerminalProxy:
    NSObject,
    TerminalSupervisorXPCProtocol,
    @unchecked Sendable
{
    typealias HandshakeBehavior = (Data, @escaping (Data?, NSError?) -> Void) -> Void
    typealias CommandBehavior = (Data, @escaping (Data?, NSError?) -> Void) -> Void
    private let handshakeBehavior: HandshakeBehavior
    private let commandBehavior: CommandBehavior

    init(
        handshakeBehavior: @escaping HandshakeBehavior = { _, _ in },
        commandBehavior: @escaping CommandBehavior
    ) {
        self.handshakeBehavior = handshakeBehavior
        self.commandBehavior = commandBehavior
    }

    func exchangeHandshake(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        handshakeBehavior(request, reply)
    }

    func terminalCommand(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        commandBehavior(request, reply)
    }

    func openTerminalArchive(
        _ request: Data,
        withReply reply: @escaping (FileHandle?, NSError?) -> Void
    ) {
        reply(nil, CocoaError(.featureUnsupported) as NSError)
    }
}

private actor StartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

@Test func xpcEndpointsUseTheFixedMachServiceNames() {
    #expect(XPCServiceEndpoint.host.machServiceName == "dev.cockpit.host")
    #expect(XPCServiceEndpoint.terminal.machServiceName == "dev.cockpit.terminal")
}

@Test func handshakeClientDefaultsToHostAndConnectDisconnectAreIdempotent() async throws {
    let connection = FakeXPCConnection(proxy: NSObject())
    let factory = ConnectionFactoryRecorder([connection])
    let client = XPCHandshakeClient(connectionFactory: factory.make)

    try await client.connect()
    try await client.connect()
    await client.disconnect()
    await client.disconnect()

    #expect(factory.recordedEndpoints() == [.host])
    let snapshot = connection.snapshot()
    #expect(snapshot.configuredInterfaceCount == 1)
    #expect(snapshot.resumeCount == 1)
    #expect(snapshot.invalidateCount == 1)
}

@Test func terminalClientUsesTerminalEndpointAndConnectDisconnectAreIdempotent() async {
    let connection = FakeXPCConnection(proxy: NSObject())
    let factory = ConnectionFactoryRecorder([connection])
    let client = TerminalSupervisorXPCClient(connectionFactory: factory.make)

    await client.connect()
    await client.connect()
    await client.disconnect()
    await client.disconnect()

    #expect(factory.recordedEndpoints() == [.terminal])
    let snapshot = connection.snapshot()
    #expect(snapshot.configuredInterfaceCount == 1)
    #expect(snapshot.resumeCount == 1)
    #expect(snapshot.invalidateCount == 1)
}

@Test func handshakeClientRebuildsAfterInvalidationAndIgnoresStaleHandler() async throws {
    let first = FakeXPCConnection(proxy: NSObject())
    let second = FakeXPCConnection(proxy: NSObject())
    let factory = ConnectionFactoryRecorder([first, second])
    let client = XPCHandshakeClient(connectionFactory: factory.make)
    try await client.connect()

    first.fireInvalidation()
    for _ in 0..<100 where factory.recordedEndpoints().count < 2 {
        await Task.yield()
        try await client.connect()
    }
    #expect(factory.recordedEndpoints() == [.host, .host])

    first.fireInvalidation()
    await Task.yield()
    try await client.connect()
    #expect(factory.recordedEndpoints() == [.host, .host])
}

@Test func terminalClientInvalidatesInterruptedConnectionBeforeReconnecting() async {
    let first = FakeXPCConnection(proxy: NSObject())
    let second = FakeXPCConnection(proxy: NSObject())
    let factory = ConnectionFactoryRecorder([first, second])
    let client = TerminalSupervisorXPCClient(connectionFactory: factory.make)
    await client.connect()

    first.fireInterruption()
    for _ in 0..<100 where factory.recordedEndpoints().count < 2 {
        await Task.yield()
        await client.connect()
    }

    #expect(factory.recordedEndpoints() == [.terminal, .terminal])
    #expect(first.snapshot().invalidateCount == 1)
}

@Test func handshakeClientRejectsProxyConstructionFailure() async throws {
    let connection = FakeXPCConnection(proxy: NSObject())
    let factory = ConnectionFactoryRecorder([connection])
    let client = XPCHandshakeClient(connectionFactory: factory.make)
    try await client.connect()

    await #expect(throws: CocoaError.self) {
        _ = try await client.exchangeHandshake(Data())
    }
}

@Test func handshakeClientRejectsNilDataAndNilError() async throws {
    let proxy = HandshakeProxy { _, reply in reply(nil, nil) }
    let connection = FakeXPCConnection(proxy: proxy)
    let factory = ConnectionFactoryRecorder([connection])
    let client = XPCHandshakeClient(connectionFactory: factory.make)
    try await client.connect()

    await #expect(throws: CocoaError.self) {
        _ = try await client.exchangeHandshake(Data())
    }
}

@Test func handshakeClientPropagatesRemoteErrorAndDiscardsLateReply() async throws {
    let expected = Data([1, 2, 3])
    let connectionBox = LockedBox<FakeXPCConnection?>(nil)
    let proxy = HandshakeProxy { _, reply in
        let replyBox = LockedBox(reply)
        let group = DispatchGroup()
        let errorDelivered = DispatchSemaphore(value: 0)
        group.enter()
        DispatchQueue.global().async {
            connectionBox.value?.fireRemoteError(TestXPCError.remote)
            errorDelivered.signal()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errorDelivered.wait()
            replyBox.value(expected, nil)
            group.leave()
        }
        group.wait()
    }
    let connection = FakeXPCConnection(proxy: proxy)
    connectionBox.value = connection
    let factory = ConnectionFactoryRecorder([connection])
    let client = XPCHandshakeClient(connectionFactory: factory.make)
    try await client.connect()

    await #expect(throws: TestXPCError.remote) {
        _ = try await client.exchangeHandshake(Data())
    }
}

@Test func cancellationBeforeHandshakeContinuationInstallationSkipsProxyRequest() async throws {
    let proxy = HandshakeProxy { _, _ in }
    let connection = FakeXPCConnection(proxy: proxy)
    let factory = ConnectionFactoryRecorder([connection])
    let client = XPCHandshakeClient(connectionFactory: factory.make)
    try await client.connect()
    let gate = StartGate()
    let task = Task {
        await gate.wait()
        return try await client.exchangeHandshake(Data())
    }

    task.cancel()
    await gate.open()

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
    #expect(connection.snapshot().proxyRequestCount == 0)
}

@Test func cancellingTerminalRequestAfterInstallationResumesIt() async throws {
    let (requests, requestContinuation) = AsyncStream<Void>.makeStream()
    let replyBox = LockedBox<((Data?, NSError?) -> Void)?>(nil)
    let proxy = TerminalProxy { _, reply in
        replyBox.value = reply
    }
    let connection = FakeXPCConnection(
        proxy: proxy,
        onProxyRequest: { requestContinuation.yield() }
    )
    let factory = ConnectionFactoryRecorder([connection])
    let client = TerminalSupervisorXPCClient(connectionFactory: factory.make)
    var iterator = requests.makeAsyncIterator()
    let task = Task { try await client.command(.reconcile) }
    _ = await iterator.next()

    task.cancel()

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }

    replyBox.value?(try JSONEncoder().encode(TerminalSupervisorCommandResponse.empty), nil)
    await Task.yield()
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

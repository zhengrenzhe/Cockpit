import Darwin
import Foundation
import Testing
import CockpitProtocol
import CockpitTerminalCore
import CockpitTypes
@testable import CockpitLocalTransport

@Suite("KeeperUDSTests")
struct KeeperUDSTests {
    @Test func protocol11HandshakeRequiresPeerRoleAndRejectsWrongUID() async throws {
        let fixture = try UDSFixture(peerUID: geteuid() + 1)
        defer { fixture.server.stop() }
        try fixture.server.start()
        let client = KeeperUDSClient(endpoint: fixture.endpoint)
        await #expect(throws: KeeperControlError.authenticationFailed) {
            _ = try await client.attach(fixture.attachRequest)
        }

        let correct = try UDSFixture(peerUID: geteuid())
        defer { correct.server.stop() }
        try correct.server.start()
        let raw = try DarwinUnixDomainSocketSystemCalls().createStreamSocket()
        defer { Darwin.close(raw) }
        try DarwinUnixDomainSocketSystemCalls().connect(
            raw,
            to: UnixDomainSocketAddress(path: correct.endpoint.path)
        )
        try KeeperControlFraming.write(
            KeeperControlEnvelope.inspect(correct.inspectRequest),
            to: raw
        )
        #expect(throws: KeeperControlError.self) {
            _ = try KeeperControlFraming.read(KeeperControlEnvelope.self, from: raw)
        }
    }

    @Test func supervisorRegistersTicketAndLeaseBeforeViewerCanWrite() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(fixture.issued.registration, at: fixture.endpoint)

        let client = KeeperUDSClient(endpoint: fixture.endpoint)
        let viewer = try await client.attach(fixture.attachRequest)
        await #expect(throws: TerminalStreamError.inputLeaseRequired) {
            _ = try await viewer.send(fixture.input(sequence: 1))
        }

        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.input]
            ),
            at: fixture.endpoint
        )
        #expect(try await viewer.send(fixture.input(sequence: 1)) == 1)
        #expect(try await viewer.send(fixture.input(sequence: 1)) == 1)
        #expect(await fixture.effects.inputs == [.text("typed")])
        await viewer.detach()
    }

    @Test func ticketReplayCrossSessionAndCapabilityEscalationFailClosed() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(fixture.issued.registration, at: fixture.endpoint)
        let client = KeeperUDSClient(endpoint: fixture.endpoint)
        let viewer = try await client.attach(fixture.attachRequest)
        await viewer.detach()
        await #expect(throws: TerminalAttachTicketError.replay) {
            _ = try await client.attach(fixture.attachRequest)
        }

        let escalated = AttachRequest(
            viewerID: fixture.viewerID,
            wireTicket: fixture.attachRequest.wireTicket,
            binding: fixture.attachRequest.binding,
            requestedCapabilities: .all,
            lastAcknowledgedOutputSequence: nil
        )
        await #expect(throws: TerminalAttachTicketError.self) {
            _ = try await client.attach(escalated)
        }
    }

    @Test func outputUsesChannelOneInputAckUsesChannelTwoAndViewerCloseDoesNotTerminatePTY() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(fixture.issued.registration, at: fixture.endpoint)
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.input]
            ),
            at: fixture.endpoint
        )
        await fixture.coordinator.publish(outputSequence: 1, frame: Data("screen".utf8))
        #expect(try await viewer.nextOutput()?.fragments == [Data("screen".utf8)])
        #expect(try await viewer.send(fixture.input(sequence: 1)) == 1)
        await viewer.detach()
        #expect(await fixture.terminated.count == 0)
        #expect(await fixture.effects.revoked == [fixture.leaseID])
    }

    @Test func readOnlyViewerCannotInputResizeSignalOrTerminate() async throws {
        let fixture = try UDSFixture(peerUID: geteuid(), capabilities: [.view])
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(fixture.issued.registration, at: fixture.endpoint)
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        await #expect(throws: TerminalStreamError.capabilityDenied) {
            _ = try await viewer.send(fixture.input(sequence: 1))
        }
        await #expect(throws: TerminalStreamError.capabilityDenied) {
            _ = try await viewer.signal(.interrupt)
        }
        await #expect(throws: TerminalStreamError.capabilityDenied) {
            try await viewer.terminate(force: false)
        }
        await viewer.detach()
    }

    @Test func signalTargetsForegroundGroupAndTerminateUsesSessionPolicy() async throws {
        let fixture = try UDSFixture(
            peerUID: geteuid(),
            capabilities: [.view, .signal, .terminate]
        )
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(fixture.issued.registration, at: fixture.endpoint)
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        await #expect(throws: TerminalStreamError.malformedMessage) {
            _ = try await viewer.send(fixture.input(sequence: 1, payload: .signal(.interrupt)))
        }
        #expect(try await viewer.signal(.interrupt) == 100)
        #expect(try await viewer.signal(.quit) == 100)
        #expect(try await viewer.signal(.suspend) == 100)
        #expect(try await viewer.signal(.continue) == 100)
        try await viewer.terminate(force: false)
        try await viewer.terminate(force: true)
        #expect(await fixture.effects.signals == [.interrupt, .quit, .suspend, .continue])
        #expect(await fixture.terminated.values == [false, true])
        await viewer.detach()
    }

    @Test func serverStopUnblocksViewerWaitingForOutputAndJoinsWorker() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(fixture.issued.registration, at: fixture.endpoint)
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        let output = Task.detached { try? await viewer.nextOutput() }

        #expect(await waitUntil { fixture.server.pendingOutputWaiterCount() == 1 })
        let completion = CompletionFlag()
        let stopping = Task.detached {
            fixture.server.stop()
            completion.markComplete()
        }
        let bounded = await waitUntil(timeout: .milliseconds(250)) { completion.isComplete }
        #expect(bounded)
        if !bounded {
            await fixture.coordinator.detach(viewerID: fixture.viewerID)
        }
        await stopping.value
        _ = await output.value
    }

    @Test func liveKeeperSocketIsNeverUnlinkedByACompetingServer() throws {
        let sessionID = TerminalSessionID()
        let workerID = WorkerInstanceID()
        let parent = "/private/tmp/cockpit-keeper-startup"
        let endpoint = try KeeperEndpoint(
            path: parent + "/keeper.sock",
            sessionID: sessionID,
            workerID: workerID
        )
        let calls = KeeperStartupSocketCalls(parent: parent, path: endpoint.path)
        let secret = Data(repeating: 0x71, count: 32)
        let first = KeeperUDSServer(
            endpoint: endpoint,
            workerSecret: secret,
            startHandler: { _ in
                try CLIProcessIdentity(validatingProcessID: 900, processGroupID: 900)
            },
            terminateHandler: { _ in },
            calls: calls,
            peerCredentials: FixedPeerReader(uid: geteuid())
        )
        defer { first.stop() }
        try first.start()
        let originalStatus = try calls.pathStatus(endpoint.path)
        let originalIdentity = try #require(originalStatus)
        let competing = KeeperUDSServer(
            endpoint: endpoint,
            workerSecret: secret,
            startHandler: { _ in
                try CLIProcessIdentity(validatingProcessID: 901, processGroupID: 901)
            },
            terminateHandler: { _ in },
            calls: calls,
            peerCredentials: FixedPeerReader(uid: geteuid())
        )
        defer { competing.stop() }

        var startError: (any Error)?
        do {
            try competing.start()
        } catch {
            startError = error
        }
        #expect(startError as? UnixDomainSocketError == .serverAlreadyRunning)
        #expect(try calls.pathStatus(endpoint.path) == originalIdentity)
        #expect(calls.unlinkCount == 0)
    }

    @Test func frameSequenceAndAcknowledgementAreIndependentPerChannel() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let stream = KeeperStreamConnection(descriptor: descriptors[0])
        defer {
            stream.close()
            Darwin.close(descriptors[1])
        }

        try stream.write("control", channel: .control)
        try stream.write("output", channel: .terminalOutput)
        try stream.write("input", channel: .terminalInput)
        let control = try readRawFrame(from: descriptors[1])
        let output = try readRawFrame(from: descriptors[1])
        let input = try readRawFrame(from: descriptors[1])
        #expect(control.header.channel == .control)
        #expect(control.header.sequence == 1)
        #expect(output.header.channel == .terminalOutput)
        #expect(output.header.sequence == 1)
        #expect(input.header.channel == .terminalInput)
        #expect(input.header.sequence == 1)

        try writeRawFrame("peer-input", channel: .terminalInput, sequence: 1, acknowledgement: 1, to: descriptors[1])
        try writeRawFrame("peer-control", channel: .control, sequence: 1, acknowledgement: 1, to: descriptors[1])
        #expect(try stream.read(String.self).1 == "peer-input")
        #expect(try stream.read(String.self).1 == "peer-control")

        try writeRawFrame("ack-regression", channel: .terminalInput, sequence: 2, acknowledgement: 0, to: descriptors[1])
        #expect(throws: TerminalStreamError.malformedMessage) {
            _ = try stream.read(String.self)
        }
    }

    @Test func pendingOutputDoesNotBlockConcurrentInputAcknowledgement() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(fixture.issued.registration, at: fixture.endpoint)
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.input]
            ),
            at: fixture.endpoint
        )

        let output = Task.detached { try await viewer.nextOutput() }
        #expect(await waitUntil { fixture.server.pendingOutputWaiterCount() == 1 })
        let input = PendingResult<UInt64>()
        Task.detached {
            do { input.store(.success(try await viewer.send(fixture.input(sequence: 1)))) }
            catch { input.store(.failure(error)) }
        }
        let inputCompletedWithoutOutput = await waitUntil(timeout: .milliseconds(250)) {
            input.value != nil
        }
        #expect(inputCompletedWithoutOutput)

        await fixture.coordinator.publish(outputSequence: 1, frame: Data("screen".utf8))
        #expect(await waitUntil { input.value != nil })
        #expect(try input.value?.get() == 1)
        #expect(try await output.value?.fragments == [Data("screen".utf8)])
        await viewer.detach()
    }

    @Test func oversizedOutputIsPagedBelowFrameLimitAndReassembled() async throws {
        let fixture = try UDSFixture(peerUID: geteuid(), capabilities: [.view])
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(fixture.issued.registration, at: fixture.endpoint)
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        let payload = Data(
            repeating: 0xA7,
            count: Int(FrameHeader.maximumPayloadLength) + 17
        )
        let output = PendingResult<TerminalOutputFrame?>()
        Task.detached {
            do { output.store(.success(try await viewer.nextOutput())) }
            catch { output.store(.failure(error)) }
        }

        await fixture.coordinator.publish(outputSequence: 1, frame: payload)
        let delivered = await waitUntil { output.value != nil }
        #expect(delivered)
        guard delivered else {
            await viewer.detach()
            return
        }
        let result = try #require(output.value)
        let frame = try #require(try result.get())
        #expect(frame.fragments == [payload])
        let pages = KeeperOutputPage.pages(for: frame)
        #expect(pages.count > 1)
        #expect(try pages.allSatisfy {
            try JSONEncoder().encode(KeeperViewerResponse.outputPage($0)).count
                <= Int(FrameHeader.maximumPayloadLength)
        })
        await viewer.detach()
    }

    @Test func nonHolderConnectionCannotSpoofLeaseHolderContext() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(fixture.issued.registration, at: fixture.endpoint)
        let holder = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)

        let otherViewerID = ViewerID()
        let otherBinding = TerminalAttachBinding(
            sessionID: fixture.sessionID,
            workerID: fixture.workerID,
            clientInstanceID: ClientInstanceID(otherViewerID.rawValue)
        )
        let otherTicket = try await fixture.tickets.issue(
            binding: otherBinding,
            capabilities: [.view, .input]
        )
        try await supervisor.registerAttachTicket(otherTicket.registration, at: fixture.endpoint)
        let other = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(
            AttachRequest(
                viewerID: otherViewerID,
                wireTicket: otherTicket.wireValue,
                binding: otherBinding,
                requestedCapabilities: [.view, .input],
                lastAcknowledgedOutputSequence: nil
            )
        )
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.input]
            ),
            at: fixture.endpoint
        )

        await #expect(throws: TerminalStreamError.inputLeaseRequired) {
            _ = try await other.send(
                fixture.input(
                    sequence: 1,
                    clientInstanceID: ClientInstanceID(fixture.viewerID.rawValue)
                )
            )
        }
        #expect(await fixture.effects.inputs.isEmpty)
        #expect(try await holder.send(fixture.input(sequence: 1)) == 1)
        #expect(await fixture.effects.inputs == [.text("typed")])
        await fixture.coordinator.publish(outputSequence: 1, frame: Data("shared".utf8))
        #expect(try await holder.nextOutput()?.fragments == [Data("shared".utf8)])
        #expect(try await other.nextOutput()?.fragments == [Data("shared".utf8)])
        await other.detach()
        await holder.detach()
    }
}

private final class UDSFixture: @unchecked Sendable {
    let endpoint: KeeperEndpoint
    let secret = Data(repeating: 0x72, count: 32)
    let sessionID = TerminalSessionID()
    let workerID = WorkerInstanceID()
    let viewerID = ViewerID()
    let leaseID = InputLeaseID()
    let tickets: TerminalAttachTicketStore
    let coordinator: TerminalStreamCoordinator
    let effects = UDSEffects()
    let terminated = TerminationCounter()
    let issued: IssuedTerminalAttachTicket
    let attachRequest: AttachRequest
    let inspectRequest: KeeperInspectRequest
    let server: KeeperUDSServer
    private let root: URL

    init(peerUID: uid_t, capabilities: TerminalAttachCapabilities = [.view, .input]) throws {
        root = URL(fileURLWithPath: "/private/tmp/cockpit-keeper-stream.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        endpoint = try KeeperEndpoint(
            path: root.appendingPathComponent("keeper.sock").path,
            sessionID: sessionID,
            workerID: workerID
        )
        let clock = FixedClock()
        let tickets = TerminalAttachTicketStore(clock: clock, randomBytes: UDSIncrementingBytes())
        self.tickets = tickets
        coordinator = TerminalStreamCoordinator(
            sessionID: sessionID,
            workerID: workerID,
            attachTicketPolicy: tickets,
            performInput: { [effects] payload in await effects.record(payload) },
            resetInputState: { [effects] in await effects.reset() },
            reportLeaseRevoked: { [effects] lease in await effects.revoke(lease) },
            signalForeground: { [effects] signal in await effects.signal(signal); return 100 },
            terminateSession: { [terminated] force in await terminated.record(force) }
        )
        let binding = TerminalAttachBinding(
            sessionID: sessionID,
            workerID: workerID,
            clientInstanceID: ClientInstanceID(viewerID.rawValue)
        )
        issued = try waitAsync { try await tickets.issue(binding: binding, capabilities: capabilities) }
        attachRequest = AttachRequest(
            viewerID: viewerID,
            wireTicket: issued.wireValue,
            binding: binding,
            requestedCapabilities: capabilities,
            lastAcknowledgedOutputSequence: nil
        )
        let nonce = Data(repeating: 1, count: 16)
        inspectRequest = KeeperInspectRequest(
            endpoint: endpoint,
            nonce: nonce,
            proofMAC: KeeperAuthentication.inspectProof(secret: secret, endpoint: endpoint, nonce: nonce)
        )
        server = KeeperUDSServer(
            endpoint: endpoint,
            workerSecret: secret,
            streamCoordinator: coordinator,
            startHandler: { _ in try CLIProcessIdentity(validatingProcessID: 900, processGroupID: 900) },
            terminateHandler: { [terminated] force in await terminated.record(force) },
            calls: DarwinUnixDomainSocketSystemCalls(),
            peerCredentials: FixedPeerReader(uid: peerUID)
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func input(
        sequence: UInt64,
        payload: TerminalInput.Payload = .text("typed"),
        clientInstanceID: ClientInstanceID? = nil
    ) throws -> TerminalInput {
        try TerminalInput(
            validatingContext: RequestContext(
                validating: .current,
                clientInstanceID: clientInstanceID ?? ClientInstanceID(viewerID.rawValue),
                windowID: WindowID(),
                workspaceContextID: .project(ProjectID()),
                environmentID: EnvironmentID(),
                activeContextGeneration: 1,
                requestID: RequestID()
            ),
            terminalSessionID: sessionID,
            inputLeaseID: leaseID,
            inputSequence: sequence,
            payload: payload
        )
    }
}

private struct FixedPeerReader: PeerCredentialReading {
    let uid: uid_t
    func peerCredentials(for descriptor: Int32) throws -> (uid: uid_t, gid: gid_t) {
        (uid: uid, gid: getegid())
    }
}

private final class KeeperStartupSocketCalls: UnixDomainSocketSystemCalls, @unchecked Sendable {
    private let lock = NSLock()
    private let parent: String
    private let path: String
    private var nextDescriptor: Int32 = 40
    private var nextInode: ino_t = 100
    private var socketStatus: UnixSocketPathStatus?
    private var unlinks = 0

    init(parent: String, path: String) {
        self.parent = parent
        self.path = path
    }

    var unlinkCount: Int { lock.withLock { unlinks } }

    func effectiveUserID() -> uid_t { geteuid() }

    func createStreamSocket() throws -> Int32 {
        lock.withLock {
            defer { nextDescriptor += 1 }
            return nextDescriptor
        }
    }

    func setCloseOnExec(_ descriptor: Int32) throws {}
    func setNoSigPipe(_ descriptor: Int32) throws {}

    func bind(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {
        try lock.withLock {
            guard socketStatus == nil else {
                throw UnixDomainSocketError.systemCall(function: "bind", errno: EADDRINUSE)
            }
            socketStatus = UnixSocketPathStatus(
                kind: .socket,
                owner: geteuid(),
                permissions: 0o777,
                device: 7,
                inode: nextInode
            )
            nextInode += 1
        }
    }

    func listen(_ descriptor: Int32, backlog: Int32) throws {}

    func accept(_ descriptor: Int32) throws -> Int32 {
        throw UnixDomainSocketError.systemCall(function: "accept", errno: EBADF)
    }

    func connect(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {
        guard lock.withLock({ socketStatus != nil }) else {
            throw UnixDomainSocketError.systemCall(function: "connect", errno: ENOENT)
        }
    }

    func pathStatus(_ requestedPath: String) throws -> UnixSocketPathStatus? {
        lock.withLock {
            if requestedPath == parent {
                return UnixSocketPathStatus(
                    kind: .directory,
                    owner: geteuid(),
                    permissions: 0o700,
                    device: 7,
                    inode: 1
                )
            }
            return requestedPath == path ? socketStatus : nil
        }
    }

    func makeDirectory(_ path: String, permissions: mode_t) throws {}

    func setPermissions(_ requestedPath: String, permissions: mode_t) throws {
        lock.withLock {
            guard requestedPath == path, let current = socketStatus else { return }
            socketStatus = UnixSocketPathStatus(
                kind: current.kind,
                owner: current.owner,
                permissions: permissions,
                device: current.device,
                inode: current.inode
            )
        }
    }

    func unlink(_ requestedPath: String) throws {
        lock.withLock {
            guard requestedPath == path else { return }
            socketStatus = nil
            unlinks += 1
        }
    }

    func close(_ descriptor: Int32) {}

    func read(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> Int {
        throw UnixDomainSocketError.systemCall(function: "read", errno: EBADF)
    }

    func write(
        _ descriptor: Int32,
        from buffer: UnsafeRawBufferPointer
    ) throws -> Int {
        throw UnixDomainSocketError.systemCall(function: "write", errno: EBADF)
    }
}

private struct FixedClock: TerminalSecurityClock {
    func now() -> Date { Date(timeIntervalSince1970: 20_000) }
}

private final class UDSIncrementingBytes: TerminalSecurityRandomBytes, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8 = 0x35
    func bytes(count: Int) throws -> [UInt8] {
        lock.withLock {
            defer { value &+= 1 }
            return Array(repeating: value, count: count)
        }
    }
}

private actor UDSEffects {
    private(set) var inputs: [TerminalInput.Payload] = []
    private(set) var resets = 0
    private(set) var revoked: [InputLeaseID] = []
    private(set) var signals: [TerminalSignal] = []
    func record(_ payload: TerminalInput.Payload) { inputs.append(payload) }
    func reset() { resets += 1 }
    func revoke(_ lease: InputLeaseID) { revoked.append(lease) }
    func signal(_ signal: TerminalSignal) { signals.append(signal) }
}

private actor TerminationCounter {
    private(set) var values: [Bool] = []
    var count: Int { values.count }
    func record(_ force: Bool) { values.append(force) }
}

private func waitAsync<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = LockedResult<Value>()
    Task.detached {
        do { box.store(.success(try await operation())) }
        catch { box.store(.failure(error)) }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.load().get()
}

private final class LockedResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, any Error>?
    func store(_ value: Result<Value, any Error>) { lock.withLock { self.value = value } }
    func load() -> Result<Value, any Error> { lock.withLock { value! } }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var isComplete: Bool { lock.withLock { completed } }
    func markComplete() { lock.withLock { completed = true } }
}

private final class PendingResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, any Error>?
    var value: Result<Value, any Error>? { lock.withLock { stored } }
    func store(_ value: Result<Value, any Error>) { lock.withLock { stored = value } }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await predicate()
}

private func readRawFrame(from descriptor: Int32) throws -> (header: FrameHeader, payload: Data) {
    var headerBytes = Data(count: FrameHeader.encodedLength)
    try headerBytes.withUnsafeMutableBytes { try readExactly($0, from: descriptor) }
    let header = try FrameHeader(decoding: headerBytes)
    var payload = Data(count: Int(header.payloadLength))
    try payload.withUnsafeMutableBytes { try readExactly($0, from: descriptor) }
    return (header, payload)
}

private func writeRawFrame<Value: Encodable>(
    _ value: Value,
    channel: ChannelID,
    sequence: UInt64,
    acknowledgement: UInt64,
    to descriptor: Int32
) throws {
    let payload = try JSONEncoder().encode(value)
    let header = FrameHeader(
        flags: 0,
        channel: channel,
        sequence: sequence,
        acknowledgement: acknowledgement,
        payloadLength: UInt32(payload.count)
    )
    try writeExactly(header.encoded(), to: descriptor)
    try writeExactly(payload, to: descriptor)
}

private func readExactly(_ bytes: UnsafeMutableRawBufferPointer, from descriptor: Int32) throws {
    guard let base = bytes.baseAddress else { return }
    var offset = 0
    while offset < bytes.count {
        let count = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw TerminalStreamError.disconnected }
        offset += count
    }
}

private func writeExactly(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw TerminalStreamError.disconnected }
            offset += count
        }
    }
}

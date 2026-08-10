import Darwin
import Dispatch
import Foundation
import CockpitProtocol
import CockpitTerminalCore
import CockpitTypes

public final class KeeperUDSServer: @unchecked Sendable {
    public typealias StartHandler = @Sendable (
        AuthenticatedStartRequest
    ) async throws -> CLIProcessIdentity
    public typealias TerminateHandler = @Sendable (_ force: Bool) async throws -> Void

    private let endpoint: KeeperEndpoint
    private let workerSecret: Data
    private let streamCoordinator: TerminalStreamCoordinator?
    private let leaseRevocations: InputLeaseRevocationBuffer?
    private let startHandler: StartHandler
    private let terminateHandler: TerminateHandler
    private let afterViewerDetachAcknowledgement: (@Sendable () -> Void)?
    private let calls: any UnixDomainSocketSystemCalls
    private let peerCredentials: any PeerCredentialReading
    private let stateLock = NSLock()
    private let worker = DispatchQueue(label: "dev.cockpit.keeper-control")
    private let connections = DispatchQueue(
        label: "dev.cockpit.keeper-connections",
        attributes: .concurrent
    )
    private let workerGroup = DispatchGroup()
    private var listener: Int32?
    private var socketIdentity: UnixSocketPathStatus?
    private var stopped = false
    private var acceptedStart: AuthenticatedStartRequest?
    private var processIdentity: CLIProcessIdentity?
    private var acceptedDescriptors: Set<Int32> = []
    private var viewerByDescriptor: [Int32: ViewerID] = [:]
    private var waitingOutputViewers: Set<ViewerID> = []

    public init(
        endpoint: KeeperEndpoint,
        workerSecret: Data,
        streamCoordinator: TerminalStreamCoordinator? = nil,
        leaseRevocations: InputLeaseRevocationBuffer? = nil,
        startHandler: @escaping StartHandler,
        terminateHandler: @escaping TerminateHandler
    ) {
        self.endpoint = endpoint
        self.workerSecret = workerSecret
        self.streamCoordinator = streamCoordinator
        self.leaseRevocations = leaseRevocations
        self.startHandler = startHandler
        self.terminateHandler = terminateHandler
        afterViewerDetachAcknowledgement = nil
        calls = DarwinUnixDomainSocketSystemCalls()
        peerCredentials = DarwinPeerCredentialReader()
    }

    init(
        endpoint: KeeperEndpoint,
        workerSecret: Data,
        streamCoordinator: TerminalStreamCoordinator? = nil,
        leaseRevocations: InputLeaseRevocationBuffer? = nil,
        startHandler: @escaping StartHandler,
        terminateHandler: @escaping TerminateHandler,
        afterViewerDetachAcknowledgement: (@Sendable () -> Void)? = nil,
        calls: any UnixDomainSocketSystemCalls,
        peerCredentials: any PeerCredentialReading
    ) {
        self.endpoint = endpoint
        self.workerSecret = workerSecret
        self.streamCoordinator = streamCoordinator
        self.leaseRevocations = leaseRevocations
        self.startHandler = startHandler
        self.terminateHandler = terminateHandler
        self.afterViewerDetachAcknowledgement = afterViewerDetachAcknowledgement
        self.calls = calls
        self.peerCredentials = peerCredentials
    }

    deinit { stop() }

    public func start() throws {
        try stateLock.withLock {
            guard listener == nil, !stopped else {
                throw UnixDomainSocketError.serverAlreadyRunning
            }
            let parent = URL(fileURLWithPath: endpoint.path).deletingLastPathComponent().path
            guard let directory = try calls.pathStatus(parent),
                  directory.kind == .directory,
                  directory.owner == calls.effectiveUserID(),
                  directory.permissions & 0o777 == 0o700 else {
                throw UnixDomainSocketError.unsafeDirectory
            }
            if let existing = try calls.pathStatus(endpoint.path) {
                guard existing.kind == .socket,
                      existing.owner == calls.effectiveUserID(),
                      existing.permissions & 0o777 == 0o600 else {
                    throw UnixDomainSocketError.unsafeSocket
                }
                let probe = try calls.createStreamSocket()
                defer { calls.close(probe) }
                try calls.setCloseOnExec(probe)
                try calls.setNoSigPipe(probe)
                let connectFailure: Int32
                do {
                    try calls.connect(
                        probe,
                        to: UnixDomainSocketAddress(path: endpoint.path)
                    )
                    throw UnixDomainSocketError.serverAlreadyRunning
                } catch let error as UnixDomainSocketError {
                    guard case let .systemCall(function, value) = error,
                          function == "connect",
                          value == ECONNREFUSED || value == ENOENT else {
                        throw error
                    }
                    connectFailure = value
                }
                let rechecked = try calls.pathStatus(endpoint.path)
                if rechecked == nil,
                   connectFailure == ECONNREFUSED || connectFailure == ENOENT {
                    // The stale path vanished. bind below remains the atomic arbiter.
                } else if rechecked == existing {
                    try calls.unlink(endpoint.path)
                } else {
                    throw UnixDomainSocketError.staleSocketRace
                }
            }
            let descriptor = try calls.createStreamSocket()
            var cleanupIdentity: UnixSocketPathStatus?
            do {
                try calls.setCloseOnExec(descriptor)
                try calls.setNoSigPipe(descriptor)
                try calls.bind(descriptor, to: UnixDomainSocketAddress(path: endpoint.path))
                if let identity = try calls.pathStatus(endpoint.path),
                   identity.kind == .socket,
                   identity.owner == calls.effectiveUserID() {
                    cleanupIdentity = identity
                }
                try calls.setPermissions(endpoint.path, permissions: 0o600)
                try calls.listen(descriptor, backlog: 16)
                guard let identity = try calls.pathStatus(endpoint.path),
                      identity.kind == .socket,
                      identity.owner == calls.effectiveUserID(),
                      identity.permissions & 0o777 == 0o600,
                      cleanupIdentity?.device == identity.device,
                      cleanupIdentity?.inode == identity.inode else {
                    throw UnixDomainSocketError.permissionMismatch
                }
                listener = descriptor
                socketIdentity = identity
            } catch {
                calls.close(descriptor)
                if let cleanupIdentity,
                   let current = try? calls.pathStatus(endpoint.path),
                   current == cleanupIdentity {
                    try? calls.unlink(endpoint.path)
                }
                throw error
            }
            workerGroup.enter()
            worker.async { [self] in
                defer { workerGroup.leave() }
                acceptLoop(descriptor)
            }
        }
    }

    public func recordBootstrapStart(
        _ request: AuthenticatedStartRequest,
        identity: CLIProcessIdentity
    ) throws {
        guard request.endpoint == endpoint,
              request.sessionID == endpoint.sessionID,
              request.workerID == endpoint.workerID else {
            throw KeeperControlError.identityMismatch
        }
        try stateLock.withLock {
            if let acceptedStart {
                guard acceptedStart == request, processIdentity == identity else {
                    throw KeeperControlError.startRequestMismatch
                }
                return
            }
            acceptedStart = request
            processIdentity = identity
        }
    }

    public func stop() {
        let state = stateLock.withLock { () -> (Int32?, [Int32], Set<ViewerID>) in
            guard !stopped else { return (nil, [], []) }
            stopped = true
            return (listener, Array(acceptedDescriptors), Set(viewerByDescriptor.values))
        }
        guard let descriptor = state.0 else { return }
        for accepted in state.1 { _ = Darwin.shutdown(accepted, SHUT_RDWR) }
        if let streamCoordinator {
            for viewerID in state.2 {
                waitForVoid { await streamCoordinator.detach(viewerID: viewerID) }
            }
        }
        wakeAcceptLoop()
        workerGroup.wait()
        calls.close(descriptor)
        stateLock.withLock { listener = nil }
        removeOwnedSocket()
    }

    func pendingOutputWaiterCount() -> Int {
        stateLock.withLock { waitingOutputViewers.count }
    }

    private func acceptLoop(_ descriptor: Int32) {
        while true {
            let accepted: Int32
            do { accepted = try calls.accept(descriptor) }
            catch {
                if stateLock.withLock({ stopped }) { return }
                continue
            }
            if stateLock.withLock({ stopped }) {
                calls.close(accepted)
                return
            }
            let admitted = stateLock.withLock { () -> Bool in
                guard !stopped else { return false }
                acceptedDescriptors.insert(accepted)
                return true
            }
            guard admitted else {
                calls.close(accepted)
                return
            }
            workerGroup.enter()
            connections.async { [self] in
                defer {
                    stateLock.withLock {
                        acceptedDescriptors.remove(accepted)
                        viewerByDescriptor.removeValue(forKey: accepted)
                    }
                    calls.close(accepted)
                    workerGroup.leave()
                }
                handleConnection(accepted)
            }
        }
    }

    private func handleConnection(_ accepted: Int32) {
        do {
            try calls.setCloseOnExec(accepted)
            try calls.setNoSigPipe(accepted)
            let peer = try peerCredentials.peerCredentials(for: accepted)
            guard peer.uid == calls.effectiveUserID() else {
                throw KeeperControlError.authenticationFailed
            }
            let stream = KeeperStreamConnection(descriptor: accepted, ownsDescriptor: false)
            switch try stream.performServerHandshake() {
            case .supervisorControl:
                let authentication = try stream.read(
                    KeeperSupervisorAuthentication.self,
                    expectedChannel: .control
                )
                guard authentication.endpoint == endpoint,
                      authentication.nonce.count == 16,
                      KeeperAuthentication.verifySupervisorProof(
                        authentication.proofMAC,
                        secret: workerSecret,
                        endpoint: endpoint,
                        nonce: authentication.nonce
                      ) else {
                    throw KeeperControlError.authenticationFailed
                }
                try stream.write(
                    KeeperSupervisorAuthenticated(endpoint: endpoint),
                    channel: .control
                )
                let request = try stream.read(
                    KeeperControlEnvelope.self,
                    expectedChannel: .control
                )
                do {
                    try stream.write(handle(request), channel: .control)
                } catch {
                    try? stream.write(
                        KeeperControlEnvelope.failure(Self.wireError(error)),
                        channel: .control
                    )
                }
            case .viewer:
                try handleViewer(stream, descriptor: accepted)
            }
        } catch {
            _ = error
        }
    }

    private func handleViewer(_ stream: KeeperStreamConnection, descriptor: Int32) throws {
        guard let streamCoordinator else { throw TerminalStreamError.authenticationFailed }
        let first = try stream.read(
            KeeperViewerRequest.self,
            expectedChannel: .control
        )
        guard case let .attach(request) = first else {
            throw TerminalStreamError.authenticationFailed
        }
        let viewerID = request.viewerID
        let attachment: Attachment
        do {
            attachment = try waitForAsync { try await streamCoordinator.attach(request) }
        } catch {
            try stream.write(
                KeeperViewerResponse.failure(KeeperStreamFailure.map(error)),
                channel: .control
            )
            return
        }
        var outputPump: Task<Void, Never>?
        defer {
            _ = stateLock.withLock { viewerByDescriptor.removeValue(forKey: descriptor) }
            waitForVoid { await streamCoordinator.detach(viewerID: viewerID) }
            if let outputPump { waitForVoid { _ = await outputPump.result } }
        }
        let admitted = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            viewerByDescriptor[descriptor] = viewerID
            return true
        }
        guard admitted else { return }
        do {
            try stream.write(
                KeeperViewerResponse.attached(attachment.capabilities),
                channel: .control
            )
        } catch {
            return
        }
        outputPump = Task.detached { [self, streamCoordinator, stream] in
            await pumpOutput(
                viewerID: viewerID,
                coordinator: streamCoordinator,
                stream: stream
            )
        }

        while !stateLock.withLock({ stopped }) {
            let packet: (ChannelID, Data)
            do { packet = try stream.readPayload() }
            catch { return }
            if packet.0 == .terminalInput {
                do {
                    let proto = try CPTerminalInput(serializedBytes: packet.1)
                    let input = try TerminalMessages.decode(
                        proto,
                        channelID: .terminalInput,
                        negotiatedVersion: .current
                    )
                    guard input.context.clientInstanceID.rawValue == viewerID.rawValue else {
                        throw TerminalStreamError.inputLeaseRequired
                    }
                    let required: TerminalAttachCapabilities = switch input.payload {
                    case .text, .key, .paste, .mouse: .input
                    case .resize: .resize
                    case .signal: .signal
                    }
                    guard attachment.capabilities.contains(required) else {
                        throw TerminalStreamError.capabilityDenied
                    }
                    let ack = try waitForAsync { try await streamCoordinator.acceptInput(input) }
                    try stream.write(
                        KeeperViewerResponse.inputAcknowledged(ack),
                        channel: .terminalInput
                    )
                } catch {
                    try? stream.write(
                        KeeperViewerResponse.failure(KeeperStreamFailure.map(error)),
                        channel: .terminalInput
                    )
                }
                continue
            }
            let message: (ChannelID, KeeperViewerRequest)
            do {
                message = (
                    packet.0,
                    try JSONDecoder().decode(KeeperViewerRequest.self, from: packet.1)
                )
            } catch {
                try? stream.write(
                    KeeperViewerResponse.failure(.malformedMessage),
                    channel: .control
                )
                continue
            }
            let responseChannel: ChannelID
            do {
                switch message.1 {
                case .attach:
                    throw TerminalStreamError.malformedMessage
                case .nextOutput:
                    throw TerminalStreamError.malformedMessage
                case .visible:
                    guard message.0 == .control else { throw TerminalStreamError.wrongChannel }
                    responseChannel = .control
                    try stream.write(KeeperViewerResponse.acknowledged, channel: responseChannel)
                case let .signalInput(payload):
                    guard message.0 == .control else { throw TerminalStreamError.wrongChannel }
                    let proto = try CPTerminalInput(serializedBytes: payload)
                    let input = try TerminalMessages.decode(
                        proto,
                        channelID: .control,
                        negotiatedVersion: .current
                    )
                    guard input.context.clientInstanceID.rawValue == viewerID.rawValue else {
                        throw TerminalStreamError.inputLeaseRequired
                    }
                    guard attachment.capabilities.contains(.signal) else {
                        throw TerminalStreamError.capabilityDenied
                    }
                    let acknowledgement = try waitForAsync {
                        try await streamCoordinator.acceptInput(input)
                    }
                    responseChannel = .control
                    try stream.write(
                        KeeperViewerResponse.inputAcknowledged(acknowledgement),
                        channel: responseChannel
                    )
                case let .signal(signal, leaseID):
                    guard message.0 == .control else { throw TerminalStreamError.wrongChannel }
                    let group = try waitForAsync {
                        try await streamCoordinator.signal(
                            signal,
                            viewerID: viewerID,
                            leaseID: leaseID
                        )
                    }
                    responseChannel = .control
                    try stream.write(KeeperViewerResponse.signalDelivered(group), channel: responseChannel)
                case let .terminate(force, leaseID):
                    guard message.0 == .control else { throw TerminalStreamError.wrongChannel }
                    try waitForAsync {
                        try await streamCoordinator.terminate(
                            force: force,
                            viewerID: viewerID,
                            leaseID: leaseID
                        )
                    }
                    responseChannel = .control
                    try stream.write(KeeperViewerResponse.acknowledged, channel: responseChannel)
                case .detach:
                    guard message.0 == .control else { throw TerminalStreamError.wrongChannel }
                    waitForVoid { await streamCoordinator.detach(viewerID: viewerID) }
                    try stream.write(KeeperViewerResponse.acknowledged, channel: .control)
                    afterViewerDetachAcknowledgement?()
                    return
                }
            } catch {
                let channel: ChannelID = message.0 == .terminalInput ? .terminalInput : .control
                try? stream.write(
                    KeeperViewerResponse.failure(KeeperStreamFailure.map(error)),
                    channel: channel
                )
            }
        }
    }

    private func pumpOutput(
        viewerID: ViewerID,
        coordinator: TerminalStreamCoordinator,
        stream: KeeperStreamConnection
    ) async {
        while !Task.isCancelled {
            _ = stateLock.withLock { waitingOutputViewers.insert(viewerID) }
            let output: TerminalOutputFrame?
            do { output = try await coordinator.nextOutput(viewerID: viewerID) }
            catch {
                _ = stateLock.withLock { waitingOutputViewers.remove(viewerID) }
                return
            }
            _ = stateLock.withLock { waitingOutputViewers.remove(viewerID) }
            guard let output else { return }
            do {
                for page in KeeperOutputPage.pages(for: output) {
                    try stream.write(
                        KeeperViewerResponse.outputPage(page),
                        channel: .terminalOutput
                    )
                }
            } catch {
                return
            }
        }
    }

    private func handle(_ envelope: KeeperControlEnvelope) throws -> KeeperControlEnvelope {
        switch envelope {
        case let .inspect(request):
            guard request.endpoint == endpoint,
                  request.nonce.count == 16,
                  request.proofMAC == KeeperAuthentication.inspectProof(
                    secret: workerSecret,
                    endpoint: endpoint,
                    nonce: request.nonce
                  ) else {
                throw KeeperControlError.authenticationFailed
            }
            return .identity(stateLock.withLock {
                KeeperIdentity(
                    endpoint: endpoint,
                    sessionID: endpoint.sessionID,
                    workerID: endpoint.workerID,
                    processIdentity: processIdentity
                )
            })

        case let .start(request):
            guard request.endpoint == endpoint,
                  request.sessionID == endpoint.sessionID,
                  request.workerID == endpoint.workerID,
                  request.startNonce.count == 16,
                  KeeperAuthentication.verifyStartProof(
                    request.proofMAC,
                    secret: workerSecret,
                    endpoint: endpoint,
                    sessionID: request.sessionID,
                    workerID: request.workerID,
                    startNonce: request.startNonce
                  ) else {
                throw KeeperControlError.authenticationFailed
            }
            if let accepted = stateLock.withLock({ acceptedStart }) {
                guard accepted == request else { throw KeeperControlError.startRequestMismatch }
                return .started(try stateLock.withLock {
                    guard let processIdentity else { throw KeeperControlError.noRunningProcess }
                    return processIdentity
                })
            }
            let identity = try waitForAsync { [self] in
                try await startHandler(request)
            }
            stateLock.withLock {
                acceptedStart = request
                processIdentity = identity
            }
            return .started(identity)

        case let .terminate(request):
            guard request.endpoint == endpoint,
                  request.nonce.count == 16,
                  request.proofMAC == KeeperAuthentication.terminateProof(
                    secret: workerSecret,
                    endpoint: endpoint,
                    force: request.force,
                    nonce: request.nonce
                  ) else {
                throw KeeperControlError.authenticationFailed
            }
            guard stateLock.withLock({ processIdentity != nil }) else {
                throw KeeperControlError.noRunningProcess
            }
            try waitForAsync { [self] in
                try await terminateHandler(request.force)
            }
            return .acknowledged

        case let .registerAttachTicket(registration, supervisorGeneration):
            guard registration.binding.sessionID == endpoint.sessionID,
                  registration.binding.workerID == endpoint.workerID,
                  let streamCoordinator else {
                throw KeeperControlError.identityMismatch
            }
            try waitForAsync {
                try await streamCoordinator.registerAttachTicket(
                    registration,
                    supervisorGeneration: supervisorGeneration
                )
            }
            return .acknowledged

        case let .registerInputLease(grant, supervisorGeneration):
            guard let streamCoordinator else { throw KeeperControlError.noRunningProcess }
            try waitForAsync {
                try await streamCoordinator.registerInputLease(
                    grant,
                    supervisorGeneration: supervisorGeneration
                )
            }
            return .acknowledged

        case let .transferInputLease(leaseID, grant, supervisorGeneration):
            guard let streamCoordinator else { throw KeeperControlError.noRunningProcess }
            try waitForAsync {
                try await streamCoordinator.transferInputLease(
                    from: leaseID,
                    to: grant,
                    supervisorGeneration: supervisorGeneration
                )
            }
            return .acknowledged

        case let .revokeInputLease(leaseID, supervisorGeneration):
            guard let streamCoordinator else { throw KeeperControlError.noRunningProcess }
            try waitForAsync {
                try await streamCoordinator.revokeInputLease(
                    leaseID,
                    supervisorGeneration: supervisorGeneration
                )
            }
            return .acknowledged

        case let .synchronizeSupervisor(request):
            guard request.acknowledgedThrough <= request.afterSequence,
                  let leaseRevocations,
                  let streamCoordinator else {
                throw KeeperControlError.malformedMessage
            }
            _ = try waitForAsync {
                try await streamCoordinator.beginSupervisorGeneration(
                    request.supervisorGeneration,
                    events: leaseRevocations
                )
            }
            let events = try waitForAsync {
                await leaseRevocations.events(
                    generation: request.supervisorGeneration,
                    acknowledgedThrough: request.acknowledgedThrough,
                    afterSequence: request.afterSequence,
                    waitForEvents: request.waitForEvents
                )
            }
            let leaseSnapshot = try waitForAsync {
                try await streamCoordinator.supervisorInputLeaseSnapshot(
                    supervisorGeneration: request.supervisorGeneration
                )
            }
            let latest = try waitForAsync {
                await leaseRevocations.latestSequence(
                    for: request.supervisorGeneration
                )
            }
            return .supervisorSynchronized(
                KeeperSupervisorSyncResponse(
                    supervisorGeneration: request.supervisorGeneration,
                    currentLease: leaseSnapshot.currentLease,
                    nextInputSequence: leaseSnapshot.nextInputSequence,
                    events: events,
                    latestEventSequence: latest
                )
            )

        case let .signalForeground(signal, viewerID, leaseID, supervisorGeneration):
            guard let streamCoordinator else { throw KeeperControlError.noRunningProcess }
            return .foregroundSignaled(
                try waitForAsync {
                    try await streamCoordinator.signal(
                        signal,
                        viewerID: viewerID,
                        leaseID: leaseID,
                        supervisorGeneration: supervisorGeneration
                    )
                }
            )

        case let .terminateAuthorized(force, viewerID, leaseID, supervisorGeneration):
            guard let streamCoordinator else { throw KeeperControlError.noRunningProcess }
            try waitForAsync {
                try await streamCoordinator.terminate(
                    force: force,
                    viewerID: viewerID,
                    leaseID: leaseID,
                    supervisorGeneration: supervisorGeneration
                )
            }
            return .acknowledged

        default:
            throw KeeperControlError.malformedMessage
        }
    }

    private func wakeAcceptLoop() {
        do {
            let descriptor = try calls.createStreamSocket()
            defer { calls.close(descriptor) }
            try calls.setCloseOnExec(descriptor)
            try calls.connect(descriptor, to: UnixDomainSocketAddress(path: endpoint.path))
        } catch {
            _ = Darwin.shutdown(stateLock.withLock { listener ?? -1 }, SHUT_RDWR)
        }
    }

    private func removeOwnedSocket() {
        guard let expected = stateLock.withLock({ socketIdentity }) else { return }
        if let current = try? calls.pathStatus(endpoint.path), current == expected {
            try? calls.unlink(endpoint.path)
        }
        stateLock.withLock { socketIdentity = nil }
    }

    private static func wireError(_ error: any Error) -> KeeperControlWireError {
        if let streamError = error as? TerminalStreamError {
            return switch streamError {
            case .leaseHeld: .leaseHeld
            case .invalidInputLease: .invalidInputLease
            case .nonMonotonicInputSequence: .nonMonotonicInputSequence
            case .capabilityDenied: .capabilityDenied
            case .viewerNotAttached: .viewerNotAttached
            default: .internalFailure
            }
        }
        return switch error as? KeeperControlError {
        case .authenticationFailed, .invalidProof: .authenticationFailed
        case .identityMismatch: .identityMismatch
        case .startRequestMismatch: .startRequestMismatch
        case .malformedMessage: .malformedMessage
        case .noRunningProcess: .noRunningProcess
        default: .internalFailure
        }
    }
}

private func waitForAsync<Output: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Output
) throws -> Output {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<Output>()
    Task.detached {
        let value: Swift.Result<Output, any Error>
        do { value = .success(try await operation()) }
        catch { value = .failure(error) }
        box.store(value)
        semaphore.signal()
    }
    semaphore.wait()
    return try box.load().get()
}

private func waitForVoid(_ operation: @escaping @Sendable () async -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        await operation()
        semaphore.signal()
    }
    semaphore.wait()
}

private final class AsyncResultBox<Output: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Swift.Result<Output, any Error>?

    func store(_ result: Swift.Result<Output, any Error>) {
        lock.withLock { self.result = result }
    }

    func load() -> Swift.Result<Output, any Error> {
        lock.withLock { result! }
    }
}

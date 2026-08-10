import Darwin
import Dispatch
import Foundation
import CockpitTerminalCore
import CockpitTypes

public final class KeeperUDSServer: @unchecked Sendable {
    public typealias StartHandler = @Sendable (
        AuthenticatedStartRequest
    ) async throws -> CLIProcessIdentity
    public typealias TerminateHandler = @Sendable (_ force: Bool) async throws -> Void

    private let endpoint: KeeperEndpoint
    private let workerSecret: Data
    private let startHandler: StartHandler
    private let terminateHandler: TerminateHandler
    private let calls: any UnixDomainSocketSystemCalls
    private let peerCredentials: any PeerCredentialReading
    private let stateLock = NSLock()
    private let worker = DispatchQueue(label: "dev.cockpit.keeper-control")
    private let workerGroup = DispatchGroup()
    private var listener: Int32?
    private var socketIdentity: UnixSocketPathStatus?
    private var stopped = false
    private var acceptedStart: AuthenticatedStartRequest?
    private var processIdentity: CLIProcessIdentity?

    public init(
        endpoint: KeeperEndpoint,
        workerSecret: Data,
        startHandler: @escaping StartHandler,
        terminateHandler: @escaping TerminateHandler
    ) {
        self.endpoint = endpoint
        self.workerSecret = workerSecret
        self.startHandler = startHandler
        self.terminateHandler = terminateHandler
        calls = DarwinUnixDomainSocketSystemCalls()
        peerCredentials = DarwinPeerCredentialReader()
    }

    init(
        endpoint: KeeperEndpoint,
        workerSecret: Data,
        startHandler: @escaping StartHandler,
        terminateHandler: @escaping TerminateHandler,
        calls: any UnixDomainSocketSystemCalls,
        peerCredentials: any PeerCredentialReading
    ) {
        self.endpoint = endpoint
        self.workerSecret = workerSecret
        self.startHandler = startHandler
        self.terminateHandler = terminateHandler
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
                      existing.owner == calls.effectiveUserID() else {
                    throw UnixDomainSocketError.unsafeSocket
                }
                try calls.unlink(endpoint.path)
            }
            let descriptor = try calls.createStreamSocket()
            do {
                try calls.setCloseOnExec(descriptor)
                try calls.setNoSigPipe(descriptor)
                try calls.bind(descriptor, to: UnixDomainSocketAddress(path: endpoint.path))
                try calls.setPermissions(endpoint.path, permissions: 0o600)
                try calls.listen(descriptor, backlog: 16)
                guard let identity = try calls.pathStatus(endpoint.path),
                      identity.kind == .socket,
                      identity.owner == calls.effectiveUserID(),
                      identity.permissions & 0o777 == 0o600 else {
                    throw UnixDomainSocketError.permissionMismatch
                }
                listener = descriptor
                socketIdentity = identity
            } catch {
                calls.close(descriptor)
                try? calls.unlink(endpoint.path)
                throw error
            }
            workerGroup.enter()
            worker.async { [self] in
                defer { workerGroup.leave() }
                acceptLoop(descriptor)
            }
        }
    }

    public func stop() {
        let descriptor = stateLock.withLock { () -> Int32? in
            guard !stopped else { return nil }
            stopped = true
            return listener
        }
        guard let descriptor else { return }
        wakeAcceptLoop()
        workerGroup.wait()
        calls.close(descriptor)
        stateLock.withLock { listener = nil }
        removeOwnedSocket()
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
            do {
                try calls.setCloseOnExec(accepted)
                try calls.setNoSigPipe(accepted)
                let peer = try peerCredentials.peerCredentials(for: accepted)
                guard peer.uid == calls.effectiveUserID() else {
                    throw KeeperControlError.authenticationFailed
                }
                let request = try KeeperControlFraming.read(
                    KeeperControlEnvelope.self,
                    from: accepted
                )
                try KeeperControlFraming.write(handle(request), to: accepted)
            } catch {
                try? KeeperControlFraming.write(
                    KeeperControlEnvelope.failure(Self.wireError(error)),
                    to: accepted
                )
            }
            calls.close(accepted)
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
        switch error as? KeeperControlError {
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

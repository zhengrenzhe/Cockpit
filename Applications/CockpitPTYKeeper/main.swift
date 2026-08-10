import Darwin
import Dispatch
import Foundation
import CoreFoundation
import CockpitLocalTransport
import CockpitTerminalCore
import CockpitTypes

if CommandLine.arguments.count >= 4,
   CommandLine.arguments[1] == "--cockpit-pty-child" {
    try PTYSession.execChildTrampoline(
        executablePath: CommandLine.arguments[2],
        arguments: Array(CommandLine.arguments.dropFirst(3))
    )
}

enum KeeperRuntimeError: Error, Equatable {
    case invalidStart
    case startFailed
}

final class BootstrapDescriptorOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32? = KeeperBootstrap.inheritedFileDescriptor

    func duplicateForResponseAndClose() throws -> Int32 {
        try lock.withLock {
            guard let descriptor else { throw KeeperControlError.disconnected }
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 4)
            guard duplicate >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            _ = Darwin.close(descriptor)
            self.descriptor = nil
            return duplicate
        }
    }

    func close() {
        lock.withLock {
            if let descriptor {
                _ = Darwin.close(descriptor)
                self.descriptor = nil
            }
        }
    }
}

final class KeeperSessionRuntime: @unchecked Sendable {
    private let bootstrap: KeeperBootstrap
    private let endpoint: KeeperEndpoint
    private let bootstrapDescriptor: BootstrapDescriptorOwner
    private let verifiedRoots: KeeperVerifiedRoots
    private let archiveStore: TerminalArchiveStore
    private let condition = NSCondition()
    private let readQueue = DispatchQueue(label: "dev.cockpit.keeper.pty-read")
    private let frameQueue = DispatchQueue(label: "dev.cockpit.keeper.frame")
    private var acceptedStart: AuthenticatedStartRequest?
    private var session: PTYSession?
    private var adapter: GhosttyVTAdapter?
    private var streamCoordinator: TerminalStreamCoordinator?
    private var starting = false
    private var failed = false
    private var finishing = false
    private var outputSequence: UInt64 = 0
    private var completionHandler: (@Sendable (Int32) -> Void)?

    init(
        bootstrap: KeeperBootstrap,
        endpoint: KeeperEndpoint,
        bootstrapDescriptor: BootstrapDescriptorOwner,
        verifiedRoots: KeeperVerifiedRoots
    ) throws {
        self.bootstrap = bootstrap
        self.endpoint = endpoint
        self.bootstrapDescriptor = bootstrapDescriptor
        self.verifiedRoots = verifiedRoots
        archiveStore = try TerminalArchiveStore(
            applicationSupportRoot: bootstrap.applicationSupportRoot,
            terminalArchivesRoot: bootstrap.terminalArchivesRoot
        )
    }

    func installStreamCoordinator(_ coordinator: TerminalStreamCoordinator) {
        condition.lock()
        streamCoordinator = coordinator
        condition.unlock()
    }

    func installCompletionHandler(_ handler: @escaping @Sendable (Int32) -> Void) {
        condition.lock()
        completionHandler = handler
        condition.unlock()
    }

    func start(_ request: AuthenticatedStartRequest) throws -> CLIProcessIdentity {
        guard request.endpoint == endpoint,
              request.sessionID == bootstrap.sessionID,
              request.workerID == bootstrap.workerInstanceID,
              request.startNonce == bootstrap.startNonce,
              KeeperAuthentication.verifyStartProof(
                request.proofMAC,
                secret: bootstrap.workerSecret,
                endpoint: endpoint,
                sessionID: request.sessionID,
                workerID: request.workerID,
                startNonce: request.startNonce
              ) else {
            throw KeeperControlError.authenticationFailed
        }

        condition.lock()
        if let acceptedStart {
            guard acceptedStart == request else {
                condition.unlock()
                throw KeeperControlError.startRequestMismatch
            }
            while starting { condition.wait() }
            if let session {
                condition.unlock()
                return session.identity
            }
            condition.unlock()
            throw KeeperRuntimeError.startFailed
        }
        acceptedStart = request
        starting = true
        condition.unlock()

        bootstrapDescriptor.close()
        do {
            let adapter = try GhosttyVTAdapter(launchSpec: bootstrap.launchSpec)
            let session = try PTYSession.start(
                bootstrap.launchSpec,
                trampolineExecutablePath: CommandLine.arguments[0]
            )
            condition.lock()
            self.session = session
            self.adapter = adapter
            starting = false
            condition.broadcast()
            condition.unlock()
            beginReading(session: session, adapter: adapter)
            return session.identity
        } catch {
            condition.lock()
            failed = true
            starting = false
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    func terminate(force: Bool) throws {
        condition.lock()
        let current = session
        let didFail = failed
        condition.unlock()
        guard let current else {
            if didFail { throw KeeperRuntimeError.startFailed }
            throw KeeperControlError.noRunningProcess
        }
        try current.terminate(force: force)
    }

    func hasStarted() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return session != nil
    }

    func performInput(_ payload: TerminalInput.Payload) throws {
        condition.lock()
        let current = session
        let terminal = adapter
        condition.unlock()
        guard let current, let terminal else { throw KeeperControlError.noRunningProcess }
        switch payload {
        case let .text(text):
            try current.write(Data(text.utf8))
        case let .key(event):
            try current.write(terminal.encodeKey(event))
        case let .paste(text):
            try current.write(terminal.encodePaste(text))
        case let .mouse(event):
            try current.write(terminal.encodeMouse(event))
        case let .resize(size):
            try current.resize(size)
            try terminal.resize(size)
        case let .signal(signal):
            _ = try signalForeground(signal)
        }
    }

    func resetInputState() {
        condition.lock()
        let terminal = adapter
        condition.unlock()
        terminal?.resetInputState()
    }

    func signalForeground(_ signal: TerminalSignal) throws -> Int32 {
        condition.lock()
        let current = session
        condition.unlock()
        guard let current else { throw KeeperControlError.noRunningProcess }
        let processGroup = tcgetpgrp(current.masterFileDescriptor)
        guard processGroup > 0 else {
            throw PTYSessionFailure(operation: "tcgetpgrp", code: errno)
        }
        let darwinSignal: Int32 = switch signal {
        case .interrupt: SIGINT
        case .quit: SIGQUIT
        case .suspend: SIGTSTP
        case .continue: SIGCONT
        }
        guard Darwin.kill(-processGroup, darwinSignal) == 0 || errno == ESRCH else {
            throw PTYSessionFailure(operation: "killpg(foreground)", code: errno)
        }
        return processGroup
    }

    private func beginReading(session: PTYSession, adapter: GhosttyVTAdapter) {
        readQueue.async { [frameQueue] in
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(
                    session.masterFileDescriptor,
                    &buffer,
                    buffer.count
                )
                if count > 0 {
                    let data = Data(buffer.prefix(count))
                    frameQueue.async { [weak self] in
                        guard let self else { return }
                        do {
                            try adapter.feed(data)
                            let coordinator: TerminalStreamCoordinator?
                            condition.lock()
                            guard outputSequence < UInt64.max else {
                                condition.unlock()
                                return
                            }
                            let sequence = outputSequence + 1
                            condition.unlock()
                            let kind: TerminalStreamFrameKind
                            let frame: Data
                            if sequence.isMultiple(of: 2) {
                                do {
                                    frame = try adapter.delta()
                                    kind = .delta
                                } catch GhosttyVTAdapterError.deltaFailed {
                                    frame = try adapter.snapshot()
                                    kind = .snapshot
                                }
                            } else {
                                frame = try adapter.snapshot()
                                kind = .snapshot
                            }
                            condition.lock()
                            outputSequence = sequence
                            coordinator = streamCoordinator
                            condition.unlock()
                            if let coordinator {
                                waitForFramePublish {
                                    await coordinator.publish(
                                        outputSequence: sequence,
                                        kind: kind,
                                        frame: frame
                                    )
                                }
                            }
                        } catch {
                            return
                        }
                    }
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if count == 0 || (count < 0 && errno == EIO) {
                    let status: Int32
                    do { status = try session.waitForExit(timeout: 5) }
                    catch {
                        self.finish(code: EIO)
                        return
                    }
                    frameQueue.async { [weak self] in
                        self?.publishArchiveAndFinish(
                            waitStatus: status,
                            adapter: adapter
                        )
                    }
                    return
                }
                self.finish(code: EIO)
                return
            }
        }
    }

    private func publishArchiveAndFinish(
        waitStatus: Int32,
        adapter: GhosttyVTAdapter
    ) {
        condition.lock()
        guard !finishing else {
            condition.unlock()
            return
        }
        finishing = true
        let latestSequence = outputSequence
        condition.unlock()

        do {
            let finalSnapshot = try adapter.snapshot()
            let chunks: [TerminalArchiveChunkData]
            let firstSequence: UInt64
            if latestSequence == 0 {
                chunks = []
                firstSequence = 0
            } else {
                chunks = [
                    try TerminalArchiveChunkData(
                        firstOutputSequence: 1,
                        lastOutputSequence: latestSequence,
                        data: try adapter.scrollback(start: 0, count: 100_000)
                    ),
                ]
                firstSequence = 1
            }
            _ = try archiveStore.publish(
                sessionID: bootstrap.sessionID,
                workerID: bootstrap.workerInstanceID,
                chunks: chunks,
                firstOutputSequence: firstSequence,
                latestOutputSequence: latestSequence,
                finalSnapshot: finalSnapshot,
                exitStatus: try Self.exitStatus(from: waitStatus),
                completedAt: Date()
            )
            finish(code: 0)
        } catch {
            finish(code: EIO)
        }
    }

    private func finish(code: Int32) {
        condition.lock()
        let handler = completionHandler
        condition.unlock()
        if let handler { handler(code) }
        else { Darwin._exit(code) }
    }

    private static func exitStatus(from waitStatus: Int32) throws -> TerminalExitStatus {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return .exited(UInt8(truncatingIfNeeded: waitStatus >> 8))
        }
        guard (1...31).contains(signal) else {
            throw KeeperRuntimeError.startFailed
        }
        return .signaled(signal)
    }
}

private func waitForFramePublish(
    _ operation: @escaping @Sendable () async -> Void
) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        await operation()
        semaphore.signal()
    }
    semaphore.wait()
}

private final class KeeperProcessLifetime: @unchecked Sendable {
    private let runtime: KeeperSessionRuntime
    private let server: KeeperUDSServer
    private let bootstrapDescriptor: BootstrapDescriptorOwner
    private let bootstrapQueue = DispatchQueue(
        label: "dev.cockpit.keeper.bootstrap-control"
    )
    private let terminationQueue = DispatchQueue(
        label: "dev.cockpit.keeper.termination"
    )
    private let deadlineLock = NSLock()
    private var deadline: DispatchSourceTimer?
    private var terminationSource: DispatchSourceSignal?

    init(
        runtime: KeeperSessionRuntime,
        server: KeeperUDSServer,
        bootstrapDescriptor: BootstrapDescriptorOwner
    ) {
        self.runtime = runtime
        self.server = server
        self.bootstrapDescriptor = bootstrapDescriptor
    }

    func start() {
        runtime.installCompletionHandler { [self] code in
            cancelSources()
            server.stop()
            Darwin._exit(code)
        }

        let terminationSource = DispatchSource.makeSignalSource(
            signal: SIGTERM,
            queue: terminationQueue
        )
        terminationSource.setEventHandler { [self] in
            try? runtime.terminate(force: true)
            server.stop()
            Darwin._exit(0)
        }
        deadlineLock.withLock { self.terminationSource = terminationSource }
        terminationSource.resume()

        let deadline = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "dev.cockpit.keeper.bootstrap-timeout")
        )
        deadline.schedule(
            deadline: .now() + .nanoseconds(
                Int(KeeperBootstrap.bootstrapTimeoutNanoseconds)
            )
        )
        deadline.setEventHandler { [self] in
            if !runtime.hasStarted() { Darwin._exit(ETIMEDOUT) }
        }
        deadlineLock.withLock { self.deadline = deadline }
        deadline.resume()

        bootstrapQueue.async { [self] in
            handleBootstrapStart()
        }
    }

    private func handleBootstrapStart() {
        var responseDescriptor: Int32?
        do {
            let request = try KeeperBootstrapChannel.receiveStart()
            responseDescriptor = try bootstrapDescriptor.duplicateForResponseAndClose()
            let identity = try runtime.start(request)
            try server.recordBootstrapStart(request, identity: identity)
            try KeeperBootstrapChannel.sendStarted(identity, to: responseDescriptor!)
            cancelDeadline()
        } catch {
            if responseDescriptor == nil {
                responseDescriptor = try? bootstrapDescriptor.duplicateForResponseAndClose()
            }
            if let responseDescriptor,
               let controlError = error as? KeeperControlError {
                try? KeeperBootstrapChannel.sendFailure(controlError, to: responseDescriptor)
            }
        }
        if let responseDescriptor { _ = Darwin.close(responseDescriptor) }
    }

    private func cancelDeadline() {
        let deadline = deadlineLock.withLock { () -> DispatchSourceTimer? in
            defer { self.deadline = nil }
            return self.deadline
        }
        deadline?.cancel()
    }

    private func cancelSources() {
        let sources = deadlineLock.withLock {
            let values = (deadline, terminationSource)
            deadline = nil
            terminationSource = nil
            return values
        }
        sources.0?.cancel()
        sources.1?.cancel()
    }
}

private func parkKeeperProcess(retaining graph: [Any]) {
    withExtendedLifetime(graph) {
        let processLifetime = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 3_153_600_000,
            0,
            0,
            0
        ) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), processLifetime, .defaultMode)
        CFRunLoopRun()
    }
}

let previousSIGCHLDHandler = signal(SIGCHLD, SIG_DFL)
guard unsafeBitCast(previousSIGCHLDHandler, to: Int.self) != -1 else {
    throw CocoaError(.executableRuntimeMismatch)
}
let previousSIGTERMHandler = signal(SIGTERM, SIG_IGN)
guard unsafeBitCast(previousSIGTERMHandler, to: Int.self) != -1 else {
    throw CocoaError(.executableRuntimeMismatch)
}
_ = umask(S_IRWXG | S_IRWXO)

let bootstrapDescriptor = BootstrapDescriptorOwner()
let bootstrap = try KeeperBootstrapChannel.receiveBootstrap()

if bootstrap.mode == .probe {
    bootstrapDescriptor.close()
    let descriptor = KeeperRuntimeDescriptor(
        sessionID: bootstrap.sessionID,
        workerInstanceID: bootstrap.workerInstanceID,
        processID: getpid(),
        processGroupID: getpgrp()
    )
    try SecureRuntimeDirectory.write(descriptor, at: bootstrap.runtimeDirectory)
    parkKeeperProcess(retaining: [bootstrapDescriptor])
}

let validatedBootstrap = try bootstrap.validated()
let roots = try validatedBootstrap.openVerifiedRoots()
try SecureRuntimeDirectory.prepare(at: validatedBootstrap.runtimeDirectory)
let endpoint = try KeeperEndpoint.runtime(
    directory: validatedBootstrap.runtimeDirectory,
    sessionID: validatedBootstrap.sessionID,
    workerID: validatedBootstrap.workerInstanceID
)
let runtime = try KeeperSessionRuntime(
    bootstrap: validatedBootstrap,
    endpoint: endpoint,
    bootstrapDescriptor: bootstrapDescriptor,
    verifiedRoots: roots
)
let attachTickets = TerminalAttachTicketStore(
    clock: SystemTerminalSecurityClock(),
    randomBytes: SecurityTerminalRandomBytes()
)
let leaseRevocations = InputLeaseRevocationBuffer()
let streamCoordinator = TerminalStreamCoordinator(
    sessionID: validatedBootstrap.sessionID,
    workerID: validatedBootstrap.workerInstanceID,
    attachTicketPolicy: attachTickets,
    performInput: { payload in try runtime.performInput(payload) },
    resetInputState: { runtime.resetInputState() },
    reportLeaseRevoked: { grant, nextSequence in
        await leaseRevocations.recordLeaseRevocation(
            grant.leaseID,
            nextSequence: nextSequence
        )
    },
    reportTicketConsumed: { digest in
        await leaseRevocations.recordAttachTicketConsumption(digest)
    },
    signalForeground: { signal in try runtime.signalForeground(signal) },
    terminateSession: { force in try runtime.terminate(force: force) }
)
runtime.installStreamCoordinator(streamCoordinator)
let server = KeeperUDSServer(
    endpoint: endpoint,
    workerSecret: validatedBootstrap.workerSecret,
    streamCoordinator: streamCoordinator,
    leaseRevocations: leaseRevocations,
    startHandler: { request in try runtime.start(request) },
    terminateHandler: { force in try runtime.terminate(force: force) }
)
try server.start()

let descriptor = KeeperRuntimeDescriptor(
    sessionID: validatedBootstrap.sessionID,
    workerInstanceID: validatedBootstrap.workerInstanceID,
    processID: getpid(),
    processGroupID: getpgrp(),
    endpoint: endpoint
)
try SecureRuntimeDirectory.write(descriptor, at: validatedBootstrap.runtimeDirectory)

let readyNonce = Data(try SecurityTerminalRandomBytes().bytes(count: 16))
let ready = KeeperReady(
    endpoint: endpoint,
    sessionID: validatedBootstrap.sessionID,
    workerID: validatedBootstrap.workerInstanceID,
    readyNonce: readyNonce,
    proofMAC: KeeperAuthentication.readyProof(
        secret: validatedBootstrap.workerSecret,
        endpoint: endpoint,
        sessionID: validatedBootstrap.sessionID,
        workerID: validatedBootstrap.workerInstanceID,
        readyNonce: readyNonce
    )
)
try KeeperBootstrapChannel.sendReady(ready)

private let processLifetime = KeeperProcessLifetime(
    runtime: runtime,
    server: server,
    bootstrapDescriptor: bootstrapDescriptor
)
processLifetime.start()
parkKeeperProcess(
    retaining: [
        runtime, streamCoordinator, leaseRevocations, attachTickets,
        server, processLifetime,
    ]
)

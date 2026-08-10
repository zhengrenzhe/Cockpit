import Darwin
import Dispatch
import Foundation
import CockpitLocalTransport
import CockpitTerminalCore

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
    private let condition = NSCondition()
    private let readQueue = DispatchQueue(label: "dev.cockpit.keeper.pty-read")
    private let frameQueue = DispatchQueue(label: "dev.cockpit.keeper.frame")
    private var acceptedStart: AuthenticatedStartRequest?
    private var session: PTYSession?
    private var starting = false
    private var failed = false

    init(
        bootstrap: KeeperBootstrap,
        endpoint: KeeperEndpoint,
        bootstrapDescriptor: BootstrapDescriptorOwner,
        verifiedRoots: KeeperVerifiedRoots
    ) {
        self.bootstrap = bootstrap
        self.endpoint = endpoint
        self.bootstrapDescriptor = bootstrapDescriptor
        self.verifiedRoots = verifiedRoots
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
                    guard (try? adapter.feed(data)) != nil else { return }
                    frameQueue.async { _ = try? adapter.snapshot() }
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if count == 0 || (count < 0 && errno == EIO) {
                    _ = try? session.waitForExit(timeout: 5)
                    return
                }
                return
            }
        }
    }
}

let previousSIGCHLDHandler = signal(SIGCHLD, SIG_DFL)
guard unsafeBitCast(previousSIGCHLDHandler, to: Int.self) != -1 else {
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
    dispatchMain()
}

let validatedBootstrap = try bootstrap.validated()
let roots = try validatedBootstrap.openVerifiedRoots()
try SecureRuntimeDirectory.prepare(at: validatedBootstrap.runtimeDirectory)
let endpoint = try KeeperEndpoint.runtime(
    directory: validatedBootstrap.runtimeDirectory,
    sessionID: validatedBootstrap.sessionID,
    workerID: validatedBootstrap.workerInstanceID
)
let runtime = KeeperSessionRuntime(
    bootstrap: validatedBootstrap,
    endpoint: endpoint,
    bootstrapDescriptor: bootstrapDescriptor,
    verifiedRoots: roots
)
let server = KeeperUDSServer(
    endpoint: endpoint,
    workerSecret: validatedBootstrap.workerSecret,
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

let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
deadline.schedule(deadline: .now() + .nanoseconds(Int(KeeperBootstrap.bootstrapTimeoutNanoseconds)))
deadline.setEventHandler {
    if !runtime.hasStarted() { Darwin._exit(ETIMEDOUT) }
}
deadline.resume()

DispatchQueue(label: "dev.cockpit.keeper.bootstrap-control").async {
    var responseDescriptor: Int32?
    do {
        let request = try KeeperBootstrapChannel.receiveStart()
        responseDescriptor = try bootstrapDescriptor.duplicateForResponseAndClose()
        let identity = try runtime.start(request)
        try KeeperBootstrapChannel.sendStarted(identity, to: responseDescriptor!)
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

dispatchMain()

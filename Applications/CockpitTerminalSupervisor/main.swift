import Darwin
import Foundation
import CockpitHostCore
@_spi(CockpitTerminalSupervisorComposition) import CockpitLocalTransport
import CockpitPersistence
@_spi(CockpitTerminalSupervisorComposition) import CockpitTerminalCore
import CockpitTypes

private func parkTerminalSupervisor(retaining graph: [Any]) {
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

private struct ConfiguredInstallationMasterKeyProvider: InstallationMasterKeyProviding {
    let key: Data

    func masterKey() async throws -> Data { key }
}

private actor TerminalSupervisorCommandService {
    private let supervisor: TerminalSupervisor
    private let repository: SQLiteTerminalSessionRepository
    private let controller: KeeperControlClient
    private let configuration: TerminalSupervisorConfiguration
    private let ticketStore: TerminalAttachTicketStore
    private let archiveStore: TerminalArchiveStore
    private let sessionOperations = TerminalSupervisorSessionOperationGate()
    private let createOperations = TerminalSupervisorIdempotencyOperationGate()
    private let supervisorGeneration: UUID
    private var leases: [TerminalSessionID: InputLeaseGrant] = [:]
    private var nextInputSequence: [TerminalSessionID: UInt64] = [:]
    private var stateRevision: [TerminalSessionID: UInt64] = [:]
    private var eventCursor: [TerminalSessionID: UInt64] = [:]
    private var synchronizedWorkers: [TerminalSessionID: WorkerInstanceID] = [:]
    private var watcherTasks: [TerminalSessionID: Task<Void, Never>] = [:]

    init(
        supervisor: TerminalSupervisor,
        repository: SQLiteTerminalSessionRepository,
        controller: KeeperControlClient,
        configuration: TerminalSupervisorConfiguration,
        ticketStore: TerminalAttachTicketStore,
        archiveStore: TerminalArchiveStore,
        supervisorGeneration: UUID
    ) {
        self.supervisor = supervisor
        self.repository = repository
        self.controller = controller
        self.configuration = configuration
        self.ticketStore = ticketStore
        self.archiveStore = archiveStore
        self.supervisorGeneration = supervisorGeneration
    }

    deinit {
        for task in watcherTasks.values { task.cancel() }
    }

    func start() async throws {
        let sessionIDs = try await repository.activeRecords().compactMap {
            $0.workerID == nil ? nil : $0.sessionID
        }
        await TerminalSupervisorStartupSynchronization.run(
            sessionIDs,
            synchronize: { [self] sessionID in
                await sessionOperations.acquire(sessionID)
                defer { sessionOperations.release(sessionID) }
                try await synchronizeSession(sessionID, startWatcher: true)
            },
            installRetryWatcher: { [self] sessionID in
                await sessionOperations.acquire(sessionID)
                defer { sessionOperations.release(sessionID) }
                try? await ensureWatcher(sessionID)
            }
        )
    }

    func perform(
        _ command: TerminalSupervisorCommandRequest
    ) async throws -> TerminalSupervisorCommandResponse {
        switch command {
        case let .createResolved(request):
            do {
                return .session(try await createResolved(request))
            } catch AgentExecutableResolverError.agentExecutableSelectionRequired {
                guard case let .agent(profileID) = request.kind else {
                    throw AgentExecutableResolverError.agentExecutableSelectionRequired
                }
                return .agentExecutableSelectionRequired(profileID)
            }
        case let .list(contextID):
            return .sessions(try await repository.records(contextID: contextID))
        case let .issueAttachTicket(request):
            return .attachAuthorization(try await issueAttachTicket(request))
        case let .acquireInputLease(request):
            return .inputLease(try await acquireInputLease(request))
        case let .transferInputLease(request):
            return .inputLease(try await transferInputLease(request))
        case let .releaseInputLease(sessionID, leaseID):
            try await releaseInputLease(sessionID: sessionID, leaseID: leaseID)
            return .empty
        case let .signal(sessionID, viewerID, leaseID, requestedSignal):
            return .processGroup(
                try await deliverSignal(
                    sessionID: sessionID,
                    viewerID: viewerID,
                    leaseID: leaseID,
                    signal: requestedSignal
                )
            )
        case let .terminate(sessionID, viewerID, leaseID, force):
            try await terminate(
                sessionID: sessionID,
                viewerID: viewerID,
                leaseID: leaseID,
                force: force
            )
            return .empty
        case .purgeFinishedRecords:
            return .purged(try await purgeFinishedRecords())
        case .reconcile:
            try await reconcileAllSessions()
            try await start()
            return .empty
        case let .beginContextDeletion(contextID, operationID):
            try await beginContextDeletion(contextID: contextID, operationID: operationID)
            return .empty
        case let .terminateContextSessions(contextID, operationID, force):
            return .contextTermination(
                try await terminateContextSessions(
                    contextID: contextID,
                    operationID: operationID,
                    force: force
                )
            )
        case let .contextTerminationStatus(contextID, operationID):
            return .contextTermination(
                try await contextTerminationStatus(
                    contextID: contextID,
                    operationID: operationID
                )
            )
        case let .purgeDeletedContext(contextID, operationID):
            try await purgeDeletedContext(
                contextID: contextID,
                operationID: operationID
            )
            return .empty
        }
    }

    func openArchive(sessionID: TerminalSessionID) async throws -> FileHandle {
        await sessionOperations.acquire(sessionID)
        defer { sessionOperations.release(sessionID) }
        let record = try await repository.record(sessionID: sessionID)
        return try archiveStore.openFinalSnapshot(record: record).makeFileHandle()
    }

    private func createResolved(
        _ request: ResolvedTerminalCreateRequest
    ) async throws -> TerminalSessionRecord {
        let loginShell = try loginShellPath()
        let executable: String
        switch request.kind {
        case .shell:
            executable = loginShell
        case let .agent(profileID):
            executable = try await AgentExecutableResolver(repository: repository).resolve(
                profileID: profileID,
                loginShellPath: loginShell,
                selectedExecutablePath: request.selectedExecutablePath
            )
        }
        let launch = try LaunchSpec(
            kind: request.kind,
            loginShellPath: loginShell,
            executablePath: executable,
            arguments: request.arguments,
            workspaceRoot: request.workspaceRoot,
            terminalSize: request.terminalSize,
            environmentOverrides: request.environmentOverrides
        )
        let createRequest = CreateTerminalSessionRequest(
            contextID: request.contextID,
            environmentID: request.environmentID,
            launchSpec: launch,
            idempotencyKey: request.idempotencyKey
        )
        return try await TerminalSupervisorCreatedSessionActivation.run(
            idempotencyGate: createOperations,
            idempotencyKey: request.idempotencyKey,
            operationGate: sessionOperations,
            create: { [supervisor] in
                try await supervisor.createSession(createRequest)
            },
            sessionID: { $0.sessionID },
            synchronizeAndStartWatcher: { [self] sessionID in
                try await synchronizeSession(sessionID, startWatcher: true)
            }
        )
    }

    private func issueAttachTicket(
        _ request: TerminalAttachTicketRequest
    ) async throws -> TerminalAttachAuthorization {
        await sessionOperations.acquire(request.sessionID)
        defer { sessionOperations.release(request.sessionID) }
        try await synchronizeSession(request.sessionID, startWatcher: true)
        let record = try await activeRecord(request.sessionID)
        guard let workerID = record.workerID else {
            throw TerminalSupervisorError.sessionNotCommitted
        }
        let endpoint = try configuration.endpoint(
            sessionID: request.sessionID,
            workerID: workerID
        )
        let binding = TerminalAttachBinding(
            sessionID: request.sessionID,
            workerID: workerID,
            clientInstanceID: request.clientInstanceID
        )
        let ticket = try await ticketStore.issue(
            binding: binding,
            capabilities: request.capabilities
        )
        do {
            try await controller.registerAttachTicket(
                ticket.registration,
                supervisorGeneration: supervisorGeneration,
                at: endpoint
            )
        } catch {
            await ticketStore.discardIssuedRegistration(
                ticketDigest: ticket.registration.ticketDigest
            )
            throw error
        }
        return TerminalAttachAuthorization(
            endpoint: endpoint,
            wireTicket: ticket.wireValue,
            binding: binding,
            viewerID: request.viewerID,
            capabilities: request.capabilities
        )
    }

    private func acquireInputLease(
        _ request: TerminalInputLeaseRequest
    ) async throws -> InputLeaseGrant {
        await sessionOperations.acquire(request.sessionID)
        defer { sessionOperations.release(request.sessionID) }
        try await synchronizeSession(request.sessionID, startWatcher: true)
        if let current = leases[request.sessionID] {
            guard current.holderViewerID == request.viewerID,
                  current.capabilities == request.capabilities else {
                throw TerminalStreamError.leaseHeld
            }
            return current
        }
        return try await registerLease(
            sessionID: request.sessionID,
            viewerID: request.viewerID,
            capabilities: request.capabilities
        )
    }

    private func transferInputLease(
        _ request: TerminalInputLeaseTransferRequest
    ) async throws -> InputLeaseGrant {
        await sessionOperations.acquire(request.sessionID)
        defer { sessionOperations.release(request.sessionID) }
        try await synchronizeSession(request.sessionID, startWatcher: true)
        guard let current = leases[request.sessionID], current.leaseID == request.leaseID else {
            throw TerminalStreamError.invalidInputLease
        }
        let record = try await activeRecord(request.sessionID)
        guard let workerID = record.workerID else {
            throw TerminalSupervisorError.sessionNotCommitted
        }
        let base = nextInputSequence[request.sessionID] ?? current.sequenceBase
        let grant = try InputLeaseGrant(
            validatingLeaseID: InputLeaseID(),
            holderViewerID: request.toViewerID,
            sequenceBase: base,
            capabilities: request.capabilities
        )
        try await controller.transferInputLease(
            from: current.leaseID,
            to: grant,
            supervisorGeneration: supervisorGeneration,
            at: configuration.endpoint(sessionID: request.sessionID, workerID: workerID)
        )
        leases[request.sessionID] = grant
        nextInputSequence[request.sessionID] = base
        bumpStateRevision(request.sessionID)
        return grant
    }

    private func releaseInputLease(
        sessionID: TerminalSessionID,
        leaseID: InputLeaseID
    ) async throws {
        await sessionOperations.acquire(sessionID)
        defer { sessionOperations.release(sessionID) }
        try await synchronizeSession(sessionID, startWatcher: true)
        guard let current = leases[sessionID], current.leaseID == leaseID else { return }
        try await revoke(current, sessionID: sessionID)
    }

    private func registerLease(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) async throws -> InputLeaseGrant {
        let record = try await activeRecord(sessionID)
        guard let workerID = record.workerID else {
            throw TerminalSupervisorError.sessionNotCommitted
        }
        let base = nextInputSequence[sessionID] ?? 1
        let grant = try InputLeaseGrant(
            validatingLeaseID: InputLeaseID(),
            holderViewerID: viewerID,
            sequenceBase: base,
            capabilities: capabilities
        )
        let endpoint = try configuration.endpoint(sessionID: sessionID, workerID: workerID)
        try await controller.registerInputLease(
            grant,
            supervisorGeneration: supervisorGeneration,
            at: endpoint
        )
        leases[sessionID] = grant
        nextInputSequence[sessionID] = base
        bumpStateRevision(sessionID)
        return grant
    }

    private func revoke(_ grant: InputLeaseGrant, sessionID: TerminalSessionID) async throws {
        let record = try await activeRecord(sessionID)
        guard let workerID = record.workerID else {
            throw TerminalSupervisorError.sessionNotCommitted
        }
        let endpoint = try configuration.endpoint(sessionID: sessionID, workerID: workerID)
        try await controller.revokeInputLease(
            grant.leaseID,
            supervisorGeneration: supervisorGeneration,
            at: endpoint
        )
        try await synchronizeSession(sessionID, startWatcher: true)
        guard leases[sessionID]?.leaseID != grant.leaseID else {
            throw TerminalStreamError.invalidInputLease
        }
    }

    private func deliverSignal(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        signal: TerminalSignal
    ) async throws -> Int32 {
        await sessionOperations.acquire(sessionID)
        defer { sessionOperations.release(sessionID) }
        try await synchronizeSession(sessionID, startWatcher: true)
        let record = try await activeRecord(sessionID)
        let grant = try authorizedGrant(
            sessionID: sessionID,
            viewerID: viewerID,
            leaseID: leaseID,
            capability: .signal
        )
        guard grant.holderViewerID == viewerID,
              let workerID = record.workerID else {
            throw TerminalStreamError.capabilityDenied
        }
        return try await controller.signalForeground(
            signal,
            viewerID: viewerID,
            leaseID: leaseID,
            supervisorGeneration: supervisorGeneration,
            at: configuration.endpoint(sessionID: sessionID, workerID: workerID)
        )
    }

    private func terminate(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        force: Bool
    ) async throws {
        await sessionOperations.acquire(sessionID)
        defer { sessionOperations.release(sessionID) }
        try await synchronizeSession(sessionID, startWatcher: true)
        let record = try await activeRecord(sessionID)
        _ = try authorizedGrant(
            sessionID: sessionID,
            viewerID: viewerID,
            leaseID: leaseID,
            capability: .terminate
        )
        guard let workerID = record.workerID else {
            throw TerminalSupervisorError.sessionNotCommitted
        }
        try await controller.terminateAuthorized(
            force: force,
            viewerID: viewerID,
            leaseID: leaseID,
            supervisorGeneration: supervisorGeneration,
            at: configuration.endpoint(sessionID: sessionID, workerID: workerID)
        )
    }

    private func authorizedGrant(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        capability: TerminalAttachCapabilities
    ) throws -> InputLeaseGrant {
        guard let grant = leases[sessionID],
              grant.leaseID == leaseID,
              grant.holderViewerID == viewerID,
              grant.capabilities.contains(capability) else {
            throw TerminalStreamError.capabilityDenied
        }
        return grant
    }

    private func synchronizeSession(
        _ sessionID: TerminalSessionID,
        startWatcher: Bool
    ) async throws {
        let (workerID, endpoint) = try await prepareWorker(sessionID)
        let capturedRevision = stateRevision[sessionID, default: 0]
        let cursor = eventCursor[sessionID, default: 0]
        do {
            let response = try await controller.synchronizeSupervisor(
                KeeperSupervisorSyncRequest(
                    supervisorGeneration: supervisorGeneration,
                    acknowledgedThrough: cursor,
                    afterSequence: cursor,
                    waitForEvents: false
                ),
                at: endpoint
            )
            try await applySynchronization(
                response,
                sessionID: sessionID,
                workerID: workerID,
                capturedRevision: capturedRevision,
                requestedCursor: cursor
            )
        } catch {
            if startWatcher {
                installWatcher(sessionID: sessionID, workerID: workerID, endpoint: endpoint)
            }
            throw error
        }
        if startWatcher {
            installWatcher(sessionID: sessionID, workerID: workerID, endpoint: endpoint)
        }
    }

    private func ensureWatcher(_ sessionID: TerminalSessionID) async throws {
        let (workerID, endpoint) = try await prepareWorker(sessionID)
        installWatcher(sessionID: sessionID, workerID: workerID, endpoint: endpoint)
    }

    private func prepareWorker(
        _ sessionID: TerminalSessionID
    ) async throws -> (WorkerInstanceID, KeeperEndpoint) {
        let record = try await activeRecord(sessionID)
        guard let workerID = record.workerID else {
            throw TerminalSupervisorError.sessionNotCommitted
        }
        if synchronizedWorkers[sessionID] != workerID {
            watcherTasks.removeValue(forKey: sessionID)?.cancel()
            synchronizedWorkers[sessionID] = workerID
            eventCursor[sessionID] = 0
            bumpStateRevision(sessionID)
        }
        let endpoint = try configuration.endpoint(sessionID: sessionID, workerID: workerID)
        return (workerID, endpoint)
    }

    private func installWatcher(
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        endpoint: KeeperEndpoint
    ) {
        guard watcherTasks[sessionID] == nil else { return }
        watcherTasks[sessionID] = Task { [weak self] in
            await self?.watchSupervisorEvents(
                sessionID: sessionID,
                workerID: workerID,
                endpoint: endpoint
            )
        }
    }

    private func watchSupervisorEvents(
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        endpoint: KeeperEndpoint
    ) async {
        while !Task.isCancelled, synchronizedWorkers[sessionID] == workerID {
            let capturedRevision = stateRevision[sessionID, default: 0]
            let cursor = eventCursor[sessionID, default: 0]
            do {
                let response = try await controller.synchronizeSupervisor(
                    KeeperSupervisorSyncRequest(
                        supervisorGeneration: supervisorGeneration,
                        acknowledgedThrough: cursor,
                        afterSequence: cursor,
                        waitForEvents: true
                    ),
                    at: endpoint
                )
                await sessionOperations.acquire(sessionID)
                defer { sessionOperations.release(sessionID) }
                try await applySynchronization(
                    response,
                    sessionID: sessionID,
                    workerID: workerID,
                    capturedRevision: capturedRevision,
                    requestedCursor: cursor
                )
            } catch {
                if Task.isCancelled { break }
                await sessionOperations.acquire(sessionID)
                let finished: Bool
                do {
                    finished = try await TerminalSupervisorCompletionRecovery.reconcileAfterDisconnect(
                        sessionID: sessionID,
                        reconcile: { [supervisor] in
                            try await supervisor.reconcileAfterTransientDisconnect(
                                sessionID: sessionID
                            )
                        },
                        activeRecords: { [repository] in
                            try await repository.activeRecords().map(\.sessionID)
                        }
                    )
                } catch {
                    finished = false
                }
                if finished, synchronizedWorkers[sessionID] == workerID {
                    retireSessionState(sessionID, workerID: workerID)
                }
                sessionOperations.release(sessionID)
                if finished { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if synchronizedWorkers[sessionID] == workerID {
            watcherTasks.removeValue(forKey: sessionID)
        }
    }

    private func applySynchronization(
        _ response: KeeperSupervisorSyncResponse,
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        capturedRevision: UInt64,
        requestedCursor: UInt64
    ) async throws {
        guard response.supervisorGeneration == supervisorGeneration,
              synchronizedWorkers[sessionID] == workerID,
              response.nextInputSequence > 0,
              response.currentLease?.nextSequence == nil
                || response.currentLease?.nextSequence == response.nextInputSequence else {
            throw KeeperControlError.identityMismatch
        }
        guard eventCursor[sessionID, default: 0] == requestedCursor else { return }
        var expected = requestedCursor
        for event in response.events {
            guard event.sequence == expected + 1 else {
                throw KeeperControlError.malformedMessage
            }
            expected = event.sequence
            switch event.payload {
            case let .leaseRevoked(leaseID, nextSequence):
                nextInputSequence[sessionID] = max(
                    nextInputSequence[sessionID] ?? 1,
                    nextSequence
                )
                if leases[sessionID]?.leaseID == leaseID {
                    leases.removeValue(forKey: sessionID)
                }
                bumpStateRevision(sessionID)
            case let .attachTicketConsumed(digest):
                try await ticketStore.acknowledgeConsumption(ticketDigest: digest)
            }
        }
        eventCursor[sessionID] = expected
        if stateRevision[sessionID, default: 0] == capturedRevision {
            nextInputSequence[sessionID] = response.nextInputSequence
            if let current = response.currentLease {
                leases[sessionID] = current.grant
            } else {
                leases.removeValue(forKey: sessionID)
            }
            bumpStateRevision(sessionID)
        } else {
            nextInputSequence[sessionID] = max(
                nextInputSequence[sessionID] ?? 1,
                response.nextInputSequence
            )
        }
    }

    private func bumpStateRevision(_ sessionID: TerminalSessionID) {
        let current = stateRevision[sessionID, default: 0]
        stateRevision[sessionID] = current == UInt64.max ? 1 : current + 1
    }

    private func reconcileAllSessions() async throws {
        let sessionIDs = try await repository.activeRecords()
            .map(\.sessionID)
            .sorted { $0.description < $1.description }
        for sessionID in sessionIDs {
            await sessionOperations.acquire(sessionID)
            do {
                try await supervisor.reconcile(sessionID: sessionID)
                if try await !repository.activeRecords().contains(where: {
                    $0.sessionID == sessionID
                }) {
                    retireSessionState(sessionID)
                }
                sessionOperations.release(sessionID)
            } catch {
                sessionOperations.release(sessionID)
                throw error
            }
        }
    }

    private func purgeFinishedRecords() async throws -> Int {
        let sessionIDs = watcherTasks.keys.sorted { $0.description < $1.description }
        for sessionID in sessionIDs { await sessionOperations.acquire(sessionID) }
        do {
            let purged = try await repository.purgeFinishedRecords()
            let active = Set(try await repository.activeRecords().map(\.sessionID))
            for sessionID in sessionIDs where !active.contains(sessionID) {
                retireSessionState(sessionID)
            }
            for sessionID in sessionIDs.reversed() { sessionOperations.release(sessionID) }
            return purged
        } catch {
            for sessionID in sessionIDs.reversed() { sessionOperations.release(sessionID) }
            throw error
        }
    }

    private func beginContextDeletion(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws {
        try await supervisor.beginContextDeletion(
            contextID: contextID,
            operationID: operationID
        )
    }

    private func terminateContextSessions(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID,
        force: Bool
    ) async throws -> ContextTerminationResult {
        let sessionIDs = try await repository.records(contextID: contextID)
            .map(\.sessionID)
            .sorted { $0.description < $1.description }
        for sessionID in sessionIDs { await sessionOperations.acquire(sessionID) }
        defer {
            for sessionID in sessionIDs.reversed() {
                sessionOperations.release(sessionID)
            }
        }
        return try await supervisor.terminateSessions(
            contextID: contextID,
            operationID: operationID,
            force: force
        )
    }

    private func purgeDeletedContext(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws {
        let records = try await repository.records(contextID: contextID)
            .sorted { $0.sessionID.description < $1.sessionID.description }
        for record in records { await sessionOperations.acquire(record.sessionID) }
        do {
            let activeStates: Set<TerminalLifecycleState> = [
                .preparing, .committed, .running,
            ]
            guard !records.contains(where: { activeStates.contains($0.lifecycleState) }) else {
                throw TerminalSessionRepositoryError.activeSessionsRemain
            }
            for record in records {
                try archiveStore.deleteArchive(sessionID: record.sessionID)
            }
            try await supervisor.purgeDeletedContext(
                contextID: contextID,
                operationID: operationID
            )
            for record in records { retireSessionState(record.sessionID) }
            for record in records.reversed() {
                sessionOperations.release(record.sessionID)
            }
        } catch {
            for record in records.reversed() {
                sessionOperations.release(record.sessionID)
            }
            throw error
        }
    }

    private func contextTerminationStatus(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws -> ContextTerminationResult {
        let sessionIDs = try await repository.records(contextID: contextID)
            .map(\.sessionID)
            .sorted { $0.description < $1.description }
        for sessionID in sessionIDs { await sessionOperations.acquire(sessionID) }
        defer {
            for sessionID in sessionIDs.reversed() {
                sessionOperations.release(sessionID)
            }
        }
        return try await supervisor.contextTerminationStatus(
            contextID: contextID,
            operationID: operationID
        )
    }

    private func retireSessionState(
        _ sessionID: TerminalSessionID,
        workerID: WorkerInstanceID? = nil
    ) {
        if let workerID, synchronizedWorkers[sessionID] != workerID { return }
        watcherTasks.removeValue(forKey: sessionID)?.cancel()
        leases.removeValue(forKey: sessionID)
        nextInputSequence.removeValue(forKey: sessionID)
        eventCursor.removeValue(forKey: sessionID)
        synchronizedWorkers.removeValue(forKey: sessionID)
        bumpStateRevision(sessionID)
    }

    private func activeRecord(_ sessionID: TerminalSessionID) async throws -> TerminalSessionRecord {
        guard let record = try await repository.activeRecords().first(where: {
            $0.sessionID == sessionID
        }) else { throw TerminalSupervisorError.sessionNotFound }
        return record
    }

    private func loginShellPath() throws -> String {
        let candidate = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard candidate.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: candidate) else {
            throw LaunchSpecError.invalidAbsolutePath
        }
        return candidate
    }
}

func optionalValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

let arguments = CommandLine.arguments
let serviceNamespace = try XPCServiceNamespace(
    ProcessInfo.processInfo.environment["COCKPIT_SERVICE_NAMESPACE"] ?? ""
)
let previousSIGCHLDHandler = signal(SIGCHLD, SIG_IGN)
guard unsafeBitCast(previousSIGCHLDHandler, to: Int.self) != -1 else {
    throw KeeperLaunchFailure(operation: "signal(SIGCHLD)", code: errno)
}
_ = umask(S_IRWXG | S_IRWXO)
let ownExecutable = URL(fileURLWithPath: arguments[0]).standardizedFileURL
let keeperExecutable = optionalValue(after: "--keeper-executable", in: arguments)
    ?? ownExecutable.deletingLastPathComponent()
        .appendingPathComponent("CockpitPTYKeeper").path
let runtimeDirectory = optionalValue(after: "--runtime-directory", in: arguments)
    ?? "/private/tmp/cockpit.\(geteuid())/terminal"

try SecureRuntimeDirectory.prepare(at: runtimeDirectory)

let launcher = KeeperProcessLauncher(executablePath: keeperExecutable)
let storage: CockpitStorageLocations
let configuredRoot = ProcessInfo.processInfo.environment[
    "COCKPIT_APPLICATION_SUPPORT_ROOT"
]
if !serviceNamespace.description.isEmpty {
    guard let configuredRoot, configuredRoot.hasPrefix("/") else {
        throw CocoaError(.fileReadInvalidFileName)
    }
    storage = try CockpitStorageLocations.under(
        URL(fileURLWithPath: configuredRoot, isDirectory: true)
    )
} else if let configuredRoot, !configuredRoot.isEmpty {
    storage = try CockpitStorageLocations.under(
        URL(fileURLWithPath: configuredRoot, isDirectory: true)
    )
} else {
    storage = try CockpitStorageLocations.production()
}
let repository = try await SQLiteTerminalSessionRepository(
    databaseURL: storage.terminalDatabase
)
let explicitMasterKeychainPath: String?
if serviceNamespace.description.isEmpty {
    explicitMasterKeychainPath = nil
} else {
    guard let fixtureHome = ProcessInfo.processInfo.environment["HOME"],
          fixtureHome.hasPrefix("/") else {
        throw CocoaError(.fileReadInvalidFileName)
    }
    explicitMasterKeychainPath = URL(
        fileURLWithPath: fixtureHome,
        isDirectory: true
    ).appendingPathComponent("Library/Keychains/cockpit-phase1.keychain-db").path
}
let masterKeyProvider: any InstallationMasterKeyProviding
if let encodedMasterKey = ProcessInfo.processInfo.environment[
    "COCKPIT_INTEGRATION_MASTER_KEY"
] {
    guard ProcessInfo.processInfo.environment[
        "COCKPIT_APPLICATION_SUPPORT_ROOT"
    ] != nil,
    let configuredMasterKey = Data(base64Encoded: encodedMasterKey),
    configuredMasterKey.count == 32
    else { throw TerminalSecurityError.invalidMasterKeyLength }
    masterKeyProvider = ConfiguredInstallationMasterKeyProvider(
        key: configuredMasterKey
    )
} else {
    masterKeyProvider = InstallationMasterKeyStore(
        service: serviceNamespace.description.isEmpty
            ? InstallationMasterKeyStore.productionService
            : "\(InstallationMasterKeyStore.productionService).\(serviceNamespace)",
        explicitKeychainPath: explicitMasterKeychainPath
    )
}
let workerSecretDeriver = WorkerSecretDeriver(
    masterKeyProvider: masterKeyProvider
)
let controller = KeeperControlClient { sessionID, workerID in
    try await workerSecretDeriver.derive(
        sessionID: sessionID,
        workerID: workerID
    )
}
let configuration = try TerminalSupervisorConfiguration(
    applicationSupportRoot: storage.applicationSupport.path,
    terminalArchivesRoot: storage.terminalArchiveRoot.path,
    runtimeDirectory: runtimeDirectory
)
let supervisor = TerminalSupervisor(
    repository: repository,
    launcher: launcher,
    controller: controller,
    workerSecretDeriver: workerSecretDeriver,
    randomBytes: SecurityTerminalRandomBytes(),
    configuration: configuration
)
try await supervisor.reconcile()
let archiveStore = try TerminalArchiveStore(
    applicationSupportRoot: storage.applicationSupport.path,
    terminalArchivesRoot: storage.terminalArchiveRoot.path
)
let attachTicketStore = TerminalAttachTicketStore(
    clock: SystemTerminalSecurityClock(),
    randomBytes: SecurityTerminalRandomBytes()
)
let supervisorGeneration = try await repository.allocateSupervisorGeneration()
private let commandService = TerminalSupervisorCommandService(
    supervisor: supervisor,
    repository: repository,
    controller: controller,
    configuration: configuration,
    ticketStore: attachTicketStore,
    archiveStore: archiveStore,
    supervisorGeneration: supervisorGeneration
)
try await commandService.start()
let exported = TerminalSupervisorXPCExport(
    handshakeHandler: { try TerminalSupervisorHandshakeHandler().handle($0) },
    commandHandler: { try await commandService.perform($0) },
    archiveHandler: { sessionID in
        try await commandService.openArchive(sessionID: sessionID)
    }
)
let delegate = MachServiceListenerDelegate(
    exportedObject: exported,
    exportedInterface: NSXPCInterface(with: TerminalSupervisorXPCProtocol.self)
)
let listener = NSXPCListener(
    machServiceName: XPCServiceEndpoint.terminal.machServiceName(
        in: serviceNamespace
    )
)
listener.delegate = delegate
listener.resume()
parkTerminalSupervisor(
    retaining:
    [
        repository, masterKeyProvider, workerSecretDeriver, controller,
        supervisor, archiveStore, attachTicketStore, commandService,
        exported, delegate, listener,
    ] as [Any]
)

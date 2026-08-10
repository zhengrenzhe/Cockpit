import Darwin
import Foundation
import Testing
import CockpitHostCore
import CockpitTerminalClient
import CockpitTerminalCore
import CockpitTypes
@_spi(CockpitTerminalSupervisorComposition) @testable import CockpitLocalTransport

@Test func terminalSupervisorSessionGateSerializesSameSessionWithoutBlockingOthers() async throws {
    let gate = TerminalSupervisorSessionOperationGate()
    let firstSession = TerminalSessionID()
    let otherSession = TerminalSessionID()
    let probe = TerminalSupervisorGateProbe()
    await gate.acquire(firstSession)

    let sameSession = Task {
        await gate.acquire(firstSession)
        await probe.markSameSessionEntered()
        gate.release(firstSession)
    }
    let other = Task {
        await gate.acquire(otherSession)
        await probe.markOtherSessionEntered()
        gate.release(otherSession)
    }
    try await Task.sleep(for: .milliseconds(25))

    #expect(await probe.otherSessionEntered)
    #expect(!(await probe.sameSessionEntered))
    gate.release(firstSession)
    await sameSession.value
    await other.value
    #expect(await probe.sameSessionEntered)
}

@Test func terminalSupervisorStartupSynchronizationIsolatesFailingSessions() async {
    let failing = TerminalSessionID()
    let healthy = TerminalSessionID()
    let probe = TerminalSupervisorGateProbe()

    await TerminalSupervisorStartupSynchronization.run(
        [failing, healthy],
        synchronize: { sessionID in
            await probe.recordStartup(sessionID)
            if sessionID == failing { throw CocoaError(.fileReadCorruptFile) }
        },
        installRetryWatcher: { sessionID in
            await probe.recordRetryWatcher(sessionID)
        }
    )

    #expect(await probe.startupSessions == [failing, healthy])
    #expect(await probe.retryWatcherSessions == [failing])
}

@Test func terminalSupervisorCreatedSessionStartsWatcherUnderItsSessionGateBeforeReturn() async throws {
    let sessionID = TerminalSessionID()
    let gate = TerminalSupervisorSessionOperationGate()
    let createGate = TerminalSupervisorIdempotencyOperationGate()
    let probe = TerminalSupervisorGateProbe()

    let returned = try await TerminalSupervisorCreatedSessionActivation.run(
        idempotencyGate: createGate,
        idempotencyKey: RequestID(),
        operationGate: gate,
        create: {
            await probe.recordCreated(sessionID)
            return sessionID
        },
        sessionID: { $0 },
        synchronizeAndStartWatcher: { createdSessionID in
            await probe.recordWatcher(createdSessionID)
        }
    )

    #expect(returned == sessionID)
    #expect(await probe.createdSessionEvents == ["create", "watcher"])
}

@Test func terminalSupervisorConcurrentIdempotentCreateLaunchesOneKeeper() async throws {
    let sessionID = TerminalSessionID()
    let gate = TerminalSupervisorSessionOperationGate()
    let createGate = TerminalSupervisorIdempotencyOperationGate()
    let requestID = RequestID()
    let probe = TerminalSupervisorConcurrentCreateProbe(sessionID: sessionID)

    let first = Task {
        try await TerminalSupervisorCreatedSessionActivation.run(
            idempotencyGate: createGate,
            idempotencyKey: requestID,
            operationGate: gate,
            create: { await probe.create() },
            sessionID: { $0 },
            synchronizeAndStartWatcher: { _ in }
        )
    }
    await probe.waitForFirstLaunch()
    let second = Task {
        try await TerminalSupervisorCreatedSessionActivation.run(
            idempotencyGate: createGate,
            idempotencyKey: requestID,
            operationGate: gate,
            create: { await probe.create() },
            sessionID: { $0 },
            synchronizeAndStartWatcher: { _ in }
        )
    }
    try await Task.sleep(for: .milliseconds(25))

    #expect(await probe.launches == 1)
    await probe.resumeLaunch()
    #expect(try await first.value == sessionID)
    #expect(try await second.value == sessionID)
    #expect(await probe.launches == 1)
}

@Test func terminalSupervisorDisconnectReconcilesVerifiedCompletionBeforeRetiringSession() async throws {
    let sessionID = TerminalSessionID()
    let probe = TerminalSupervisorCompletionProbe(sessionID: sessionID)

    #expect(await probe.isActive(sessionID))
    let finished = try await TerminalSupervisorCompletionRecovery.reconcileAfterDisconnect(
        sessionID: sessionID,
        reconcile: { await probe.reconcileVerifiedArchive() },
        activeRecords: { await probe.activeRecords() }
    )

    #expect(finished)
    #expect(await probe.events == ["reconcile", "active-records"])
    #expect(!(await probe.isActive(sessionID)))
}

@Test func terminalSupervisorDisconnectTreatsPurgedRecordAsRetired() async throws {
    let sessionID = TerminalSessionID()
    let finished = try await TerminalSupervisorCompletionRecovery.reconcileAfterDisconnect(
        sessionID: sessionID,
        reconcile: { throw TerminalSessionRepositoryError.recordNotFound },
        activeRecords: { Issue.record("activeRecords must not run after recordNotFound"); return [] }
    )

    #expect(finished)
}

@Test func terminalAppReattachPreservesSessionKeeperAndCLIIdentityAndInput() async throws {
    guard let executable = ProcessInfo.processInfo.environment["COCKPIT_PTY_KEEPER_EXECUTABLE"] else {
        return
    }
    let root = try terminalIntegrationTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let applicationSupport = root.appendingPathComponent("ApplicationSupport")
    let archives = applicationSupport.appendingPathComponent("TerminalArchives")
    let runtime = root.appendingPathComponent("runtime")
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
    for directory in [applicationSupport, archives, runtime, workspace] {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    let probeSource = root.appendingPathComponent("reattach-probe.c")
    let probe = root.appendingPathComponent("reattach-probe")
    try """
    #include <termios.h>
    #include <unistd.h>
    int main(void) {
      static const char ready[] = "READY\\n";
      static const char consumed[] = "CONSUMED:";
      char bytes[256];
      struct termios settings;
      if (tcgetattr(STDIN_FILENO, &settings) == 0) {
        settings.c_lflag &= (tcflag_t)~(ECHO | ICANON);
        settings.c_cc[VMIN] = 1;
        settings.c_cc[VTIME] = 0;
        (void)tcsetattr(STDIN_FILENO, TCSANOW, &settings);
      }
      (void)write(STDOUT_FILENO, ready, sizeof(ready) - 1);
      for (;;) {
        ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
        if (count <= 0) return 0;
        (void)write(STDOUT_FILENO, consumed, sizeof(consumed) - 1);
        (void)write(STDOUT_FILENO, bytes, (size_t)count);
      }
    }
    """.write(to: probeSource, atomically: true, encoding: .utf8)
    try runTerminalIntegrationProcess("/usr/bin/clang", [probeSource.path, "-o", probe.path])

    let secret = Data(repeating: 0xA1, count: 32)
    let nonce = Data(repeating: 0xA2, count: 16)
    let sessionID = TerminalSessionID()
    let workerID = WorkerInstanceID()
    let projectID = ProjectID()
    let contextID = WorkspaceContextID.project(projectID)
    let environmentID = EnvironmentID()
    let bootstrap = try KeeperBootstrap(
        sessionID: sessionID,
        workerInstanceID: workerID,
        launchSpec: try LaunchSpec(
            kind: .agent(.codex),
            loginShellPath: "/bin/zsh",
            executablePath: probe.path,
            arguments: [],
            workspaceRoot: workspace.path,
            terminalSize: TerminalResize(validatingColumns: 80, rows: 24),
            environmentOverrides: ["TERM": "xterm-256color"]
        ),
        startNonce: nonce,
        applicationSupportRoot: applicationSupport.path,
        terminalArchivesRoot: archives.path,
        runtimeDirectory: runtime.path,
        workerSecret: secret
    )
    let launched = try await terminalIntegrationStage("launch keeper") {
        try await KeeperProcessLauncher(executablePath: executable).launch(bootstrap)
    }
    var cliProcessGroupID: pid_t?
    defer {
        if let cliProcessGroupID {
            terminateTerminalIntegrationProcessGroup(cliProcessGroupID)
        }
        reapTerminalIntegrationProcess(launched.processID)
        if let cliProcessGroupID {
            #expect(terminalIntegrationProcessGroupIsAbsent(cliProcessGroupID))
        }
    }
    let keeper = KeeperControlClient(secretProvider: { _, _ in secret })
    let ready = try await terminalIntegrationStage("await keeper ready") {
        try await keeper.awaitReady(launched)
    }
    let start = AuthenticatedStartRequest(
        endpoint: ready.endpoint,
        sessionID: sessionID,
        workerID: workerID,
        startNonce: nonce,
        proofMAC: KeeperAuthentication.startProof(
            secret: secret,
            endpoint: ready.endpoint,
            sessionID: sessionID,
            workerID: workerID,
            startNonce: nonce
        )
    )
    let originalCLI = try await terminalIntegrationStage("authenticated start") {
        try await keeper.authenticatedStart(start)
    }
    cliProcessGroupID = originalCLI.processGroupID
    let originalKeeperPID = launched.processID
    #expect(originalCLI.processID == originalCLI.processGroupID)

    let record = try TerminalSessionRecord(
        validatingSessionID: sessionID,
        contextID: contextID,
        environmentID: environmentID,
        protocolVersion: .current,
        launchSpecData: try JSONEncoder().encode(bootstrap.launchSpec),
        lifecycleState: .running,
        startNonce: nonce,
        workerID: workerID,
        processIdentity: originalCLI
    )
    let supervisorService = TerminalIntegrationSupervisorService(
        record: record,
        endpoint: ready.endpoint,
        keeper: keeper
    )
    try await supervisorService.start()
    let supervisorExport = TerminalSupervisorXPCExport(
        handshakeHandler: { try TerminalSupervisorHandshakeHandler().handle($0) },
        commandHandler: { try await supervisorService.perform($0) },
        archiveHandler: { _ in
            try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        }
    )
    let supervisorClient = TerminalSupervisorXPCClient(
        connectionFactory: { _ in FakeTerminalSupervisorConnection(proxy: supervisorExport) }
    )
    let supervisorTransport = TerminalSupervisorControlTransport(client: supervisorClient)
    let resolvedContext = try ResolvedWorkspaceContext(
        validating: contextID,
        projectID: projectID,
        conversationID: nil,
        environmentID: environmentID,
        workspaceRootIdentity: "terminal-integration-root"
    )
    let workspaceService = TerminalIntegrationWorkspaceService(context: resolvedContext)
    let hostTerminalService = WorkspaceTerminalService(
        resolveContext: { requested in
            guard requested == contextID else { throw CocoaError(.coderInvalidValue) }
            return resolvedContext
        },
        resolveWorkspaceRoot: { _ in workspace.path },
        supervisor: supervisorTransport
    )
    let hostExport = HostXPCExport(
        handshakeHandler: { try HostHandshakeHandler().handle($0) },
        workspaceRouter: WorkspaceCommandRouter(service: workspaceService),
        workspaceTerminalService: hostTerminalService
    )

    func appController(
        clientID: ClientInstanceID,
        capabilities: TerminalAttachCapabilities
    ) -> TerminalAttachmentController {
        let hostClient = HostXPCClient(
            connectionFactory: { _ in TerminalIntegrationXPCConnection(proxy: hostExport) }
        )
        return TerminalAttachmentController(
            clientInstanceID: clientID,
            requestedCapabilities: capabilities,
            controlTransport: HostTerminalControlTransport(
                client: hostClient,
                contextID: contextID,
                environmentID: environmentID,
                runtimeDirectory: runtime.path
            ),
            dataTransport: KeeperTerminalDataTransport()
        )
    }

    let firstController = appController(
        clientID: ClientInstanceID(),
        capabilities: [.view]
    )
    let firstEvents = await firstController.events()
    let firstFrameTask = Task {
        try await terminalIntegrationFrame(from: firstEvents, containing: nil)
    }
    try await firstController.attach(sessionID: sessionID, lastAcknowledgedSequence: nil)
    let firstFrameObservation = try await terminalIntegrationStage("receive first app frame") {
        try await firstFrameTask.value
    }
    let firstFrame = firstFrameObservation.frame
    await firstController.detach()

    let afterQuit = try await keeper.inspect(ready.endpoint)
    #expect(afterQuit.sessionID == sessionID)
    #expect(afterQuit.workerID == workerID)
    #expect(afterQuit.processIdentity == originalCLI)
    #expect(kill(originalKeeperPID, 0) == 0)
    #expect(kill(originalCLI.processID, 0) == 0)

    let secondClientID = ClientInstanceID()
    let secondController = appController(
        clientID: secondClientID,
        capabilities: [.view, .input, .resize]
    )
    let secondEvents = await secondController.events()
    try await secondController.attach(
        sessionID: sessionID,
        lastAcknowledgedSequence: nil
    )
    let marker = "marker-\(UUID().uuidString)"
    let markerTask = Task {
        try await terminalIntegrationFrame(
            from: secondEvents,
            containing: "CONSUMED:\(marker)"
        )
    }
    let input = try TerminalInput(
        validatingContext: RequestContext(
            validating: .current,
            clientInstanceID: secondClientID,
            windowID: WindowID(),
            workspaceContextID: contextID,
            environmentID: environmentID,
            activeContextGeneration: 1,
            requestID: RequestID()
        ),
        terminalSessionID: sessionID,
        inputLeaseID: InputLeaseID(),
        inputSequence: 999,
        payload: .text("\(marker)\n")
    )
    try await secondController.send(input)
    let continuedFrameObservation = try await terminalIntegrationStage("CLI consumes unique marker") {
        try await markerTask.value
    }
    let continuedFrame = continuedFrameObservation.frame
    #expect(continuedFrameObservation.sawDelta)
    #expect(continuedFrame.outputSequence > firstFrame.outputSequence)

    let secondMarker = "marker-\(UUID().uuidString)"
    let secondMarkerTask = Task {
        try await terminalIntegrationFrame(
            from: secondEvents,
            containing: "CONSUMED:\(secondMarker)"
        )
    }
    try await secondController.send(
        try TerminalInput(
            validatingContext: input.context,
            terminalSessionID: sessionID,
            inputLeaseID: InputLeaseID(),
            inputSequence: 999,
            payload: .text("\(secondMarker)\n")
        )
    )
    let secondMarkerFrame = try await terminalIntegrationStage("advance to snapshot turn") {
        try await secondMarkerTask.value.frame
    }
    #expect(secondMarkerFrame.outputSequence > continuedFrame.outputSequence)

    try await secondController.send(
        try TerminalInput(
            validatingContext: input.context,
            terminalSessionID: sessionID,
            inputLeaseID: InputLeaseID(),
            inputSequence: 999,
            payload: .resize(try TerminalResize(validatingColumns: 79, rows: 23))
        )
    )
    let postResizeMarker = "marker-\(UUID().uuidString)"
    let postResizeTask = Task {
        try await terminalIntegrationFrame(
            from: secondEvents,
            containing: "CONSUMED:\(postResizeMarker)"
        )
    }
    try await secondController.send(
        try TerminalInput(
            validatingContext: input.context,
            terminalSessionID: sessionID,
            inputLeaseID: InputLeaseID(),
            inputSequence: 999,
            payload: .text("\(postResizeMarker)\n")
        )
    )
    let postResizeObservation = try await terminalIntegrationStage("full-dirty delta falls back") {
        try await postResizeTask.value
    }
    let postResizeFrame = postResizeObservation.frame
    #expect(postResizeObservation.sawSnapshot)
    #expect(postResizeFrame.outputSequence > secondMarkerFrame.outputSequence)

    let afterReattach = try await keeper.inspect(ready.endpoint)
    #expect(afterReattach.processIdentity == originalCLI)
    #expect(launched.processID == originalKeeperPID)
    await secondController.detach()
    try await keeper.terminate(ready.endpoint, force: true)
}

@Test func terminalSupervisorXPCUsesTypedCommandsAndResolvedWorkspaceRoot() async throws {
    let contextID = WorkspaceContextID.project(ProjectID())
    let environmentID = EnvironmentID()
    let request = ResolvedTerminalCreateRequest(
        contextID: contextID,
        environmentID: environmentID,
        kind: .shell,
        arguments: [],
        workspaceRoot: "/private/tmp/Cockpit",
        terminalSize: try TerminalResize(validatingColumns: 120, rows: 40),
        environmentOverrides: [:],
        idempotencyKey: RequestID()
    )
    let expected = try terminalRecord(
        contextID: contextID,
        environmentID: environmentID,
        state: .running
    )
    let exported = TerminalSupervisorXPCExport(
        handshakeHandler: { try TerminalSupervisorHandshakeHandler().handle($0) },
        commandHandler: { command in
            guard command == .createResolved(request) else {
                throw CocoaError(.coderInvalidValue)
            }
            return .session(expected)
        }
    )
    let connection = FakeTerminalSupervisorConnection(proxy: exported)
    let client = TerminalSupervisorXPCClient(connectionFactory: { _ in connection })

    #expect(try await client.createResolved(request) == expected)
    #expect(connection.resumeCount == 1)
    await client.disconnect()
}

@Test func terminalSupervisorProtocolRejectsWrongUIDBeforeExportOrResume() {
    let delegate = MachServiceListenerDelegate(
        exportedObject: NSObject(),
        exportedInterface: NSXPCInterface(with: TerminalSupervisorXPCProtocol.self),
        peerValidator: XPCPeerValidator(expectedEffectiveUserIdentifier: 501)
    )
    let connection = FakeTerminalIncomingConnection(effectiveUserIdentifier: 502)

    #expect(!delegate.shouldAccept(connection))
    #expect(connection.exportedInterface == nil)
    #expect(connection.exportedObject == nil)
    #expect(connection.resumeCount == 0)
}

@Test func terminalSupervisorCommandSurfaceRoundTripsEveryFrozenRequestType() throws {
    let session = TerminalSessionID()
    let context = WorkspaceContextID.project(ProjectID())
    let client = ClientInstanceID()
    let viewer = ViewerID()
    let lease = InputLeaseID()
    let requests: [TerminalSupervisorCommandRequest] = [
        .list(contextID: context),
        .issueAttachTicket(
            TerminalAttachTicketRequest(
                sessionID: session,
                clientInstanceID: client,
                viewerID: viewer,
                capabilities: [.view, .input]
            )
        ),
        .acquireInputLease(
            TerminalInputLeaseRequest(
                sessionID: session,
                viewerID: viewer,
                capabilities: [.input, .resize]
            )
        ),
        .transferInputLease(
            TerminalInputLeaseTransferRequest(
                sessionID: session,
                leaseID: lease,
                toViewerID: ViewerID(),
                capabilities: [.input]
            )
        ),
        .releaseInputLease(sessionID: session, leaseID: lease),
        .signal(
            sessionID: session,
            viewerID: viewer,
            leaseID: lease,
            signal: .interrupt
        ),
        .terminate(
            sessionID: session,
            viewerID: viewer,
            leaseID: lease,
            force: false
        ),
        .purgeFinishedRecords,
        .reconcile,
    ]

    for request in requests {
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(TerminalSupervisorCommandRequest.self, from: data) == request)
    }
}

private func terminalRecord(
    contextID: WorkspaceContextID,
    environmentID: EnvironmentID,
    state: TerminalLifecycleState
) throws -> TerminalSessionRecord {
    try TerminalSessionRecord(
        validatingSessionID: TerminalSessionID(),
        contextID: contextID,
        environmentID: environmentID,
        protocolVersion: .current,
        launchSpecData: Data([1]),
        lifecycleState: state,
        startNonce: Data(repeating: 1, count: 16),
        workerID: WorkerInstanceID(),
        processIdentity: try CLIProcessIdentity(validatingProcessID: 900, processGroupID: 900)
    )
}

private final class FakeTerminalSupervisorConnection: XPCConnectionBoundary, @unchecked Sendable {
    let proxy: Any
    private(set) var resumeCount = 0

    init(proxy: Any) { self.proxy = proxy }
    func configureRemoteObjectInterface(_ interface: NSXPCInterface) {}
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {}
    func resume() { resumeCount += 1 }
    func invalidate() {}
    func remoteObjectProxy(errorHandler: @escaping @Sendable (any Error) -> Void) -> Any { proxy }
}

private final class FakeTerminalIncomingConnection: IncomingXPCConnectionBoundary {
    let effectiveUserIdentifier: uid_t
    var exportedInterface: NSXPCInterface?
    var exportedObject: Any?
    private(set) var resumeCount = 0

    init(effectiveUserIdentifier: uid_t) { self.effectiveUserIdentifier = effectiveUserIdentifier }
    func resume() { resumeCount += 1 }
}

private typealias TerminalIntegrationXPCConnection = FakeTerminalSupervisorConnection

private actor TerminalIntegrationSupervisorService {
    private let record: TerminalSessionRecord
    private let endpoint: KeeperEndpoint
    private let keeper: KeeperControlClient
    private let generation = UUID()
    private let tickets = TerminalAttachTicketStore(
        clock: SystemTerminalSecurityClock(),
        randomBytes: SecurityTerminalRandomBytes()
    )
    private var cursor: UInt64 = 0
    private var lease: InputLeaseGrant?
    private var nextInputSequence: UInt64 = 1

    init(
        record: TerminalSessionRecord,
        endpoint: KeeperEndpoint,
        keeper: KeeperControlClient
    ) {
        self.record = record
        self.endpoint = endpoint
        self.keeper = keeper
    }

    func start() async throws { try await synchronize() }

    func perform(
        _ command: TerminalSupervisorCommandRequest
    ) async throws -> TerminalSupervisorCommandResponse {
        switch command {
        case .createResolved:
            return .session(record)
        case .list:
            return .sessions([record])
        case let .issueAttachTicket(request):
            try await synchronize()
            guard let workerID = record.workerID else {
                throw CocoaError(.coderInvalidValue)
            }
            let binding = TerminalAttachBinding(
                sessionID: record.sessionID,
                workerID: workerID,
                clientInstanceID: request.clientInstanceID
            )
            let issued = try await tickets.issue(
                binding: binding,
                capabilities: request.capabilities
            )
            try await keeper.registerAttachTicket(
                issued.registration,
                supervisorGeneration: generation,
                at: endpoint
            )
            return .attachAuthorization(
                TerminalAttachAuthorization(
                    endpoint: endpoint,
                    wireTicket: issued.wireValue,
                    binding: binding,
                    viewerID: request.viewerID,
                    capabilities: request.capabilities
                )
            )
        case let .acquireInputLease(request):
            try await synchronize()
            if let lease {
                guard lease.holderViewerID == request.viewerID,
                      lease.capabilities == request.capabilities else {
                    throw TerminalStreamError.leaseHeld
                }
                return .inputLease(lease)
            }
            let grant = try InputLeaseGrant(
                validatingLeaseID: InputLeaseID(),
                holderViewerID: request.viewerID,
                sequenceBase: nextInputSequence,
                capabilities: request.capabilities
            )
            try await keeper.registerInputLease(
                grant,
                supervisorGeneration: generation,
                at: endpoint
            )
            lease = grant
            return .inputLease(grant)
        case let .transferInputLease(request):
            try await synchronize()
            guard lease?.leaseID == request.leaseID else {
                throw TerminalStreamError.invalidInputLease
            }
            let grant = try InputLeaseGrant(
                validatingLeaseID: InputLeaseID(),
                holderViewerID: request.toViewerID,
                sequenceBase: nextInputSequence,
                capabilities: request.capabilities
            )
            try await keeper.transferInputLease(
                from: request.leaseID,
                to: grant,
                supervisorGeneration: generation,
                at: endpoint
            )
            lease = grant
            return .inputLease(grant)
        case let .releaseInputLease(_, leaseID):
            try await synchronize()
            if lease?.leaseID == leaseID {
                try await keeper.revokeInputLease(
                    leaseID,
                    supervisorGeneration: generation,
                    at: endpoint
                )
                lease = nil
            }
            return .empty
        case let .signal(_, viewerID, leaseID, signal):
            try await synchronize()
            guard let lease,
                  lease.leaseID == leaseID,
                  lease.holderViewerID == viewerID,
                  lease.capabilities.contains(.signal) else {
                throw TerminalStreamError.capabilityDenied
            }
            return .processGroup(
                try await keeper.signalForeground(
                    signal,
                    viewerID: viewerID,
                    leaseID: leaseID,
                    supervisorGeneration: generation,
                    at: endpoint
                )
            )
        case let .terminate(_, viewerID, leaseID, force):
            try await synchronize()
            guard let lease,
                  lease.leaseID == leaseID,
                  lease.holderViewerID == viewerID,
                  lease.capabilities.contains(.terminate) else {
                throw TerminalStreamError.capabilityDenied
            }
            try await keeper.terminateAuthorized(
                force: force,
                viewerID: viewerID,
                leaseID: leaseID,
                supervisorGeneration: generation,
                at: endpoint
            )
            return .empty
        case .purgeFinishedRecords:
            return .purged(0)
        case .reconcile:
            try await synchronize()
            return .empty
        }
    }

    private func synchronize() async throws {
        let response = try await keeper.synchronizeSupervisor(
            KeeperSupervisorSyncRequest(
                supervisorGeneration: generation,
                acknowledgedThrough: cursor,
                afterSequence: cursor,
                waitForEvents: false
            ),
            at: endpoint
        )
        for event in response.events {
            guard event.sequence == cursor + 1 else {
                throw KeeperControlError.malformedMessage
            }
            cursor = event.sequence
            switch event.payload {
            case let .attachTicketConsumed(digest):
                try await tickets.acknowledgeConsumption(ticketDigest: digest)
            case let .leaseRevoked(leaseID, nextSequence):
                if lease?.leaseID == leaseID { lease = nil }
                nextInputSequence = max(nextInputSequence, nextSequence)
            }
        }
        if let current = response.currentLease {
            lease = current.grant
            nextInputSequence = current.nextSequence
        } else if response.events.contains(where: {
            if case .leaseRevoked = $0.payload { return true }
            return false
        }) {
            lease = nil
        }
    }
}

private actor TerminalIntegrationWorkspaceService: WorkspaceServing {
    let context: ResolvedWorkspaceContext

    init(context: ResolvedWorkspaceContext) { self.context = context }

    func addProject(bookmark: Data, displayName: String) throws -> ProjectSnapshot {
        throw CocoaError(.featureUnsupported)
    }
    func listWorkspace() throws -> WorkspaceSnapshot { [] }
    func createDirectConversation(projectID: ProjectID) throws -> Conversation {
        throw CocoaError(.featureUnsupported)
    }
    func renameConversation(id: ConversationID, title: String) throws {
        throw CocoaError(.featureUnsupported)
    }
    func resolveContext(_ id: WorkspaceContextID) throws -> ResolvedWorkspaceContext {
        guard id == context.contextID else { throw CocoaError(.coderInvalidValue) }
        return context
    }
    func performFileOperation(
        context: RequestContext,
        operation: FileOperation
    ) throws -> FileOperationResult {
        throw CocoaError(.featureUnsupported)
    }
}

private func terminalIntegrationTemporaryDirectory() throws -> URL {
    let root = URL(
        fileURLWithPath: "/private/tmp/ctar.\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    return root
}

private struct TerminalIntegrationStageFailure: Error {
    let stage: String
    let underlying: String
}

private func terminalIntegrationStage<Value: Sendable>(
    _ stage: String,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    do { return try await operation() }
    catch {
        throw TerminalIntegrationStageFailure(
            stage: stage,
            underlying: String(reflecting: error)
        )
    }
}

private func runTerminalIntegrationProcess(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.executableRuntimeMismatch)
    }
}

private final class TerminalIntegrationOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<TerminalOutputFrame?, any Error>?

    var value: Result<TerminalOutputFrame?, any Error>? {
        lock.withLock { stored }
    }

    func store(_ value: Result<TerminalOutputFrame?, any Error>) {
        lock.withLock { stored = value }
    }
}

private struct TerminalIntegrationFrameObservation: Sendable {
    let frame: TerminalOutputFrame
    let sawDelta: Bool
    let sawSnapshot: Bool
}

private final class TerminalIntegrationFrameObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<TerminalIntegrationFrameObservation?, any Error>?

    var value: Result<TerminalIntegrationFrameObservation?, any Error>? {
        lock.withLock { stored }
    }

    func store(_ value: Result<TerminalIntegrationFrameObservation?, any Error>) {
        lock.withLock { stored = value }
    }
}

private func terminalIntegrationOutput(
    from viewer: KeeperViewerConnection,
    timeout: TimeInterval
) async throws -> TerminalOutputFrame {
    let result = TerminalIntegrationOutputBox()
    Task.detached {
        do { result.store(.success(try await viewer.nextOutput())) }
        catch { result.store(.failure(error)) }
    }
    let deadline = Date().addingTimeInterval(timeout)
    while result.value == nil, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard let value = result.value else {
        await viewer.detach()
        throw CocoaError(.executableRuntimeMismatch)
    }
    return try #require(try value.get())
}

private func terminalIntegrationFrame(
    from events: AsyncStream<TerminalClientEvent>,
    containing expectedText: String?
) async throws -> TerminalIntegrationFrameObservation {
    let result = TerminalIntegrationFrameObservationBox()
    let reading = Task {
        var accumulated = ""
        var sawDelta = false
        var sawSnapshot = false
        for await event in events {
            guard case let .frame(_, frame) = event else { continue }
            sawDelta = sawDelta || frame.kind == .delta
            sawSnapshot = sawSnapshot || frame.kind == .snapshot
            accumulated += terminalIntegrationGraphemeText(frame)
            if expectedText == nil || accumulated.contains(expectedText!) {
                result.store(.success(.init(
                    frame: frame,
                    sawDelta: sawDelta,
                    sawSnapshot: sawSnapshot
                )))
                return
            }
        }
        result.store(.success(nil))
    }
    defer { reading.cancel() }
    let deadline = Date().addingTimeInterval(5)
    while result.value == nil, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard let value = result.value else { throw CocoaError(.executableRuntimeMismatch) }
    return try #require(try value.get())
}

private func terminalIntegrationGraphemeText(_ frame: TerminalOutputFrame) -> String {
    var result = ""
    for fragment in frame.fragments where fragment.count >= 36 {
        guard fragment.prefix(4) == Data("CKGF".utf8),
              let sectionCount = terminalIntegrationUInt32(fragment, at: 32) else {
            continue
        }
        var offset = 36
        var cells: [(row: UInt32, column: UInt32, grapheme: UInt32)] = []
        var graphemes: [UInt32: String] = [:]
        for _ in 0..<sectionCount {
            guard offset + 8 <= fragment.count,
                  let length = terminalIntegrationUInt32(fragment, at: offset + 4) else {
                break
            }
            let type = fragment[offset]
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + Int(length)
            guard payloadEnd <= fragment.count else { break }
            if type == 4,
               let count = terminalIntegrationUInt32(fragment, at: payloadStart) {
                var entry = payloadStart + 4
                for _ in 0..<count {
                    guard entry + 20 <= payloadEnd,
                          let row = terminalIntegrationUInt32(fragment, at: entry),
                          let column = terminalIntegrationUInt32(fragment, at: entry + 4),
                          let grapheme = terminalIntegrationUInt32(fragment, at: entry + 12) else {
                        break
                    }
                    cells.append((row, column, grapheme))
                    entry += 20
                }
            } else if type == 5,
                      let count = terminalIntegrationUInt32(fragment, at: payloadStart) {
                var entry = payloadStart + 4
                for _ in 0..<count {
                    guard entry + 8 <= payloadEnd,
                          let index = terminalIntegrationUInt32(fragment, at: entry),
                          let byteCount = terminalIntegrationUInt32(fragment, at: entry + 4) else {
                        break
                    }
                    let start = entry + 8
                    let end = start + Int(byteCount)
                    guard end <= payloadEnd else { break }
                    graphemes[index] = String(decoding: fragment[start..<end], as: UTF8.self)
                    entry = end
                }
            }
            offset = payloadEnd
        }
        for cell in cells.sorted(by: {
            ($0.row, $0.column) < ($1.row, $1.column)
        }) where cell.grapheme != 0 {
            result += graphemes[cell.grapheme] ?? ""
        }
    }
    return result
}

private func terminalIntegrationUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func reapTerminalIntegrationProcess(_ processID: pid_t) {
    if kill(processID, 0) == 0 { _ = kill(processID, SIGKILL) }
    var status: Int32 = 0
    while waitpid(processID, &status, 0) < 0, errno == EINTR {}
}

private func terminateTerminalIntegrationProcessGroup(_ processGroupID: pid_t) {
    guard processGroupID > 1 else { return }
    if kill(-processGroupID, 0) == 0 || errno == EPERM {
        _ = kill(-processGroupID, SIGKILL)
    }
}

private func terminalIntegrationProcessGroupIsAbsent(_ processGroupID: pid_t) -> Bool {
    guard processGroupID > 1 else { return true }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    repeat {
        if kill(-processGroupID, 0) != 0, errno == ESRCH { return true }
        usleep(10_000)
    } while ContinuousClock.now < deadline
    return kill(-processGroupID, 0) != 0 && errno == ESRCH
}

private actor TerminalSupervisorGateProbe {
    private(set) var sameSessionEntered = false
    private(set) var otherSessionEntered = false
    private(set) var startupSessions: [TerminalSessionID] = []
    private(set) var retryWatcherSessions: [TerminalSessionID] = []
    private(set) var createdSessionEvents: [String] = []

    func markSameSessionEntered() { sameSessionEntered = true }
    func markOtherSessionEntered() { otherSessionEntered = true }
    func recordStartup(_ sessionID: TerminalSessionID) { startupSessions.append(sessionID) }
    func recordRetryWatcher(_ sessionID: TerminalSessionID) {
        retryWatcherSessions.append(sessionID)
    }
    func recordCreated(_ sessionID: TerminalSessionID) { createdSessionEvents.append("create") }
    func recordWatcher(_ sessionID: TerminalSessionID) { createdSessionEvents.append("watcher") }
}

private actor TerminalSupervisorCompletionProbe {
    private let sessionID: TerminalSessionID
    private(set) var events: [String] = []
    private var active = true

    init(sessionID: TerminalSessionID) {
        self.sessionID = sessionID
    }

    func reconcileVerifiedArchive() {
        events.append("reconcile")
        active = false
    }

    func activeRecords() -> [TerminalSessionID] {
        events.append("active-records")
        return active ? [sessionID] : []
    }

    func isActive(_ candidate: TerminalSessionID) -> Bool {
        active && candidate == sessionID
    }
}

private actor TerminalSupervisorConcurrentCreateProbe {
    private let sessionID: TerminalSessionID
    private var committed: TerminalSessionID?
    private var firstLaunchWaiter: CheckedContinuation<Void, Never>?
    private var launchWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var launches = 0

    init(sessionID: TerminalSessionID) {
        self.sessionID = sessionID
    }

    func create() async -> TerminalSessionID {
        if let committed { return committed }
        launches += 1
        firstLaunchWaiter?.resume()
        firstLaunchWaiter = nil
        if !released {
            await withCheckedContinuation { launchWaiters.append($0) }
        }
        committed = sessionID
        return sessionID
    }

    func waitForFirstLaunch() async {
        if launches > 0 { return }
        await withCheckedContinuation { firstLaunchWaiter = $0 }
    }

    func resumeLaunch() {
        released = true
        let pending = launchWaiters
        launchWaiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

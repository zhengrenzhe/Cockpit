import Foundation
import Testing
import CockpitTypes
@testable import CockpitTerminalCore

@Test func contextTerminationGateRejectsNewSessionAndWrongOperationID() async throws {
    let fixture = try ContextTerminationFixture()
    try await fixture.repository.beginContextDeletion(
        contextID: fixture.contextID,
        operationID: fixture.operationID
    )

    await #expect(throws: TerminalSessionRepositoryError.contextDeleting) {
        _ = try await fixture.supervisor.createSession(fixture.createRequest)
    }
    await #expect(throws: TerminalSessionRepositoryError.deletionOperationMismatch) {
        _ = try await fixture.supervisor.terminateSessions(
            contextID: fixture.contextID,
            operationID: DeletionOperationID(),
            force: false
        )
    }
    #expect(await fixture.launcher.launchCount == 0)
}

@Test func contextTerminationRequiresSeparateForceAndPurgesOnlyInactiveSessions() async throws {
    let fixture = try ContextTerminationFixture(withRunningSession: true)
    try await fixture.supervisor.beginContextDeletion(
        contextID: fixture.contextID,
        operationID: fixture.operationID
    )

    let normal = try await fixture.supervisor.terminateSessions(
        contextID: fixture.contextID,
        operationID: fixture.operationID,
        force: false
    )
    #expect(normal == .forceConfirmationRequired(activeSessionIDs: [fixture.sessionID]))
    #expect(await fixture.controller.terminations == [
        ContextTerminationCall(sessionID: fixture.sessionID, force: false),
    ])

    await #expect(throws: TerminalSessionRepositoryError.activeSessionsRemain) {
        try await fixture.supervisor.purgeDeletedContext(
            contextID: fixture.contextID,
            operationID: fixture.operationID
        )
    }

    try await fixture.repository.finishForTest(fixture.sessionID)
    let forced = try await fixture.supervisor.terminateSessions(
        contextID: fixture.contextID,
        operationID: fixture.operationID,
        force: true
    )
    #expect(forced == .complete)
    try await fixture.supervisor.purgeDeletedContext(
        contextID: fixture.contextID,
        operationID: fixture.operationID
    )
    try await fixture.supervisor.purgeDeletedContext(
        contextID: fixture.contextID,
        operationID: fixture.operationID
    )

    #expect(await fixture.repository.records(contextID: fixture.contextID).isEmpty)
    #expect(try await fixture.repository.contextDeletion(
        contextID: fixture.contextID
    )?.state == .purged)
}

@Test func contextTerminationRetiresWorkerlessPreparingSessionAfterRestart() async throws {
    let fixture = try ContextTerminationFixture(withPreparingSession: true)
    try await fixture.supervisor.beginContextDeletion(
        contextID: fixture.contextID,
        operationID: fixture.operationID
    )

    let restarted = fixture.makeSupervisor()
    let result = try await restarted.terminateSessions(
        contextID: fixture.contextID,
        operationID: fixture.operationID,
        force: false
    )

    #expect(result == .complete)
    #expect(try await fixture.repository.record(
        sessionID: fixture.sessionID
    ).lifecycleState == .interrupted)
    #expect(await fixture.controller.terminations.isEmpty)
    try await restarted.purgeDeletedContext(
        contextID: fixture.contextID,
        operationID: fixture.operationID
    )
    #expect(await fixture.repository.records(contextID: fixture.contextID).isEmpty)
}

private struct ContextTerminationFixture {
    let contextID = WorkspaceContextID.conversation(
        ConversationID(UUID(uuidString: "74000000-0000-4000-8000-000000000001")!)
    )
    let environmentID = EnvironmentID(
        UUID(uuidString: "74000000-0000-4000-8000-000000000002")!
    )
    let operationID = DeletionOperationID(
        UUID(uuidString: "74000000-0000-4000-8000-000000000003")!
    )
    let sessionID = TerminalSessionID(
        UUID(uuidString: "74000000-0000-4000-8000-000000000004")!
    )
    let repository: ContextTerminationRepositoryFixture
    let launcher = ContextTerminationLauncherFixture()
    let controller = ContextTerminationControllerFixture()
    let configuration: TerminalSupervisorConfiguration
    let supervisor: TerminalSupervisor
    let createRequest: CreateTerminalSessionRequest

    init(withRunningSession: Bool = false, withPreparingSession: Bool = false) throws {
        precondition(!(withRunningSession && withPreparingSession))
        let launch = try LaunchSpec(
            kind: .shell,
            loginShellPath: "/bin/zsh",
            executablePath: "/bin/zsh",
            arguments: [],
            workspaceRoot: "/tmp/context-termination",
            terminalSize: TerminalResize(validatingColumns: 80, rows: 24),
            environmentOverrides: [:]
        )
        createRequest = CreateTerminalSessionRequest(
            contextID: contextID,
            environmentID: environmentID,
            launchSpec: launch,
            idempotencyKey: RequestID()
        )
        let initialRecords: [TerminalSessionRecord]
        if withRunningSession || withPreparingSession {
            initialRecords = [try TerminalSessionRecord(
                validatingSessionID: sessionID,
                contextID: contextID,
                environmentID: environmentID,
                protocolVersion: .current,
                launchSpecData: JSONEncoder().encode(launch),
                lifecycleState: withRunningSession ? .running : .preparing,
                startNonce: Data(repeating: 1, count: 16),
                workerID: withRunningSession ? WorkerInstanceID(
                    UUID(uuidString: "74000000-0000-4000-8000-000000000005")!
                ) : nil,
                processIdentity: withRunningSession ? try CLIProcessIdentity(
                    validatingProcessID: 904,
                    processGroupID: 904
                ) : nil
            )]
        } else {
            initialRecords = []
        }
        let repository = ContextTerminationRepositoryFixture(initialRecords: initialRecords)
        self.repository = repository
        let configuration = try TerminalSupervisorConfiguration(
            applicationSupportRoot: "/tmp/context-termination-app",
            terminalArchivesRoot: "/tmp/context-termination-app/TerminalArchives",
            runtimeDirectory: "/tmp/context-termination-runtime"
        )
        self.configuration = configuration
        supervisor = TerminalSupervisor(
            repository: repository,
            launcher: launcher,
            controller: controller,
            workerSecretDeriver: ContextTerminationSecretFixture(),
            randomBytes: ContextTerminationRandomFixture(),
            configuration: configuration
        )
    }

    func makeSupervisor() -> TerminalSupervisor {
        TerminalSupervisor(
            repository: repository,
            launcher: launcher,
            controller: controller,
            workerSecretDeriver: ContextTerminationSecretFixture(),
            randomBytes: ContextTerminationRandomFixture(),
            configuration: configuration
        )
    }
}

private actor ContextTerminationRepositoryFixture: TerminalSessionRepository {
    private var stored: [TerminalSessionID: TerminalSessionRecord] = [:]
    private var deletions: [WorkspaceContextID: TerminalContextDeletion] = [:]

    init(initialRecords: [TerminalSessionRecord] = []) {
        stored = Dictionary(uniqueKeysWithValues: initialRecords.map { ($0.sessionID, $0) })
    }

    func insertPreparing(
        _ record: TerminalSessionRecord,
        idempotencyKey: RequestID
    ) throws -> TerminalSessionRecord {
        if deletions[record.contextID]?.state == .deleting {
            throw TerminalSessionRepositoryError.contextDeleting
        }
        stored[record.sessionID] = record
        return record
    }
    func markCommitted(sessionID: TerminalSessionID, workerID: WorkerInstanceID) throws {
        throw TerminalSessionRepositoryError.recordNotFound
    }
    func markRunning(sessionID: TerminalSessionID, identity: CLIProcessIdentity) throws {
        throw TerminalSessionRepositoryError.recordNotFound
    }
    func finish(
        sessionID: TerminalSessionID,
        state: TerminalLifecycleState,
        exitStatus: Int32?,
        latestSequence: UInt64,
        archiveManifest: RelativeArchivePath?
    ) throws {
        guard let current = stored[sessionID] else {
            throw TerminalSessionRepositoryError.recordNotFound
        }
        stored[sessionID] = try TerminalSessionRecord(
            validatingSessionID: current.sessionID,
            contextID: current.contextID,
            environmentID: current.environmentID,
            protocolVersion: current.protocolVersion,
            launchSpecData: current.launchSpecData,
            lifecycleState: state,
            startNonce: current.startNonce,
            workerID: current.workerID,
            processIdentity: current.processIdentity,
            exitStatus: exitStatus,
            latestSequence: latestSequence,
            archiveManifest: archiveManifest
        )
    }
    func activeRecords() -> [TerminalSessionRecord] {
        stored.values.filter { [.preparing, .committed, .running].contains($0.lifecycleState) }
    }
    func record(sessionID: TerminalSessionID) throws -> TerminalSessionRecord {
        guard let value = stored[sessionID] else { throw TerminalSessionRepositoryError.recordNotFound }
        return value
    }
    func records(contextID: WorkspaceContextID) -> [TerminalSessionRecord] {
        stored.values.filter { $0.contextID == contextID }.sorted {
            $0.sessionID.description < $1.sessionID.description
        }
    }
    func purgeFinishedRecords() -> Int { 0 }
    func beginContextDeletion(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws {
        if let current = deletions[contextID], current.operationID != operationID {
            throw TerminalSessionRepositoryError.deletionOperationMismatch
        }
        deletions[contextID] = TerminalContextDeletion(
            contextID: contextID,
            operationID: operationID,
            state: .deleting
        )
    }
    func contextDeletion(
        contextID: WorkspaceContextID
    ) async throws -> TerminalContextDeletion? {
        deletions[contextID]
    }
    func purgeDeletedContext(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws {
        guard let deletion = deletions[contextID], deletion.operationID == operationID else {
            throw TerminalSessionRepositoryError.deletionOperationMismatch
        }
        guard !activeRecords().contains(where: { $0.contextID == contextID }) else {
            throw TerminalSessionRepositoryError.activeSessionsRemain
        }
        stored = stored.filter { $0.value.contextID != contextID }
        deletions[contextID] = TerminalContextDeletion(
            contextID: contextID,
            operationID: operationID,
            state: .purged
        )
    }
    func finishForTest(_ sessionID: TerminalSessionID) throws {
        try finish(
            sessionID: sessionID,
            state: .terminated,
            exitStatus: nil,
            latestSequence: 0,
            archiveManifest: nil
        )
    }
}

private actor ContextTerminationLauncherFixture: KeeperLaunching {
    var launchCount = 0
    func launch(_ bootstrap: KeeperBootstrap) throws -> LaunchedKeeper {
        launchCount += 1
        throw KeeperControlError.disconnected
    }
}

private actor ContextTerminationControllerFixture: KeeperControlling {
    var terminations: [ContextTerminationCall] = []
    func awaitReady(_ keeper: LaunchedKeeper) throws -> KeeperReady {
        throw KeeperControlError.disconnected
    }
    func authenticatedStart(_ request: AuthenticatedStartRequest) throws -> CLIProcessIdentity {
        throw KeeperControlError.disconnected
    }
    func inspect(_ endpoint: KeeperEndpoint) -> KeeperIdentity {
        KeeperIdentity(
            endpoint: endpoint,
            sessionID: endpoint.sessionID,
            workerID: endpoint.workerID,
            processIdentity: try? CLIProcessIdentity(
                validatingProcessID: 904,
                processGroupID: 904
            )
        )
    }
    func terminate(_ endpoint: KeeperEndpoint, force: Bool) {
        terminations.append(ContextTerminationCall(sessionID: endpoint.sessionID, force: force))
    }
}

private struct ContextTerminationCall: Equatable, Sendable {
    let sessionID: TerminalSessionID
    let force: Bool
}

private struct ContextTerminationSecretFixture: WorkerSecretDeriving {
    func derive(sessionID: TerminalSessionID, workerID: WorkerInstanceID) -> Data {
        Data(repeating: 7, count: 32)
    }
}

private struct ContextTerminationRandomFixture: TerminalSecurityRandomBytes {
    func bytes(count: Int) -> [UInt8] { [UInt8](repeating: 3, count: count) }
}

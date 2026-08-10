import Foundation
import Testing
import CockpitTypes
@testable import CockpitTerminalCore

@Suite("TerminalSupervisorTwoPhaseTests")
struct TerminalSupervisorTwoPhaseTests {
    @Test func preparingReadyCommittedStartRunningAreStrictlyOrdered() async throws {
        let fixture = try SupervisorFixture()
        defer { fixture.cleanup() }

        let record = try await fixture.supervisor.createSession(fixture.request)

        #expect(record.lifecycleState == .running)
        let events = await fixture.events.values
        #expect(events == ["preparing", "launch", "ready", "committed", "start", "running"])
        let bootstrap = try #require(await fixture.launcher.bootstraps.first)
        #expect(bootstrap.launchSpec == fixture.request.launchSpec)
        #expect(bootstrap.startNonce.count == 16)
        #expect(bootstrap.workerSecret == Data(repeating: 0x5a, count: 32))
        #expect(bootstrap.applicationSupportRoot == fixture.applicationSupport.path)
        #expect(bootstrap.terminalArchivesRoot == fixture.archives.path)
        #expect(await fixture.controller.createdCLIcount == 1)
    }

    @Test func committedSessionIsAdoptedAfterSupervisorReplacementAndExactStartIsIdempotent() async throws {
        let fixture = try SupervisorFixture(failStart: true)
        defer { fixture.cleanup() }

        await #expect(throws: FakeControlError.injectedStartFailure) {
            _ = try await fixture.supervisor.createSession(fixture.request)
        }
        let committed = try #require(await fixture.repository.activeRecords().first)
        #expect(committed.lifecycleState == .committed)
        #expect(await fixture.controller.createdCLIcount == 0)

        await fixture.controller.setFailStart(false)
        let replacement = fixture.makeSupervisor()
        let running = try await replacement.startCommittedSession(committed.sessionID)
        #expect(running.lifecycleState == .running)
        let retried = try await replacement.startCommittedSession(committed.sessionID)
        #expect(retried.processIdentity == running.processIdentity)
        #expect(await fixture.controller.createdCLIcount == 1)
        #expect(await fixture.launcher.bootstraps.count == 1)
    }

    @Test func failureBeforeReadyLeavesPreparingWithoutAnyCLI() async throws {
        let fixture = try SupervisorFixture(failLaunch: true)
        defer { fixture.cleanup() }

        await #expect(throws: FakeLauncherError.injected) {
            _ = try await fixture.supervisor.createSession(fixture.request)
        }
        let record = try #require(await fixture.repository.activeRecords().first)
        #expect(record.lifecycleState == .preparing)
        #expect(await fixture.controller.createdCLIcount == 0)
        #expect(!(await fixture.events.values).contains("committed"))
    }

    @Test func mismatchedReadyIdentityFailsClosedBeforeCommit() async throws {
        let fixture = try SupervisorFixture(mismatchReady: true)
        defer { fixture.cleanup() }

        await #expect(throws: TerminalSupervisorError.keeperIdentityMismatch) {
            _ = try await fixture.supervisor.createSession(fixture.request)
        }
        let record = try #require(await fixture.repository.activeRecords().first)
        #expect(record.lifecycleState == .preparing)
        #expect(await fixture.controller.createdCLIcount == 0)
    }
}

private final class SupervisorFixture: @unchecked Sendable {
    let root: URL
    let applicationSupport: URL
    let archives: URL
    let runtime: URL
    let events = OrderedEvents()
    let repository: MemoryTerminalSessionRepository
    let launcher: FakeKeeperLauncher
    let controller: FakeKeeperController
    let configuration: TerminalSupervisorConfiguration
    let request: CreateTerminalSessionRequest
    let supervisor: TerminalSupervisor

    init(
        failLaunch: Bool = false,
        failStart: Bool = false,
        mismatchReady: Bool = false
    ) throws {
        root = URL(fileURLWithPath: "/private/tmp/cockpit-supervisor.\(UUID().uuidString)")
        applicationSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        archives = applicationSupport.appendingPathComponent("TerminalArchives", isDirectory: true)
        runtime = root.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
        for url in [root, applicationSupport, archives, runtime] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        repository = MemoryTerminalSessionRepository(events: events)
        launcher = FakeKeeperLauncher(events: events, fail: failLaunch)
        controller = FakeKeeperController(
            events: events,
            secret: Data(repeating: 0x5a, count: 32),
            failStart: failStart,
            mismatchReady: mismatchReady
        )
        configuration = try TerminalSupervisorConfiguration(
            applicationSupportRoot: applicationSupport.path,
            terminalArchivesRoot: archives.path,
            runtimeDirectory: runtime.path
        )
        request = CreateTerminalSessionRequest(
            contextID: .project(ProjectID()),
            environmentID: EnvironmentID(),
            launchSpec: try LaunchSpec(
                kind: .shell,
                loginShellPath: "/bin/zsh",
                executablePath: "/bin/zsh",
                arguments: [],
                workspaceRoot: root.path,
                terminalSize: try TerminalResize(validatingColumns: 80, rows: 24),
                environmentOverrides: ["TERM": "xterm-256color"]
            ),
            idempotencyKey: RequestID()
        )
        supervisor = TerminalSupervisor(
            repository: repository,
            launcher: launcher,
            controller: controller,
            workerSecretDeriver: FixedWorkerSecretDeriver(),
            randomBytes: FixedSupervisorRandomBytes(),
            configuration: configuration
        )
    }

    func makeSupervisor() -> TerminalSupervisor {
        TerminalSupervisor(
            repository: repository,
            launcher: launcher,
            controller: controller,
            workerSecretDeriver: FixedWorkerSecretDeriver(),
            randomBytes: FixedSupervisorRandomBytes(),
            configuration: configuration
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor OrderedEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private enum FakeLauncherError: Error { case injected }

private actor FakeKeeperLauncher: KeeperLaunching {
    private let events: OrderedEvents
    private let fail: Bool
    private(set) var bootstraps: [KeeperBootstrap] = []

    init(events: OrderedEvents, fail: Bool) {
        self.events = events
        self.fail = fail
    }

    func launch(_ bootstrap: KeeperBootstrap) async throws -> LaunchedKeeper {
        bootstraps.append(bootstrap)
        await events.append("launch")
        if fail { throw FakeLauncherError.injected }
        return LaunchedKeeper(
            sessionID: bootstrap.sessionID,
            workerID: bootstrap.workerInstanceID,
            processID: 40,
            bootstrapControlDescriptor: -1,
            runtimeDescriptorPath: bootstrap.runtimeDescriptorPath
        )
    }
}

private enum FakeControlError: Error, Equatable { case injectedStartFailure }

private actor FakeKeeperController: KeeperControlling {
    private let events: OrderedEvents
    private let secret: Data
    private var failStart: Bool
    private let mismatchReady: Bool
    private var acceptedRequest: AuthenticatedStartRequest?
    private let identity = try! CLIProcessIdentity(validatingProcessID: 9001, processGroupID: 9001)
    private(set) var createdCLIcount = 0

    init(events: OrderedEvents, secret: Data, failStart: Bool, mismatchReady: Bool) {
        self.events = events
        self.secret = secret
        self.failStart = failStart
        self.mismatchReady = mismatchReady
    }

    func setFailStart(_ value: Bool) { failStart = value }

    func awaitReady(_ keeper: LaunchedKeeper) async throws -> KeeperReady {
        await events.append("ready")
        let sessionID = mismatchReady ? TerminalSessionID() : keeper.sessionID
        let endpoint = try KeeperEndpoint(
            path: "/private/tmp/cockpit-test/\(keeper.sessionID).sock",
            sessionID: sessionID,
            workerID: keeper.workerID
        )
        let nonce = Data(repeating: 0x33, count: 16)
        return KeeperReady(
            endpoint: endpoint,
            sessionID: sessionID,
            workerID: keeper.workerID,
            readyNonce: nonce,
            proofMAC: KeeperAuthentication.readyProof(
                secret: secret,
                endpoint: endpoint,
                sessionID: sessionID,
                workerID: keeper.workerID,
                readyNonce: nonce
            )
        )
    }

    func authenticatedStart(_ request: AuthenticatedStartRequest) async throws -> CLIProcessIdentity {
        if failStart { throw FakeControlError.injectedStartFailure }
        if let acceptedRequest {
            guard acceptedRequest == request else { throw TerminalSupervisorError.authenticationFailed }
            return identity
        }
        acceptedRequest = request
        createdCLIcount += 1
        await events.append("start")
        return identity
    }

    func inspect(_ endpoint: KeeperEndpoint) async throws -> KeeperIdentity {
        KeeperIdentity(
            endpoint: endpoint,
            sessionID: endpoint.sessionID,
            workerID: endpoint.workerID,
            processIdentity: acceptedRequest == nil ? nil : identity
        )
    }
}

private struct FixedWorkerSecretDeriver: WorkerSecretDeriving {
    func derive(sessionID: TerminalSessionID, workerID: WorkerInstanceID) async throws -> Data {
        Data(repeating: 0x5a, count: 32)
    }
}

private struct FixedSupervisorRandomBytes: TerminalSecurityRandomBytes {
    func bytes(count: Int) throws -> [UInt8] {
        Array(repeating: 0xa5, count: count)
    }
}

private actor MemoryTerminalSessionRepository: TerminalSessionRepository {
    private let events: OrderedEvents
    private var values: [TerminalSessionID: TerminalSessionRecord] = [:]
    private var requests: [RequestID: TerminalSessionID] = [:]

    init(events: OrderedEvents) { self.events = events }

    func insertPreparing(
        _ record: TerminalSessionRecord,
        idempotencyKey: RequestID
    ) async throws -> TerminalSessionRecord {
        if let sessionID = requests[idempotencyKey], let existing = values[sessionID] {
            return existing
        }
        requests[idempotencyKey] = record.sessionID
        values[record.sessionID] = record
        await events.append("preparing")
        return record
    }

    func markCommitted(sessionID: TerminalSessionID, workerID: WorkerInstanceID) async throws {
        let record = try require(sessionID)
        values[sessionID] = try copy(record, state: .committed, workerID: workerID)
        await events.append("committed")
    }

    func markRunning(sessionID: TerminalSessionID, identity: CLIProcessIdentity) async throws {
        let record = try require(sessionID)
        values[sessionID] = try copy(record, state: .running, processIdentity: identity)
        await events.append("running")
    }

    func finish(
        sessionID: TerminalSessionID,
        state: TerminalLifecycleState,
        exitStatus: Int32?,
        latestSequence: UInt64,
        archiveManifest: RelativeArchivePath?
    ) throws {
        let record = try require(sessionID)
        values[sessionID] = try TerminalSessionRecord(
            validatingSessionID: record.sessionID,
            contextID: record.contextID,
            environmentID: record.environmentID,
            protocolVersion: record.protocolVersion,
            launchSpecData: record.launchSpecData,
            lifecycleState: state,
            startNonce: record.startNonce,
            workerID: record.workerID,
            processIdentity: record.processIdentity,
            exitStatus: exitStatus,
            latestSequence: latestSequence,
            archiveManifest: archiveManifest
        )
    }

    func activeRecords() -> [TerminalSessionRecord] {
        values.values.filter { [.preparing, .committed, .running].contains($0.lifecycleState) }
    }

    func record(sessionID: TerminalSessionID) throws -> TerminalSessionRecord {
        try require(sessionID)
    }

    func records(contextID: WorkspaceContextID) -> [TerminalSessionRecord] {
        values.values.filter { $0.contextID == contextID }
    }

    func purgeFinishedRecords() -> Int {
        let finished = values.values.filter {
            [.exited, .terminated, .interrupted].contains($0.lifecycleState)
        }
        for record in finished {
            values.removeValue(forKey: record.sessionID)
        }
        return finished.count
    }

    private func require(_ id: TerminalSessionID) throws -> TerminalSessionRecord {
        guard let value = values[id] else { throw TerminalSessionRepositoryError.recordNotFound }
        return value
    }

    private func copy(
        _ record: TerminalSessionRecord,
        state: TerminalLifecycleState,
        workerID: WorkerInstanceID? = nil,
        processIdentity: CLIProcessIdentity? = nil
    ) throws -> TerminalSessionRecord {
        try TerminalSessionRecord(
            validatingSessionID: record.sessionID,
            contextID: record.contextID,
            environmentID: record.environmentID,
            protocolVersion: record.protocolVersion,
            launchSpecData: record.launchSpecData,
            lifecycleState: state,
            startNonce: record.startNonce,
            workerID: workerID ?? record.workerID,
            processIdentity: processIdentity ?? record.processIdentity,
            exitStatus: record.exitStatus,
            latestSequence: record.latestSequence,
            archiveManifest: record.archiveManifest
        )
    }
}

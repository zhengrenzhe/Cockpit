import Foundation
import Testing
import CockpitTypes
@_spi(CockpitTerminalSupervisorComposition) @testable import CockpitTerminalCore

@Suite("TerminalReconcilerTests")
struct TerminalReconcilerTests {
    @Test func terminalReconcilerAdoptsCommittedAndRunningRecordsForExactWorker() async throws {
        let fixture = try ReconcilerFixture()
        defer { fixture.cleanup() }
        let committed = try fixture.record(state: .committed, workerID: WorkerInstanceID())
        let running = try fixture.record(
            state: .running,
            workerID: WorkerInstanceID(),
            identity: try CLIProcessIdentity(validatingProcessID: 902, processGroupID: 902)
        )
        await fixture.repository.set([committed, running])
        let committedIdentity = try CLIProcessIdentity(validatingProcessID: 901, processGroupID: 901)
        let descriptors = try [
            fixture.descriptor(for: committed, processID: 401),
            fixture.descriptor(for: running, processID: 402),
        ]
        await fixture.controller.setIdentity(committedIdentity, for: committed.sessionID)
        await fixture.controller.setIdentity(running.processIdentity, for: running.sessionID)

        try await fixture.reconciler(descriptors: descriptors).reconcile()

        #expect(await fixture.repository.record(committed.sessionID)?.lifecycleState == .running)
        #expect(await fixture.repository.record(committed.sessionID)?.processIdentity == committedIdentity)
        #expect(await fixture.repository.record(running.sessionID) == running)
    }

    @Test func terminalReconcilerSkipsPreparingAndRejectsWorkerMismatch() async throws {
        let fixture = try ReconcilerFixture()
        defer { fixture.cleanup() }
        let preparing = try fixture.record(state: .preparing, workerID: nil)
        let committed = try fixture.record(state: .committed, workerID: WorkerInstanceID())
        let archivedMismatch = try fixture.record(
            state: .running,
            workerID: WorkerInstanceID()
        )
        await fixture.repository.set([preparing, committed, archivedMismatch])
        let wrongWorkerDescriptor = KeeperRuntimeDescriptor(
            sessionID: committed.sessionID,
            workerInstanceID: WorkerInstanceID(),
            processID: 403,
            processGroupID: 403,
            endpoint: try KeeperEndpoint(
                path: fixture.runtime.appendingPathComponent("wrong.sock").path,
                sessionID: committed.sessionID,
                workerID: WorkerInstanceID()
            )
        )
        _ = try fixture.archiveStore.publish(
            sessionID: archivedMismatch.sessionID,
            workerID: WorkerInstanceID(),
            chunks: [],
            firstOutputSequence: 0,
            latestOutputSequence: 0,
            finalSnapshot: Data("wrong-worker".utf8),
            exitStatus: .exited(0),
            completedAt: Date(timeIntervalSince1970: 20_000)
        )

        try await fixture.reconciler(descriptors: [wrongWorkerDescriptor]).reconcile()

        #expect(await fixture.repository.record(preparing.sessionID) == preparing)
        #expect(await fixture.repository.record(committed.sessionID) == committed)
        #expect(await fixture.repository.record(archivedMismatch.sessionID) == archivedMismatch)
        #expect(await fixture.controller.inspectCount == 0)
    }

    @Test func terminalReconcilerMarksMissingKeeperInterruptedButPreservesKeychainFailure() async throws {
        let fixture = try ReconcilerFixture()
        defer { fixture.cleanup() }
        let missing = try fixture.record(state: .committed, workerID: WorkerInstanceID())
        let inaccessible = try fixture.record(state: .running, workerID: WorkerInstanceID())
        await fixture.repository.set([missing, inaccessible])
        let descriptor = try fixture.descriptor(for: inaccessible, processID: 404)
        await fixture.deriver.fail(sessionID: inaccessible.sessionID)

        try await fixture.reconciler(descriptors: [descriptor]).reconcile()

        #expect(await fixture.repository.record(missing.sessionID)?.lifecycleState == .interrupted)
        #expect(await fixture.repository.record(inaccessible.sessionID) == inaccessible)
    }

    @Test func targetedReconcileDoesNotMutateAnotherActiveSession() async throws {
        let fixture = try ReconcilerFixture()
        defer { fixture.cleanup() }
        let disconnected = try fixture.record(state: .running, workerID: WorkerInstanceID())
        let concurrentlyControlled = try fixture.record(
            state: .running,
            workerID: WorkerInstanceID()
        )
        await fixture.repository.set([disconnected, concurrentlyControlled])

        try await fixture.reconciler(descriptors: []).reconcile(
            sessionID: disconnected.sessionID
        )

        #expect(
            await fixture.repository.record(disconnected.sessionID)?.lifecycleState
                == .interrupted
        )
        #expect(await fixture.repository.record(concurrentlyControlled.sessionID) == concurrentlyControlled)
    }

    @Test func watcherDisconnectPreservesRunningRecordWhenRuntimeInspectIsTransientlyUnavailable() async throws {
        let fixture = try ReconcilerFixture()
        defer { fixture.cleanup() }
        let running = try fixture.record(state: .running, workerID: WorkerInstanceID())
        await fixture.repository.set([running])
        let descriptor = try fixture.descriptor(for: running, processID: 406)
        await fixture.controller.failInspect(for: running.sessionID)

        try await fixture.reconciler(descriptors: [descriptor])
            .reconcileAfterTransientDisconnect(sessionID: running.sessionID)

        #expect(await fixture.repository.record(running.sessionID) == running)
        #expect(await fixture.controller.inspectCount == 1)
    }

    @Test func terminalReconcilerOnlyPublishesVerifiedArchiveTerminalState() async throws {
        let fixture = try ReconcilerFixture()
        defer { fixture.cleanup() }
        let exited = try fixture.record(state: .running, workerID: WorkerInstanceID())
        let tampered = try fixture.record(state: .running, workerID: WorkerInstanceID())
        await fixture.repository.set([exited, tampered])
        _ = try fixture.archiveStore.publish(
            sessionID: exited.sessionID,
            workerID: exited.workerID!,
            chunks: [],
            firstOutputSequence: 0,
            latestOutputSequence: 0,
            finalSnapshot: Data("empty-screen".utf8),
            exitStatus: .exited(7),
            completedAt: Date(timeIntervalSince1970: 20_000)
        )
        _ = try fixture.archiveStore.publish(
            sessionID: tampered.sessionID,
            workerID: tampered.workerID!,
            chunks: [],
            firstOutputSequence: 0,
            latestOutputSequence: 0,
            finalSnapshot: Data("before-tamper".utf8),
            exitStatus: .signaled(15),
            completedAt: Date(timeIntervalSince1970: 20_000)
        )
        let tamperedSnapshot = fixture.archives
            .appendingPathComponent(tampered.sessionID.description)
            .appendingPathComponent("final-snapshot.ckgf")
        try Data("after-tamper".utf8).write(to: tamperedSnapshot)

        try await fixture.reconciler(descriptors: []).reconcile()

        let exitedRecord = try #require(await fixture.repository.record(exited.sessionID))
        #expect(exitedRecord.lifecycleState == .exited)
        #expect(exitedRecord.exitStatus == 7)
        #expect(exitedRecord.latestSequence == 0)
        #expect(exitedRecord.archiveManifest?.rawValue == "\(exited.sessionID)/manifest.pb")
        let tamperedRecord = try #require(await fixture.repository.record(tampered.sessionID))
        #expect(tamperedRecord.lifecycleState == .interrupted)
        #expect(tamperedRecord.archiveManifest == nil)
    }

    @Test func terminalRuntimeDescriptorReaderRejectsSymlinkAndReadsExactIdentity() throws {
        let fixture = try ReconcilerFixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(state: .committed, workerID: WorkerInstanceID())
        let descriptor = try fixture.descriptor(for: record, processID: 405)
        try SecureRuntimeDirectory.write(descriptor, at: fixture.runtime.path)
        let reader = TerminalRuntimeDescriptorStore(runtimeDirectory: fixture.runtime.path)
        #expect(try reader.descriptors() == [descriptor])

        let external = fixture.root.appendingPathComponent("external.json")
        try JSONEncoder().encode(descriptor).write(to: external)
        let link = fixture.runtime.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        #expect(throws: TerminalReconciliationError.invalidRuntimeDescriptor) {
            _ = try reader.descriptors()
        }
    }
}

private final class ReconcilerFixture {
    let root: URL
    let applicationSupport: URL
    let archives: URL
    let runtime: URL
    let repository = ReconciliationRepository()
    let controller = ReconciliationController()
    let deriver = ReconciliationSecretDeriver()
    let archiveStore: TerminalArchiveStore

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/cockpit-reconcile.\(UUID().uuidString)")
        applicationSupport = root.appendingPathComponent("ApplicationSupport")
        archives = applicationSupport.appendingPathComponent("TerminalArchives")
        runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
        for directory in [root, applicationSupport, archives, runtime] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        archiveStore = try TerminalArchiveStore(
            applicationSupportRoot: applicationSupport.path,
            terminalArchivesRoot: archives.path
        )
    }

    func record(
        state: TerminalLifecycleState,
        workerID: WorkerInstanceID?,
        identity: CLIProcessIdentity? = nil
    ) throws -> TerminalSessionRecord {
        try TerminalSessionRecord(
            validatingSessionID: TerminalSessionID(),
            contextID: .project(ProjectID()),
            environmentID: EnvironmentID(),
            protocolVersion: .current,
            launchSpecData: Data([1]),
            lifecycleState: state,
            startNonce: Data(repeating: 1, count: 16),
            workerID: workerID,
            processIdentity: identity
        )
    }

    func descriptor(
        for record: TerminalSessionRecord,
        processID: Int32
    ) throws -> KeeperRuntimeDescriptor {
        let workerID = record.workerID!
        return KeeperRuntimeDescriptor(
            sessionID: record.sessionID,
            workerInstanceID: workerID,
            processID: processID,
            processGroupID: processID,
            endpoint: try KeeperEndpoint.runtime(
                directory: runtime.path,
                sessionID: record.sessionID,
                workerID: workerID
            )
        )
    }

    func reconciler(descriptors: [KeeperRuntimeDescriptor]) -> TerminalReconciler {
        TerminalReconciler(
            repository: repository,
            controller: controller,
            workerSecretDeriver: deriver,
            archiveStore: archiveStore,
            descriptorReader: FixedDescriptorReader(values: descriptors)
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private struct FixedDescriptorReader: TerminalRuntimeDescriptorReading {
    let values: [KeeperRuntimeDescriptor]
    func descriptors() throws -> [KeeperRuntimeDescriptor] { values }
}

private enum ReconciliationTestError: Error { case keychain, inspect }

private actor ReconciliationSecretDeriver: WorkerSecretDeriving {
    private var failures: Set<TerminalSessionID> = []
    func fail(sessionID: TerminalSessionID) { failures.insert(sessionID) }
    func derive(sessionID: TerminalSessionID, workerID: WorkerInstanceID) throws -> Data {
        if failures.contains(sessionID) { throw ReconciliationTestError.keychain }
        return Data(repeating: 7, count: 32)
    }
}

private actor ReconciliationController: KeeperControlling {
    private var identities: [TerminalSessionID: CLIProcessIdentity?] = [:]
    private var inspectFailures: Set<TerminalSessionID> = []
    private(set) var inspectCount = 0
    func setIdentity(_ identity: CLIProcessIdentity?, for sessionID: TerminalSessionID) {
        identities[sessionID] = identity
    }
    func failInspect(for sessionID: TerminalSessionID) {
        inspectFailures.insert(sessionID)
    }
    func awaitReady(_ keeper: LaunchedKeeper) throws -> KeeperReady {
        throw KeeperControlError.disconnected
    }
    func authenticatedStart(_ request: AuthenticatedStartRequest) throws -> CLIProcessIdentity {
        throw KeeperControlError.disconnected
    }
    func inspect(_ endpoint: KeeperEndpoint) throws -> KeeperIdentity {
        inspectCount += 1
        if inspectFailures.contains(endpoint.sessionID) {
            throw ReconciliationTestError.inspect
        }
        return KeeperIdentity(
            endpoint: endpoint,
            sessionID: endpoint.sessionID,
            workerID: endpoint.workerID,
            processIdentity: identities[endpoint.sessionID] ?? nil
        )
    }
}

private actor ReconciliationRepository: TerminalSessionRepository {
    private var values: [TerminalSessionID: TerminalSessionRecord] = [:]

    func set(_ records: [TerminalSessionRecord]) {
        values = Dictionary(uniqueKeysWithValues: records.map { ($0.sessionID, $0) })
    }

    func record(_ id: TerminalSessionID) -> TerminalSessionRecord? { values[id] }

    func insertPreparing(
        _ record: TerminalSessionRecord,
        idempotencyKey: RequestID
    ) -> TerminalSessionRecord {
        values[record.sessionID] = record
        return record
    }

    func markCommitted(sessionID: TerminalSessionID, workerID: WorkerInstanceID) throws {
        throw TerminalSessionRepositoryError.invalidTransition(current: .committed, requested: .committed)
    }

    func markRunning(sessionID: TerminalSessionID, identity: CLIProcessIdentity) throws {
        let record = try require(sessionID)
        values[sessionID] = try copy(record, state: .running, identity: identity)
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
        guard let record = values[id] else { throw TerminalSessionRepositoryError.recordNotFound }
        return record
    }

    private func copy(
        _ record: TerminalSessionRecord,
        state: TerminalLifecycleState,
        identity: CLIProcessIdentity
    ) throws -> TerminalSessionRecord {
        try TerminalSessionRecord(
            validatingSessionID: record.sessionID,
            contextID: record.contextID,
            environmentID: record.environmentID,
            protocolVersion: record.protocolVersion,
            launchSpecData: record.launchSpecData,
            lifecycleState: state,
            startNonce: record.startNonce,
            workerID: record.workerID,
            processIdentity: identity,
            exitStatus: record.exitStatus,
            latestSequence: record.latestSequence,
            archiveManifest: record.archiveManifest
        )
    }
}

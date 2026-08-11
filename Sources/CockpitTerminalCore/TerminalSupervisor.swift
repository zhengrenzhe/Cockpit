import Darwin
import Foundation
import CockpitTypes

public enum TerminalSupervisorError: Error, Equatable, Sendable {
    case invalidConfiguration
    case randomGenerationFailed
    case sessionNotFound
    case sessionNotCommitted
    case requestConflict
    case keeperIdentityMismatch
    case authenticationFailed
}

public struct TerminalSupervisorConfiguration: Hashable, Sendable {
    public let applicationSupportRoot: String
    public let terminalArchivesRoot: String
    public let runtimeDirectory: String

    public init(
        applicationSupportRoot: String,
        terminalArchivesRoot: String,
        runtimeDirectory: String
    ) throws {
        guard LaunchSpec.isCanonicalAbsolutePath(applicationSupportRoot),
              LaunchSpec.isCanonicalAbsolutePath(terminalArchivesRoot),
              LaunchSpec.isCanonicalAbsolutePath(runtimeDirectory),
              terminalArchivesRoot == URL(
                fileURLWithPath: applicationSupportRoot,
                isDirectory: true
              ).appendingPathComponent("TerminalArchives", isDirectory: true).path
        else {
            throw TerminalSupervisorError.invalidConfiguration
        }
        self.applicationSupportRoot = applicationSupportRoot
        self.terminalArchivesRoot = terminalArchivesRoot
        self.runtimeDirectory = runtimeDirectory
    }

    public func endpoint(
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID
    ) throws -> KeeperEndpoint {
        try KeeperEndpoint.runtime(
            directory: runtimeDirectory,
            sessionID: sessionID,
            workerID: workerID
        )
    }
}

public actor TerminalSupervisor {
    private let repository: any TerminalSessionRepository
    private let launcher: any KeeperLaunching
    private let controller: any KeeperControlling
    private let workerSecretDeriver: any WorkerSecretDeriving
    private let randomBytes: any TerminalSecurityRandomBytes
    private let configuration: TerminalSupervisorConfiguration

    public init(
        repository: any TerminalSessionRepository,
        launcher: any KeeperLaunching,
        controller: any KeeperControlling,
        workerSecretDeriver: any WorkerSecretDeriving,
        randomBytes: any TerminalSecurityRandomBytes,
        configuration: TerminalSupervisorConfiguration
    ) {
        self.repository = repository
        self.launcher = launcher
        self.controller = controller
        self.workerSecretDeriver = workerSecretDeriver
        self.randomBytes = randomBytes
        self.configuration = configuration
    }

    public func createSession(
        _ request: CreateTerminalSessionRequest
    ) async throws -> TerminalSessionRecord {
        let nonce = try random(count: 16)
        let launchData = try JSONEncoder().encode(request.launchSpec)
        let preparing = try TerminalSessionRecord(
            validatingSessionID: TerminalSessionID(),
            contextID: request.contextID,
            environmentID: request.environmentID,
            protocolVersion: .current,
            launchSpecData: launchData,
            lifecycleState: .preparing,
            startNonce: nonce
        )
        let record = try await repository.insertPreparing(
            preparing,
            idempotencyKey: request.idempotencyKey
        )
        guard record.contextID == request.contextID,
              record.environmentID == request.environmentID,
              record.launchSpecData == launchData else {
            throw TerminalSupervisorError.requestConflict
        }
        switch record.lifecycleState {
        case .running:
            return record
        case .committed:
            return try await startCommittedSession(record.sessionID)
        case .preparing:
            break
        default:
            throw TerminalSupervisorError.requestConflict
        }

        let workerID = WorkerInstanceID()
        let secret = try await workerSecretDeriver.derive(
            sessionID: record.sessionID,
            workerID: workerID
        )
        let bootstrap = try KeeperBootstrap(
            sessionID: record.sessionID,
            workerInstanceID: workerID,
            launchSpec: request.launchSpec,
            startNonce: record.startNonce,
            applicationSupportRoot: configuration.applicationSupportRoot,
            terminalArchivesRoot: configuration.terminalArchivesRoot,
            runtimeDirectory: configuration.runtimeDirectory,
            workerSecret: secret
        )
        let launched = try await launcher.launch(bootstrap)
        let ready = try await controller.awaitReady(launched)
        guard ready.sessionID == record.sessionID,
              ready.workerID == workerID,
              ready.endpoint.sessionID == record.sessionID,
              ready.endpoint.workerID == workerID else {
            throw TerminalSupervisorError.keeperIdentityMismatch
        }
        guard ready.readyNonce.count == 16,
              KeeperAuthentication.verifyReadyProof(
                ready.proofMAC,
                secret: secret,
                endpoint: ready.endpoint,
                sessionID: record.sessionID,
                workerID: workerID,
                readyNonce: ready.readyNonce
              ) else {
            throw TerminalSupervisorError.authenticationFailed
        }
        try await repository.markCommitted(sessionID: record.sessionID, workerID: workerID)
        let identity = try await controller.authenticatedStart(
            startRequest(
                endpoint: ready.endpoint,
                record: record,
                workerID: workerID,
                secret: secret
            )
        )
        try await repository.markRunning(sessionID: record.sessionID, identity: identity)
        return try await requireActive(record.sessionID)
    }

    public func reconcile() async throws {
        try await makeReconciler().reconcile()
    }

    @_spi(CockpitTerminalSupervisorComposition)
    public func reconcile(sessionID: TerminalSessionID) async throws {
        try await makeReconciler().reconcile(sessionID: sessionID)
    }

    @_spi(CockpitTerminalSupervisorComposition)
    public func reconcileAfterTransientDisconnect(
        sessionID: TerminalSessionID
    ) async throws {
        try await makeReconciler().reconcileAfterTransientDisconnect(sessionID: sessionID)
    }

    private func makeReconciler() throws -> TerminalReconciler {
        let archiveStore = try TerminalArchiveStore(
            applicationSupportRoot: configuration.applicationSupportRoot,
            terminalArchivesRoot: configuration.terminalArchivesRoot
        )
        return TerminalReconciler(
            repository: repository,
            controller: controller,
            workerSecretDeriver: workerSecretDeriver,
            archiveStore: archiveStore,
            descriptorReader: TerminalRuntimeDescriptorStore(
                runtimeDirectory: configuration.runtimeDirectory
            )
        )
    }

    public func startCommittedSession(
        _ id: TerminalSessionID
    ) async throws -> TerminalSessionRecord {
        let record = try await requireActive(id)
        if record.lifecycleState == .running { return record }
        guard record.lifecycleState == .committed, let workerID = record.workerID else {
            throw TerminalSupervisorError.sessionNotCommitted
        }
        let endpoint = try configuration.endpoint(sessionID: id, workerID: workerID)
        let keeper = try await controller.inspect(endpoint)
        guard keeper.sessionID == id,
              keeper.workerID == workerID,
              keeper.endpoint.sessionID == id,
              keeper.endpoint.workerID == workerID else {
            throw TerminalSupervisorError.keeperIdentityMismatch
        }
        if let identity = keeper.processIdentity {
            try await repository.markRunning(sessionID: id, identity: identity)
            return try await requireActive(id)
        }
        let secret = try await workerSecretDeriver.derive(sessionID: id, workerID: workerID)
        let identity = try await controller.authenticatedStart(
            startRequest(
                endpoint: keeper.endpoint,
                record: record,
                workerID: workerID,
                secret: secret
            )
        )
        try await repository.markRunning(sessionID: id, identity: identity)
        return try await requireActive(id)
    }

    public func terminate(_ id: TerminalSessionID, force: Bool) async throws {
        let record = try await requireActive(id)
        guard let workerID = record.workerID else {
            throw TerminalSupervisorError.sessionNotCommitted
        }
        let endpoint = try configuration.endpoint(sessionID: id, workerID: workerID)
        let keeper = try await controller.inspect(endpoint)
        guard let identity = keeper.processIdentity else {
            throw KeeperControlError.noRunningProcess
        }
        let signal = force ? SIGKILL : SIGTERM
        guard Darwin.kill(-identity.processGroupID, signal) == 0 || errno == ESRCH else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        try await repository.finish(
            sessionID: id,
            state: .terminated,
            exitStatus: nil,
            latestSequence: record.latestSequence,
            archiveManifest: record.archiveManifest
        )
    }

    public func beginContextDeletion(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws {
        try await repository.beginContextDeletion(
            contextID: contextID,
            operationID: operationID
        )
    }

    public func terminateSessions(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID,
        force: Bool
    ) async throws -> ContextTerminationResult {
        try await requireDeletion(contextID: contextID, operationID: operationID)
        let records = try await repository.records(contextID: contextID)
        let active = records.filter { Self.activeStates.contains($0.lifecycleState) }
        for record in active {
            if record.lifecycleState == .preparing, record.workerID == nil {
                try await repository.finish(
                    sessionID: record.sessionID,
                    state: .interrupted,
                    exitStatus: nil,
                    latestSequence: record.latestSequence,
                    archiveManifest: record.archiveManifest
                )
                continue
            }
            guard let workerID = record.workerID else { continue }
            let endpoint = try configuration.endpoint(
                sessionID: record.sessionID,
                workerID: workerID
            )
            try await controller.terminate(endpoint, force: force)
        }
        let remaining = try await repository.records(contextID: contextID)
            .filter { Self.activeStates.contains($0.lifecycleState) }
            .map(\.sessionID)
            .sorted { $0.description < $1.description }
        return remaining.isEmpty
            ? .complete
            : .forceConfirmationRequired(activeSessionIDs: remaining)
    }

    public func contextTerminationStatus(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws -> ContextTerminationResult {
        try await requireDeletion(contextID: contextID, operationID: operationID)
        let remaining = try await repository.records(contextID: contextID)
            .filter { Self.activeStates.contains($0.lifecycleState) }
            .map(\.sessionID)
            .sorted { $0.description < $1.description }
        return remaining.isEmpty
            ? .complete
            : .forceConfirmationRequired(activeSessionIDs: remaining)
    }

    public func purgeDeletedContext(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws {
        try await requireDeletion(contextID: contextID, operationID: operationID)
        let active = try await repository.records(contextID: contextID)
            .contains { Self.activeStates.contains($0.lifecycleState) }
        guard !active else { throw TerminalSessionRepositoryError.activeSessionsRemain }
        try await repository.purgeDeletedContext(
            contextID: contextID,
            operationID: operationID
        )
    }

    private func requireDeletion(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async throws {
        guard let deletion = try await repository.contextDeletion(contextID: contextID),
              deletion.operationID == operationID else {
            throw TerminalSessionRepositoryError.deletionOperationMismatch
        }
    }

    private static let activeStates: Set<TerminalLifecycleState> = [
        .preparing, .committed, .running,
    ]

    private func startRequest(
        endpoint: KeeperEndpoint,
        record: TerminalSessionRecord,
        workerID: WorkerInstanceID,
        secret: Data
    ) -> AuthenticatedStartRequest {
        AuthenticatedStartRequest(
            endpoint: endpoint,
            sessionID: record.sessionID,
            workerID: workerID,
            startNonce: record.startNonce,
            proofMAC: KeeperAuthentication.startProof(
                secret: secret,
                endpoint: endpoint,
                sessionID: record.sessionID,
                workerID: workerID,
                startNonce: record.startNonce
            )
        )
    }

    private func requireActive(_ id: TerminalSessionID) async throws -> TerminalSessionRecord {
        guard let record = try await repository.activeRecords().first(where: { $0.sessionID == id }) else {
            throw TerminalSupervisorError.sessionNotFound
        }
        return record
    }

    private func random(count: Int) throws -> Data {
        let bytes: [UInt8]
        do { bytes = try randomBytes.bytes(count: count) }
        catch { throw TerminalSupervisorError.randomGenerationFailed }
        guard bytes.count == count else { throw TerminalSupervisorError.randomGenerationFailed }
        return Data(bytes)
    }
}

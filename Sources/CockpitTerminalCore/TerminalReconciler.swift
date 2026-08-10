import Darwin
import Foundation
import CockpitTypes

public enum TerminalReconciliationError: Error, Equatable, Sendable {
    case invalidRuntimeDirectory
    case invalidRuntimeDescriptor
    case keeperIdentityMismatch
}

public protocol TerminalRuntimeDescriptorReading: Sendable {
    func descriptors() throws -> [KeeperRuntimeDescriptor]
}

public struct TerminalRuntimeDescriptorStore: TerminalRuntimeDescriptorReading, Sendable {
    private let runtimeDirectory: String

    public init(runtimeDirectory: String) {
        self.runtimeDirectory = runtimeDirectory
    }

    public func descriptors() throws -> [KeeperRuntimeDescriptor] {
        let directory = Darwin.open(
            runtimeDirectory,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw TerminalReconciliationError.invalidRuntimeDirectory
        }
        defer { _ = Darwin.close(directory) }
        var directoryStatus = stat()
        guard fstat(directory, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_mode & 0o777 == 0o700 else {
            throw TerminalReconciliationError.invalidRuntimeDirectory
        }
        let duplicate = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw TerminalReconciliationError.invalidRuntimeDirectory
        }
        defer { closedir(stream) }

        var result: [KeeperRuntimeDescriptor] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard name.hasSuffix(".json") else { continue }
            let descriptor = name.withCString {
                openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw TerminalReconciliationError.invalidRuntimeDescriptor
            }
            defer { _ = Darwin.close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o777 == 0o600,
                  status.st_size > 0,
                  status.st_size <= 1_048_576 else {
                throw TerminalReconciliationError.invalidRuntimeDescriptor
            }
            var bytes = Data(count: Int(status.st_size))
            try bytes.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.read(
                        descriptor,
                        base.advanced(by: offset),
                        buffer.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw TerminalReconciliationError.invalidRuntimeDescriptor
                    }
                    offset += count
                }
            }
            let value: KeeperRuntimeDescriptor
            do { value = try JSONDecoder().decode(KeeperRuntimeDescriptor.self, from: bytes) }
            catch { throw TerminalReconciliationError.invalidRuntimeDescriptor }
            let expectedName = "\(value.sessionID).\(value.workerInstanceID).json"
            guard name == expectedName,
                  value.processID > 0,
                  value.processGroupID > 0,
                  value.processID == value.processGroupID,
                  let endpoint = value.endpoint,
                  endpoint.sessionID == value.sessionID,
                  endpoint.workerID == value.workerInstanceID else {
                throw TerminalReconciliationError.invalidRuntimeDescriptor
            }
            result.append(value)
        }
        return result.sorted {
            ($0.sessionID.description, $0.workerInstanceID.description)
                < ($1.sessionID.description, $1.workerInstanceID.description)
        }
    }
}

public actor TerminalReconciler {
    private let repository: any TerminalSessionRepository
    private let controller: any KeeperControlling
    private let workerSecretDeriver: any WorkerSecretDeriving
    private let archiveStore: TerminalArchiveStore
    private let descriptorReader: any TerminalRuntimeDescriptorReading

    public init(
        repository: any TerminalSessionRepository,
        controller: any KeeperControlling,
        workerSecretDeriver: any WorkerSecretDeriving,
        archiveStore: TerminalArchiveStore,
        descriptorReader: any TerminalRuntimeDescriptorReading
    ) {
        self.repository = repository
        self.controller = controller
        self.workerSecretDeriver = workerSecretDeriver
        self.archiveStore = archiveStore
        self.descriptorReader = descriptorReader
    }

    public func reconcile() async throws {
        let descriptors = try descriptorReader.descriptors()
        let records = try await repository.activeRecords().sorted {
            $0.sessionID.description < $1.sessionID.description
        }
        for record in records {
            guard record.lifecycleState == .committed || record.lifecycleState == .running,
                  let workerID = record.workerID else { continue }

            if let manifest = try verifiedManifest(for: record) {
                guard manifest.workerInstanceID == workerID else { continue }
                let final: (TerminalLifecycleState, Int32) = switch manifest.exitStatus {
                case let .exited(code): (.exited, Int32(code))
                case let .signaled(signal): (.terminated, -signal)
                }
                try await repository.finish(
                    sessionID: record.sessionID,
                    state: final.0,
                    exitStatus: final.1,
                    latestSequence: manifest.latestOutputSequence,
                    archiveManifest: archiveStore.manifestRelativePath(
                        sessionID: record.sessionID
                    )
                )
                continue
            }

            let sessionDescriptors = descriptors.filter { $0.sessionID == record.sessionID }
            guard let runtime = sessionDescriptors.first(where: {
                $0.workerInstanceID == workerID
            }) else {
                if sessionDescriptors.isEmpty {
                    try await markInterrupted(record)
                }
                continue
            }
            guard let endpoint = runtime.endpoint,
                  endpoint.sessionID == record.sessionID,
                  endpoint.workerID == workerID else { continue }

            let secret: Data
            do {
                secret = try await workerSecretDeriver.derive(
                    sessionID: record.sessionID,
                    workerID: workerID
                )
            } catch {
                // Keychain/master-key unavailability preserves the durable state.
                continue
            }

            let keeper: KeeperIdentity
            do { keeper = try await controller.inspect(endpoint) }
            catch {
                try await markInterrupted(record)
                continue
            }
            guard keeper.endpoint == endpoint,
                  keeper.sessionID == record.sessionID,
                  keeper.workerID == workerID else { continue }

            if let identity = keeper.processIdentity {
                if let recorded = record.processIdentity, recorded != identity { continue }
                try await repository.markRunning(
                    sessionID: record.sessionID,
                    identity: identity
                )
                continue
            }
            guard record.lifecycleState == .committed else {
                try await markInterrupted(record)
                continue
            }
            let request = AuthenticatedStartRequest(
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
            do {
                let identity = try await controller.authenticatedStart(request)
                try await repository.markRunning(
                    sessionID: record.sessionID,
                    identity: identity
                )
            } catch {
                // A reachable committed Keeper remains retryable after transient start failure.
            }
        }
    }

    private func verifiedManifest(
        for record: TerminalSessionRecord
    ) throws -> TerminalArchiveManifest? {
        do { return try archiveStore.verifiedManifest(sessionID: record.sessionID) }
        catch TerminalArchiveError.integrityMismatch,
              TerminalArchiveError.invalidManifest,
              TerminalArchiveError.invalidLayout {
            return nil
        }
    }

    private func markInterrupted(_ record: TerminalSessionRecord) async throws {
        try await repository.finish(
            sessionID: record.sessionID,
            state: .interrupted,
            exitStatus: nil,
            latestSequence: record.latestSequence,
            archiveManifest: nil
        )
    }
}

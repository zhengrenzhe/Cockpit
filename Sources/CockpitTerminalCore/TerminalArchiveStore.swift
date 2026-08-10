import CryptoKit
import Darwin
import Foundation
import CockpitProtocol
import CockpitTypes

public final class TerminalArchiveStore: @unchecked Sendable {
    public static let manifestName = "manifest.pb"
    public static let snapshotName = "final-snapshot.ckgf"

    private let terminalArchivesRoot: String
    private let effectiveUserID: uid_t

    public init(
        applicationSupportRoot: String,
        terminalArchivesRoot: String
    ) throws {
        let expected = URL(
            fileURLWithPath: applicationSupportRoot,
            isDirectory: true
        ).appendingPathComponent("TerminalArchives", isDirectory: true).path
        guard LaunchSpec.isCanonicalAbsolutePath(applicationSupportRoot),
              LaunchSpec.isCanonicalAbsolutePath(terminalArchivesRoot),
              terminalArchivesRoot == expected else {
            throw TerminalArchiveError.invalidRoot
        }
        effectiveUserID = geteuid()
        self.terminalArchivesRoot = terminalArchivesRoot
        try Self.validatePhysicalDirectory(
            applicationSupportRoot,
            owner: effectiveUserID,
            permissions: 0o700
        )
        try Self.validatePhysicalDirectory(
            terminalArchivesRoot,
            owner: effectiveUserID,
            permissions: 0o700
        )
    }

    public func publish(
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        chunks: [TerminalArchiveChunkData],
        firstOutputSequence: UInt64,
        latestOutputSequence: UInt64,
        finalSnapshot: Data,
        exitStatus: TerminalExitStatus,
        completedAt: Date
    ) throws -> TerminalArchiveManifest {
        guard !finalSnapshot.isEmpty else { throw TerminalArchiveError.invalidLayout }
        let chunkModels = try chunks.map { chunk in
            try TerminalArchiveChunk(
                validatingName: String(
                    format: "%020llu.ckgs",
                    chunk.firstOutputSequence
                ),
                firstOutputSequence: chunk.firstOutputSequence,
                lastOutputSequence: chunk.lastOutputSequence,
                sha256: try Self.digest(chunk.data)
            )
        }
        let manifest = try TerminalArchiveManifest(
            validatingTerminalSessionID: sessionID,
            workerInstanceID: workerID,
            firstOutputSequence: firstOutputSequence,
            latestOutputSequence: latestOutputSequence,
            chunks: chunkModels,
            finalSnapshotSHA256: try Self.digest(finalSnapshot),
            exitStatus: exitStatus,
            completedAt: completedAt
        )
        let wire = try TerminalMessages.encode(manifest, negotiatedVersion: .current)
        let manifestData = try wire.serializedData()

        try withArchiveRoot { root in
            let session = try requireDirectory(
                parent: root,
                name: sessionID.description,
                create: true
            )
            defer { _ = Darwin.close(session) }
            // The session directory entry must be durable before publishing files in it.
            try synchronize(root, component: sessionID.description)
            let chunkDirectory = try requireDirectory(
                parent: session,
                name: "chunks",
                create: true
            )
            defer { _ = Darwin.close(chunkDirectory) }

            for (chunk, model) in zip(chunks, chunkModels) {
                try writeImmutable(
                    chunk.data,
                    named: model.name,
                    in: chunkDirectory
                )
            }
            try synchronize(chunkDirectory, component: "chunks")
            try writeImmutable(finalSnapshot, named: Self.snapshotName, in: session)
            try synchronize(session, component: sessionID.description)
            try publishManifest(manifestData, in: session)
        }
        return manifest
    }

    public func verifiedManifest(
        sessionID: TerminalSessionID
    ) throws -> TerminalArchiveManifest? {
        try withArchiveRoot { root -> TerminalArchiveManifest? in
            guard let session = try optionalDirectory(
                parent: root,
                name: sessionID.description
            ) else { return nil }
            defer { _ = Darwin.close(session) }
            guard let manifestData = try optionalFile(
                named: Self.manifestName,
                in: session
            ) else { return nil }
            let message: CPTerminalArchiveManifest
            do { message = try CPTerminalArchiveManifest(serializedBytes: manifestData) }
            catch { throw TerminalArchiveError.invalidManifest }
            let manifest: TerminalArchiveManifest
            do { manifest = try TerminalMessages.decode(message, negotiatedVersion: .current) }
            catch { throw TerminalArchiveError.invalidManifest }
            guard manifest.terminalSessionID == sessionID else {
                throw TerminalArchiveError.invalidManifest
            }
            let chunkDirectory = try requiredChildDirectory(parent: session, name: "chunks")
            defer { _ = Darwin.close(chunkDirectory) }
            for chunk in manifest.chunks {
                guard let data = try optionalFile(
                    named: chunk.name,
                    in: chunkDirectory
                ) else { throw TerminalArchiveError.integrityMismatch }
                guard try Self.digest(data) == chunk.sha256 else {
                    throw TerminalArchiveError.integrityMismatch
                }
            }
            guard let snapshot = try optionalFile(named: Self.snapshotName, in: session),
                  try Self.digest(snapshot) == manifest.finalSnapshotSHA256 else {
                throw TerminalArchiveError.integrityMismatch
            }
            return manifest
        }
    }

    public func openFinalSnapshot(
        sessionID: TerminalSessionID
    ) throws -> TerminalArchiveReadHandle {
        let manifest = try verifiedManifest(sessionID: sessionID)
        guard manifest != nil else { throw TerminalArchiveError.invalidManifest }
        return try withArchiveRoot { root in
            guard let session = try optionalDirectory(
                parent: root,
                name: sessionID.description
            ) else { throw TerminalArchiveError.invalidManifest }
            defer { _ = Darwin.close(session) }
            let descriptor = Self.snapshotName.withCString {
                openat(session, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw Self.io("openat") }
            do {
                try validateFile(descriptor, component: Self.snapshotName)
                let bytes = try Self.readAll(from: descriptor)
                guard try Self.digest(bytes) == manifest!.finalSnapshotSHA256 else {
                    throw TerminalArchiveError.integrityMismatch
                }
                return TerminalArchiveReadHandle(descriptor: descriptor)
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
    }

    @_spi(CockpitTerminalSupervisorComposition)
    public func openFinalSnapshot(
        record: TerminalSessionRecord
    ) throws -> TerminalArchiveReadHandle {
        guard [.exited, .terminated].contains(record.lifecycleState),
              let workerID = record.workerID,
              let archiveManifest = record.archiveManifest,
              archiveManifest == (try manifestRelativePath(sessionID: record.sessionID)),
              let manifest = try verifiedManifest(sessionID: record.sessionID),
              manifest.workerInstanceID == workerID,
              manifest.latestOutputSequence == record.latestSequence else {
            throw TerminalArchiveError.invalidManifest
        }
        let expectedExitStatus: Int32 = switch manifest.exitStatus {
        case let .exited(code): Int32(code)
        case let .signaled(signal): -signal
        }
        guard record.exitStatus == expectedExitStatus,
              (record.lifecycleState == .exited) == (expectedExitStatus >= 0) else {
            throw TerminalArchiveError.invalidManifest
        }
        return try openFinalSnapshot(sessionID: record.sessionID)
    }

    public func manifestRelativePath(
        sessionID: TerminalSessionID
    ) throws -> RelativeArchivePath {
        try RelativeArchivePath(validating: "\(sessionID)/\(Self.manifestName)")
    }

    private func withArchiveRoot<Result>(
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        let descriptor = Darwin.open(
            terminalArchivesRoot,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw Self.io("open") }
        defer { _ = Darwin.close(descriptor) }
        try validateDirectory(descriptor, component: terminalArchivesRoot)
        return try body(descriptor)
    }

    private func requireDirectory(
        parent: Int32,
        name: String,
        create: Bool
    ) throws -> Int32 {
        if create {
            let result = name.withCString { mkdirat(parent, $0, 0o700) }
            if result != 0, errno != EEXIST { throw Self.io("mkdirat") }
        }
        guard let descriptor = try optionalDirectory(parent: parent, name: name) else {
            throw TerminalArchiveError.invalidLayout
        }
        return descriptor
    }

    private func requiredChildDirectory(parent: Int32, name: String) throws -> Int32 {
        guard let descriptor = try optionalDirectory(parent: parent, name: name) else {
            throw TerminalArchiveError.integrityMismatch
        }
        return descriptor
    }

    private func optionalDirectory(parent: Int32, name: String) throws -> Int32? {
        guard Self.validComponent(name) else { throw TerminalArchiveError.invalidLayout }
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw Self.io("openat") }
        do {
            try validateDirectory(descriptor, component: name)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func validateDirectory(_ descriptor: Int32, component: String) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Self.io("fstat") }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == effectiveUserID,
              status.st_mode & 0o777 == 0o700 else {
            throw TerminalArchiveError.invalidLayout
        }
    }

    private func validateFile(_ descriptor: Int32, component: String) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Self.io("fstat") }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == effectiveUserID,
              status.st_mode & 0o777 == 0o600,
              status.st_size >= 0,
              status.st_size <= Int64(FrameHeader.maximumPayloadLength) else {
            throw TerminalArchiveError.invalidLayout
        }
    }

    private func writeImmutable(_ data: Data, named name: String, in directory: Int32) throws {
        guard Self.validComponent(name) else { throw TerminalArchiveError.invalidLayout }
        let descriptor = name.withCString {
            openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        if descriptor < 0, errno == EEXIST {
            guard let existing = try optionalFile(named: name, in: directory),
                  existing == data else {
                throw TerminalArchiveError.integrityMismatch
            }
            return
        }
        guard descriptor >= 0 else { throw Self.io("openat") }
        var ownedDescriptor: Int32? = descriptor
        do {
            guard fchmod(descriptor, 0o600) == 0 else { throw Self.io("fchmod") }
            try Self.writeAll(data, to: descriptor)
            try synchronize(descriptor, component: name)
            ownedDescriptor = nil
            guard Darwin.close(descriptor) == 0 else { throw Self.io("close") }
        } catch {
            if let ownedDescriptor { _ = Darwin.close(ownedDescriptor) }
            _ = name.withCString { unlinkat(directory, $0, 0) }
            throw error
        }
    }

    private func publishManifest(_ data: Data, in directory: Int32) throws {
        if let existing = try optionalFile(named: Self.manifestName, in: directory) {
            guard existing == data else {
                throw TerminalArchiveError.manifestAlreadyPublished
            }
            return
        }
        let temporary = ".manifest.\(getpid()).\(UUID().uuidString).tmp"
        let descriptor = temporary.withCString {
            openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else { throw Self.io("openat") }
        var ownedDescriptor: Int32? = descriptor
        var renamed = false
        do {
            guard fchmod(descriptor, 0o600) == 0 else { throw Self.io("fchmod") }
            try Self.writeAll(data, to: descriptor)
            try synchronize(descriptor, component: temporary)
            ownedDescriptor = nil
            guard Darwin.close(descriptor) == 0 else { throw Self.io("close") }
            let result = temporary.withCString { source in
                Self.manifestName.withCString { destination in
                    renameatx_np(directory, source, directory, destination, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else {
                if errno == EEXIST,
                   let existing = try optionalFile(named: Self.manifestName, in: directory),
                   existing == data {
                    _ = temporary.withCString { unlinkat(directory, $0, 0) }
                    try synchronize(directory, component: Self.manifestName)
                    return
                }
                throw errno == EEXIST
                    ? TerminalArchiveError.manifestAlreadyPublished
                    : Self.io("renameatx_np")
            }
            renamed = true
            try synchronize(directory, component: Self.manifestName)
        } catch {
            if let ownedDescriptor { _ = Darwin.close(ownedDescriptor) }
            if !renamed { _ = temporary.withCString { unlinkat(directory, $0, 0) } }
            throw error
        }
    }

    private func optionalFile(named name: String, in directory: Int32) throws -> Data? {
        guard Self.validComponent(name) else { throw TerminalArchiveError.invalidLayout }
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw Self.io("openat") }
        defer { _ = Darwin.close(descriptor) }
        try validateFile(descriptor, component: name)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Self.io("fstat") }
        var data = Data(count: Int(status.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw TerminalArchiveError.io(
                        operation: "read",
                        errno: count == 0 ? EIO : errno
                    )
                }
                offset += count
            }
        }
        return data
    }

    private func synchronize(_ descriptor: Int32, component: String) throws {
        while true {
            if fsync(descriptor) == 0 { return }
            if errno == EINTR { continue }
            throw Self.io("fsync")
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw TerminalArchiveError.io(
                        operation: "write",
                        errno: count == 0 ? EIO : errno
                    )
                }
                offset += count
            }
        }
    }

    private static func readAll(from descriptor: Int32) throws -> Data {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_size >= 0,
              status.st_size <= Int64(Int.max) else {
            throw Self.io("fstat")
        }
        var data = Data(count: Int(status.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = pread(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw TerminalArchiveError.io(
                        operation: "pread",
                        errno: count == 0 ? EIO : errno
                    )
                }
                offset += count
            }
        }
        return data
    }

    private static func digest(_ data: Data) throws -> CockpitTypes.SHA256Digest {
        try CockpitTypes.SHA256Digest(validating: Data(SHA256.hash(data: data)))
    }

    private static func validatePhysicalDirectory(
        _ path: String,
        owner: uid_t,
        permissions: mode_t
    ) throws {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == owner,
              status.st_mode & 0o777 == permissions else {
            throw TerminalArchiveError.invalidRoot
        }
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }

    private static func io(_ operation: String) -> TerminalArchiveError {
        .io(operation: operation, errno: errno)
    }
}

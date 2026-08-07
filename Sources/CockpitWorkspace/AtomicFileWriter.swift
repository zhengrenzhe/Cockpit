import CryptoKit
import Darwin
import Foundation
import CockpitHostCore
import CockpitProtocol
import CockpitTypes

struct AtomicFileWriterSystemCalls: @unchecked Sendable {
    let write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    let fsync: @Sendable (Int32) -> Int32
    let rename: @Sendable (Int32, String, Int32, String, UInt32) -> Int32

    init(
        write: @escaping @Sendable (Int32, UnsafeRawPointer, Int) -> Int,
        fsync: @escaping @Sendable (Int32) -> Int32,
        rename: @escaping @Sendable (Int32, String, Int32, String, UInt32) -> Int32
    ) {
        self.write = write
        self.fsync = fsync
        self.rename = rename
    }

    static let live = AtomicFileWriterSystemCalls(
        write: { Darwin.write($0, $1, $2) },
        fsync: { Darwin.fsync($0) },
        rename: { renameatx_np($0, $1, $2, $3, $4) }
    )
}

struct AtomicFileWriterHooks: @unchecked Sendable {
    let afterInitialFingerprint: @Sendable () -> Void
    let beforeCommitValidation: @Sendable (RelativePath) -> Void
    let afterRename: @Sendable () -> Void
    let beforeStagedState: @Sendable (RelativePath) -> Void
    let afterSnapshotRead: @Sendable () -> Void

    init(
        afterInitialFingerprint: @escaping @Sendable () -> Void = {},
        beforeCommitValidation: @escaping @Sendable (RelativePath) -> Void = { _ in },
        afterRename: @escaping @Sendable () -> Void = {},
        beforeStagedState: @escaping @Sendable (RelativePath) -> Void = { _ in },
        afterSnapshotRead: @escaping @Sendable () -> Void = {}
    ) {
        self.afterInitialFingerprint = afterInitialFingerprint
        self.beforeCommitValidation = beforeCommitValidation
        self.afterRename = afterRename
        self.beforeStagedState = beforeStagedState
        self.afterSnapshotRead = afterSnapshotRead
    }
}

struct AtomicFileWriter {
    let rootFD: Int32
    let systemCalls: AtomicFileWriterSystemCalls
    let hooks: AtomicFileWriterHooks

    init(
        rootFD: Int32,
        systemCalls: AtomicFileWriterSystemCalls = .live,
        hooks: AtomicFileWriterHooks = AtomicFileWriterHooks()
    ) {
        self.rootFD = rootFD
        self.systemCalls = systemCalls
        self.hooks = hooks
    }

    static func snapshot(
        rootFD: Int32,
        path: RelativePath,
        hooks: AtomicFileWriterHooks = AtomicFileWriterHooks()
    ) throws -> DocumentFileSnapshot {
        let path = try validated(path)
        let descriptor = openat(
            rootFD,
            path.string,
            O_RDONLY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw pathError(errno) }
        defer { close(descriptor) }
        return try snapshot(descriptor: descriptor, afterRead: hooks.afterSnapshotRead)
    }

    func write(
        _ data: Data,
        to path: RelativePath,
        expectedFingerprint: DiskFingerprint
    ) throws -> DiskFingerprint {
        let path = try Self.validated(path)
        let components = path.string.split(separator: "/").map(String.init)
        let parent = components.dropLast().joined(separator: "/")
        let parentFD = try openedParent(parent)
        defer { close(parentFD) }

        let targetFD = openat(
            rootFD,
            path.string,
            O_RDONLY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC
        )
        guard targetFD >= 0 else { throw Self.pathError(errno) }
        defer { close(targetFD) }
        let target = try Self.snapshot(descriptor: targetFD)
        guard target.fingerprint == expectedFingerprint else {
            throw DocumentStorageError.fingerprintMismatch(
                expected: expectedFingerprint,
                actual: target.fingerprint
            )
        }

        var targetStatus = stat()
        guard fstat(targetFD, &targetStatus) == 0 else { throw Self.posixError(errno) }
        guard targetStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw DocumentStorageError.unsupportedFileType
        }

        hooks.afterInitialFingerprint()
        try validateBinding(
            parent: parent,
            retainedParentFD: parentFD,
            path: path,
            retainedTargetStatus: targetStatus,
            expectedFingerprint: expectedFingerprint,
            temporary: nil
        )

        let temporaryName = ".cockpit-save-\(UUID().uuidString)"
        let temporaryPath = try RelativePath(
            parent.isEmpty ? temporaryName : parent + "/" + temporaryName
        )
        let descriptor = openat(
            rootFD,
            temporaryPath.string,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC,
            targetStatus.st_mode & permissionMask
        )
        guard descriptor >= 0 else { throw Self.pathError(errno) }
        defer { close(descriptor) }

        do {
            guard fchmod(descriptor, targetStatus.st_mode & permissionMask) == 0 else {
                throw Self.posixError(errno)
            }
            try writeAll(data, descriptor: descriptor)
            try synchronize(descriptor)
            let committedFingerprint = try Self.fingerprint(descriptor: descriptor, data: data)

            hooks.beforeCommitValidation(temporaryPath)
            try validateBinding(
                parent: parent,
                retainedParentFD: parentFD,
                path: path,
                retainedTargetStatus: targetStatus,
                expectedFingerprint: expectedFingerprint,
                temporary: (descriptor, temporaryPath)
            )
            guard systemCalls.rename(
                rootFD,
                temporaryPath.string,
                rootFD,
                path.string,
                UInt32(RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
            ) == 0 else { throw Self.pathError(errno) }

            hooks.afterRename()
            do {
                try synchronize(parentFD)
            } catch {
                throw DocumentWriteRecoveryRequiredError(
                    path: path,
                    state: .committedButDurabilityUnknown(committedFingerprint),
                    originalError: error
                )
            }
            return committedFingerprint
        } catch let error as DocumentWriteRecoveryRequiredError {
            throw error
        } catch {
            hooks.beforeStagedState(temporaryPath)
            throw DocumentWriteRecoveryRequiredError(
                path: path,
                state: stagedState(descriptor: descriptor, path: temporaryPath),
                originalError: error
            )
        }
    }

    private var permissionMask: mode_t {
        mode_t(S_IRWXU | S_IRWXG | S_IRWXO | S_ISUID | S_ISGID | S_ISVTX)
    }

    private func openedParent(_ parent: String) throws -> Int32 {
        let descriptor: Int32
        if parent.isEmpty {
            descriptor = dup(rootFD)
        } else {
            descriptor = openat(
                rootFD,
                parent,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw Self.pathError(errno) }
        return descriptor
    }

    private func validateBinding(
        parent: String,
        retainedParentFD: Int32,
        path: RelativePath,
        retainedTargetStatus: stat,
        expectedFingerprint: DiskFingerprint,
        temporary: (descriptor: Int32, path: RelativePath)?
    ) throws {
        let currentTarget = try Self.snapshot(rootFD: rootFD, path: path)
        let currentParentFD = try openedParent(parent)
        defer { close(currentParentFD) }
        var retainedParent = stat()
        var currentParent = stat()
        var currentTargetStatus = stat()
        guard fstat(retainedParentFD, &retainedParent) == 0,
              fstat(currentParentFD, &currentParent) == 0,
              fstatat(
                rootFD,
                path.string,
                &currentTargetStatus,
                AT_SYMLINK_NOFOLLOW | AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH
              ) == 0
        else { throw Self.pathError(errno) }
        guard Self.sameIdentity(retainedParent, currentParent),
              Self.sameIdentity(retainedTargetStatus, currentTargetStatus),
              currentTarget.fingerprint == expectedFingerprint
        else {
            throw DocumentStorageError.fingerprintMismatch(
                expected: expectedFingerprint,
                actual: currentTarget.fingerprint
            )
        }
        if let temporary {
            var retainedTemporary = stat()
            var namedTemporary = stat()
            guard fstat(temporary.descriptor, &retainedTemporary) == 0,
                  fstatat(
                    rootFD,
                    temporary.path.string,
                    &namedTemporary,
                    AT_SYMLINK_NOFOLLOW | AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH
                  ) == 0,
                  Self.sameIdentity(retainedTemporary, namedTemporary)
            else { throw FileOperationError.identityChanged }
        }
    }

    private func stagedState(descriptor: Int32, path: RelativePath) -> DocumentWriteRecoveryState {
        var retained = stat()
        var named = stat()
        guard fstat(descriptor, &retained) == 0,
              fstatat(
                rootFD,
                path.string,
                &named,
                AT_SYMLINK_NOFOLLOW | AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH
              ) == 0,
              Self.sameIdentity(retained, named)
        else { return .stagedLocationUnknown }
        return .staged(path)
    }

    private static func snapshot(
        descriptor: Int32,
        afterRead: @Sendable () -> Void = {}
    ) throws -> DocumentFileSnapshot {
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw posixError(errno) }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw DocumentStorageError.unsupportedFileType
        }
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw posixError(errno) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError(errno) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        afterRead()
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw posixError(errno) }
        guard stable(before, after), UInt64(data.count) == UInt64(after.st_size) else {
            throw DocumentStorageError.unstableRead
        }
        return DocumentFileSnapshot(
            data: data,
            fingerprint: try fingerprint(status: after, data: data)
        )
    }

    private static func fingerprint(descriptor: Int32, data: Data) throws -> DiskFingerprint {
        var before = stat()
        var after = stat()
        guard fstat(descriptor, &before) == 0, fstat(descriptor, &after) == 0 else {
            throw posixError(errno)
        }
        guard stable(before, after), UInt64(data.count) == UInt64(after.st_size) else {
            throw DocumentStorageError.unstableRead
        }
        return try fingerprint(status: after, data: data)
    }

    private static func fingerprint(status: stat, data: Data) throws -> DiskFingerprint {
        guard status.st_size >= 0,
              status.st_mtimespec.tv_nsec >= 0,
              status.st_mtimespec.tv_nsec < 1_000_000_000
        else { throw DocumentStorageError.unstableRead }
        return DiskFingerprint(
            deviceID: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: UInt64(status.st_size),
            modificationTimeSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationTimeNanoseconds: UInt32(status.st_mtimespec.tv_nsec),
            contentSHA256: try CockpitTypes.SHA256Digest(validating: Data(SHA256.hash(data: data)))
        )
    }

    private static func stable(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode & mode_t(S_IFMT) == rhs.st_mode & mode_t(S_IFMT)
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = systemCalls.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.posixError(count == 0 ? EIO : errno) }
                offset += count
            }
        }
    }

    private func synchronize(_ descriptor: Int32) throws {
        while true {
            if systemCalls.fsync(descriptor) == 0 { return }
            if errno == EINTR { continue }
            throw Self.posixError(errno)
        }
    }

    private static func validated(_ path: RelativePath) throws -> RelativePath {
        guard !path.string.contains("\0"), let valid = try? RelativePath(path.string),
              valid.string == path.string
        else { throw FileOperationError.invalidPath }
        return valid
    }

    private static func pathError(_ code: Int32) -> any Error {
        code == ELOOP ? FileOperationError.symbolicLinkTraversal : posixError(code)
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

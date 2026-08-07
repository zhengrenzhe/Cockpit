import Darwin
import Foundation
import CockpitHostCore
import CockpitProtocol
import CockpitTypes

struct PhysicalFileOperationResult: Sendable {
    let result: FileOperationResult
    let affectedKind: FileTreeEntryKind
    let trashURL: URL?

    init(
        result: FileOperationResult,
        affectedKind: FileTreeEntryKind,
        trashURL: URL?
    ) {
        self.result = result
        self.affectedKind = affectedKind
        self.trashURL = trashURL
    }
}

protocol FileOperationPhysicallyPerforming: Sendable {
    func perform(_ operation: FileOperation) async throws -> PhysicalFileOperationResult
}

final class WorkspaceRootHandle: FileOperationPhysicallyPerforming, DocumentServing, @unchecked Sendable {
    private let rootURL: URL
    private let queue = DispatchQueue(label: "com.openai.cockpit.file-operation-io")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let beforeOpeningComponent: @Sendable (String) -> Void
    private let beforeTrashValidation: @Sendable (URL) -> Void
    private let afterCreatingDirectoryStaging: @Sendable (RelativePath) -> Void
    private var rootFD: Int32 = -1

    init(
        rootURL: URL,
        beforeOpeningComponent: @escaping @Sendable (String) -> Void = { _ in },
        beforeTrashValidation: @escaping @Sendable (URL) -> Void = { _ in },
        afterCreatingDirectoryStaging: @escaping @Sendable (RelativePath) -> Void = { _ in }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.beforeOpeningComponent = beforeOpeningComponent
        self.beforeTrashValidation = beforeTrashValidation
        self.afterCreatingDirectoryStaging = afterCreatingDirectoryStaging
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeRootIfNeeded()
        } else {
            queue.sync { closeRootIfNeeded() }
        }
    }

    func perform(_ operation: FileOperation) async throws -> PhysicalFileOperationResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try performSynchronously(operation) })
            }
        }
    }

    func readDocument(at path: RelativePath) async throws -> DocumentFileSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result {
                    try AtomicFileWriter.snapshot(rootFD: openedRootFD(), path: path)
                })
            }
        }
    }

    func atomicallyWriteDocument(
        _ data: Data,
        to path: RelativePath,
        expectedFingerprint: DiskFingerprint
    ) async throws -> DiskFingerprint {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result {
                    try AtomicFileWriter(rootFD: openedRootFD()).write(
                        data,
                        to: path,
                        expectedFingerprint: expectedFingerprint
                    )
                })
            }
        }
    }

    private func performSynchronously(
        _ operation: FileOperation
    ) throws -> PhysicalFileOperationResult {
        let rootFD = try openedRootFD()
        switch operation {
        case let .createFile(parent, name):
            let parent = try validatedDirectory(parent)
            let name = try validatedName(name)
            let destination = try childPath(parent: parent, name: name)
            announce(directory: parent)
            let fd = openat(
                rootFD,
                destination.string,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            )
            guard fd >= 0 else {
                let code = errno
                throw pathResolutionError(code: code, path: try currentURL(for: destination).path)
            }
            close(fd)
            return PhysicalFileOperationResult(
                result: .created(path: destination, kind: .file),
                affectedKind: .file,
                trashURL: nil
            )

        case let .createDirectory(parent, name):
            let parent = try validatedDirectory(parent)
            let name = try validatedName(name)
            let destination = try childPath(parent: parent, name: name)
            announce(directory: parent)
            try validateDirectory(parent, rootFD: rootFD)
            try validateAbsent(destination, rootFD: rootFD)
            try createDirectory(operation: operation, destination: destination, rootFD: rootFD)
            return PhysicalFileOperationResult(
                result: .created(path: destination, kind: .directory),
                affectedKind: .directory,
                trashURL: nil
            )

        case let .rename(source, newName):
            let source = try validatedPath(source)
            let newName = try validatedName(newName)
            let sourceParts = split(source)
            let destination = try childPath(parent: sourceParts.parent, name: newName)
            announce(directory: sourceParts.parent)
            try validateDirectory(sourceParts.parent, rootFD: rootFD)
            announce(directory: sourceParts.parent)
            try validateDirectory(sourceParts.parent, rootFD: rootFD)
            let metadata = try entryMetadata(rootFD: rootFD, path: source)
            guard renameatx_np(
                rootFD,
                source.string,
                rootFD,
                destination.string,
                secureRenameFlags
            ) == 0 else {
                let code = errno
                throw pathResolutionError(code: code, path: try currentURL(for: destination).path)
            }
            return PhysicalFileOperationResult(
                result: .relocated(from: source, to: destination),
                affectedKind: kind(for: metadata.st_mode),
                trashURL: nil
            )

        case let .move(source, destinationDirectory):
            let source = try validatedPath(source)
            let destinationDirectory = try validatedDirectory(destinationDirectory)
            let sourceParts = split(source)
            announce(directory: sourceParts.parent)
            try validateDirectory(sourceParts.parent, rootFD: rootFD)
            let initialMetadata = try entryMetadata(rootFD: rootFD, path: source)
            let initialKind = kind(for: initialMetadata.st_mode)
            if initialKind == .directory,
               case let .relative(destinationPath) = destinationDirectory,
               (destinationPath.string == source.string || destinationPath.string.hasPrefix(source.string + "/")) {
                throw FileOperationError.moveIntoDescendant
            }
            let destination = try childPath(parent: destinationDirectory, name: sourceParts.name)
            announce(directory: destinationDirectory)
            try validateDirectory(destinationDirectory, rootFD: rootFD)
            let metadata = try entryMetadata(rootFD: rootFD, path: source)
            guard renameatx_np(
                rootFD,
                source.string,
                rootFD,
                destination.string,
                secureRenameFlags
            ) == 0 else {
                let code = errno
                throw pathResolutionError(code: code, path: try currentURL(for: destination).path)
            }
            return PhysicalFileOperationResult(
                result: .relocated(from: source, to: destination),
                affectedKind: kind(for: metadata.st_mode),
                trashURL: nil
            )

        case let .trash(path):
            let path = try validatedPath(path)
            let parts = split(path)
            announce(directory: parts.parent)
            try validateDirectory(parts.parent, rootFD: rootFD)
            let stagingPath = try moveToUniqueStaging(
                source: path,
                prefix: ".cockpit-trash-",
                rootFD: rootFD
            )
            let stagingFD: Int32
            do {
                stagingFD = try openStagedObject(rootFD: rootFD, path: stagingPath)
            } catch {
                throw FileOperationRecoveryRequiredError(
                    originalOperation: operation,
                    state: .stagedLocationUnknown,
                    originalError: error
                )
            }
            defer { close(stagingFD) }
            do {
                var before = stat()
                guard fstat(stagingFD, &before) == 0 else {
                    throw posixError(code: errno, path: try currentURL(for: stagingPath).path)
                }
                let stagingURL = try currentURL(for: stagingPath)
                beforeTrashValidation(stagingURL)
                let secureAfter = try entryMetadata(rootFD: rootFD, path: stagingPath)
                var pathAfter = stat()
                guard lstat(stagingURL.path, &pathAfter) == 0 else {
                    throw posixError(code: errno, path: stagingURL.path)
                }
                guard sameIdentity(before, secureAfter), sameIdentity(before, pathAfter) else {
                    throw FileOperationError.identityChanged
                }
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: stagingURL, resultingItemURL: &resultingURL)
                return PhysicalFileOperationResult(
                    result: .trashed(path: path),
                    affectedKind: kind(for: before.st_mode),
                    trashURL: resultingURL as URL?
                )
            } catch {
                throw FileOperationRecoveryRequiredError(
                    originalOperation: operation,
                    state: stagedRecoveryState(stagingFD: stagingFD, rootFD: rootFD),
                    originalError: error
                )
            }
        }
    }

    private func openedRootFD() throws -> Int32 {
        if rootFD >= 0 { return rootFD }
        let value = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard value >= 0 else { throw posixError(code: errno, path: rootURL.path) }
        rootFD = value
        return value
    }

    private func closeRootIfNeeded() {
        guard rootFD >= 0 else { return }
        close(rootFD)
        rootFD = -1
    }

    private var secureRenameFlags: UInt32 {
        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
    }

    private func announce(directory: WorkspaceDirectory) {
        guard case let .relative(path) = directory else { return }
        path.string.split(separator: "/").forEach { beforeOpeningComponent(String($0)) }
    }

    private func validateDirectory(_ directory: WorkspaceDirectory, rootFD: Int32) throws {
        guard case let .relative(path) = directory else { return }
        let fd = openat(
            rootFD,
            path.string,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH | O_CLOEXEC
        )
        guard fd >= 0 else {
            let code = errno
            throw pathResolutionError(code: code, path: try currentURL(for: path).path)
        }
        close(fd)
    }

    private func createDirectory(
        operation: FileOperation,
        destination: RelativePath,
        rootFD: Int32
    ) throws {
        let mode = mode_t(S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
        let stagingName: String
        while true {
            let candidate = ".cockpit-mkdir-\(UUID().uuidString)"
            if mkdirat(rootFD, candidate, mode) == 0 {
                stagingName = candidate
                break
            }
            let code = errno
            if code != EEXIST {
                throw posixError(code: code, path: try currentRootURL().appendingPathComponent(candidate).path)
            }
        }
        let stagingPath = try RelativePath(stagingName)
        let stagingFD: Int32
        do {
            stagingFD = try openStagedObject(rootFD: rootFD, path: stagingPath)
        } catch {
            throw FileOperationRecoveryRequiredError(
                originalOperation: operation,
                state: .stagedLocationUnknown,
                originalError: error
            )
        }
        defer { close(stagingFD) }
        afterCreatingDirectoryStaging(stagingPath)
        do {
            _ = try entryMetadata(rootFD: rootFD, path: stagingPath)
            guard renameatx_np(
                rootFD,
                stagingName,
                rootFD,
                destination.string,
                secureRenameFlags
            ) == 0 else {
                let code = errno
                throw pathResolutionError(code: code, path: try currentURL(for: destination).path)
            }
        } catch {
            throw FileOperationRecoveryRequiredError(
                originalOperation: operation,
                state: stagedRecoveryState(stagingFD: stagingFD, rootFD: rootFD),
                originalError: error
            )
        }
    }

    private func validateAbsent(_ path: RelativePath, rootFD: Int32) throws {
        var metadata = stat()
        if fstatat(
            rootFD,
            path.string,
            &metadata,
            AT_SYMLINK_NOFOLLOW | AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH
        ) == 0 {
            throw posixError(code: EEXIST, path: try currentURL(for: path).path)
        }
        let code = errno
        guard code == ENOENT else {
            throw pathResolutionError(code: code, path: try currentURL(for: path).path)
        }
    }

    private func moveToUniqueStaging(
        source: RelativePath,
        prefix: String,
        rootFD: Int32
    ) throws -> RelativePath {
        while true {
            let candidate = try RelativePath(prefix + UUID().uuidString)
            if renameatx_np(
                rootFD,
                source.string,
                rootFD,
                candidate.string,
                secureRenameFlags
            ) == 0 {
                return candidate
            }
            let code = errno
            if code != EEXIST {
                throw pathResolutionError(code: code, path: try currentURL(for: source).path)
            }
        }
    }

    private func openStagedObject(rootFD: Int32, path: RelativePath) throws -> Int32 {
        let fd = openat(
            rootFD,
            path.string,
            O_EVTONLY | O_SYMLINK | O_RESOLVE_BENEATH | O_CLOEXEC
        )
        guard fd >= 0 else {
            throw pathResolutionError(code: errno, path: try currentURL(for: path).path)
        }
        return fd
    }

    private func stagedRecoveryState(
        stagingFD: Int32,
        rootFD: Int32
    ) -> FileOperationRecoveryState {
        guard let rootPath = try? pathForFD(rootFD),
              let objectPath = try? pathForFD(stagingFD)
        else {
            return .stagedLocationUnknown
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let object = URL(fileURLWithPath: objectPath).standardizedFileURL
        guard object.deletingLastPathComponent() == root,
              let relativePath = try? RelativePath(object.lastPathComponent)
        else {
            return .stagedLocationUnknown
        }
        var retainedMetadata = stat()
        guard fstat(stagingFD, &retainedMetadata) == 0,
              let currentMetadata = try? entryMetadata(rootFD: rootFD, path: relativePath),
              sameIdentity(retainedMetadata, currentMetadata),
              (try? pathForFD(stagingFD)) == objectPath
        else {
            return .stagedLocationUnknown
        }
        return .staged(relativePath)
    }

    private func validatedDirectory(_ directory: WorkspaceDirectory) throws -> WorkspaceDirectory {
        do {
            let valid = try directory.validated()
            if case let .relative(path) = valid, path.string.contains("\0") {
                throw FileOperationError.invalidPath
            }
            return valid
        } catch let error as FileOperationError {
            throw error
        } catch {
            throw FileOperationError.invalidPath
        }
    }

    private func validatedPath(_ path: RelativePath) throws -> RelativePath {
        do {
            guard !path.string.contains("\0") else { throw FileOperationError.invalidPath }
            return try RelativePath(path.string)
        } catch let error as FileOperationError {
            throw error
        } catch {
            throw FileOperationError.invalidPath
        }
    }

    private func validatedName(_ name: String) throws -> String {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\0")
        else {
            throw FileOperationError.invalidName
        }
        return name
    }

    private func split(_ path: RelativePath) -> (parent: WorkspaceDirectory, name: String) {
        let components = path.string.split(separator: "/").map(String.init)
        if components.count == 1 { return (.root, components[0]) }
        return (.relative(try! RelativePath(components.dropLast().joined(separator: "/"))), components.last!)
    }

    private func childPath(parent: WorkspaceDirectory, name: String) throws -> RelativePath {
        switch parent {
        case .root: try RelativePath(name)
        case let .relative(path): try RelativePath(path.string + "/" + name)
        }
    }

    private func entryMetadata(rootFD: Int32, path: RelativePath) throws -> stat {
        var metadata = stat()
        guard fstatat(
            rootFD,
            path.string,
            &metadata,
            AT_SYMLINK_NOFOLLOW | AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH
        ) == 0 else {
            let code = errno
            throw pathResolutionError(code: code, path: try currentURL(for: path).path)
        }
        return metadata
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode & mode_t(S_IFMT) == rhs.st_mode & mode_t(S_IFMT)
    }

    private func kind(for mode: mode_t) -> FileTreeEntryKind {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): .directory
        case mode_t(S_IFLNK): .symbolicLink
        default: .file
        }
    }

    private func currentURL(for path: RelativePath) throws -> URL {
        try currentRootURL()
            .appendingPathComponent(path.string)
    }

    private func currentRootURL() throws -> URL {
        URL(fileURLWithPath: try pathForFD(try openedRootFD()), isDirectory: true)
    }

    private func pathForFD(_ fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer {
            fcntl(fd, F_GETPATH, $0.baseAddress!)
        }
        guard result >= 0 else { throw posixError(code: errno, path: rootURL.path) }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func posixError(code: Int32, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    private func pathResolutionError(code: Int32, path: String) -> any Error {
        code == ELOOP
            ? FileOperationError.symbolicLinkTraversal
            : posixError(code: code, path: path)
    }
}

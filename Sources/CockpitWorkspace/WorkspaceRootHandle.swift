import Darwin
import Foundation
import CockpitHostCore
import CockpitTypes

struct PhysicalFileOperationResult: Sendable {
    let result: FileOperationResult
    let affectedKind: FileTreeEntryKind
    let trashURL: URL?
}

protocol FileOperationPhysicallyPerforming: Sendable {
    func perform(_ operation: FileOperation) async throws -> PhysicalFileOperationResult
}

final class WorkspaceRootHandle: FileOperationPhysicallyPerforming, @unchecked Sendable {
    private let rootURL: URL
    private let queue = DispatchQueue(label: "com.openai.cockpit.file-operation-io")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let beforeOpeningComponent: @Sendable (String) -> Void
    private let beforeTrashValidation: @Sendable (URL) -> Void
    private var rootFD: Int32 = -1

    init(
        rootURL: URL,
        beforeOpeningComponent: @escaping @Sendable (String) -> Void = { _ in },
        beforeTrashValidation: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.beforeOpeningComponent = beforeOpeningComponent
        self.beforeTrashValidation = beforeTrashValidation
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

    private func performSynchronously(
        _ operation: FileOperation
    ) throws -> PhysicalFileOperationResult {
        let rootFD = try openedRootFD()
        switch operation {
        case let .createFile(parent, name):
            let parent = try validatedDirectory(parent)
            let name = try validatedName(name)
            let parentFD = try openDirectory(parent, rootFD: rootFD)
            defer { close(parentFD) }
            let destination = try childPath(parent: parent, name: name)
            let fd = openat(
                parentFD,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
            )
            guard fd >= 0 else {
                let code = errno
                throw posixError(code: code, path: try currentURL(for: destination).path)
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
            let parentFD = try openDirectory(parent, rootFD: rootFD)
            defer { close(parentFD) }
            let destination = try childPath(parent: parent, name: name)
            guard mkdirat(
                parentFD,
                name,
                mode_t(S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
            ) == 0 else {
                let code = errno
                throw posixError(code: code, path: try currentURL(for: destination).path)
            }
            return PhysicalFileOperationResult(
                result: .created(path: destination, kind: .directory),
                affectedKind: .directory,
                trashURL: nil
            )

        case let .rename(source, newName):
            let source = try validatedPath(source)
            let newName = try validatedName(newName)
            let sourceParts = split(source)
            let sourceParentFD = try openDirectory(sourceParts.parent, rootFD: rootFD)
            defer { close(sourceParentFD) }
            let kind = try entryKind(parentFD: sourceParentFD, name: sourceParts.name, path: source)
            let destination = try childPath(parent: sourceParts.parent, name: newName)
            let destinationParentFD = try openDirectory(sourceParts.parent, rootFD: rootFD)
            defer { close(destinationParentFD) }
            guard renameatx_np(
                sourceParentFD,
                sourceParts.name,
                destinationParentFD,
                newName,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                let code = errno
                throw posixError(code: code, path: try currentURL(for: destination).path)
            }
            return PhysicalFileOperationResult(
                result: .relocated(from: source, to: destination),
                affectedKind: kind,
                trashURL: nil
            )

        case let .move(source, destinationDirectory):
            let source = try validatedPath(source)
            let destinationDirectory = try validatedDirectory(destinationDirectory)
            let sourceParts = split(source)
            let sourceParentFD = try openDirectory(sourceParts.parent, rootFD: rootFD)
            defer { close(sourceParentFD) }
            let kind = try entryKind(parentFD: sourceParentFD, name: sourceParts.name, path: source)
            if kind == .directory,
               case let .relative(destinationPath) = destinationDirectory,
               (destinationPath.string == source.string || destinationPath.string.hasPrefix(source.string + "/")) {
                throw FileOperationError.moveIntoDescendant
            }
            let destination = try childPath(parent: destinationDirectory, name: sourceParts.name)
            let destinationParentFD = try openDirectory(destinationDirectory, rootFD: rootFD)
            defer { close(destinationParentFD) }
            guard renameatx_np(
                sourceParentFD,
                sourceParts.name,
                destinationParentFD,
                sourceParts.name,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                let code = errno
                throw posixError(code: code, path: try currentURL(for: destination).path)
            }
            return PhysicalFileOperationResult(
                result: .relocated(from: source, to: destination),
                affectedKind: kind,
                trashURL: nil
            )

        case let .trash(path):
            let path = try validatedPath(path)
            let parts = split(path)
            let parentFD = try openDirectory(parts.parent, rootFD: rootFD)
            defer { close(parentFD) }
            var before = stat()
            guard fstatat(parentFD, parts.name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                let code = errno
                throw posixError(code: code, path: try currentURL(for: path).path)
            }
            let sourceURL = try URL(fileURLWithPath: pathForFD(parentFD), isDirectory: true)
                .appendingPathComponent(parts.name)
            beforeTrashValidation(sourceURL)
            var after = stat()
            guard lstat(sourceURL.path, &after) == 0 else {
                throw posixError(code: errno, path: sourceURL.path)
            }
            guard before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino,
                  before.st_mode & mode_t(S_IFMT) == after.st_mode & mode_t(S_IFMT)
            else {
                throw FileOperationError.identityChanged
            }
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: sourceURL, resultingItemURL: &resultingURL)
            let kind = kind(for: before.st_mode)
            return PhysicalFileOperationResult(
                result: .trashed(path: path),
                affectedKind: kind,
                trashURL: resultingURL as URL?
            )
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

    private func openDirectory(_ directory: WorkspaceDirectory, rootFD: Int32) throws -> Int32 {
        var current = dup(rootFD)
        guard current >= 0 else { throw posixError(code: errno, path: rootURL.path) }
        do {
            if case let .relative(path) = directory {
                for component in path.string.split(separator: "/").map(String.init) {
                    beforeOpeningComponent(component)
                    let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else {
                        let code = errno
                        var metadata = stat()
                        if fstatat(current, component, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                           metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                            throw FileOperationError.symbolicLinkTraversal
                        }
                        throw posixError(
                            code: code,
                            path: URL(fileURLWithPath: try pathForFD(current), isDirectory: true)
                                .appendingPathComponent(component).path
                        )
                    }
                    close(current)
                    current = next
                }
            }
            return current
        } catch {
            close(current)
            throw error
        }
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

    private func entryKind(
        parentFD: Int32,
        name: String,
        path: RelativePath
    ) throws -> FileTreeEntryKind {
        var metadata = stat()
        guard fstatat(parentFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            throw posixError(code: code, path: try currentURL(for: path).path)
        }
        return kind(for: metadata.st_mode)
    }

    private func kind(for mode: mode_t) -> FileTreeEntryKind {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): .directory
        case mode_t(S_IFLNK): .symbolicLink
        default: .file
        }
    }

    private func currentURL(for path: RelativePath) throws -> URL {
        URL(fileURLWithPath: try pathForFD(try openedRootFD()), isDirectory: true)
            .appendingPathComponent(path.string)
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
}

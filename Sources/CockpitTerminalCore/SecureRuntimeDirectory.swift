import Darwin
import Foundation

public struct SecureRuntimeFailure: Error, Equatable, Sendable {
    public let operation: String
    public let component: String
    public let code: Int32

    public init(operation: String, component: String, code: Int32) {
        self.operation = operation
        self.component = component
        self.code = code
    }
}

public enum SecureRuntimeDirectory {
    public static func prepare(at path: String) throws {
        try prepare(at: path, effectiveUserID: geteuid())
    }

    static func prepare(at path: String, effectiveUserID: uid_t) throws {
        try withVerifiedDirectory(at: path, effectiveUserID: effectiveUserID) { _ in }
    }

    public static func write(
        _ descriptor: KeeperRuntimeDescriptor,
        at path: String
    ) throws {
        let data = try JSONEncoder().encode(descriptor)
        let fileName = "\(descriptor.sessionID).\(descriptor.workerInstanceID).json"

        try withVerifiedDirectory(at: path, effectiveUserID: geteuid()) { directory in
            try replaceFile(
                named: fileName,
                with: data,
                in: directory
            )
        }
    }

    private static func withVerifiedDirectory<Result>(
        at path: String,
        effectiveUserID: uid_t,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        let components = try pathComponents(path)
        let rootDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw failure(operation: "open", component: "/")
        }

        var current = OwnedFileDescriptor(rootDescriptor)
        let currentStatus = try status(
            of: current.rawValue,
            operation: "fstat",
            component: "/"
        )
        var passedWorldWritableAncestor = isWorldWritable(currentStatus.st_mode)

        do {
            for (index, component) in components.enumerated() {
                var created = false
                var nextDescriptor = component.withCString {
                    openat(
                        current.rawValue,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }

                if nextDescriptor < 0, errno == ENOENT {
                    let makeResult = component.withCString {
                        mkdirat(current.rawValue, $0, S_IRWXU)
                    }
                    if makeResult == 0 {
                        created = true
                    } else if errno != EEXIST {
                        throw failure(operation: "mkdirat", component: component)
                    }

                    nextDescriptor = component.withCString {
                        openat(
                            current.rawValue,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                }

                guard nextDescriptor >= 0 else {
                    throw failure(operation: "openat", component: component)
                }

                let next = OwnedFileDescriptor(nextDescriptor)
                var nextStatus = try status(
                    of: next.rawValue,
                    operation: "fstat",
                    component: component
                )

                let isTrustedSystemOwner = !passedWorldWritableAncestor
                    && nextStatus.st_uid == 0
                guard nextStatus.st_uid == effectiveUserID || isTrustedSystemOwner else {
                    throw SecureRuntimeFailure(
                        operation: "validate-owner",
                        component: component,
                        code: EPERM
                    )
                }

                let isFinalComponent = index == components.indices.last
                if created || isFinalComponent {
                    guard nextStatus.st_uid == effectiveUserID else {
                        throw SecureRuntimeFailure(
                            operation: "validate-owner",
                            component: component,
                            code: EPERM
                        )
                    }
                    guard fchmod(next.rawValue, S_IRWXU) == 0 else {
                        throw failure(operation: "fchmod", component: component)
                    }
                    nextStatus = try status(
                        of: next.rawValue,
                        operation: "fstat",
                        component: component
                    )
                }

                if isFinalComponent {
                    guard nextStatus.st_uid == effectiveUserID else {
                        throw SecureRuntimeFailure(
                            operation: "validate-owner",
                            component: component,
                            code: EPERM
                        )
                    }
                    guard permissionBits(nextStatus.st_mode) == S_IRWXU else {
                        throw SecureRuntimeFailure(
                            operation: "validate-mode",
                            component: component,
                            code: EPERM
                        )
                    }
                }

                passedWorldWritableAncestor = passedWorldWritableAncestor
                    || isWorldWritable(nextStatus.st_mode)
                try current.close(operation: "close", component: component)
                current = next
            }

            let result = try body(current.rawValue)
            try current.close(operation: "close", component: components.last ?? "/")
            return result
        } catch {
            try? current.close(operation: "close", component: components.last ?? "/")
            throw error
        }
    }

    private static func replaceFile(
        named fileName: String,
        with data: Data,
        in directoryDescriptor: Int32
    ) throws {
        guard !fileName.isEmpty, !fileName.contains("/") else {
            throw SecureRuntimeFailure(
                operation: "validate-name",
                component: fileName,
                code: EINVAL
            )
        }

        let temporaryName = ".cockpit-descriptor.\(getpid()).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw failure(operation: "openat", component: temporaryName)
        }

        let temporaryFile = OwnedFileDescriptor(descriptor)
        var renamed = false
        do {
            guard fchmod(temporaryFile.rawValue, S_IRUSR | S_IWUSR) == 0 else {
                throw failure(operation: "fchmod", component: temporaryName)
            }
            try writeAll(data, to: temporaryFile.rawValue, component: temporaryName)
            try synchronize(temporaryFile.rawValue, component: temporaryName)
            try temporaryFile.close(operation: "close", component: temporaryName)

            let renameResult = temporaryName.withCString { temporary in
                fileName.withCString { destination in
                    renameat(
                        directoryDescriptor,
                        temporary,
                        directoryDescriptor,
                        destination
                    )
                }
            }
            guard renameResult == 0 else {
                throw failure(operation: "renameat", component: fileName)
            }
            renamed = true
        } catch {
            try? temporaryFile.close(operation: "close", component: temporaryName)
            if !renamed {
                let unlinkResult = temporaryName.withCString {
                    unlinkat(directoryDescriptor, $0, 0)
                }
                if unlinkResult != 0, errno != ENOENT {
                    throw failure(operation: "unlinkat", component: temporaryName)
                }
            }
            throw error
        }
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        component: String
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    let code = written == 0 ? EIO : errno
                    throw SecureRuntimeFailure(
                        operation: "write",
                        component: component,
                        code: code
                    )
                }
                offset += written
            }
        }
    }

    private static func synchronize(_ descriptor: Int32, component: String) throws {
        while true {
            let result = fsync(descriptor)
            if result == 0 { return }
            if errno == EINTR { continue }
            throw failure(operation: "fsync", component: component)
        }
    }

    private static func pathComponents(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw SecureRuntimeFailure(
                operation: "validate-path",
                component: path,
                code: EINVAL
            )
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw SecureRuntimeFailure(
                operation: "validate-path",
                component: path,
                code: EINVAL
            )
        }
        return components
    }

    private static func status(
        of descriptor: Int32,
        operation: String,
        component: String
    ) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw failure(operation: operation, component: component)
        }
        guard value.st_mode & S_IFMT == S_IFDIR else {
            throw SecureRuntimeFailure(
                operation: "validate-directory",
                component: component,
                code: ENOTDIR
            )
        }
        return value
    }

    private static func permissionBits(_ mode: mode_t) -> mode_t {
        mode & (S_IRWXU | S_IRWXG | S_IRWXO | S_ISUID | S_ISGID | S_ISVTX)
    }

    private static func isWorldWritable(_ mode: mode_t) -> Bool {
        mode & S_IWOTH != 0
    }

    private static func failure(
        operation: String,
        component: String
    ) -> SecureRuntimeFailure {
        SecureRuntimeFailure(operation: operation, component: component, code: errno)
    }
}

private final class OwnedFileDescriptor {
    private(set) var rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    func close(operation: String, component: String) throws {
        guard rawValue >= 0 else { return }
        let descriptor = rawValue
        rawValue = -1
        guard Darwin.close(descriptor) == 0 else {
            throw SecureRuntimeFailure(
                operation: operation,
                component: component,
                code: errno
            )
        }
    }

    deinit {
        if rawValue >= 0 {
            _ = Darwin.close(rawValue)
        }
    }
}

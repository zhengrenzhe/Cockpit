import Darwin
import Foundation
import CockpitTerminalCore

public struct KeeperLaunchFailure: Error, Equatable, Sendable {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }
}

public struct KeeperProcessLauncher: Sendable {
    public static let spawnFlags =
        Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)

    public let executablePath: String

    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    public func launch(_ bootstrap: KeeperBootstrap) throws -> KeeperLaunchReceipt {
        let payload = try JSONEncoder().encode(bootstrap)

        var pipeDescriptors = [Int32](repeating: -1, count: 2)
        let pipeResult = pipeDescriptors.withUnsafeMutableBufferPointer {
            Darwin.pipe($0.baseAddress)
        }
        guard pipeResult == 0 else {
            throw KeeperLaunchFailure(operation: "pipe", code: errno)
        }

        var readDescriptor = pipeDescriptors[0]
        var writeDescriptor = pipeDescriptors[1]

        if readDescriptor == KeeperBootstrap.inheritedFileDescriptor {
            let duplicated = fcntl(readDescriptor, F_DUPFD_CLOEXEC, 4)
            guard duplicated >= 0 else {
                let code = errno
                Darwin.close(readDescriptor)
                Darwin.close(writeDescriptor)
                throw KeeperLaunchFailure(operation: "fcntl", code: code)
            }
            Darwin.close(readDescriptor)
            readDescriptor = duplicated
        }

        if writeDescriptor == KeeperBootstrap.inheritedFileDescriptor {
            let duplicated = fcntl(writeDescriptor, F_DUPFD_CLOEXEC, 4)
            guard duplicated >= 0 else {
                let code = errno
                Darwin.close(readDescriptor)
                Darwin.close(writeDescriptor)
                throw KeeperLaunchFailure(operation: "fcntl", code: code)
            }
            Darwin.close(writeDescriptor)
            writeDescriptor = duplicated
        }

        let readHandle = FileHandle(
            fileDescriptor: readDescriptor,
            closeOnDealloc: true
        )
        let writeHandle = FileHandle(
            fileDescriptor: writeDescriptor,
            closeOnDealloc: true
        )

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?

        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else {
            throw KeeperLaunchFailure(
                operation: "posix_spawn_file_actions_init",
                code: result
            )
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        result = posix_spawnattr_init(&attributes)
        guard result == 0 else {
            throw KeeperLaunchFailure(operation: "posix_spawnattr_init", code: result)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        result = posix_spawn_file_actions_adddup2(
            &actions,
            readDescriptor,
            KeeperBootstrap.inheritedFileDescriptor
        )
        guard result == 0 else {
            throw KeeperLaunchFailure(
                operation: "posix_spawn_file_actions_adddup2",
                code: result
            )
        }

        result = posix_spawn_file_actions_addclose(&actions, readDescriptor)
        guard result == 0 else {
            throw KeeperLaunchFailure(
                operation: "posix_spawn_file_actions_addclose(read)",
                code: result
            )
        }

        result = posix_spawn_file_actions_addclose(&actions, writeDescriptor)
        guard result == 0 else {
            throw KeeperLaunchFailure(
                operation: "posix_spawn_file_actions_addclose(write)",
                code: result
            )
        }

        result = posix_spawnattr_setflags(&attributes, Self.spawnFlags)
        guard result == 0 else {
            throw KeeperLaunchFailure(operation: "posix_spawnattr_setflags", code: result)
        }

        var processID: pid_t = 0
        result = executablePath.withCString { executable in
            var arguments: [UnsafeMutablePointer<CChar>?] = [
                UnsafeMutablePointer(mutating: executable),
                nil,
            ]
            return arguments.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processID,
                    executable,
                    &actions,
                    &attributes,
                    buffer.baseAddress,
                    environ
                )
            }
        }

        try readHandle.close()

        guard result == 0 else {
            try? writeHandle.close()
            throw KeeperLaunchFailure(operation: "posix_spawn", code: result)
        }

        do {
            try writeHandle.write(contentsOf: payload)
            try writeHandle.close()
        } catch {
            let killResult = Darwin.kill(processID, SIGKILL)
            guard killResult == 0 || errno == ESRCH else {
                throw KeeperLaunchFailure(operation: "kill", code: errno)
            }
            throw error
        }

        return KeeperLaunchReceipt(
            sessionID: bootstrap.sessionID,
            workerInstanceID: bootstrap.workerInstanceID,
            processID: processID,
            runtimeDescriptorPath: bootstrap.runtimeDescriptorPath
        )
    }
}

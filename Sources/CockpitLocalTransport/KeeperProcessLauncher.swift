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

        guard fcntl(writeDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let code = errno
            Darwin.close(readDescriptor)
            Darwin.close(writeDescriptor)
            throw KeeperLaunchFailure(operation: "fcntl(F_SETNOSIGPIPE)", code: code)
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

        guard result == 0 else {
            try? readHandle.close()
            try? writeHandle.close()
            throw KeeperLaunchFailure(operation: "posix_spawn", code: result)
        }

        do {
            try readHandle.close()
            try KeeperControlFraming.write(bootstrap, to: writeDescriptor)
            try writeHandle.close()
        } catch {
            let launchError = error
            try? readHandle.close()
            try? writeHandle.close()
            try terminateAndReap(processID)
            throw launchError
        }

        return KeeperLaunchReceipt(
            sessionID: bootstrap.sessionID,
            workerInstanceID: bootstrap.workerInstanceID,
            processID: processID,
            runtimeDescriptorPath: bootstrap.runtimeDescriptorPath
        )
    }
}

extension KeeperProcessLauncher: KeeperLaunching {
    public func launch(_ bootstrap: KeeperBootstrap) async throws -> LaunchedKeeper {
        _ = try bootstrap.validated()
        var pair = try KeeperControlFraming.makeSocketPair()
        do {
            pair.parent = try moveAwayFromBootstrapDescriptor(pair.parent)
            pair.child = try moveAwayFromBootstrapDescriptor(pair.child)
        } catch {
            Darwin.close(pair.parent)
            Darwin.close(pair.child)
            throw error
        }
        var parentOwned = true
        var childOwned = true
        defer {
            if parentOwned { Darwin.close(pair.parent) }
            if childOwned { Darwin.close(pair.child) }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else {
            throw KeeperLaunchFailure(operation: "posix_spawn_file_actions_init", code: result)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        result = posix_spawnattr_init(&attributes)
        guard result == 0 else {
            throw KeeperLaunchFailure(operation: "posix_spawnattr_init", code: result)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        result = posix_spawn_file_actions_adddup2(
            &actions,
            pair.child,
            KeeperBootstrap.inheritedFileDescriptor
        )
        guard result == 0 else {
            throw KeeperLaunchFailure(operation: "posix_spawn_file_actions_adddup2", code: result)
        }
        for descriptor in [pair.parent, pair.child] {
            result = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard result == 0 else {
                throw KeeperLaunchFailure(operation: "posix_spawn_file_actions_addclose", code: result)
            }
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
        guard result == 0 else {
            throw KeeperLaunchFailure(operation: "posix_spawn", code: result)
        }
        Darwin.close(pair.child)
        childOwned = false
        do {
            try KeeperControlFraming.write(bootstrap, to: pair.parent)
        } catch {
            Darwin.close(pair.parent)
            parentOwned = false
            try? terminateAndReap(processID)
            throw error
        }
        parentOwned = false
        return LaunchedKeeper(
            sessionID: bootstrap.sessionID,
            workerID: bootstrap.workerInstanceID,
            processID: processID,
            bootstrapControlDescriptor: pair.parent,
            runtimeDescriptorPath: bootstrap.runtimeDescriptorPath
        )
    }
}

private func moveAwayFromBootstrapDescriptor(_ descriptor: Int32) throws -> Int32 {
    guard descriptor == KeeperBootstrap.inheritedFileDescriptor else { return descriptor }
    let duplicated = fcntl(descriptor, F_DUPFD_CLOEXEC, 4)
    guard duplicated >= 0 else {
        throw KeeperLaunchFailure(operation: "fcntl(F_DUPFD_CLOEXEC)", code: errno)
    }
    Darwin.close(descriptor)
    return duplicated
}

private func terminateAndReap(_ processID: pid_t) throws {
    let killResult = Darwin.kill(processID, SIGKILL)
    guard killResult == 0 || errno == ESRCH else {
        throw KeeperLaunchFailure(operation: "kill", code: errno)
    }

    var status: Int32 = 0
    let maximumAttempts = 100

    for attempt in 0..<maximumAttempts {
        let waitResult = waitpid(processID, &status, WNOHANG)
        if waitResult == processID {
            return
        }
        if waitResult < 0 {
            let code = errno
            if code == ECHILD {
                return
            }
            if code != EINTR {
                throw KeeperLaunchFailure(operation: "waitpid", code: code)
            }
        }

        if attempt + 1 < maximumAttempts {
            var delay = timespec(tv_sec: 0, tv_nsec: 10_000_000)
            _ = nanosleep(&delay, nil)
        }
    }

    throw KeeperLaunchFailure(operation: "waitpid", code: ETIMEDOUT)
}

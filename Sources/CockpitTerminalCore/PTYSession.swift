import Darwin
import Foundation
import CockpitTypes

public struct PTYSessionFailure: Error, Equatable, Sendable {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }
}

public final class PTYSession: @unchecked Sendable {
    public static let spawnFlags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)

    public let identity: CLIProcessIdentity
    public let masterFileDescriptor: Int32
    private let lock = NSLock()
    private var waitStatus: Int32?
    private var closed = false

    private init(identity: CLIProcessIdentity, masterFileDescriptor: Int32) {
        self.identity = identity
        self.masterFileDescriptor = masterFileDescriptor
    }

    deinit {
        lock.withLock {
            if !closed {
                _ = Darwin.close(masterFileDescriptor)
                closed = true
            }
        }
    }

    public static func start(
        _ launchSpec: LaunchSpec,
        trampolineExecutablePath: String? = nil
    ) throws -> PTYSession {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: Int(PATH_MAX))
        var size = winsize(
            ws_row: launchSpec.terminalSize.rows,
            ws_col: launchSpec.terminalSize.columns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&master, &slave, &name, nil, &size) == 0 else {
            throw failure("openpty")
        }
        var masterOwned = true
        var slaveOwned = true
        defer {
            if masterOwned { Darwin.close(master) }
            if slaveOwned { Darwin.close(slave) }
        }
        guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0 else {
            throw failure("fcntl(FD_CLOEXEC)")
        }
        let slavePath = String(
            decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard Darwin.close(slave) == 0 else { throw failure("close(slave)") }
        slaveOwned = false

        var handshake = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&handshake) == 0 else { throw failure("pipe") }
        let handshakeRead = try moveDescriptor(handshake[0], minimum: 5)
        let handshakeWrite = try moveDescriptor(handshake[1], minimum: 5)
        var handshakeReadOwned = true
        var handshakeWriteOwned = true
        defer {
            if handshakeReadOwned { Darwin.close(handshakeRead) }
            if handshakeWriteOwned { Darwin.close(handshakeWrite) }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else { throw PTYSessionFailure(operation: "file-actions-init", code: code) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        code = posix_spawnattr_init(&attributes)
        guard code == 0 else { throw PTYSessionFailure(operation: "spawnattr-init", code: code) }
        defer { posix_spawnattr_destroy(&attributes) }

        code = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slavePath, O_RDWR, 0)
        guard code == 0 else { throw PTYSessionFailure(operation: "addopen(slave)", code: code) }
        code = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
        guard code == 0 else { throw PTYSessionFailure(operation: "dup2(stdout)", code: code) }
        code = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)
        guard code == 0 else { throw PTYSessionFailure(operation: "dup2(stderr)", code: code) }
        if #available(macOS 26.0, *) {
            code = posix_spawn_file_actions_addchdir(&actions, launchSpec.workspaceRoot)
        } else {
            code = posix_spawn_file_actions_addchdir_np(&actions, launchSpec.workspaceRoot)
        }
        guard code == 0 else { throw PTYSessionFailure(operation: "addchdir", code: code) }
        code = posix_spawn_file_actions_adddup2(&actions, handshakeWrite, 4)
        guard code == 0 else { throw PTYSessionFailure(operation: "dup2(handshake)", code: code) }
        for descriptor in [handshakeRead, handshakeWrite] {
            code = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard code == 0 else {
                throw PTYSessionFailure(operation: "close(handshake)", code: code)
            }
        }
        code = posix_spawnattr_setflags(&attributes, spawnFlags)
        guard code == 0 else { throw PTYSessionFailure(operation: "setflags", code: code) }

        let command = launchSpec.executableAndArguments
        let trampoline = try trampolineExecutablePath ?? defaultTrampolineExecutable()
        let trampolineArguments = [
            trampoline,
            "--cockpit-pty-child",
            command.executable,
        ] + command.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in launchSpec.environmentOverrides { environment[key] = value }
        let environmentStrings = environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
        var processID: pid_t = 0
        code = withCStringArray(trampolineArguments) { arguments in
            withCStringArray(environmentStrings) { environment in
                trampoline.withCString { executable in
                    posix_spawn(
                        &processID,
                        executable,
                        &actions,
                        &attributes,
                        arguments,
                        environment
                    )
                }
            }
        }
        guard code == 0 else { throw PTYSessionFailure(operation: "posix_spawn", code: code) }
        Darwin.close(handshakeWrite)
        handshakeWriteOwned = false
        guard ioctl(master, TIOCSWINSZ, &size) == 0 else {
            _ = Darwin.kill(-processID, SIGKILL)
            throw failure("ioctl(TIOCSWINSZ)")
        }
        do {
            try waitForTrampoline(handshakeRead)
            Darwin.close(handshakeRead)
            handshakeReadOwned = false
        } catch {
            _ = Darwin.kill(-processID, SIGKILL)
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0, errno == EINTR {}
            throw error
        }
        let identity = try CLIProcessIdentity(
            validatingProcessID: processID,
            processGroupID: processID
        )
        masterOwned = false
        return PTYSession(identity: identity, masterFileDescriptor: master)
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    masterFileDescriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.failure("write") }
                offset += count
            }
        }
    }

    public func resize(_ size: TerminalResize) throws {
        var value = winsize(
            ws_row: size.rows,
            ws_col: size.columns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(masterFileDescriptor, TIOCSWINSZ, &value) == 0 else {
            throw Self.failure("ioctl(TIOCSWINSZ)")
        }
    }

    public func terminate(force: Bool) throws {
        let signal = force ? SIGKILL : SIGTERM
        guard Darwin.kill(-identity.processGroupID, signal) == 0 || errno == ESRCH else {
            throw Self.failure("killpg")
        }
    }

    public func readUntilExit(timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while Date() < deadline {
            var descriptor = pollfd(fd: masterFileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            let result = poll(&descriptor, 1, min(remaining, 100))
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw Self.failure("poll") }
            if result == 0 { continue }
            let count = Darwin.read(masterFileDescriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 || (count < 0 && errno == EIO) { break }
            if count < 0, errno == EINTR { continue }
            throw Self.failure("read")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func waitForExit(timeout: TimeInterval) throws -> Int32 {
        if let status = lock.withLock({ waitStatus }) { return status }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(identity.processID, &status, WNOHANG)
            if result == identity.processID {
                lock.withLock { waitStatus = status }
                return status
            }
            if result < 0, errno == EINTR { continue }
            if result < 0 { throw Self.failure("waitpid") }
            usleep(10_000)
        }
        throw PTYSessionFailure(operation: "waitpid", code: ETIMEDOUT)
    }

    private static func failure(_ operation: String) -> PTYSessionFailure {
        PTYSessionFailure(operation: operation, code: errno)
    }

    public static func execChildTrampoline(
        executablePath: String,
        arguments: [String]
    ) throws -> Never {
        guard !arguments.isEmpty else {
            throw PTYSessionFailure(operation: "trampoline-argv", code: EINVAL)
        }
        guard ioctl(STDIN_FILENO, TIOCSCTTY, 0) == 0 else {
            throw failure("ioctl(TIOCSCTTY)")
        }
        guard tcsetpgrp(STDIN_FILENO, getpid()) == 0 else {
            throw failure("tcsetpgrp")
        }
        var ready: UInt8 = 1
        guard Darwin.write(4, &ready, 1) == 1 else {
            throw failure("write(trampoline-ready)")
        }
        guard Darwin.close(4) == 0 else { throw failure("close(trampoline-ready)") }
        withCStringArray(arguments) { argv in
            executablePath.withCString { executable in
                _ = Darwin.execve(executable, argv, environ)
            }
        }
        throw failure("execve")
    }

    private static func defaultTrampolineExecutable() throws -> String {
        if let configured = ProcessInfo.processInfo.environment["COCKPIT_PTY_TRAMPOLINE"],
           isPhysicalExecutable(configured) {
            return configured
        }
        let buildCandidate = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build/debug/CockpitPTYKeeper").path
        if isPhysicalExecutable(buildCandidate) { return buildCandidate }
        var cursor = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        for _ in 0..<8 {
            let candidate = cursor.deletingLastPathComponent()
                .appendingPathComponent("CockpitPTYKeeper").path
            if isPhysicalExecutable(candidate) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw PTYSessionFailure(operation: "locate-trampoline", code: ENOENT)
    }

    private static func isPhysicalExecutable(_ path: String) -> Bool {
        var status = stat()
        return path.hasPrefix("/")
            && lstat(path, &status) == 0
            && status.st_mode & S_IFMT == S_IFREG
            && access(path, X_OK) == 0
    }

    private static func moveDescriptor(_ descriptor: Int32, minimum: Int32) throws -> Int32 {
        guard descriptor < minimum else { return descriptor }
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, minimum)
        guard duplicate >= 0 else { throw failure("fcntl(F_DUPFD_CLOEXEC)") }
        Darwin.close(descriptor)
        return duplicate
    }

    private static func waitForTrampoline(_ descriptor: Int32) throws {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        while true {
            let result = poll(&pollDescriptor, 1, 5_000)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw PTYSessionFailure(operation: "trampoline-ready", code: result == 0 ? ETIMEDOUT : errno)
            }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1, byte == 1 else {
                throw PTYSessionFailure(operation: "trampoline-ready", code: EPROTO)
            }
            return
        }
    }
}

private func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> Result
) rethrows -> Result {
    var pointers = strings.map { strdup($0) as UnsafeMutablePointer<CChar>? }
    pointers.append(nil)
    defer {
        for pointer in pointers where pointer != nil { free(pointer) }
    }
    return try pointers.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress)
    }
}

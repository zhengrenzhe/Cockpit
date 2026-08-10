import Darwin
import Foundation
import CockpitTypes

public enum KeeperBootstrapError: Error, Equatable, Sendable {
    case invalidNonce
    case invalidWorkerSecret
    case invalidRoot
    case invalidRuntimeDirectory
}

public enum KeeperBootstrapMode: String, Codable, Sendable {
    case session
    case probe
}

public struct KeeperBootstrap: Codable, Equatable, Sendable {
    public static let inheritedFileDescriptor: Int32 = 3
    public static let bootstrapTimeoutNanoseconds: UInt64 = 30_000_000_000

    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID
    public let launchSpec: LaunchSpec
    public let startNonce: Data
    public let applicationSupportRoot: String
    public let terminalArchivesRoot: String
    public let runtimeDirectory: String
    public let workerSecret: Data
    public let mode: KeeperBootstrapMode

    public init(
        sessionID: TerminalSessionID,
        workerInstanceID: WorkerInstanceID,
        launchSpec: LaunchSpec,
        startNonce: Data,
        applicationSupportRoot: String,
        terminalArchivesRoot: String,
        runtimeDirectory: String,
        workerSecret: Data
    ) throws {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
        self.launchSpec = launchSpec
        self.startNonce = startNonce
        self.applicationSupportRoot = applicationSupportRoot
        self.terminalArchivesRoot = terminalArchivesRoot
        self.runtimeDirectory = runtimeDirectory
        self.workerSecret = workerSecret
        self.mode = .session
        _ = try validated()
    }

    public init(
        sessionID: TerminalSessionID,
        workerInstanceID: WorkerInstanceID,
        runtimeDirectory: String
    ) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
        self.launchSpec = try! LaunchSpec(
            kind: .shell,
            loginShellPath: "/bin/zsh",
            executablePath: "/bin/zsh",
            arguments: [],
            workspaceRoot: "/",
            terminalSize: try! TerminalResize(validatingColumns: 80, rows: 24),
            environmentOverrides: [:]
        )
        self.startNonce = Data(repeating: 0, count: 16)
        self.applicationSupportRoot = runtimeDirectory
        self.terminalArchivesRoot = URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
            .appendingPathComponent("TerminalArchives", isDirectory: true).path
        self.runtimeDirectory = runtimeDirectory
        self.workerSecret = Data(repeating: 0, count: 32)
        self.mode = .probe
    }

    public var runtimeDescriptorPath: String {
        URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
            .appendingPathComponent("\(sessionID).\(workerInstanceID).json")
            .path
    }

    public func validated(effectiveUserID: uid_t = geteuid()) throws -> Self {
        guard LaunchSpec.isCanonicalAbsolutePath(runtimeDirectory) else {
            throw KeeperBootstrapError.invalidRuntimeDirectory
        }
        if mode == .probe { return self }
        guard startNonce.count == 16 else { throw KeeperBootstrapError.invalidNonce }
        guard workerSecret.count == 32 else { throw KeeperBootstrapError.invalidWorkerSecret }
        guard LaunchSpec.isCanonicalAbsolutePath(applicationSupportRoot),
              LaunchSpec.isCanonicalAbsolutePath(terminalArchivesRoot),
              terminalArchivesRoot == URL(
                fileURLWithPath: applicationSupportRoot,
                isDirectory: true
              ).appendingPathComponent("TerminalArchives", isDirectory: true).path,
              Self.isOwnedPhysicalDirectory(applicationSupportRoot, effectiveUserID: effectiveUserID),
              Self.isOwnedPhysicalDirectory(terminalArchivesRoot, effectiveUserID: effectiveUserID)
        else {
            throw KeeperBootstrapError.invalidRoot
        }
        return self
    }

    public func openVerifiedRoots() throws -> KeeperVerifiedRoots {
        _ = try validated()
        guard mode == .session else { throw KeeperBootstrapError.invalidRoot }
        return try KeeperVerifiedRoots(paths: [applicationSupportRoot, terminalArchivesRoot])
    }

    private static func isOwnedPhysicalDirectory(
        _ path: String,
        effectiveUserID: uid_t
    ) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
            && status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == effectiveUserID
    }
}

public final class KeeperVerifiedRoots: @unchecked Sendable {
    private var descriptors: [Int32]
    public var count: Int { descriptors.count }

    fileprivate init(paths: [String]) throws {
        var opened: [Int32] = []
        do {
            for path in paths {
                let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw KeeperBootstrapError.invalidRoot }
                opened.append(descriptor)
            }
            descriptors = opened
        } catch {
            for descriptor in opened { Darwin.close(descriptor) }
            throw error
        }
    }

    deinit {
        for descriptor in descriptors { Darwin.close(descriptor) }
    }
}

public struct KeeperProbeRequest: Codable, Equatable, Sendable {
    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID

    public init(sessionID: TerminalSessionID, workerInstanceID: WorkerInstanceID) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
    }
}

public struct KeeperLaunchReceipt: Codable, Equatable, Sendable {
    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID
    public let processID: Int32
    public let runtimeDescriptorPath: String

    public init(
        sessionID: TerminalSessionID,
        workerInstanceID: WorkerInstanceID,
        processID: Int32,
        runtimeDescriptorPath: String
    ) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
        self.processID = processID
        self.runtimeDescriptorPath = runtimeDescriptorPath
    }
}

public struct KeeperRuntimeDescriptor: Codable, Equatable, Sendable {
    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID
    public let processID: Int32
    public let processGroupID: Int32
    public let endpoint: KeeperEndpoint?

    public init(
        sessionID: TerminalSessionID,
        workerInstanceID: WorkerInstanceID,
        processID: Int32,
        processGroupID: Int32,
        endpoint: KeeperEndpoint? = nil
    ) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
        self.processID = processID
        self.processGroupID = processGroupID
        self.endpoint = endpoint
    }
}

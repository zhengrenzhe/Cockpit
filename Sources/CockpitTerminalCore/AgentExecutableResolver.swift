import Darwin
import Foundation

public enum AgentExecutableResolverError: Error, Equatable, Sendable {
    case agentExecutableSelectionRequired
    case resolutionFailed
}

typealias AgentCommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ environment: [String: String]
) async throws -> String

public struct AgentExecutableResolver: Sendable {
    private let repository: any AgentExecutableRepository
    private let effectiveUserID: uid_t
    private let commandRunner: AgentCommandRunner

    public init(repository: any AgentExecutableRepository) {
        self.init(
            repository: repository,
            effectiveUserID: geteuid(),
            commandRunner: Self.runCommand
        )
    }

    init(
        repository: any AgentExecutableRepository,
        effectiveUserID: uid_t,
        commandRunner: @escaping AgentCommandRunner
    ) {
        self.repository = repository
        self.effectiveUserID = effectiveUserID
        self.commandRunner = commandRunner
    }

    public func resolve(
        profileID: AgentProfileID,
        loginShellPath: String,
        selectedExecutablePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> String {
        if let selectedExecutablePath {
            guard let canonical = Self.canonicalExecutable(selectedExecutablePath),
                  Self.isExecutable(canonical, effectiveUserID: effectiveUserID)
            else {
                throw AgentExecutableResolverError.agentExecutableSelectionRequired
            }
            try await repository.storeCanonicalExecutable(canonical, for: profileID)
            return canonical
        }

        if let stored = try await repository.canonicalExecutable(for: profileID) {
            guard Self.isExecutable(stored, effectiveUserID: effectiveUserID) else {
                throw AgentExecutableResolverError.agentExecutableSelectionRequired
            }
            return stored
        }

        let output: String
        do {
            output = try await commandRunner(
                loginShellPath,
                [
                    "-l",
                    "-c",
                    "command -v -- \"$1\"",
                    "cockpit-resolve",
                    profileID.rawValue,
                ],
                environment
            )
        } catch {
            throw AgentExecutableResolverError.agentExecutableSelectionRequired
        }
        let lines = output.split(whereSeparator: \ .isNewline).map(String.init)
        guard lines.count == 1,
              let canonical = Self.canonicalExecutable(lines[0]),
              Self.isExecutable(canonical, effectiveUserID: effectiveUserID)
        else {
            throw AgentExecutableResolverError.agentExecutableSelectionRequired
        }
        try await repository.storeCanonicalExecutable(canonical, for: profileID)
        return canonical
    }

    private static func canonicalExecutable(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &resolved) != nil else { return nil }
        let canonical = String(
            decoding: resolved.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return LaunchSpec.isCanonicalAbsolutePath(canonical) ? canonical : nil
    }

    private static func isExecutable(_ path: String, effectiveUserID: uid_t) -> Bool {
        guard let canonical = canonicalExecutable(path), canonical == path else { return false }
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == effectiveUserID || access(path, X_OK) == 0
        else {
            return false
        }
        return access(path, X_OK) == 0
    }

    private static func runCommand(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw AgentExecutableResolverError.resolutionFailed
        }
        return String(
            decoding: try output.fileHandleForReading.readToEnd() ?? Data(),
            as: UTF8.self
        )
    }
}

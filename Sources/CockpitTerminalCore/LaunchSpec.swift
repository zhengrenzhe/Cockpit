import Foundation
import CockpitTypes

public enum LaunchSpecError: Error, Equatable, Sendable {
    case invalidAbsolutePath
    case invalidEnvironmentOverride
    case invalidExecutableForKind
}

public enum TerminalKind: Hashable, Codable, Sendable {
    case shell
    case agent(AgentProfileID)
}

public struct LaunchSpec: Hashable, Codable, Sendable {
    public let kind: TerminalKind
    public let loginShellPath: String
    public let executablePath: String
    public let arguments: [String]
    public let workspaceRoot: String
    public let terminalSize: TerminalResize
    public let environmentOverrides: [String: String]

    public init(
        kind: TerminalKind,
        loginShellPath: String,
        executablePath: String,
        arguments: [String],
        workspaceRoot: String,
        terminalSize: TerminalResize,
        environmentOverrides: [String: String]
    ) throws {
        guard Self.isCanonicalAbsolutePath(loginShellPath),
              Self.isCanonicalAbsolutePath(executablePath),
              Self.isCanonicalAbsolutePath(workspaceRoot),
              arguments.allSatisfy({ !$0.contains("\0") })
        else {
            throw LaunchSpecError.invalidAbsolutePath
        }
        guard environmentOverrides.allSatisfy({ key, value in
            !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
        }) else {
            throw LaunchSpecError.invalidEnvironmentOverride
        }
        if case .shell = kind, executablePath != loginShellPath {
            throw LaunchSpecError.invalidExecutableForKind
        }
        self.kind = kind
        self.loginShellPath = loginShellPath
        self.executablePath = executablePath
        self.arguments = arguments
        self.workspaceRoot = workspaceRoot
        self.terminalSize = try TerminalResize(
            validatingColumns: UInt32(terminalSize.columns),
            rows: UInt32(terminalSize.rows)
        )
        self.environmentOverrides = environmentOverrides
    }

    public var executableAndArguments: (executable: String, arguments: [String]) {
        switch kind {
        case .shell:
            let name = URL(fileURLWithPath: loginShellPath).lastPathComponent
            return (loginShellPath, ["-\(name)"])
        case .agent:
            return (
                loginShellPath,
                [
                    loginShellPath,
                    "-l",
                    "-c",
                    "exec \"$@\"",
                    "cockpit-agent",
                    executablePath,
                ] + arguments
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, loginShellPath, executablePath, arguments, workspaceRoot
        case terminalSize, environmentOverrides
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(TerminalKind.self, forKey: .kind),
            loginShellPath: container.decode(String.self, forKey: .loginShellPath),
            executablePath: container.decode(String.self, forKey: .executablePath),
            arguments: container.decode([String].self, forKey: .arguments),
            workspaceRoot: container.decode(String.self, forKey: .workspaceRoot),
            terminalSize: container.decode(TerminalResize.self, forKey: .terminalSize),
            environmentOverrides: container.decode([String: String].self, forKey: .environmentOverrides)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        let valid = try Self(
            kind: kind,
            loginShellPath: loginShellPath,
            executablePath: executablePath,
            arguments: arguments,
            workspaceRoot: workspaceRoot,
            terminalSize: terminalSize,
            environmentOverrides: environmentOverrides
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.kind, forKey: .kind)
        try container.encode(valid.loginShellPath, forKey: .loginShellPath)
        try container.encode(valid.executablePath, forKey: .executablePath)
        try container.encode(valid.arguments, forKey: .arguments)
        try container.encode(valid.workspaceRoot, forKey: .workspaceRoot)
        try container.encode(valid.terminalSize, forKey: .terminalSize)
        try container.encode(valid.environmentOverrides, forKey: .environmentOverrides)
    }

    static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        if path == "/" { return true }
        guard !path.hasSuffix("/"), !path.hasPrefix("//") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public struct CreateTerminalSessionRequest: Hashable, Codable, Sendable {
    public let contextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let launchSpec: LaunchSpec
    public let idempotencyKey: RequestID

    public init(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        launchSpec: LaunchSpec,
        idempotencyKey: RequestID
    ) {
        self.contextID = contextID
        self.environmentID = environmentID
        self.launchSpec = launchSpec
        self.idempotencyKey = idempotencyKey
    }
}

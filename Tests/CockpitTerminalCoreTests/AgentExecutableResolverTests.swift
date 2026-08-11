import Darwin
import Foundation
import Testing
import CockpitTypes
@testable import CockpitTerminalCore

@Suite("AgentExecutableResolverTests")
struct AgentExecutableResolverTests {
    @Test func firstResolutionUsesFixedLoginShellArgumentsAndPersistsCanonicalPath() async throws {
        let repository = MemoryAgentExecutableRepository()
        let fixture = try fixtureExecutable(named: "codex")
        let calls = AgentCommandCalls()
        let resolver = AgentExecutableResolver(
            repository: repository,
            effectiveUserID: geteuid(),
            commandRunner: { executable, arguments, environment in
                await calls.append(executable: executable, arguments: arguments, environment: environment)
                return fixture.path + "\n"
            }
        )

        let result = try await resolver.resolve(
            profileID: .codex,
            loginShellPath: "/bin/zsh",
            environment: ["PATH": fixture.deletingLastPathComponent().path]
        )

        #expect(result == fixture.path)
        #expect(await repository.canonicalExecutable(for: .codex) == fixture.path)
        let call = try #require(await calls.values.first)
        #expect(call.executable == "/bin/zsh")
        #expect(call.arguments == [
            "-l", "-c", "command -v -- \"$1\"", "cockpit-resolve", "codex",
        ])
        #expect(call.environment["PATH"] == fixture.deletingLastPathComponent().path)
    }

    @Test func storedExecutableIsRevalidatedWithoutRunningUserAgentOrFallingBack() async throws {
        let repository = MemoryAgentExecutableRepository()
        let fixture = try fixtureExecutable(named: "claude")
        try await repository.storeCanonicalExecutable(fixture.path, for: .claude)
        let calls = AgentCommandCalls()
        let resolver = AgentExecutableResolver(
            repository: repository,
            effectiveUserID: geteuid(),
            commandRunner: { executable, arguments, environment in
                await calls.append(executable: executable, arguments: arguments, environment: environment)
                return "unexpected"
            }
        )

        #expect(try await resolver.resolve(
            profileID: .claude,
            loginShellPath: "/bin/zsh"
        ) == fixture.path)
        #expect(await calls.values.isEmpty)

        let symlink = fixture.deletingLastPathComponent().appendingPathComponent("claude-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture)
        defer { try? FileManager.default.removeItem(at: symlink) }
        try await repository.storeCanonicalExecutable(symlink.path, for: .claude)
        await #expect(throws: AgentExecutableResolverError.agentExecutableSelectionRequired) {
            _ = try await resolver.resolve(profileID: .claude, loginShellPath: "/bin/zsh")
        }
        #expect(await calls.values.isEmpty)
    }

    @Test func selectedExecutableIsCanonicalizedPersistedAndSkipsLoginShellResolution() async throws {
        let repository = MemoryAgentExecutableRepository()
        let fixture = try fixtureExecutable(named: "codex")
        let calls = AgentCommandCalls()
        let resolver = AgentExecutableResolver(
            repository: repository,
            effectiveUserID: geteuid(),
            commandRunner: { executable, arguments, environment in
                await calls.append(
                    executable: executable,
                    arguments: arguments,
                    environment: environment
                )
                return "unexpected"
            }
        )

        let result = try await resolver.resolve(
            profileID: .codex,
            loginShellPath: "/bin/zsh",
            selectedExecutablePath: fixture.path
        )

        #expect(result == fixture.path)
        #expect(await repository.canonicalExecutable(for: .codex) == fixture.path)
        #expect(await calls.values.isEmpty)

        let symlink = fixture.deletingLastPathComponent()
            .appendingPathComponent("selected-codex-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture)
        defer { try? FileManager.default.removeItem(at: symlink) }
        #expect(try await resolver.resolve(
            profileID: .codex,
            loginShellPath: "/bin/zsh",
            selectedExecutablePath: symlink.path
        ) == fixture.path)
        #expect(await repository.canonicalExecutable(for: .codex) == fixture.path)

        await #expect(throws: AgentExecutableResolverError.agentExecutableSelectionRequired) {
            _ = try await resolver.resolve(
                profileID: .codex,
                loginShellPath: "/bin/zsh",
                selectedExecutablePath: fixture.deletingLastPathComponent().path
            )
        }
        #expect(await repository.canonicalExecutable(for: .codex) == fixture.path)
        #expect(await calls.values.isEmpty)
    }

    @Test func launchSpecBuildsOnlyFrozenShellAndAgentArgv() throws {
        let size = try TerminalResize(validatingColumns: 100, rows: 40)
        let shell = try LaunchSpec(
            kind: .shell,
            loginShellPath: "/bin/zsh",
            executablePath: "/bin/zsh",
            arguments: [],
            workspaceRoot: "/private/tmp/workspace",
            terminalSize: size,
            environmentOverrides: ["TERM": "xterm-256color"]
        )
        #expect(shell.executableAndArguments == (
            executable: "/bin/zsh",
            arguments: ["-zsh"]
        ))

        let agent = try LaunchSpec(
            kind: .agent(.codex),
            loginShellPath: "/bin/zsh",
            executablePath: "/usr/local/bin/codex",
            arguments: ["--resume", "safe value;$(false)"],
            workspaceRoot: "/private/tmp/workspace",
            terminalSize: size,
            environmentOverrides: [:]
        )
        #expect(agent.executableAndArguments == (
            executable: "/bin/zsh",
            arguments: [
                "/bin/zsh", "-l", "-c", "exec \"$@\"", "cockpit-agent",
                "/usr/local/bin/codex", "--resume", "safe value;$(false)",
            ]
        ))
    }
}

private actor MemoryAgentExecutableRepository: AgentExecutableRepository {
    private var paths: [AgentProfileID: String] = [:]

    func storeCanonicalExecutable(_ path: String, for profileID: AgentProfileID) {
        paths[profileID] = path
    }

    func canonicalExecutable(for profileID: AgentProfileID) -> String? {
        paths[profileID]
    }
}

private actor AgentCommandCalls {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    private(set) var values: [Call] = []

    func append(executable: String, arguments: [String], environment: [String: String]) {
        values.append(Call(executable: executable, arguments: arguments, environment: environment))
    }
}

private func fixtureExecutable(named name: String) throws -> URL {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let fixture = root.appendingPathComponent("Fixtures/Agents/\(name)").standardizedFileURL
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    return fixture
}

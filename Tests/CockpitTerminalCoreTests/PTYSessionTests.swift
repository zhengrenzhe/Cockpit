import Darwin
import Foundation
import Testing
import CockpitTypes
@testable import CockpitTerminalCore

@Suite("PTYSessionTests")
struct PTYSessionTests {
    @Test func realPTYOwnsSessionProcessGroupCwdResizeAndOnlyDeclaredDescriptors() throws {
        let fixtureRoot = try temporaryDirectory(prefix: "cockpit-pty")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let probe = fixtureRoot.appendingPathComponent("fd-probe")
        let source = fixturesRoot().appendingPathComponent("fd-probe.c")
        try run("/usr/bin/clang", [source.path, "-o", probe.path])

        let spec = try LaunchSpec(
            kind: .agent(.codex),
            loginShellPath: "/bin/zsh",
            executablePath: probe.path,
            arguments: [],
            workspaceRoot: fixtureRoot.path,
            terminalSize: try TerminalResize(validatingColumns: 91, rows: 37),
            environmentOverrides: ["TERM": "xterm-256color"]
        )
        let session = try PTYSession.start(spec)
        defer { try? session.terminate(force: true) }

        #expect(getsid(session.identity.processID) == session.identity.processID)
        #expect(tcgetpgrp(session.masterFileDescriptor) == session.identity.processID)
        var windowSize = winsize()
        #expect(ioctl(session.masterFileDescriptor, TIOCGWINSZ, &windowSize) == 0)
        #expect(windowSize.ws_col == 91)
        #expect(windowSize.ws_row == 37)

        let output = try session.readUntilExit(timeout: 5)
        #expect(output.contains("fd=0\r\n"))
        #expect(output.contains("fd=1\r\n"))
        #expect(output.contains("fd=2\r\n"))
        #expect(!output.contains("fd=3\r\n"))
        #expect(output.contains("pid=\(session.identity.processID) pgid=\(session.identity.processGroupID) sid=\(session.identity.processID) cwd=\(fixtureRoot.path)"))
        #expect(try session.waitForExit(timeout: 5) == 0)
    }

    @Test func interactiveShellResizesAndCanBeForceTerminated() throws {
        let root = try temporaryDirectory(prefix: "cockpit-shell")
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = try LaunchSpec(
            kind: .shell,
            loginShellPath: "/bin/zsh",
            executablePath: "/bin/zsh",
            arguments: [],
            workspaceRoot: root.path,
            terminalSize: try TerminalResize(validatingColumns: 80, rows: 24),
            environmentOverrides: ["TERM": "xterm-256color"]
        )
        let session = try PTYSession.start(spec)
        try session.resize(try TerminalResize(validatingColumns: 132, rows: 48))
        var windowSize = winsize()
        #expect(ioctl(session.masterFileDescriptor, TIOCGWINSZ, &windowSize) == 0)
        #expect(windowSize.ws_col == 132)
        #expect(windowSize.ws_row == 48)
        try session.terminate(force: true)
        let status = try session.waitForExit(timeout: 5)
        #expect(status & 0x7f == SIGKILL)
        errno = 0
        #expect(kill(-session.identity.processGroupID, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func shellExitsNaturallyAndFixtureAgentsExecInPlace() throws {
        let root = try temporaryDirectory(prefix: "cockpit-natural-exit")
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = try PTYSession.start(LaunchSpec(
            kind: .shell,
            loginShellPath: "/bin/zsh",
            executablePath: "/bin/zsh",
            arguments: [],
            workspaceRoot: root.path,
            terminalSize: try TerminalResize(validatingColumns: 80, rows: 24),
            environmentOverrides: ["TERM": "xterm-256color"]
        ))
        try shell.write(Data("exit 7\n".utf8))
        _ = try shell.readUntilExit(timeout: 5)
        let shellStatus = try shell.waitForExit(timeout: 5)
        #expect(shellStatus & 0x7f == 0)
        #expect((shellStatus >> 8) & 0xff == 7)

        for (profile, name) in [(AgentProfileID.codex, "codex"), (.claude, "claude")] {
            let executable = fixturesRoot().appendingPathComponent(name)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
            let output = root.appendingPathComponent("\(name).txt")
            let session = try PTYSession.start(LaunchSpec(
                kind: .agent(profile),
                loginShellPath: "/bin/zsh",
                executablePath: executable.path,
                arguments: [output.path, "safe value;$(false)"],
                workspaceRoot: root.path,
                terminalSize: try TerminalResize(validatingColumns: 80, rows: 24),
                environmentOverrides: ["TERM": "xterm-256color"]
            ))
            _ = try session.readUntilExit(timeout: 5)
            #expect(try session.waitForExit(timeout: 5) == 0)
            let report = try String(contentsOf: output, encoding: .utf8)
            #expect(report.contains("agent=\(name)"))
            #expect(report.contains("cwd=\(root.path)"))
            #expect(report.contains("pid=\(session.identity.processID) pgid=\(session.identity.processID)"))
            #expect(report.contains("args=safe value;$(false)"))
        }
    }

    @Test func forceTerminationKillsFixtureAgentDescendant() throws {
        let root = try temporaryDirectory(prefix: "cockpit-agent-group")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = fixturesRoot().appendingPathComponent("codex")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let output = root.appendingPathComponent("codex.txt")
        let session = try PTYSession.start(LaunchSpec(
            kind: .agent(.codex),
            loginShellPath: "/bin/zsh",
            executablePath: executable.path,
            arguments: [output.path, "--wait-with-child"],
            workspaceRoot: root.path,
            terminalSize: try TerminalResize(validatingColumns: 80, rows: 24),
            environmentOverrides: ["TERM": "xterm-256color"]
        ))
        let child = try waitForChildProcess(in: output, timeout: 5)
        #expect(getpgid(child) == session.identity.processGroupID)
        try session.terminate(force: true)
        let status = try session.waitForExit(timeout: 5)
        #expect(status & 0x7f == SIGKILL)
        try waitForMissingProcess(child, timeout: 5)
        errno = 0
        #expect(kill(-session.identity.processGroupID, 0) == -1)
        #expect(errno == ESRCH)
    }
}

private func fixturesRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Agents")
}

private func temporaryDirectory(prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: "/private/tmp/\(prefix).\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
}

private func waitForChildProcess(in output: URL, timeout: TimeInterval) throws -> pid_t {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let report = try? String(contentsOf: output, encoding: .utf8),
           let line = report.split(separator: "\n").first(where: { $0.hasPrefix("child=") }),
           let value = Int32(line.dropFirst("child=".count)) {
            return value
        }
        usleep(10_000)
    }
    throw PTYSessionFailure(operation: "fixture-child", code: ETIMEDOUT)
}

private func waitForMissingProcess(_ processID: pid_t, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        errno = 0
        if kill(processID, 0) == -1, errno == ESRCH { return }
        usleep(10_000)
    }
    throw PTYSessionFailure(operation: "descendant-exit", code: ETIMEDOUT)
}

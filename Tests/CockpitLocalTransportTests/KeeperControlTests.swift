import Darwin
import Foundation
import Testing
import CockpitTerminalCore
import CockpitTypes
@testable import CockpitLocalTransport

@Suite("KeeperControlTests")
struct KeeperControlTests {
    @Test func keeperExecutableProcessIntegration() async throws {
        guard let executable = ProcessInfo.processInfo.environment["COCKPIT_KEEPER_EXECUTABLE"] else {
            return
        }
        let root = try secureTemporaryDirectory(prefix: "cockpit-keeper-process")
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("ApplicationSupport")
        let archives = applicationSupport.appendingPathComponent("TerminalArchives")
        let runtime = root.appendingPathComponent("runtime")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        for url in [applicationSupport, archives, runtime, workspace] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        let probe = root.appendingPathComponent("fd-probe")
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Agents/fd-probe.c")
        try runProcess("/usr/bin/clang", [source.path, "-o", probe.path])
        let output = root.appendingPathComponent("probe.txt")
        let secret = Data(repeating: 0x91, count: 32)
        let nonce = Data(repeating: 0x92, count: 16)
        let sessionID = TerminalSessionID()
        let workerID = WorkerInstanceID()
        let bootstrap = try KeeperBootstrap(
            sessionID: sessionID,
            workerInstanceID: workerID,
            launchSpec: try LaunchSpec(
                kind: .agent(.codex),
                loginShellPath: "/bin/zsh",
                executablePath: probe.path,
                arguments: [output.path, "30"],
                workspaceRoot: workspace.path,
                terminalSize: TerminalResize(validatingColumns: 93, rows: 38),
                environmentOverrides: ["TERM": "xterm-256color"]
            ),
            startNonce: nonce,
            applicationSupportRoot: applicationSupport.path,
            terminalArchivesRoot: archives.path,
            runtimeDirectory: runtime.path,
            workerSecret: secret
        )
        let launched = try await KeeperProcessLauncher(executablePath: executable).launch(bootstrap)
        defer { reapProcess(launched.processID) }
        let client = KeeperControlClient(secretProvider: { _, _ in secret })
        let ready = try await client.awaitReady(launched)
        #expect(ready.sessionID == sessionID)
        #expect(ready.workerID == workerID)
        #expect(try await client.inspect(ready.endpoint).processIdentity == nil)

        let request = AuthenticatedStartRequest(
            endpoint: ready.endpoint,
            sessionID: sessionID,
            workerID: workerID,
            startNonce: nonce,
            proofMAC: KeeperAuthentication.startProof(
                secret: secret,
                endpoint: ready.endpoint,
                sessionID: sessionID,
                workerID: workerID,
                startNonce: nonce
            )
        )
        let identity = try await client.authenticatedStart(request)
        #expect(try await client.authenticatedStart(request) == identity)
        #expect(identity.processID == identity.processGroupID)
        #expect(getsid(identity.processID) == identity.processID)
        try await waitForFile(output, timeout: 5)
        let report = try String(contentsOf: output, encoding: .utf8)
        #expect(report.contains("fd=0\n"))
        #expect(report.contains("fd=1\n"))
        #expect(report.contains("fd=2\n"))
        #expect(!report.contains("fd=3\n"))
        #expect(report.contains("pid=\(identity.processID) pgid=\(identity.processID) sid=\(identity.processID) cwd=\(workspace.path)"))
        try await client.terminate(ready.endpoint, force: true)
        try await waitForProcessExit(identity.processID, timeout: 5)
    }

    @Test func bootstrapChannelIsLengthDelimitedFullDuplexUnixStream() throws {
        let descriptors = try KeeperControlFraming.makeSocketPair()
        defer {
            Darwin.close(descriptors.parent)
            Darwin.close(descriptors.child)
        }
        var socketType: Int32 = 0
        var size = socklen_t(MemoryLayout.size(ofValue: socketType))
        #expect(getsockopt(descriptors.parent, SOL_SOCKET, SO_TYPE, &socketType, &size) == 0)
        #expect(socketType == SOCK_STREAM)

        let endpoint = try KeeperEndpoint(
            path: "/private/tmp/cockpit.501/terminal/session.sock",
            sessionID: TerminalSessionID(),
            workerID: WorkerInstanceID()
        )
        let message = KeeperControlEnvelope.inspect(
            KeeperInspectRequest(
                endpoint: endpoint,
                nonce: Data(repeating: 7, count: 16),
                proofMAC: Data(repeating: 8, count: 32)
            )
        )
        try KeeperControlFraming.write(message, to: descriptors.parent)
        #expect(try KeeperControlFraming.read(KeeperControlEnvelope.self, from: descriptors.child) == message)
        try KeeperControlFraming.write(message, to: descriptors.child)
        #expect(try KeeperControlFraming.read(KeeperControlEnvelope.self, from: descriptors.parent) == message)
    }

    @Test func readyAndStartMACBindEveryFrozenIdentityField() throws {
        let secret = Data(repeating: 0x44, count: 32)
        let sessionID = TerminalSessionID()
        let workerID = WorkerInstanceID()
        let endpoint = try KeeperEndpoint(
            path: "/private/tmp/cockpit.501/terminal/worker.sock",
            sessionID: sessionID,
            workerID: workerID
        )
        let readyNonce = Data(repeating: 0x11, count: 16)
        let ready = KeeperAuthentication.readyProof(
            secret: secret,
            endpoint: endpoint,
            sessionID: sessionID,
            workerID: workerID,
            readyNonce: readyNonce
        )
        #expect(KeeperAuthentication.verifyReadyProof(
            ready,
            secret: secret,
            endpoint: endpoint,
            sessionID: sessionID,
            workerID: workerID,
            readyNonce: readyNonce
        ))
        #expect(!KeeperAuthentication.verifyReadyProof(
            ready,
            secret: secret,
            endpoint: endpoint,
            sessionID: TerminalSessionID(),
            workerID: workerID,
            readyNonce: readyNonce
        ))

        let startNonce = Data(repeating: 0x22, count: 16)
        let start = KeeperAuthentication.startProof(
            secret: secret,
            endpoint: endpoint,
            sessionID: sessionID,
            workerID: workerID,
            startNonce: startNonce
        )
        #expect(KeeperAuthentication.verifyStartProof(
            start,
            secret: secret,
            endpoint: endpoint,
            sessionID: sessionID,
            workerID: workerID,
            startNonce: startNonce
        ))
        #expect(!KeeperAuthentication.verifyStartProof(
            start,
            secret: secret,
            endpoint: endpoint,
            sessionID: sessionID,
            workerID: WorkerInstanceID(),
            startNonce: startNonce
        ))
        #expect(!KeeperAuthentication.verifyStartProof(
            start,
            secret: secret,
            endpoint: endpoint,
            sessionID: sessionID,
            workerID: workerID,
            startNonce: Data(repeating: 0x23, count: 16)
        ))
    }

    @Test func supervisorUDSRoleAuthenticatesPeerAndCreatesAtMostOneCLI() async throws {
        let root = try secureTemporaryDirectory(prefix: "cockpit-keeper-control")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = TerminalSessionID()
        let workerID = WorkerInstanceID()
        let endpoint = try KeeperEndpoint(
            path: root.appendingPathComponent("keeper.sock").path,
            sessionID: sessionID,
            workerID: workerID
        )
        let secret = Data(repeating: 0x66, count: 32)
        let expectedIdentity = try CLIProcessIdentity(
            validatingProcessID: 4100,
            processGroupID: 4100
        )
        let starts = StartCounter(identity: expectedIdentity)
        let server = KeeperUDSServer(
            endpoint: endpoint,
            workerSecret: secret,
            startHandler: { request in await starts.start(request) },
            terminateHandler: { _ in }
        )
        try server.start()
        defer { server.stop() }

        let client = KeeperControlClient(secretProvider: { receivedSession, receivedWorker in
            guard receivedSession == sessionID, receivedWorker == workerID else {
                throw KeeperControlError.authenticationFailed
            }
            return secret
        })
        let before = try await client.inspect(endpoint)
        #expect(before.sessionID == sessionID)
        #expect(before.workerID == workerID)
        #expect(before.processIdentity == nil)

        let nonce = Data(repeating: 0x77, count: 16)
        let request = AuthenticatedStartRequest(
            endpoint: endpoint,
            sessionID: sessionID,
            workerID: workerID,
            startNonce: nonce,
            proofMAC: KeeperAuthentication.startProof(
                secret: secret,
                endpoint: endpoint,
                sessionID: sessionID,
                workerID: workerID,
                startNonce: nonce
            )
        )
        #expect(try await client.authenticatedStart(request) == expectedIdentity)
        #expect(try await client.authenticatedStart(request) == expectedIdentity)
        #expect(await starts.count == 1)
        #expect(try await client.inspect(endpoint).processIdentity == expectedIdentity)

        let wrongNonce = Data(repeating: 0x78, count: 16)
        let mismatch = AuthenticatedStartRequest(
            endpoint: endpoint,
            sessionID: sessionID,
            workerID: workerID,
            startNonce: wrongNonce,
            proofMAC: KeeperAuthentication.startProof(
                secret: secret,
                endpoint: endpoint,
                sessionID: sessionID,
                workerID: workerID,
                startNonce: wrongNonce
            )
        )
        await #expect(throws: KeeperControlError.startRequestMismatch) {
            _ = try await client.authenticatedStart(mismatch)
        }
        #expect(await starts.count == 1)
        var status = stat()
        #expect(lstat(endpoint.path, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFSOCK)
        #expect(status.st_mode & 0o777 == 0o600)
    }

    @Test func bootstrapRootsAndRuntimeDescriptorEndpointFailClosed() throws {
        let root = try secureTemporaryDirectory(prefix: "cockpit-bootstrap-roots")
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("ApplicationSupport")
        let archives = applicationSupport.appendingPathComponent("TerminalArchives")
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
        for url in [applicationSupport, archives, runtime] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }

        let sessionID = TerminalSessionID()
        let workerID = WorkerInstanceID()
        let endpoint = try KeeperEndpoint(
            path: runtime.appendingPathComponent("keeper.sock").path,
            sessionID: sessionID,
            workerID: workerID
        )
        let bootstrap = try KeeperBootstrap(
            sessionID: sessionID,
            workerInstanceID: workerID,
            launchSpec: LaunchSpec.testShell(workspaceRoot: root.path),
            startNonce: Data(repeating: 1, count: 16),
            applicationSupportRoot: applicationSupport.path,
            terminalArchivesRoot: archives.path,
            runtimeDirectory: runtime.path,
            workerSecret: Data(repeating: 2, count: 32)
        )
        #expect(try bootstrap.validated() == bootstrap)
        #expect(try bootstrap.openVerifiedRoots().count == 2)

        let descriptor = KeeperRuntimeDescriptor(
            sessionID: sessionID,
            workerInstanceID: workerID,
            processID: getpid(),
            processGroupID: getpgrp(),
            endpoint: endpoint
        )
        try SecureRuntimeDirectory.write(descriptor, at: runtime.path)
        let data = try Data(contentsOf: URL(fileURLWithPath: bootstrap.runtimeDescriptorPath))
        #expect(try JSONDecoder().decode(KeeperRuntimeDescriptor.self, from: data) == descriptor)

        let link = root.appendingPathComponent("archive-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archives)
        #expect(throws: KeeperBootstrapError.invalidRoot) {
            _ = try KeeperBootstrap(
                sessionID: sessionID,
                workerInstanceID: workerID,
                launchSpec: LaunchSpec.testShell(workspaceRoot: root.path),
                startNonce: Data(repeating: 1, count: 16),
                applicationSupportRoot: applicationSupport.path,
                terminalArchivesRoot: link.path,
                runtimeDirectory: runtime.path,
                workerSecret: Data(repeating: 2, count: 32)
            )
        }
    }
}

private actor StartCounter {
    private(set) var count = 0
    let identity: CLIProcessIdentity

    init(identity: CLIProcessIdentity) { self.identity = identity }

    func start(_ request: AuthenticatedStartRequest) -> CLIProcessIdentity {
        _ = request
        count += 1
        return identity
    }
}

private func secureTemporaryDirectory(prefix: String) throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp/\(prefix).\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    return root
}

private func runProcess(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
}

private func waitForFile(_ url: URL, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: url.path) {
        guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func waitForProcessExit(_ processID: pid_t, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while kill(processID, 0) == 0 {
        guard Date() < deadline else { throw CocoaError(.executableRuntimeMismatch) }
        try await Task.sleep(for: .milliseconds(10))
    }
    guard errno == ESRCH else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
}

private func reapProcess(_ processID: pid_t) {
    if kill(processID, 0) == 0 { _ = kill(processID, SIGKILL) }
    var status: Int32 = 0
    while waitpid(processID, &status, 0) < 0, errno == EINTR {}
}

private extension LaunchSpec {
    static func testShell(workspaceRoot: String) throws -> LaunchSpec {
        try LaunchSpec(
            kind: .shell,
            loginShellPath: "/bin/zsh",
            executablePath: "/bin/zsh",
            arguments: [],
            workspaceRoot: workspaceRoot,
            terminalSize: TerminalResize(validatingColumns: 80, rows: 24),
            environmentOverrides: [:]
        )
    }
}

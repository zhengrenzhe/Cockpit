import Darwin
import Foundation
import Testing
import CockpitTerminalCore
import CockpitTypes
@_spi(CockpitTerminalSupervisorComposition) @testable import CockpitLocalTransport

@Test func keeperSiblingPathUsesTheActualExecutableInsteadOfRelativeArgumentZero() throws {
    let path = try KeeperProcessLauncher.siblingExecutablePath(
        named: "CockpitPTYKeeper",
        currentExecutablePath: "/Applications/Cockpit.app/Contents/Resources/CockpitTerminalSupervisor"
    )

    #expect(path == "/Applications/Cockpit.app/Contents/Resources/CockpitPTYKeeper")
}

@Test func keeperSpawnFlagsCreateIndependentSessionAndCloseUndeclaredDescriptors() {
    #expect(
        KeeperProcessLauncher.spawnFlags
            == Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
    )
}

@Test func launcherReapsExactChildWhenBootstrapWriteFails() throws {
    let root = URL(
        fileURLWithPath: "/private/tmp/cockpit-launcher-tests.\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let executable = root.appendingPathComponent("close-bootstrap-and-wait.zsh")
    try """
    #!/bin/zsh
    exec 3<&-
    /bin/sleep 30
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executable.path
    )

    var blockedSignals = sigset_t()
    sigemptyset(&blockedSignals)
    sigaddset(&blockedSignals, SIGPIPE)
    var previousSignals = sigset_t()
    try #require(pthread_sigmask(SIG_BLOCK, &blockedSignals, &previousSignals) == 0)
    defer { _ = pthread_sigmask(SIG_SETMASK, &previousSignals, nil) }

    var unrelatedProcessID: pid_t = 0
    let trueExecutable = "/usr/bin/true"
    let spawnResult = trueExecutable.withCString { executablePath in
        var arguments: [UnsafeMutablePointer<CChar>?] = [
            UnsafeMutablePointer(mutating: executablePath),
            nil,
        ]
        return arguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &unrelatedProcessID,
                executablePath,
                nil,
                nil,
                buffer.baseAddress,
                environ
            )
        }
    }
    try #require(spawnResult == 0)
    var unrelatedExit = siginfo_t()
    try #require(
        waitid(P_PID, id_t(unrelatedProcessID), &unrelatedExit, WEXITED | WNOWAIT) == 0
    )

    let bootstrap = KeeperBootstrap(
        sessionID: TerminalSessionID(),
        workerInstanceID: WorkerInstanceID(),
        runtimeDirectory: "/private/tmp/" + String(repeating: "x", count: 1_000_000)
    )
    do {
        _ = try KeeperProcessLauncher(executablePath: executable.path).launch(bootstrap)
        Issue.record("launch unexpectedly succeeded after the child closed bootstrap FD 3")
    } catch {
        // The real broken-pipe error is the behavior under test.
    }

    let processList = Process()
    let processOutput = Pipe()
    processList.executableURL = URL(fileURLWithPath: "/bin/ps")
    processList.arguments = ["-axo", "command="]
    processList.standardOutput = processOutput
    try processList.run()
    let processOutputData = processOutput.fileHandleForReading.readDataToEndOfFile()
    processList.waitUntilExit()
    #expect(processList.terminationStatus == 0)
    let audit = String(
        data: processOutputData,
        encoding: .utf8
    ) ?? ""
    #expect(!audit.contains(executable.path))

    var unrelatedStatus: Int32 = 0
    errno = 0
    let unrelatedWaitResult = waitpid(unrelatedProcessID, &unrelatedStatus, 0)
    #expect(unrelatedWaitResult == unrelatedProcessID)
}

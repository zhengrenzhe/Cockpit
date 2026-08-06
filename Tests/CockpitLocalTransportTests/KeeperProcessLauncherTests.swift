import Darwin
import Foundation
import Testing
import CockpitTerminalCore
import CockpitTypes
@testable import CockpitLocalTransport

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
    let processIDFile = URL(fileURLWithPath: executable.path + ".pid")
    try """
    #!/bin/zsh
    print -r -- "$$" > "${0}.pid"
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

    for _ in 0..<200 where !FileManager.default.fileExists(atPath: processIDFile.path) {
        usleep(5_000)
    }
    let processIDText = try String(contentsOf: processIDFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let processID = try #require(pid_t(processIDText))
    defer { reapIfNeeded(processID) }

    errno = 0
    let probeResult = kill(processID, 0)
    let probeCode = errno
    #expect(probeResult == -1)
    #expect(probeCode == ESRCH)

    var status: Int32 = 0
    errno = 0
    let waitResult = waitpid(processID, &status, WNOHANG)
    #expect(waitResult == -1)
    #expect(errno == ECHILD)
}

private func reapIfNeeded(_ processID: pid_t) {
    if kill(processID, 0) == 0 {
        _ = kill(processID, SIGKILL)
    }
    var status: Int32 = 0
    while waitpid(processID, &status, 0) < 0, errno == EINTR {}
}

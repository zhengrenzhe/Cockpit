import Darwin
import Foundation
import CockpitLocalTransport
import CockpitPersistence
import CockpitTerminalCore

func optionalValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

let arguments = CommandLine.arguments
let previousSIGCHLDHandler = signal(SIGCHLD, SIG_IGN)
guard unsafeBitCast(previousSIGCHLDHandler, to: Int.self) != -1 else {
    throw KeeperLaunchFailure(operation: "signal(SIGCHLD)", code: errno)
}
_ = umask(S_IRWXG | S_IRWXO)
let ownExecutable = URL(fileURLWithPath: arguments[0]).standardizedFileURL
let keeperExecutable = optionalValue(after: "--keeper-executable", in: arguments)
    ?? ownExecutable.deletingLastPathComponent()
        .appendingPathComponent("CockpitPTYKeeper").path
let runtimeDirectory = optionalValue(after: "--runtime-directory", in: arguments)
    ?? "/private/tmp/cockpit.\(geteuid())/terminal"

try SecureRuntimeDirectory.prepare(at: runtimeDirectory)

let launcher = KeeperProcessLauncher(executablePath: keeperExecutable)
let storage = try CockpitStorageLocations.production()
let repository = try await SQLiteTerminalSessionRepository(
    databaseURL: storage.terminalDatabase
)
let masterKeyStore = InstallationMasterKeyStore()
let workerSecretDeriver = WorkerSecretDeriver(
    masterKeyProvider: masterKeyStore
)
let controller = KeeperControlClient { sessionID, workerID in
    try await workerSecretDeriver.derive(
        sessionID: sessionID,
        workerID: workerID
    )
}
let supervisor = TerminalSupervisor(
    repository: repository,
    launcher: launcher,
    controller: controller,
    workerSecretDeriver: workerSecretDeriver,
    randomBytes: SecurityTerminalRandomBytes(),
    configuration: try TerminalSupervisorConfiguration(
        applicationSupportRoot: storage.applicationSupport.path,
        terminalArchivesRoot: storage.terminalArchiveRoot.path,
        runtimeDirectory: runtimeDirectory
    )
)
let exported = TerminalSupervisorXPCExport(
    handshakeHandler: { try TerminalSupervisorHandshakeHandler().handle($0) },
    spawnHandler: { request in
        try launcher.launch(
            KeeperBootstrap(
                sessionID: request.sessionID,
                workerInstanceID: request.workerInstanceID,
                runtimeDirectory: runtimeDirectory
            )
        )
    }
)
let delegate = MachServiceListenerDelegate(
    exportedObject: exported,
    exportedInterface: NSXPCInterface(with: TerminalSupervisorXPCProtocol.self)
)
let listener = NSXPCListener(machServiceName: "dev.cockpit.terminal")
listener.delegate = delegate
listener.resume()
withExtendedLifetime(
    [
        repository, masterKeyStore, workerSecretDeriver, controller,
        supervisor, exported, delegate, listener,
    ] as [Any]
) {
    RunLoop.current.run()
}

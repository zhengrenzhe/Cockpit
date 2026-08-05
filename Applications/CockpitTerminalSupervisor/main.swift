import Darwin
import Foundation
import CockpitLocalTransport
import CockpitTerminalCore

func optionalValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func setOwnerOnlyDirectoryMode(_ path: String) throws {
    let result = path.withCString { chmod($0, S_IRWXU) }
    guard result == 0 else { throw CocoaError(.fileWriteNoPermission) }
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

try FileManager.default.createDirectory(
    atPath: runtimeDirectory,
    withIntermediateDirectories: true
)
try setOwnerOnlyDirectoryMode(runtimeDirectory)

let launcher = KeeperProcessLauncher(executablePath: keeperExecutable)
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
RunLoop.current.run()

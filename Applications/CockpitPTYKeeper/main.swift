import Darwin
import Dispatch
import Foundation
import CockpitTerminalCore

let previousSIGCHLDHandler = signal(SIGCHLD, SIG_DFL)
guard unsafeBitCast(previousSIGCHLDHandler, to: Int.self) != -1 else {
    throw CocoaError(.executableRuntimeMismatch)
}
_ = umask(S_IRWXG | S_IRWXO)

func setOwnerOnlyMode(_ path: String, _ mode: mode_t) throws {
    let result = path.withCString { chmod($0, mode) }
    guard result == 0 else { throw CocoaError(.fileWriteNoPermission) }
}

let bootstrapHandle = FileHandle(
    fileDescriptor: KeeperBootstrap.inheritedFileDescriptor,
    closeOnDealloc: true
)
guard
    let bootstrapData = try bootstrapHandle.readToEnd(),
    !bootstrapData.isEmpty
else {
    throw CocoaError(.fileReadCorruptFile)
}
try bootstrapHandle.close()

let bootstrap = try JSONDecoder().decode(KeeperBootstrap.self, from: bootstrapData)
try FileManager.default.createDirectory(
    atPath: bootstrap.runtimeDirectory,
    withIntermediateDirectories: true
)
try setOwnerOnlyMode(bootstrap.runtimeDirectory, S_IRWXU)

let descriptor = KeeperRuntimeDescriptor(
    sessionID: bootstrap.sessionID,
    workerInstanceID: bootstrap.workerInstanceID,
    processID: getpid(),
    processGroupID: getpgrp()
)
let descriptorURL = URL(fileURLWithPath: bootstrap.runtimeDescriptorPath)
try JSONEncoder().encode(descriptor).write(to: descriptorURL, options: .atomic)
try setOwnerOnlyMode(descriptorURL.path, S_IRUSR | S_IWUSR)

dispatchMain()

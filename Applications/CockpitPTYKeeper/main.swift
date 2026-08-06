import Darwin
import Dispatch
import Foundation
import CockpitTerminalCore

let previousSIGCHLDHandler = signal(SIGCHLD, SIG_DFL)
guard unsafeBitCast(previousSIGCHLDHandler, to: Int.self) != -1 else {
    throw CocoaError(.executableRuntimeMismatch)
}
_ = umask(S_IRWXG | S_IRWXO)

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

let descriptor = KeeperRuntimeDescriptor(
    sessionID: bootstrap.sessionID,
    workerInstanceID: bootstrap.workerInstanceID,
    processID: getpid(),
    processGroupID: getpgrp()
)
try SecureRuntimeDirectory.write(descriptor, at: bootstrap.runtimeDirectory)

dispatchMain()

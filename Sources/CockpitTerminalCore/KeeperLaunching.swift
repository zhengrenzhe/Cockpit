import Foundation
import CockpitTypes

public struct LaunchedKeeper: Sendable {
    public let sessionID: TerminalSessionID
    public let workerID: WorkerInstanceID
    public let processID: Int32
    public let bootstrapControlDescriptor: Int32
    public let runtimeDescriptorPath: String

    public init(
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        processID: Int32,
        bootstrapControlDescriptor: Int32,
        runtimeDescriptorPath: String
    ) {
        self.sessionID = sessionID
        self.workerID = workerID
        self.processID = processID
        self.bootstrapControlDescriptor = bootstrapControlDescriptor
        self.runtimeDescriptorPath = runtimeDescriptorPath
    }
}

public protocol KeeperLaunching: Sendable {
    func launch(_ bootstrap: KeeperBootstrap) async throws -> LaunchedKeeper
}

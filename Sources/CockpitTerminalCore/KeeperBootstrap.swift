import Foundation
import CockpitTypes

public struct KeeperBootstrap: Codable, Equatable, Sendable {
    public static let inheritedFileDescriptor: Int32 = 3
    public static let bootstrapTimeoutNanoseconds: UInt64 = 30_000_000_000

    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID
    public let runtimeDirectory: String

    public init(
        sessionID: TerminalSessionID,
        workerInstanceID: WorkerInstanceID,
        runtimeDirectory: String
    ) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
        self.runtimeDirectory = runtimeDirectory
    }

    public var runtimeDescriptorPath: String {
        URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
            .appendingPathComponent("\(sessionID).\(workerInstanceID).json")
            .path
    }
}

public struct KeeperProbeRequest: Codable, Equatable, Sendable {
    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID

    public init(sessionID: TerminalSessionID, workerInstanceID: WorkerInstanceID) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
    }
}

public struct KeeperLaunchReceipt: Codable, Equatable, Sendable {
    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID
    public let processID: Int32
    public let runtimeDescriptorPath: String

    public init(
        sessionID: TerminalSessionID,
        workerInstanceID: WorkerInstanceID,
        processID: Int32,
        runtimeDescriptorPath: String
    ) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
        self.processID = processID
        self.runtimeDescriptorPath = runtimeDescriptorPath
    }
}

public struct KeeperRuntimeDescriptor: Codable, Equatable, Sendable {
    public let sessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID
    public let processID: Int32
    public let processGroupID: Int32

    public init(
        sessionID: TerminalSessionID,
        workerInstanceID: WorkerInstanceID,
        processID: Int32,
        processGroupID: Int32
    ) {
        self.sessionID = sessionID
        self.workerInstanceID = workerInstanceID
        self.processID = processID
        self.processGroupID = processGroupID
    }
}

import Foundation
import CockpitTypes

public enum TerminalSessionRecordError: Error, Equatable, Sendable {
    case invalidProcessIdentity
    case invalidArchivePath
    case invalidProtocolVersion
    case emptyLaunchSpec
    case invalidStartNonceLength
}

public struct CLIProcessIdentity: Hashable, Codable, Sendable {
    public let processID: Int32
    public let processGroupID: Int32

    public init(validatingProcessID processID: Int32, processGroupID: Int32) throws {
        guard processID > 0, processGroupID > 0, processID == processGroupID else {
            throw TerminalSessionRecordError.invalidProcessIdentity
        }
        self.processID = processID
        self.processGroupID = processGroupID
    }

    private enum CodingKeys: String, CodingKey { case processID, processGroupID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validatingProcessID: container.decode(Int32.self, forKey: .processID),
            processGroupID: container.decode(Int32.self, forKey: .processGroupID)
        )
    }
}

public struct RelativeArchivePath: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(validating rawValue: String) throws {
        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawValue.isEmpty,
              !rawValue.hasPrefix("/"),
              !rawValue.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw TerminalSessionRecordError.invalidArchivePath
        }
        self.rawValue = rawValue
    }

    public init?(rawValue: String) {
        try? self.init(validating: rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct TerminalSessionRecord: Hashable, Codable, Sendable {
    public let sessionID: TerminalSessionID
    public let contextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let protocolVersion: ProtocolVersion
    public let launchSpecData: Data
    public let workerID: WorkerInstanceID?
    public let lifecycleState: TerminalLifecycleState
    public let startNonce: Data
    public let processIdentity: CLIProcessIdentity?
    public let exitStatus: Int32?
    public let latestSequence: UInt64
    public let archiveManifest: RelativeArchivePath?

    public init(
        validatingSessionID sessionID: TerminalSessionID,
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        protocolVersion: ProtocolVersion,
        launchSpecData: Data,
        lifecycleState: TerminalLifecycleState,
        startNonce: Data,
        workerID: WorkerInstanceID? = nil,
        processIdentity: CLIProcessIdentity? = nil,
        exitStatus: Int32? = nil,
        latestSequence: UInt64 = 0,
        archiveManifest: RelativeArchivePath? = nil
    ) throws {
        guard protocolVersion.major > 0 else {
            throw TerminalSessionRecordError.invalidProtocolVersion
        }
        guard !launchSpecData.isEmpty else { throw TerminalSessionRecordError.emptyLaunchSpec }
        guard startNonce.count == 16 else {
            throw TerminalSessionRecordError.invalidStartNonceLength
        }
        self.sessionID = sessionID
        self.contextID = contextID
        self.environmentID = environmentID
        self.protocolVersion = protocolVersion
        self.launchSpecData = launchSpecData
        self.workerID = workerID
        self.lifecycleState = lifecycleState
        self.startNonce = startNonce
        self.processIdentity = processIdentity
        self.exitStatus = exitStatus
        self.latestSequence = latestSequence
        self.archiveManifest = archiveManifest
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, contextID, environmentID, protocolVersion, launchSpecData
        case workerID, lifecycleState, startNonce, processIdentity, exitStatus
        case latestSequence, archiveManifest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validatingSessionID: container.decode(TerminalSessionID.self, forKey: .sessionID),
            contextID: container.decode(WorkspaceContextID.self, forKey: .contextID),
            environmentID: container.decode(EnvironmentID.self, forKey: .environmentID),
            protocolVersion: container.decode(ProtocolVersion.self, forKey: .protocolVersion),
            launchSpecData: container.decode(Data.self, forKey: .launchSpecData),
            lifecycleState: container.decode(TerminalLifecycleState.self, forKey: .lifecycleState),
            startNonce: container.decode(Data.self, forKey: .startNonce),
            workerID: container.decodeIfPresent(WorkerInstanceID.self, forKey: .workerID),
            processIdentity: container.decodeIfPresent(CLIProcessIdentity.self, forKey: .processIdentity),
            exitStatus: container.decodeIfPresent(Int32.self, forKey: .exitStatus),
            latestSequence: container.decode(UInt64.self, forKey: .latestSequence),
            archiveManifest: container.decodeIfPresent(RelativeArchivePath.self, forKey: .archiveManifest)
        )
    }
}

import Foundation
import CockpitTerminalCore
import CockpitTypes

public struct TerminalCreateRequest: Hashable, Codable, Sendable {
    public let contextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let kind: TerminalKind
    public let arguments: [String]
    public let terminalSize: TerminalResize
    public let environmentOverrides: [String: String]
    public let idempotencyKey: RequestID

    public init(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        kind: TerminalKind,
        arguments: [String],
        terminalSize: TerminalResize,
        environmentOverrides: [String: String],
        idempotencyKey: RequestID
    ) {
        self.contextID = contextID
        self.environmentID = environmentID
        self.kind = kind
        self.arguments = arguments
        self.terminalSize = terminalSize
        self.environmentOverrides = environmentOverrides
        self.idempotencyKey = idempotencyKey
    }
}

public struct ResolvedTerminalCreateRequest: Hashable, Codable, Sendable {
    public let contextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let kind: TerminalKind
    public let arguments: [String]
    public let workspaceRoot: String
    public let terminalSize: TerminalResize
    public let environmentOverrides: [String: String]
    public let idempotencyKey: RequestID

    public init(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        kind: TerminalKind,
        arguments: [String],
        workspaceRoot: String,
        terminalSize: TerminalResize,
        environmentOverrides: [String: String],
        idempotencyKey: RequestID
    ) {
        self.contextID = contextID
        self.environmentID = environmentID
        self.kind = kind
        self.arguments = arguments
        self.workspaceRoot = workspaceRoot
        self.terminalSize = terminalSize
        self.environmentOverrides = environmentOverrides
        self.idempotencyKey = idempotencyKey
    }
}

public struct TerminalAttachTicketRequest: Hashable, Codable, Sendable {
    public let sessionID: TerminalSessionID
    public let clientInstanceID: ClientInstanceID
    public let viewerID: ViewerID
    public let capabilities: TerminalAttachCapabilities

    public init(
        sessionID: TerminalSessionID,
        clientInstanceID: ClientInstanceID,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) {
        self.sessionID = sessionID
        self.clientInstanceID = clientInstanceID
        self.viewerID = viewerID
        self.capabilities = capabilities
    }
}

public struct TerminalInputLeaseRequest: Hashable, Codable, Sendable {
    public let sessionID: TerminalSessionID
    public let viewerID: ViewerID
    public let capabilities: TerminalAttachCapabilities

    public init(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) {
        self.sessionID = sessionID
        self.viewerID = viewerID
        self.capabilities = capabilities
    }
}

public struct TerminalInputLeaseTransferRequest: Hashable, Codable, Sendable {
    public let sessionID: TerminalSessionID
    public let leaseID: InputLeaseID
    public let toViewerID: ViewerID
    public let capabilities: TerminalAttachCapabilities

    public init(
        sessionID: TerminalSessionID,
        leaseID: InputLeaseID,
        toViewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) {
        self.sessionID = sessionID
        self.leaseID = leaseID
        self.toViewerID = toViewerID
        self.capabilities = capabilities
    }
}

public struct ClientTerminalSession: Hashable, Codable, Sendable {
    public let sessionID: TerminalSessionID
    public let contextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let protocolVersion: ProtocolVersion
    public let workerID: WorkerInstanceID?
    public let lifecycleState: TerminalLifecycleState
    public let exitStatus: Int32?
    public let latestSequence: UInt64
    public let archiveAvailable: Bool

    public init(_ record: TerminalSessionRecord) {
        sessionID = record.sessionID
        contextID = record.contextID
        environmentID = record.environmentID
        protocolVersion = record.protocolVersion
        workerID = record.workerID
        lifecycleState = record.lifecycleState
        exitStatus = record.exitStatus
        latestSequence = record.latestSequence
        archiveAvailable = record.archiveManifest != nil
    }
}

public struct ClientTerminalAttachAuthorization: Hashable, Codable, Sendable {
    public let wireTicket: String
    public let binding: TerminalAttachBinding
    public let viewerID: ViewerID
    public let capabilities: TerminalAttachCapabilities

    public init(_ authorization: TerminalAttachAuthorization) {
        wireTicket = authorization.wireTicket
        binding = authorization.binding
        viewerID = authorization.viewerID
        capabilities = authorization.capabilities
    }
}

public struct HostTerminalArchiveRequest: Hashable, Codable, Sendable {
    public let contextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let sessionID: TerminalSessionID

    public init(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        sessionID: TerminalSessionID
    ) {
        self.contextID = contextID
        self.environmentID = environmentID
        self.sessionID = sessionID
    }
}

public protocol TerminalSupervisorControlling: Sendable {
    func createResolved(_ request: ResolvedTerminalCreateRequest) async throws -> TerminalSessionRecord
    func list(contextID: WorkspaceContextID) async throws -> [TerminalSessionRecord]
    func issueAttachTicket(_ request: TerminalAttachTicketRequest) async throws -> TerminalAttachAuthorization
    func acquireInputLease(_ request: TerminalInputLeaseRequest) async throws -> InputLeaseGrant
    func transferInputLease(_ request: TerminalInputLeaseTransferRequest) async throws -> InputLeaseGrant
    func releaseInputLease(sessionID: TerminalSessionID, leaseID: InputLeaseID) async throws
    func signal(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        signal: TerminalSignal
    ) async throws -> Int32
    func terminate(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        force: Bool
    ) async throws
    func purgeFinishedRecords() async throws -> Int
    func reconcile() async throws
    func openArchive(sessionID: TerminalSessionID) async throws -> FileHandle
}

public enum TerminalSupervisorCommandRequest: Hashable, Codable, Sendable {
    case createResolved(ResolvedTerminalCreateRequest)
    case list(contextID: WorkspaceContextID)
    case issueAttachTicket(TerminalAttachTicketRequest)
    case acquireInputLease(TerminalInputLeaseRequest)
    case transferInputLease(TerminalInputLeaseTransferRequest)
    case releaseInputLease(sessionID: TerminalSessionID, leaseID: InputLeaseID)
    case signal(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        signal: TerminalSignal
    )
    case terminate(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        force: Bool
    )
    case purgeFinishedRecords
    case reconcile
}

public enum TerminalSupervisorCommandResponse: Hashable, Codable, Sendable {
    case session(TerminalSessionRecord)
    case sessions([TerminalSessionRecord])
    case attachAuthorization(TerminalAttachAuthorization)
    case inputLease(InputLeaseGrant)
    case processGroup(Int32)
    case purged(Int)
    case empty
}

public enum HostTerminalCommandRequest: Hashable, Codable, Sendable {
    case create(TerminalCreateRequest)
    case list(contextID: WorkspaceContextID)
    case issueAttachTicket(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        request: TerminalAttachTicketRequest
    )
    case acquireInputLease(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        request: TerminalInputLeaseRequest
    )
    case transferInputLease(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        request: TerminalInputLeaseTransferRequest
    )
    case releaseInputLease(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        sessionID: TerminalSessionID,
        leaseID: InputLeaseID
    )
    case signal(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        signal: TerminalSignal
    )
    case terminate(
        contextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        force: Bool
    )
}

public enum HostTerminalCommandResponse: Hashable, Codable, Sendable {
    case session(ClientTerminalSession)
    case sessions([ClientTerminalSession])
    case attachAuthorization(ClientTerminalAttachAuthorization)
    case inputLease(InputLeaseGrant)
    case processGroup(Int32)
    case empty
}

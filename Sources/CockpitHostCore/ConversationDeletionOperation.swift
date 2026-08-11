import Foundation
import CockpitProtocol
import CockpitTerminalCore
import CockpitTypes

public enum ConversationDeletionPhase: Int, Codable, Hashable, Sendable {
    case deleting
    case terminatingSessions
    case purgingTerminalRecords
    case removingClientState
    case deleted
}

public struct ConversationDeletionOperation: Hashable, Codable, Sendable {
    public let operationID: DeletionOperationID
    public let conversationID: ConversationID
    public let projectID: ProjectID
    public let environmentID: EnvironmentID
    public let phase: ConversationDeletionPhase

    public init(
        operationID: DeletionOperationID,
        conversationID: ConversationID,
        projectID: ProjectID,
        environmentID: EnvironmentID,
        phase: ConversationDeletionPhase
    ) {
        self.operationID = operationID
        self.conversationID = conversationID
        self.projectID = projectID
        self.environmentID = environmentID
        self.phase = phase
    }
}

public struct DocumentDeletionState: Hashable, Sendable {
    public let snapshot: DocumentSnapshot
    public let liveViewerContexts: Set<WorkspaceContextID>

    public init(
        snapshot: DocumentSnapshot,
        liveViewerContexts: Set<WorkspaceContextID>
    ) {
        self.snapshot = snapshot
        self.liveViewerContexts = liveViewerContexts
    }
}

public struct ConversationDeletionPersistedViewer: Hashable, Sendable {
    public let documentID: DocumentID
    public let contextID: WorkspaceContextID

    public init(documentID: DocumentID, contextID: WorkspaceContextID) {
        self.documentID = documentID
        self.contextID = contextID
    }
}

public struct ConversationDeletionDocumentReservation: Hashable, Sendable {
    public let id: UUID
    public let environmentID: EnvironmentID

    public init(id: UUID, environmentID: EnvironmentID) {
        self.id = id
        self.environmentID = environmentID
    }
}

public struct ConversationDeletionImpact: Hashable, Codable, Sendable {
    public let conversationID: ConversationID
    public let projectID: ProjectID
    public let environmentID: EnvironmentID
    public let dirtyDocuments: [DocumentSnapshot]
    public let deletionOperationID: DeletionOperationID?
    public let preparationID: UUID?

    public init(
        conversationID: ConversationID,
        projectID: ProjectID,
        environmentID: EnvironmentID,
        dirtyDocuments: [DocumentSnapshot],
        deletionOperationID: DeletionOperationID? = nil,
        preparationID: UUID? = nil
    ) {
        self.conversationID = conversationID
        self.projectID = projectID
        self.environmentID = environmentID
        self.dirtyDocuments = dirtyDocuments
        self.deletionOperationID = deletionOperationID
        self.preparationID = preparationID
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID
        case projectID
        case environmentID
        case dirtyDocuments
        case deletionOperationID
        case preparationID
    }

    public init(from decoder: Decoder) throws {
        try requireExactKeys(
            decoder,
            required: [
                "conversationID", "projectID", "environmentID", "dirtyDocuments",
            ],
            optional: ["deletionOperationID", "preparationID"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try container.decode(ConversationID.self, forKey: .conversationID)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        environmentID = try container.decode(EnvironmentID.self, forKey: .environmentID)
        deletionOperationID = try container.decodeIfPresent(
            DeletionOperationID.self,
            forKey: .deletionOperationID
        )
        preparationID = try container.decodeIfPresent(UUID.self, forKey: .preparationID)
        dirtyDocuments = try container.decode([Data].self, forKey: .dirtyDocuments).map {
            try HostDataPlaneMessages.decode(
                CPDocumentSnapshotValue(serializedBytes: $0)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(environmentID, forKey: .environmentID)
        try container.encodeIfPresent(deletionOperationID, forKey: .deletionOperationID)
        try container.encodeIfPresent(preparationID, forKey: .preparationID)
        try container.encode(
            dirtyDocuments.map {
                try HostDataPlaneMessages.encode($0).serializedData()
            },
            forKey: .dirtyDocuments
        )
    }
}

public enum ConversationDeletionProgress: Hashable, Codable, Sendable {
    case preparationStale(ConversationDeletionImpact)
    case forceConfirmationRequired(
        operationID: DeletionOperationID,
        activeSessionIDs: [TerminalSessionID]
    )
    case deleted(projectContextID: WorkspaceContextID)
}

public enum ConversationDeletionError: Error, Equatable, Sendable {
    case operationMismatch
    case stalePreparation
    case terminalControlUnavailable
    case forceConfirmationRequired(
        operationID: DeletionOperationID,
        activeSessionIDs: [TerminalSessionID]
    )
}

public protocol ConversationDeletionServing: Sendable {
    func deletionImpact(
        conversationID: ConversationID
    ) async throws -> ConversationDeletionImpact
    func beginConversationDeletion(
        conversationID: ConversationID,
        operationID: DeletionOperationID,
        preparationID: UUID
    ) async throws -> ConversationDeletionProgress
    func resumeConversationDeletion(
        operationID: DeletionOperationID,
        force: Bool
    ) async throws -> ConversationDeletionProgress
}

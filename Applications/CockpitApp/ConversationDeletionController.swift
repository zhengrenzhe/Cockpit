import CockpitHostCore
import CockpitProtocol
import CockpitTypes
import Foundation

enum ConversationDeletionDocumentDecision: Hashable, Sendable {
    case save
    case discard
    case cancel
}

enum ConversationDeletionControllerResult: Hashable, Sendable {
    case cancelled
    case deletionPending(operationID: DeletionOperationID)
    case deleted
}

@MainActor
final class ConversationDeletionController {
    typealias DocumentDecision = @MainActor (DocumentSnapshot) async throws
        -> ConversationDeletionDocumentDecision
    typealias DocumentAction = @MainActor (DocumentSnapshot) async throws -> Void
    typealias Confirmation = @MainActor () async -> Bool
    typealias ForceConfirmation = @MainActor ([TerminalSessionID]) async -> Bool
    typealias ProjectSelection = @MainActor (WorkspaceContextID) async throws -> Void

    private let service: any ConversationDeletionServing
    private let operationID: () -> DeletionOperationID
    private let documentDecision: DocumentDecision
    private let saveDocument: DocumentAction
    private let discardDocument: DocumentAction
    private let confirmTermination: Confirmation
    private let confirmForce: ForceConfirmation
    private let selectProjectContext: ProjectSelection

    init(
        service: any ConversationDeletionServing,
        operationID: @escaping () -> DeletionOperationID = { DeletionOperationID() },
        documentDecision: @escaping DocumentDecision,
        saveDocument: @escaping DocumentAction,
        discardDocument: @escaping DocumentAction,
        confirmTermination: @escaping Confirmation,
        confirmForce: @escaping ForceConfirmation,
        selectProjectContext: @escaping ProjectSelection
    ) {
        self.service = service
        self.operationID = operationID
        self.documentDecision = documentDecision
        self.saveDocument = saveDocument
        self.discardDocument = discardDocument
        self.confirmTermination = confirmTermination
        self.confirmForce = confirmForce
        self.selectProjectContext = selectProjectContext
    }

    func delete(
        conversationID: ConversationID
    ) async throws -> ConversationDeletionControllerResult {
        var impact = try await service.deletionImpact(conversationID: conversationID)
        let progress: ConversationDeletionProgress
        while true {
            if let pendingOperationID = impact.deletionOperationID {
                progress = try await service.resumeConversationDeletion(
                    operationID: pendingOperationID,
                    force: false
                )
                break
            }

            var documentStateChanged = false
            for document in impact.dirtyDocuments {
                switch try await documentDecision(document) {
                case .save:
                    try await saveDocument(document)
                    documentStateChanged = true
                case .discard:
                    try await discardDocument(document)
                    documentStateChanged = true
                case .cancel:
                    return .cancelled
                }
            }
            if documentStateChanged {
                impact = try await service.deletionImpact(conversationID: conversationID)
                continue
            }

            guard await confirmTermination() else { return .cancelled }
            guard let preparationID = impact.preparationID else {
                throw ConversationDeletionError.stalePreparation
            }
            let result = try await service.beginConversationDeletion(
                conversationID: conversationID,
                operationID: operationID(),
                preparationID: preparationID
            )
            if case let .preparationStale(freshImpact) = result {
                impact = freshImpact
                continue
            }
            progress = result
            break
        }

        let completed: ConversationDeletionProgress
        if case let .forceConfirmationRequired(pendingOperationID, activeSessionIDs) = progress {
            guard await confirmForce(activeSessionIDs) else {
                return .deletionPending(operationID: pendingOperationID)
            }
            completed = try await service.resumeConversationDeletion(
                operationID: pendingOperationID,
                force: true
            )
        } else {
            completed = progress
        }

        switch completed {
        case .preparationStale:
            throw ConversationDeletionError.stalePreparation
        case let .deleted(projectContextID):
            try await selectProjectContext(projectContextID)
            return .deleted
        case let .forceConfirmationRequired(operationID, activeSessionIDs):
            throw ConversationDeletionError.forceConfirmationRequired(
                operationID: operationID,
                activeSessionIDs: activeSessionIDs
            )
        }
    }
}

import Foundation
import CockpitProtocol
import CockpitTypes

public struct ProjectSnapshot: Hashable, Sendable {
    public let projectID: ProjectID
    public let displayName: String
    public let resolvedContext: ResolvedWorkspaceContext
    public let conversations: [Conversation]

    public init(
        projectID: ProjectID,
        displayName: String,
        resolvedContext: ResolvedWorkspaceContext,
        conversations: [Conversation]
    ) {
        self.projectID = projectID
        self.displayName = displayName
        self.resolvedContext = resolvedContext
        self.conversations = conversations
    }
}

public typealias WorkspaceSnapshot = [ProjectSnapshot]

public protocol WorkspaceServing: Sendable {
    func addProject(bookmark: Data, displayName: String) async throws -> ProjectSnapshot
    func listWorkspace() async throws -> WorkspaceSnapshot
    func createDirectConversation(projectID: ProjectID) async throws -> Conversation
    func renameConversation(id: ConversationID, title: String) async throws
    func resolveContext(_ id: WorkspaceContextID) async throws -> ResolvedWorkspaceContext
    func performFileOperation(
        context: RequestContext,
        operation: FileOperation
    ) async throws -> FileOperationResult
}

public protocol ClientWorkspaceStateServing: Sendable {
    func loadClientState(
        _ key: ClientWorkspaceStateKey
    ) async throws -> ClientWorkspaceState?
    func saveClientState(_ state: ClientWorkspaceState) async throws
}

public protocol ProjectRootAccessToken: AnyObject, Sendable {}

public struct ResolvedProjectRoot: Sendable {
    public let canonicalAbsolutePath: String
    public let canonicalRootIdentity: String
    public let gitCommonDirectory: String?
    public let accessToken: any ProjectRootAccessToken

    public init(
        canonicalAbsolutePath: String,
        canonicalRootIdentity: String,
        gitCommonDirectory: String?,
        accessToken: any ProjectRootAccessToken
    ) {
        self.canonicalAbsolutePath = canonicalAbsolutePath
        self.canonicalRootIdentity = canonicalRootIdentity
        self.gitCommonDirectory = gitCommonDirectory
        self.accessToken = accessToken
    }
}

public protocol ProjectRootResolving: Sendable {
    func importBookmark(
        _ bookmark: Data
    ) throws -> (persistentBookmark: Data, root: ResolvedProjectRoot)
    func resolve(bookmark: Data) throws -> ResolvedProjectRoot
}

public extension ProjectRootResolving {
    func importBookmark(
        _ bookmark: Data
    ) throws -> (persistentBookmark: Data, root: ResolvedProjectRoot) {
        (bookmark, try resolve(bookmark: bookmark))
    }
}

public protocol WorkspaceKernelRegistering: FileOperationServing, Sendable {
    func register(environmentID: EnvironmentID, root: ResolvedProjectRoot) async
    func perform(
        _ operation: FileOperation,
        in environmentID: EnvironmentID,
        contextID: WorkspaceContextID
    ) async throws -> FileOperationResult
    func documentDeletionStates(
        in environmentID: EnvironmentID,
        documentIDs: Set<DocumentID>
    ) async throws -> [DocumentDeletionState]
    func documentDeletionStates(
        in environmentID: EnvironmentID,
        documentIDs: Set<DocumentID>,
        includingViewerContext contextID: WorkspaceContextID
    ) async throws -> [DocumentDeletionState]
    func reserveConversationDeletion(
        in environmentID: EnvironmentID,
        preparationID: UUID,
        targetContextID: WorkspaceContextID,
        expectedDocumentStates: [DocumentDeletionState]
    ) async throws -> ConversationDeletionDocumentReservation
    func commitConversationDeletion(
        _ reservation: ConversationDeletionDocumentReservation,
        blocking targetContextID: WorkspaceContextID
    ) async
    func cancelConversationDeletion(
        _ reservation: ConversationDeletionDocumentReservation
    ) async
}

public extension WorkspaceKernelRegistering {
    func perform(
        _ operation: FileOperation,
        in environmentID: EnvironmentID,
        contextID: WorkspaceContextID
    ) async throws -> FileOperationResult {
        try await perform(operation, in: environmentID)
    }

    func documentDeletionStates(
        in environmentID: EnvironmentID,
        documentIDs: Set<DocumentID>
    ) async throws -> [DocumentDeletionState] { [] }

    func documentDeletionStates(
        in environmentID: EnvironmentID,
        documentIDs: Set<DocumentID>,
        includingViewerContext contextID: WorkspaceContextID
    ) async throws -> [DocumentDeletionState] {
        try await documentDeletionStates(
            in: environmentID,
            documentIDs: documentIDs
        )
    }

    func reserveConversationDeletion(
        in environmentID: EnvironmentID,
        preparationID: UUID,
        targetContextID: WorkspaceContextID,
        expectedDocumentStates: [DocumentDeletionState]
    ) async throws -> ConversationDeletionDocumentReservation {
        ConversationDeletionDocumentReservation(
            id: preparationID,
            environmentID: environmentID
        )
    }

    func commitConversationDeletion(
        _ reservation: ConversationDeletionDocumentReservation,
        blocking targetContextID: WorkspaceContextID
    ) async {}

    func cancelConversationDeletion(
        _ reservation: ConversationDeletionDocumentReservation
    ) async {}
}

public actor WorkspaceService: WorkspaceServing, ClientWorkspaceStateServing, ConversationDeletionServing {
    private struct DeletionPreparation: Sendable {
        let id: UUID
        let conversationID: ConversationID
        let environmentID: EnvironmentID
        let targetContextID: WorkspaceContextID
        let relevantDocumentIDs: Set<DocumentID>
        let persistedViewers: Set<ConversationDeletionPersistedViewer>
        let documentStates: [DocumentDeletionState]
    }

    private let repository: any WorkspaceRepository
    private let rootResolver: any ProjectRootResolving
    private let kernelRegistry: any WorkspaceKernelRegistering
    private let deletionCoordinator: ConversationDeletionCoordinator?
    private var deletionPreparations: [ConversationID: DeletionPreparation] = [:]

    public init(
        repository: any WorkspaceRepository,
        rootResolver: any ProjectRootResolving,
        kernelRegistry: any WorkspaceKernelRegistering,
        terminalDeletion: (any ContextTerminalDeletionControlling)? = nil
    ) {
        self.repository = repository
        self.rootResolver = rootResolver
        self.kernelRegistry = kernelRegistry
        deletionCoordinator = terminalDeletion.map {
            ConversationDeletionCoordinator(repository: repository, terminal: $0)
        }
    }

    public func addProject(
        bookmark: Data,
        displayName: String
    ) async throws -> ProjectSnapshot {
        let imported = try rootResolver.importBookmark(bookmark)
        let root = imported.root
        let project = try await repository.createProjectWithDirectEnvironment(
            NewProject(
                displayName: displayName,
                rootBookmark: imported.persistentBookmark,
                canonicalRootIdentity: root.canonicalRootIdentity,
                workspaceRoot: root.canonicalAbsolutePath,
                gitCommonDirectory: root.gitCommonDirectory
            )
        )
        await kernelRegistry.register(environmentID: project.baseEnvironmentID, root: root)
        return try await snapshot(for: project)
    }

    public func listWorkspace() async throws -> WorkspaceSnapshot {
        let projects = try await repository.listProjects()
        var snapshots: [ProjectSnapshot] = []
        snapshots.reserveCapacity(projects.count)
        for project in projects {
            let root = try rootResolver.resolve(bookmark: project.rootBookmark)
            await kernelRegistry.register(environmentID: project.baseEnvironmentID, root: root)
            snapshots.append(try await snapshot(for: project))
        }
        return snapshots
    }

    public func createDirectConversation(projectID: ProjectID) async throws -> Conversation {
        let (_, root) = try await registerProject(id: projectID)
        let conversation = try await repository.createConversation(
            NewConversation(projectID: projectID, title: "新任务")
        )
        await kernelRegistry.register(environmentID: conversation.environmentID, root: root)
        return conversation
    }

    public func renameConversation(id: ConversationID, title: String) async throws {
        try await repository.renameConversation(id: id, title: title)
    }

    public func resolveContext(
        _ id: WorkspaceContextID
    ) async throws -> ResolvedWorkspaceContext {
        let resolved = try await repository.resolve(id)
        let (_, root) = try await registerProject(id: resolved.projectID)
        await kernelRegistry.register(environmentID: resolved.environmentID, root: root)
        return resolved
    }

    public func performFileOperation(
        context: RequestContext,
        operation: FileOperation
    ) async throws -> FileOperationResult {
        let context = try context.validated(negotiatedVersion: .current)
        let resolved = try await repository.resolve(context.workspaceContextID)
        guard resolved.environmentID == context.environmentID else {
            throw FileOperationError.contextEnvironmentMismatch
        }
        let (_, root) = try await registerProject(id: resolved.projectID)
        await kernelRegistry.register(environmentID: resolved.environmentID, root: root)
        return try await kernelRegistry.perform(
            operation,
            in: resolved.environmentID,
            contextID: resolved.contextID
        )
    }

    public func loadClientState(
        _ key: ClientWorkspaceStateKey
    ) async throws -> ClientWorkspaceState? {
        guard let state = try await repository.loadClientState(key) else { return nil }
        let valid = try state.validated()
        guard valid.key == key else { throw WorkspaceRepositoryError.invalidStoredValue }
        return valid
    }

    public func saveClientState(_ state: ClientWorkspaceState) async throws {
        try await repository.saveClientState(try state.validated())
    }

    public func deletionImpact(
        conversationID: ConversationID
    ) async throws -> ConversationDeletionImpact {
        let projects = try await repository.listProjects()
        var matched: Conversation?
        for project in projects where matched == nil {
            matched = try await repository.listConversations(projectID: project.id)
                .first { $0.id == conversationID }
        }
        guard let conversation = matched else {
            throw WorkspaceRepositoryError.conversationNotFound
        }
        let (_, root) = try await registerProject(id: conversation.projectID)
        await kernelRegistry.register(environmentID: conversation.environmentID, root: root)

        if let deletionOperationID = conversation.deletionOperationID {
            deletionPreparations.removeValue(forKey: conversationID)
            return ConversationDeletionImpact(
                conversationID: conversation.id,
                projectID: conversation.projectID,
                environmentID: conversation.environmentID,
                dirtyDocuments: [],
                deletionOperationID: deletionOperationID
            )
        }

        let targetContext = WorkspaceContextID.conversation(conversationID)
        let states = try await repository.allClientStates()
        var persistedViewers: [DocumentID: Set<WorkspaceContextID>] = [:]
        for state in states {
            for tab in state.tabs {
                guard case let .file(documentID) = tab.resource else { continue }
                persistedViewers[documentID, default: []].insert(state.key.workspaceContextID)
            }
        }
        let targetDocumentIDs = Set(
            persistedViewers.compactMap { documentID, contexts in
                contexts.contains(targetContext) ? documentID : nil
            }
        )
        let documentStates = try await kernelRegistry.documentDeletionStates(
            in: conversation.environmentID,
            documentIDs: targetDocumentIDs,
            includingViewerContext: targetContext
        )
        let relevantDocumentIDs = Set(documentStates.map { $0.snapshot.documentID })
        var expectedPersistedViewers: Set<ConversationDeletionPersistedViewer> = []
        for documentID in relevantDocumentIDs {
            for contextID in persistedViewers[documentID, default: []] {
                expectedPersistedViewers.insert(ConversationDeletionPersistedViewer(
                    documentID: documentID,
                    contextID: contextID
                ))
            }
        }
        let dirtyDocuments = documentStates.compactMap { state -> DocumentSnapshot? in
            guard state.snapshot.dirtyState != .clean else { return nil }
            let otherPersisted = persistedViewers[state.snapshot.documentID, default: []]
                .subtracting([targetContext])
            let otherLive = state.liveViewerContexts.subtracting([targetContext])
            guard otherPersisted.isEmpty, otherLive.isEmpty else { return nil }
            return state.snapshot
        }.sorted { lhs, rhs in
            if lhs.relativePath.string == rhs.relativePath.string {
                return lhs.documentID.description < rhs.documentID.description
            }
            return lhs.relativePath.string < rhs.relativePath.string
        }
        let preparationID = UUID()
        deletionPreparations[conversationID] = DeletionPreparation(
            id: preparationID,
            conversationID: conversationID,
            environmentID: conversation.environmentID,
            targetContextID: targetContext,
            relevantDocumentIDs: relevantDocumentIDs,
            persistedViewers: expectedPersistedViewers,
            documentStates: documentStates
        )
        return ConversationDeletionImpact(
            conversationID: conversation.id,
            projectID: conversation.projectID,
            environmentID: conversation.environmentID,
            dirtyDocuments: dirtyDocuments,
            preparationID: preparationID
        )
    }

    public func beginConversationDeletion(
        conversationID: ConversationID,
        operationID: DeletionOperationID,
        preparationID: UUID
    ) async throws -> ConversationDeletionProgress {
        guard let deletionCoordinator else {
            throw ConversationDeletionError.terminalControlUnavailable
        }
        guard let preparation = deletionPreparations[conversationID],
              preparation.id == preparationID,
              preparation.conversationID == conversationID else {
            return .preparationStale(
                try await deletionImpact(conversationID: conversationID)
            )
        }

        let reservation: ConversationDeletionDocumentReservation
        do {
            reservation = try await kernelRegistry.reserveConversationDeletion(
                in: preparation.environmentID,
                preparationID: preparation.id,
                targetContextID: preparation.targetContextID,
                expectedDocumentStates: preparation.documentStates
            )
        } catch ConversationDeletionError.stalePreparation {
            if deletionPreparations[conversationID]?.id == preparation.id {
                deletionPreparations.removeValue(forKey: conversationID)
            }
            return .preparationStale(
                try await deletionImpact(conversationID: conversationID)
            )
        }

        do {
            _ = try await repository.beginConversationDeletion(
                conversationID: conversationID,
                operationID: operationID,
                targetContextID: preparation.targetContextID,
                relevantDocumentIDs: preparation.relevantDocumentIDs,
                expectedPersistedViewers: preparation.persistedViewers
            )
        } catch ConversationDeletionError.stalePreparation {
            await kernelRegistry.cancelConversationDeletion(reservation)
            if deletionPreparations[conversationID]?.id == preparation.id {
                deletionPreparations.removeValue(forKey: conversationID)
            }
            return .preparationStale(
                try await deletionImpact(conversationID: conversationID)
            )
        } catch {
            await kernelRegistry.cancelConversationDeletion(reservation)
            throw error
        }

        await kernelRegistry.commitConversationDeletion(
            reservation,
            blocking: preparation.targetContextID
        )
        if deletionPreparations[conversationID]?.id == preparation.id {
            deletionPreparations.removeValue(forKey: conversationID)
        }

        do {
            try await deletionCoordinator.resume(operationID: operationID)
        } catch let error as ConversationDeletionError {
            if case let .forceConfirmationRequired(id, sessions) = error {
                return .forceConfirmationRequired(operationID: id, activeSessionIDs: sessions)
            }
            throw error
        }
        return try await deletedProgress(operationID: operationID)
    }

    public func resumeConversationDeletion(
        operationID: DeletionOperationID,
        force: Bool
    ) async throws -> ConversationDeletionProgress {
        guard let deletionCoordinator else {
            throw ConversationDeletionError.terminalControlUnavailable
        }
        do {
            if force {
                try await deletionCoordinator.force(operationID: operationID)
            } else {
                try await deletionCoordinator.resume(operationID: operationID)
            }
        } catch let error as ConversationDeletionError {
            if case let .forceConfirmationRequired(id, sessions) = error {
                return .forceConfirmationRequired(operationID: id, activeSessionIDs: sessions)
            }
            throw error
        }
        return try await deletedProgress(operationID: operationID)
    }

    private func deletedProgress(
        operationID: DeletionOperationID
    ) async throws -> ConversationDeletionProgress {
        guard let operation = try await repository.conversationDeletion(operationID: operationID),
              operation.phase == .deleted else {
            throw ConversationDeletionError.operationMismatch
        }
        return .deleted(projectContextID: .project(operation.projectID))
    }

    private func snapshot(for project: Project) async throws -> ProjectSnapshot {
        ProjectSnapshot(
            projectID: project.id,
            displayName: project.displayName,
            resolvedContext: try await repository.resolve(.project(project.id)),
            conversations: try await repository.listConversations(projectID: project.id)
        )
    }

    private func registerProject(
        id projectID: ProjectID
    ) async throws -> (Project, ResolvedProjectRoot) {
        guard let project = try await repository.listProjects().first(where: { $0.id == projectID }) else {
            throw WorkspaceRepositoryError.projectNotFound
        }
        let root = try rootResolver.resolve(bookmark: project.rootBookmark)
        await kernelRegistry.register(environmentID: project.baseEnvironmentID, root: root)
        return (project, root)
    }
}

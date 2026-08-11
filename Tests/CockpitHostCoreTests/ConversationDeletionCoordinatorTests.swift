import Foundation
import Testing
import CockpitProtocol
import CockpitTypes
@testable import CockpitHostCore

@Test func conversationDeletionImpactPromptsOnlyDirtyDocumentsLosingTheirFinalViewer() async throws {
    let fixture = try ConversationDeletionHostFixture()
    let repository = ConversationDeletionRepositoryFixture(
        conversation: fixture.conversation,
        clientStates: [
            try fixture.clientState(
                contextID: .conversation(fixture.conversation.id),
                documentIDs: [fixture.sharedDocument.documentID, fixture.orphanedDocument.documentID],
                window: 1
            ),
            try fixture.clientState(
                contextID: .project(fixture.projectID),
                documentIDs: [fixture.sharedDocument.documentID],
                window: 2
            ),
        ]
    )
    let kernels = ConversationDeletionKernelFixture(states: [
        DocumentDeletionState(
            snapshot: fixture.sharedDocument,
            liveViewerContexts: [.conversation(fixture.conversation.id), .project(fixture.projectID)]
        ),
        DocumentDeletionState(
            snapshot: fixture.orphanedDocument,
            liveViewerContexts: [.conversation(fixture.conversation.id)]
        ),
        DocumentDeletionState(
            snapshot: fixture.cleanDocument,
            liveViewerContexts: [.conversation(fixture.conversation.id)]
        ),
        DocumentDeletionState(
            snapshot: fixture.liveOnlyDocument,
            liveViewerContexts: [.conversation(fixture.conversation.id)]
        ),
    ])
    let service = WorkspaceService(
        repository: repository,
        rootResolver: ConversationDeletionRootResolver(),
        kernelRegistry: kernels
    )

    let impact = try await service.deletionImpact(conversationID: fixture.conversation.id)

    #expect(await kernels.registeredEnvironmentIDs.contains(fixture.environmentID))
    #expect(impact.conversationID == fixture.conversation.id)
    #expect(impact.projectID == fixture.projectID)
    #expect(impact.environmentID == fixture.environmentID)
    #expect(impact.dirtyDocuments.map(\.documentID) == [
        fixture.orphanedDocument.documentID,
        fixture.liveOnlyDocument.documentID,
    ])
}

@Test func conversationDeletionBeginRejectsDocumentChangesAfterImpactWithoutCreatingOperation() async throws {
    let fixture = try ConversationDeletionHostFixture()
    let targetContext = WorkspaceContextID.conversation(fixture.conversation.id)
    let repository = ConversationDeletionRepositoryFixture(
        conversation: fixture.conversation,
        clientStates: [
            try fixture.clientState(
                contextID: targetContext,
                documentIDs: [fixture.orphanedDocument.documentID],
                window: 1
            ),
        ]
    )
    let kernels = ConversationDeletionKernelFixture(states: [
        DocumentDeletionState(
            snapshot: fixture.orphanedDocument,
            liveViewerContexts: [targetContext]
        ),
    ])
    let terminal = ConversationDeletionTerminalFixture(results: [.complete])
    let service = WorkspaceService(
        repository: repository,
        rootResolver: ConversationDeletionRootResolver(),
        kernelRegistry: kernels,
        terminalDeletion: terminal
    )
    let operationID = DeletionOperationID()

    let impact = try await service.deletionImpact(conversationID: fixture.conversation.id)
    let preparationID = try #require(impact.preparationID)
    await kernels.replaceStates(with: [
        DocumentDeletionState(
            snapshot: try DocumentSnapshot(
                validatingDocumentID: fixture.orphanedDocument.documentID,
                environmentID: fixture.environmentID,
                relativePath: fixture.orphanedDocument.relativePath,
                text: fixture.orphanedDocument.text + " after impact",
                documentVersion: fixture.orphanedDocument.documentVersion + 1,
                persistedVersion: fixture.orphanedDocument.persistedVersion,
                lastAcceptedClientSequence: fixture.orphanedDocument.lastAcceptedClientSequence + 1,
                dirtyState: .dirty,
                observedDiskFingerprint: fixture.orphanedDocument.observedDiskFingerprint,
                currentLease: fixture.orphanedDocument.currentLease,
                maintenance: fixture.orphanedDocument.maintenance
            ),
            liveViewerContexts: [targetContext]
        ),
    ])

    let result = try await service.beginConversationDeletion(
        conversationID: fixture.conversation.id,
        operationID: operationID,
        preparationID: preparationID
    )
    guard case let .preparationStale(freshImpact) = result else {
        Issue.record("changed preparation must return a fresh impact")
        return
    }
    #expect(freshImpact.dirtyDocuments.first?.documentVersion == 3)
    #expect(freshImpact.preparationID != preparationID)
    #expect(await repository.operations.isEmpty)
    #expect(await terminal.calls.isEmpty)
}

@Test func conversationDeletionBeginRejectsPersistedViewerRemovalForLiveOnlyTargetDocument() async throws {
    let fixture = try ConversationDeletionHostFixture()
    let targetContext = WorkspaceContextID.conversation(fixture.conversation.id)
    let otherContext = WorkspaceContextID.project(fixture.projectID)
    let repository = ConversationDeletionRepositoryFixture(
        conversation: fixture.conversation,
        clientStates: [
            try fixture.clientState(
                contextID: otherContext,
                documentIDs: [fixture.liveOnlyDocument.documentID],
                window: 2
            ),
        ]
    )
    let kernels = ConversationDeletionKernelFixture(states: [
        DocumentDeletionState(
            snapshot: fixture.liveOnlyDocument,
            liveViewerContexts: [targetContext]
        ),
    ])
    let terminal = ConversationDeletionTerminalFixture(results: [.complete])
    let service = WorkspaceService(
        repository: repository,
        rootResolver: ConversationDeletionRootResolver(),
        kernelRegistry: kernels,
        terminalDeletion: terminal
    )
    let operationID = DeletionOperationID()

    let impact = try await service.deletionImpact(conversationID: fixture.conversation.id)
    #expect(impact.dirtyDocuments.isEmpty)
    let preparationID = try #require(impact.preparationID)
    await repository.replaceClientStates(with: [])

    let result = try await service.beginConversationDeletion(
        conversationID: fixture.conversation.id,
        operationID: operationID,
        preparationID: preparationID
    )

    guard case .preparationStale = result else {
        Issue.record("removing the only persisted viewer must stale the preparation")
        return
    }
    #expect(await repository.operations.isEmpty)
    #expect(await terminal.calls.isEmpty)
}

@Test func concurrentConversationDeletionsReevaluateSharedDirtyDocumentAfterFirstContextRetires() async throws {
    let fixture = try ConversationDeletionHostFixture()
    let second = Conversation(
        id: ConversationID(),
        projectID: fixture.projectID,
        environmentID: fixture.environmentID,
        title: "Delete second",
        lifecycleState: .active,
        deletionOperationID: nil,
        createdAt: Date(timeIntervalSince1970: 2)
    )
    let firstContext = WorkspaceContextID.conversation(fixture.conversation.id)
    let secondContext = WorkspaceContextID.conversation(second.id)
    let repository = ConversationDeletionRepositoryFixture(
        conversation: fixture.conversation,
        additionalConversations: [second],
        clientStates: [
            try fixture.clientState(
                contextID: firstContext,
                documentIDs: [fixture.sharedDocument.documentID],
                window: 1
            ),
            try fixture.clientState(
                contextID: secondContext,
                documentIDs: [fixture.sharedDocument.documentID],
                window: 2
            ),
        ]
    )
    let kernels = ConversationDeletionKernelFixture(states: [
        DocumentDeletionState(
            snapshot: fixture.sharedDocument,
            liveViewerContexts: [firstContext, secondContext]
        ),
    ])
    let terminal = ConversationDeletionTerminalFixture(results: [.complete])
    let service = WorkspaceService(
        repository: repository,
        rootResolver: ConversationDeletionRootResolver(),
        kernelRegistry: kernels,
        terminalDeletion: terminal
    )

    let firstImpact = try await service.deletionImpact(
        conversationID: fixture.conversation.id
    )
    let secondImpact = try await service.deletionImpact(conversationID: second.id)
    #expect(firstImpact.dirtyDocuments.isEmpty)
    #expect(secondImpact.dirtyDocuments.isEmpty)

    let firstResult = try await service.beginConversationDeletion(
        conversationID: fixture.conversation.id,
        operationID: DeletionOperationID(),
        preparationID: try #require(firstImpact.preparationID)
    )
    guard case .deleted = firstResult else {
        Issue.record("first deletion did not finish")
        return
    }

    let secondResult = try await service.beginConversationDeletion(
        conversationID: second.id,
        operationID: DeletionOperationID(),
        preparationID: try #require(secondImpact.preparationID)
    )
    guard case let .preparationStale(freshImpact) = secondResult else {
        Issue.record("second deletion must re-evaluate the retired first Context")
        return
    }
    #expect(freshImpact.dirtyDocuments.map(\.documentID) == [
        fixture.sharedDocument.documentID,
    ])
}

@Test func conversationDeletionCancelBeforeBeginCreatesNoOperationOrTerminalGate() async throws {
    let fixture = try ConversationDeletionHostFixture()
    let repository = ConversationDeletionRepositoryFixture(conversation: fixture.conversation)
    let terminal = ConversationDeletionTerminalFixture(results: [])
    let coordinator = ConversationDeletionCoordinator(repository: repository, terminal: terminal)

    #expect(await repository.operations.isEmpty)
    #expect(await terminal.calls.isEmpty)
    _ = coordinator
}

@Test func conversationDeletionNormalTerminationStopsAtForceConfirmationWithoutPurging() async throws {
    let fixture = try ConversationDeletionHostFixture()
    let operationID = DeletionOperationID(
        UUID(uuidString: "71000000-0000-4000-8000-000000000001")!
    )
    let activeSession = TerminalSessionID(
        UUID(uuidString: "71000000-0000-4000-8000-000000000002")!
    )
    let repository = ConversationDeletionRepositoryFixture(conversation: fixture.conversation)
    let terminal = ConversationDeletionTerminalFixture(
        results: [.forceConfirmationRequired(activeSessionIDs: [activeSession])]
    )
    let coordinator = ConversationDeletionCoordinator(repository: repository, terminal: terminal)

    await #expect(throws: ConversationDeletionError.forceConfirmationRequired(
        operationID: operationID,
        activeSessionIDs: [activeSession]
    )) {
        try await coordinator.begin(
            conversationID: fixture.conversation.id,
            operationID: operationID
        )
    }

    #expect(await repository.operations[operationID]?.phase == .terminatingSessions)
    #expect(await terminal.calls == [
        .begin(.conversation(fixture.conversation.id), operationID),
        .terminate(.conversation(fixture.conversation.id), operationID, false),
    ])
    #expect(await repository.finishCount == 0)
}

@Test func conversationDeletionExplicitForceCompletesEveryDurablePhaseExactlyOnce() async throws {
    let fixture = try ConversationDeletionHostFixture()
    let operationID = DeletionOperationID(
        UUID(uuidString: "72000000-0000-4000-8000-000000000001")!
    )
    let activeSession = TerminalSessionID(
        UUID(uuidString: "72000000-0000-4000-8000-000000000002")!
    )
    let repository = ConversationDeletionRepositoryFixture(conversation: fixture.conversation)
    let terminal = ConversationDeletionTerminalFixture(
        results: [
            .forceConfirmationRequired(activeSessionIDs: [activeSession]),
            .complete,
        ]
    )
    let coordinator = ConversationDeletionCoordinator(repository: repository, terminal: terminal)

    do {
        try await coordinator.begin(
            conversationID: fixture.conversation.id,
            operationID: operationID
        )
        Issue.record("normal termination must require a separate force confirmation")
    } catch let error as ConversationDeletionError {
        #expect(error == .forceConfirmationRequired(
            operationID: operationID,
            activeSessionIDs: [activeSession]
        ))
    }

    try await coordinator.force(operationID: operationID)
    try await coordinator.resume(operationID: operationID)

    #expect(await repository.operations[operationID]?.phase == .deleted)
    #expect(await repository.finishCount == 1)
    #expect(await terminal.calls == [
        .begin(.conversation(fixture.conversation.id), operationID),
        .terminate(.conversation(fixture.conversation.id), operationID, false),
        .terminate(.conversation(fixture.conversation.id), operationID, true),
        .purge(.conversation(fixture.conversation.id), operationID),
    ])
}

@Test func conversationDeletionResumeContinuesFromPersistedPhaseWithoutRepeatingCompletedEffects() async throws {
    let fixture = try ConversationDeletionHostFixture()
    let phases: [ConversationDeletionPhase] = [
        .deleting, .terminatingSessions, .purgingTerminalRecords, .removingClientState, .deleted,
    ]

    for (offset, phase) in phases.enumerated() {
        let operationID = DeletionOperationID(
            UUID(uuidString: String(format: "73000000-0000-4000-8000-%012d", offset + 1))!
        )
        let repository = ConversationDeletionRepositoryFixture(
            conversation: fixture.conversation,
            operation: ConversationDeletionOperation(
                operationID: operationID,
                conversationID: fixture.conversation.id,
                projectID: fixture.projectID,
                environmentID: fixture.environmentID,
                phase: phase
            )
        )
        let terminal = ConversationDeletionTerminalFixture(results: [.complete])
        let coordinator = ConversationDeletionCoordinator(repository: repository, terminal: terminal)

        try await coordinator.resume(operationID: operationID)

        #expect(await repository.operations[operationID]?.phase == .deleted)
        switch phase {
        case .deleting:
            #expect(await terminal.calls == [
                .begin(.conversation(fixture.conversation.id), operationID),
                .terminate(.conversation(fixture.conversation.id), operationID, false),
                .purge(.conversation(fixture.conversation.id), operationID),
            ])
        case .terminatingSessions:
            #expect(await terminal.calls == [
                .terminate(.conversation(fixture.conversation.id), operationID, false),
                .purge(.conversation(fixture.conversation.id), operationID),
            ])
        case .purgingTerminalRecords:
            #expect(await terminal.calls == [
                .purge(.conversation(fixture.conversation.id), operationID),
            ])
        case .removingClientState, .deleted:
            #expect(await terminal.calls.isEmpty)
        }
    }
}

@Test func conversationDeletionSerializesConcurrentResumeForTheSameOperation() async throws {
    let fixture = try ConversationDeletionHostFixture()
    let operationID = DeletionOperationID()
    let repository = ConversationDeletionRepositoryFixture(
        conversation: fixture.conversation,
        operation: ConversationDeletionOperation(
            operationID: operationID,
            conversationID: fixture.conversation.id,
            projectID: fixture.projectID,
            environmentID: fixture.environmentID,
            phase: .deleting
        )
    )
    let barrier = ConversationDeletionBarrier()
    let terminal = PausingConversationDeletionTerminal(barrier: barrier)
    let coordinator = ConversationDeletionCoordinator(
        repository: repository,
        terminal: terminal
    )

    let first = Task { try await coordinator.resume(operationID: operationID) }
    await barrier.waitUntilEntered()
    let second = Task { try await coordinator.resume(operationID: operationID) }
    try await Task.sleep(for: .milliseconds(25))

    #expect(await terminal.beginCount == 1)
    await barrier.release()
    try await first.value
    try await second.value
    #expect(await repository.operations[operationID]?.phase == .deleted)
    #expect(await terminal.beginCount == 1)
    #expect(await terminal.terminateCount == 1)
    #expect(await terminal.purgeCount == 1)
}

private struct ConversationDeletionHostFixture {
    let projectID = ProjectID(UUID(uuidString: "70000000-0000-4000-8000-000000000001")!)
    let environmentID = EnvironmentID(UUID(uuidString: "70000000-0000-4000-8000-000000000002")!)
    let conversation: Conversation
    let sharedDocument: DocumentSnapshot
    let orphanedDocument: DocumentSnapshot
    let cleanDocument: DocumentSnapshot
    let liveOnlyDocument: DocumentSnapshot

    init() throws {
        let conversationID = ConversationID(
            UUID(uuidString: "70000000-0000-4000-8000-000000000003")!
        )
        conversation = Conversation(
            id: conversationID,
            projectID: projectID,
            environmentID: environmentID,
            title: "Delete me",
            lifecycleState: .active,
            deletionOperationID: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        sharedDocument = try Self.snapshot(
            id: "70000000-0000-4000-8000-000000000011",
            environmentID: environmentID,
            path: "shared.txt",
            dirty: .dirty
        )
        orphanedDocument = try Self.snapshot(
            id: "70000000-0000-4000-8000-000000000012",
            environmentID: environmentID,
            path: "orphaned.txt",
            dirty: .conflict
        )
        cleanDocument = try Self.snapshot(
            id: "70000000-0000-4000-8000-000000000013",
            environmentID: environmentID,
            path: "clean.txt",
            dirty: .clean
        )
        liveOnlyDocument = try Self.snapshot(
            id: "70000000-0000-4000-8000-000000000014",
            environmentID: environmentID,
            path: "z-live-only.txt",
            dirty: .dirty
        )
    }

    func clientState(
        contextID: WorkspaceContextID,
        documentIDs: [DocumentID],
        window: Int
    ) throws -> ClientWorkspaceState {
        let tabs = try documentIDs.enumerated().map { index, documentID in
            try TabRecord(
                validatingID: TabID(UUID(uuidString: String(
                    format: "70000000-0000-4000-8%03d-%012d",
                    window,
                    index + 100
                ))!),
                resource: .file(documentID),
                terminalKind: nil,
                fileViewState: .initial()
            )
        }
        return try ClientWorkspaceState(
            validatingKey: ClientWorkspaceStateKey(
                deviceID: DeviceID(UUID(uuidString: "70000000-0000-4000-8000-000000000021")!),
                windowID: WindowID(UUID(uuidString: String(
                    format: "70000000-0000-4000-8000-%012d",
                    window + 30
                ))!),
                workspaceContextID: contextID
            ),
            tabs: tabs,
            selectedTabID: tabs.first?.id,
            sidebar: SidebarState(isCollapsed: false),
            splitView: SplitViewState(
                validatingLeadingPaneWidth: 200,
                trailingPaneWidth: 300
            )
        )
    }

    private static func snapshot(
        id: String,
        environmentID: EnvironmentID,
        path: String,
        dirty: DocumentDirtyState
    ) throws -> DocumentSnapshot {
        try DocumentSnapshot(
            validatingDocumentID: DocumentID(UUID(uuidString: id)!),
            environmentID: environmentID,
            relativePath: RelativePath(path),
            text: "fixture",
            documentVersion: dirty == .clean ? 1 : 2,
            persistedVersion: 1,
            lastAcceptedClientSequence: dirty == .clean ? 0 : 1,
            dirtyState: dirty,
            observedDiskFingerprint: nil,
            currentLease: nil,
            maintenance: []
        )
    }
}

private actor ConversationDeletionRepositoryFixture: WorkspaceRepository {
    let conversation: Conversation
    private var storedConversations: [ConversationID: Conversation]
    private var clientStates: [ClientWorkspaceState]
    var operations: [DeletionOperationID: ConversationDeletionOperation] = [:]
    var finishCount = 0

    init(
        conversation: Conversation,
        additionalConversations: [Conversation] = [],
        clientStates: [ClientWorkspaceState] = [],
        operation: ConversationDeletionOperation? = nil
    ) {
        self.conversation = conversation
        storedConversations = Dictionary(
            uniqueKeysWithValues: ([conversation] + additionalConversations).map {
                ($0.id, $0)
            }
        )
        self.clientStates = clientStates
        if let operation { operations[operation.operationID] = operation }
    }

    func createProjectWithDirectEnvironment(_ input: NewProject) throws -> Project {
        throw WorkspaceRepositoryError.phaseOneProjectLimit
    }
    func listProjects() -> [Project] {
        [Project(
            id: conversation.projectID,
            displayName: "Fixture",
            rootBookmark: Data([1]),
            canonicalRootIdentity: "fixture-root",
            baseEnvironmentID: conversation.environmentID,
            createdAt: conversation.createdAt
        )]
    }
    func createConversation(_ input: NewConversation) throws -> Conversation { conversation }
    func listConversations(projectID: ProjectID) -> [Conversation] {
        storedConversations.values
            .filter { $0.projectID == projectID }
            .sorted { $0.createdAt < $1.createdAt }
    }
    func renameConversation(id: ConversationID, title: String) {}
    func resolve(_ contextID: WorkspaceContextID) throws -> ResolvedWorkspaceContext {
        let resolvedConversation: Conversation?
        switch contextID {
        case .project:
            resolvedConversation = nil
        case let .conversation(id):
            resolvedConversation = storedConversations[id]
            guard resolvedConversation != nil else {
                throw WorkspaceRepositoryError.conversationNotFound
            }
        }
        return try ResolvedWorkspaceContext(
            validating: contextID,
            projectID: conversation.projectID,
            conversationID: resolvedConversation?.id,
            environmentID: conversation.environmentID,
            workspaceRootIdentity: "fixture-root"
        )
    }
    func loadClientState(_ key: ClientWorkspaceStateKey) -> ClientWorkspaceState? {
        clientStates.first { $0.key == key }
    }
    func saveClientState(_ state: ClientWorkspaceState) {}
    func relocateDocumentLocators(
        in environmentID: EnvironmentID,
        from source: RelativePath,
        to destination: RelativePath
    ) {}
    func allClientStates() -> [ClientWorkspaceState] {
        clientStates.filter { state in
            switch state.key.workspaceContextID {
            case .project:
                return true
            case let .conversation(id):
                return storedConversations[id]?.lifecycleState == .active
            }
        }
    }

    func replaceClientStates(with states: [ClientWorkspaceState]) {
        clientStates = states
    }

    func beginConversationDeletion(
        conversationID: ConversationID,
        operationID: DeletionOperationID
    ) throws -> ConversationDeletionOperation {
        if let existing = operations[operationID] { return existing }
        guard let current = storedConversations[conversationID] else {
            throw WorkspaceRepositoryError.conversationNotFound
        }
        let operation = ConversationDeletionOperation(
            operationID: operationID,
            conversationID: conversationID,
            projectID: current.projectID,
            environmentID: current.environmentID,
            phase: .deleting
        )
        operations[operationID] = operation
        storedConversations[conversationID] = Conversation(
            id: current.id,
            projectID: current.projectID,
            environmentID: current.environmentID,
            title: current.title,
            lifecycleState: .deleting(phase: "deleting"),
            deletionOperationID: operationID,
            createdAt: current.createdAt
        )
        return operation
    }

    func beginConversationDeletion(
        conversationID: ConversationID,
        operationID: DeletionOperationID,
        targetContextID: WorkspaceContextID,
        relevantDocumentIDs: Set<DocumentID>,
        expectedPersistedViewers: Set<ConversationDeletionPersistedViewer>
    ) throws -> ConversationDeletionOperation {
        let actual = Set(clientStates.flatMap { state in
            state.tabs.compactMap { tab -> ConversationDeletionPersistedViewer? in
                guard case let .file(documentID) = tab.resource,
                      state.key.workspaceContextID == targetContextID
                        || relevantDocumentIDs.contains(documentID) else {
                    return nil
                }
                return ConversationDeletionPersistedViewer(
                    documentID: documentID,
                    contextID: state.key.workspaceContextID
                )
            }
        })
        guard actual == expectedPersistedViewers else {
            throw ConversationDeletionError.stalePreparation
        }
        return try beginConversationDeletion(
            conversationID: conversationID,
            operationID: operationID
        )
    }

    func conversationDeletion(operationID: DeletionOperationID) -> ConversationDeletionOperation? {
        operations[operationID]
    }

    func advanceConversationDeletion(
        operationID: DeletionOperationID,
        from expected: ConversationDeletionPhase,
        to phase: ConversationDeletionPhase
    ) throws -> ConversationDeletionOperation {
        guard let current = operations[operationID], current.phase == expected else {
            throw ConversationDeletionError.operationMismatch
        }
        let advanced = ConversationDeletionOperation(
            operationID: current.operationID,
            conversationID: current.conversationID,
            projectID: current.projectID,
            environmentID: current.environmentID,
            phase: phase
        )
        operations[operationID] = advanced
        return advanced
    }

    func finishConversationDeletion(operationID: DeletionOperationID) throws {
        guard let current = operations[operationID], current.phase == .removingClientState else {
            throw ConversationDeletionError.operationMismatch
        }
        operations[operationID] = ConversationDeletionOperation(
            operationID: current.operationID,
            conversationID: current.conversationID,
            projectID: current.projectID,
            environmentID: current.environmentID,
            phase: .deleted
        )
        storedConversations.removeValue(forKey: current.conversationID)
        clientStates.removeAll {
            $0.key.workspaceContextID == .conversation(current.conversationID)
        }
        finishCount += 1
    }
}

private actor ConversationDeletionTerminalFixture: ContextTerminalDeletionControlling {
    enum Call: Hashable {
        case begin(WorkspaceContextID, DeletionOperationID)
        case terminate(WorkspaceContextID, DeletionOperationID, Bool)
        case purge(WorkspaceContextID, DeletionOperationID)
    }

    var calls: [Call] = []
    private var results: [ContextTerminationResult]

    init(results: [ContextTerminationResult]) { self.results = results }

    func beginContextDeletion(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) {
        calls.append(.begin(contextID, operationID))
    }

    func terminateSessions(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID,
        force: Bool
    ) -> ContextTerminationResult {
        calls.append(.terminate(contextID, operationID, force))
        return results.isEmpty ? .complete : results.removeFirst()
    }

    func purgeDeletedContext(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) {
        calls.append(.purge(contextID, operationID))
    }
}

private actor PausingConversationDeletionTerminal: ContextTerminalDeletionControlling {
    private let barrier: ConversationDeletionBarrier
    private(set) var beginCount = 0
    private(set) var terminateCount = 0
    private(set) var purgeCount = 0

    init(barrier: ConversationDeletionBarrier) {
        self.barrier = barrier
    }

    func beginContextDeletion(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) async {
        beginCount += 1
        if beginCount == 1 { await barrier.suspend() }
    }

    func terminateSessions(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID,
        force: Bool
    ) -> ContextTerminationResult {
        terminateCount += 1
        return .complete
    }

    func purgeDeletedContext(
        contextID: WorkspaceContextID,
        operationID: DeletionOperationID
    ) {
        purgeCount += 1
    }
}

private actor ConversationDeletionBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ConversationDeletionKernelFixture: WorkspaceKernelRegistering {
    private var states: [DocumentDeletionState]
    private var blockedContexts: Set<WorkspaceContextID> = []
    private(set) var registeredEnvironmentIDs: [EnvironmentID] = []
    init(states: [DocumentDeletionState]) { self.states = states }
    func replaceStates(with values: [DocumentDeletionState]) { states = values }
    func register(environmentID: EnvironmentID, root: ResolvedProjectRoot) {
        registeredEnvironmentIDs.append(environmentID)
    }
    func perform(_ operation: FileOperation, in environmentID: EnvironmentID) throws -> FileOperationResult {
        throw FileOperationError.environmentNotRegistered
    }
    func documentDeletionStates(
        in environmentID: EnvironmentID,
        documentIDs: Set<DocumentID>
    ) -> [DocumentDeletionState] {
        currentStates().filter { documentIDs.contains($0.snapshot.documentID) }
    }
    func documentDeletionStates(
        in environmentID: EnvironmentID,
        documentIDs: Set<DocumentID>,
        includingViewerContext contextID: WorkspaceContextID
    ) -> [DocumentDeletionState] {
        currentStates().filter {
            documentIDs.contains($0.snapshot.documentID)
                || $0.liveViewerContexts.contains(contextID)
        }
    }
    func reserveConversationDeletion(
        in environmentID: EnvironmentID,
        preparationID: UUID,
        targetContextID: WorkspaceContextID,
        expectedDocumentStates: [DocumentDeletionState]
    ) throws -> ConversationDeletionDocumentReservation {
        guard Set(currentStates()) == Set(expectedDocumentStates) else {
            throw ConversationDeletionError.stalePreparation
        }
        return ConversationDeletionDocumentReservation(
            id: preparationID,
            environmentID: environmentID
        )
    }

    func commitConversationDeletion(
        _ reservation: ConversationDeletionDocumentReservation,
        blocking targetContextID: WorkspaceContextID
    ) {
        blockedContexts.insert(targetContextID)
    }

    private func currentStates() -> [DocumentDeletionState] {
        states.map {
            DocumentDeletionState(
                snapshot: $0.snapshot,
                liveViewerContexts: $0.liveViewerContexts.subtracting(blockedContexts)
            )
        }
    }
}

private struct ConversationDeletionRootResolver: ProjectRootResolving {
    func resolve(bookmark: Data) throws -> ResolvedProjectRoot {
        ResolvedProjectRoot(
            canonicalAbsolutePath: "/private/tmp/Cockpit-Conversation-Deletion",
            canonicalRootIdentity: "conversation-deletion-root",
            gitCommonDirectory: nil,
            accessToken: ConversationDeletionRootToken()
        )
    }
}

private final class ConversationDeletionRootToken:
    ProjectRootAccessToken,
    @unchecked Sendable
{}

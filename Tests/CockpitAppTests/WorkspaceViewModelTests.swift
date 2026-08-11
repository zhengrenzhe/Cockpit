import Foundation
import XCTest
import CockpitClientCore
import CockpitHostCore
import CockpitTypes
@testable import Cockpit

@MainActor
final class WorkspaceViewModelTests: XCTestCase {
    func testProjectWithoutConversationsRemainsSelectableAndSelectionsAdvanceGeneration() async throws {
        let fixture = try WorkspaceModelFixture()
        let viewModel = fixture.makeViewModel()

        try await viewModel.loadWorkspace()

        XCTAssertEqual(viewModel.projects.count, 2)
        XCTAssertEqual(viewModel.projects[0].conversations, [])
        XCTAssertEqual(
            viewModel.sidebarItems,
            [
                .project(fixture.emptyProject.projectID),
                .project(fixture.project.projectID),
                .conversation(fixture.conversation.id),
            ]
        )

        let project = try await viewModel.selectContext(
            .project(fixture.emptyProject.projectID)
        )
        let conversation = try await viewModel.selectContext(
            .conversation(fixture.conversation.id)
        )

        XCTAssertEqual(project.generation, 1)
        XCTAssertEqual(conversation.generation, 2)
        XCTAssertEqual(conversation.environmentID, fixture.conversation.environmentID)
        XCTAssertEqual(viewModel.activeContext, conversation)
    }

    func testContextLocalTabsPersistPickerReplacementAndCancellationIndependently() async throws {
        let fixture = try WorkspaceModelFixture()
        let viewModel = fixture.makeViewModel()
        try await viewModel.loadWorkspace()

        try await viewModel.selectContext(.project(fixture.project.projectID))
        let projectPicker = try await viewModel.openNewTabPicker()
        let documentID = DocumentID()
        try await viewModel.replaceNewTabPicker(
            projectPicker,
            with: .file(documentID)
        )

        try await viewModel.selectContext(.conversation(fixture.conversation.id))
        let shellPicker = try await viewModel.openNewTabPicker()
        let shellSession = TerminalSessionID()
        try await viewModel.replaceNewTabPicker(
            shellPicker,
            with: .shell(shellSession)
        )
        let cancelledPicker = try await viewModel.openNewTabPicker()
        try await viewModel.cancelNewTabPicker(cancelledPicker)

        XCTAssertEqual(
            viewModel.currentTabs.map(\.kind),
            [.shell(shellSession)]
        )
        let projectTabs = try await viewModel.tabs(
            for: .project(fixture.project.projectID)
        )
        let conversationTabs = try await viewModel.tabs(
            for: .conversation(fixture.conversation.id)
        )
        XCTAssertEqual(
            projectTabs.map(\.kind),
            [.file(documentID)]
        )
        XCTAssertEqual(
            conversationTabs.map(\.kind),
            [.shell(shellSession)]
        )
    }

    func testEveryFrozenTabKindCanReplaceTheContextLocalPickerInPlace() async throws {
        let fixture = try WorkspaceModelFixture()
        let viewModel = fixture.makeViewModel()
        try await viewModel.loadWorkspace()
        try await viewModel.selectContext(.project(fixture.project.projectID))

        let kinds: [WorkspaceTabKind] = [
            .file(DocumentID()),
            .shell(TerminalSessionID()),
            .codex(TerminalSessionID()),
            .claude(TerminalSessionID()),
        ]
        for kind in kinds {
            let picker = try await viewModel.openNewTabPicker()
            try await viewModel.replaceNewTabPicker(picker, with: kind)
        }

        XCTAssertEqual(viewModel.currentTabs.map(\.kind), kinds)
        XCTAssertEqual(NewTabPickerController.options, [.file, .shell, .codex, .claude])
    }

    func testStaleAsyncContextSelectionCannotOverwriteTheLatestIntent() async throws {
        let fixture = try WorkspaceModelFixture()
        let service = PausingWorkspaceService(
            snapshot: fixture.snapshot,
            resolved: fixture.resolved
        )
        let viewModel = fixture.makeViewModel(service: service)
        try await viewModel.loadWorkspace()

        await service.pauseNextResolution(of: .project(fixture.project.projectID))
        let stale = Task {
            try await viewModel.selectContext(.project(fixture.project.projectID))
        }
        await service.waitUntilPaused()
        let latest = try await viewModel.selectContext(
            .conversation(fixture.conversation.id)
        )
        await service.resumeResolution()

        await XCTAssertThrowsErrorAsync(CancellationError.self) {
            _ = try await stale.value
        }
        XCTAssertEqual(viewModel.activeContext, latest)
        XCTAssertEqual(latest.contextID, .conversation(fixture.conversation.id))
    }

    func testDurableStateRestoresTerminalKindsAndSelectionAcrossRebuiltLocalCoordinator() async throws {
        let fixture = try WorkspaceModelFixture()
        let first = fixture.makeViewModel()
        try await first.loadWorkspace()
        try await first.selectContext(.project(fixture.project.projectID))

        let codexTab = try await first.openNewTabPicker()
        let codexSession = TerminalSessionID()
        try await first.replaceNewTabPicker(codexTab, with: .codex(codexSession))
        let claudeTab = try await first.openNewTabPicker()
        let claudeSession = TerminalSessionID()
        try await first.replaceNewTabPicker(claudeTab, with: .claude(claudeSession))
        try await first.selectTab(codexTab)

        let rebuilt = fixture.makeViewModel()
        try await rebuilt.loadWorkspace()
        try await rebuilt.selectContext(.project(fixture.project.projectID))

        XCTAssertEqual(
            rebuilt.currentTabs.map(\.kind),
            [.codex(codexSession), .claude(claudeSession)]
        )
        XCTAssertEqual(rebuilt.selectedTabID, codexTab)
    }

    func testFileSelectionPersistsOnlyAfterExactSelectionHandlerAcknowledges() async throws {
        let fixture = try WorkspaceModelFixture()
        let selector = RecordingFileSelection()
        let viewModel = fixture.makeViewModel(fileSelection: selector.select)
        try await viewModel.loadWorkspace()
        try await viewModel.selectContext(.project(fixture.project.projectID))

        let firstTab = try await viewModel.openNewTabPicker()
        let firstDocument = DocumentID()
        try await viewModel.replaceNewTabPicker(firstTab, with: .file(firstDocument))
        let secondTab = try await viewModel.openNewTabPicker()
        let secondDocument = DocumentID()
        try await viewModel.replaceNewTabPicker(secondTab, with: .file(secondDocument))

        try await viewModel.selectTab(firstTab)
        XCTAssertEqual(
            selector.requests,
            [
                .init(
                    contextID: .project(fixture.project.projectID),
                    tabID: firstTab,
                    documentID: firstDocument
                ),
            ]
        )
        XCTAssertEqual(viewModel.selectedTabID, firstTab)

        selector.error = WorkspaceViewModelError.relocationUnavailable
        await XCTAssertThrowsErrorAsync(WorkspaceViewModelError.self) {
            try await viewModel.selectTab(secondTab)
        }
        XCTAssertEqual(viewModel.selectedTabID, firstTab)

        let restoredSelector = RecordingFileSelection()
        let rebuilt = fixture.makeViewModel(fileSelection: restoredSelector.select)
        try await rebuilt.loadWorkspace()
        try await rebuilt.selectContext(.project(fixture.project.projectID))
        XCTAssertEqual(rebuilt.selectedTabID, firstTab)
        XCTAssertEqual(
            restoredSelector.requests,
            [
                .init(
                    contextID: .project(fixture.project.projectID),
                    tabID: firstTab,
                    documentID: firstDocument
                ),
            ]
        )
    }

    func testConcurrentPickerMutationsSerializeTheWholeDurableReadModifySave() async throws {
        let fixture = try WorkspaceModelFixture()
        let store = PausingClientWorkspaceStateService()
        let viewModel = fixture.makeViewModel(stateService: store)
        try await viewModel.loadWorkspace()
        try await viewModel.selectContext(.project(fixture.project.projectID))

        await store.pauseNextSave()
        async let first = viewModel.openNewTabPicker()
        await store.waitUntilSavePaused()
        async let second = viewModel.openNewTabPicker()
        for _ in 0..<20 { await Task.yield() }
        await store.resumeSave()
        let created = try await [first, second]

        let restored = try await store.loadClientState(
            ClientWorkspaceStateKey(
                deviceID: fixture.deviceID,
                windowID: fixture.windowID,
                workspaceContextID: .project(fixture.project.projectID)
            )
        )
        XCTAssertEqual(Set(try XCTUnwrap(restored).tabs.map(\.id)), Set(created))
    }
}

@MainActor
private struct WorkspaceModelFixture {
    let emptyProject: ProjectSnapshot
    let project: ProjectSnapshot
    let conversation: Conversation
    let snapshot: WorkspaceSnapshot
    let resolved: [WorkspaceContextID: ResolvedWorkspaceContext]
    let stateService = MemoryClientWorkspaceStateService()
    let activeContexts = ActiveContextController()
    let deviceID = DeviceID()
    let windowID = WindowID()
    let clientInstanceID = ClientInstanceID()

    init() throws {
        let emptyProjectID = ProjectID()
        let projectID = ProjectID()
        let emptyContext = try ResolvedWorkspaceContext(
            validating: .project(emptyProjectID),
            projectID: emptyProjectID,
            conversationID: nil,
            environmentID: EnvironmentID(),
            workspaceRootIdentity: "empty-root"
        )
        let projectContext = try ResolvedWorkspaceContext(
            validating: .project(projectID),
            projectID: projectID,
            conversationID: nil,
            environmentID: EnvironmentID(),
            workspaceRootIdentity: "project-root"
        )
        let conversation = Conversation(
            id: ConversationID(),
            projectID: projectID,
            environmentID: EnvironmentID(),
            title: "Conversation",
            lifecycleState: .active,
            deletionOperationID: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let conversationContext = try ResolvedWorkspaceContext(
            validating: .conversation(conversation.id),
            projectID: projectID,
            conversationID: conversation.id,
            environmentID: conversation.environmentID,
            workspaceRootIdentity: "project-root"
        )
        emptyProject = ProjectSnapshot(
            projectID: emptyProjectID,
            displayName: "Empty",
            resolvedContext: emptyContext,
            conversations: []
        )
        project = ProjectSnapshot(
            projectID: projectID,
            displayName: "Project",
            resolvedContext: projectContext,
            conversations: [conversation]
        )
        self.conversation = conversation
        snapshot = [emptyProject, project]
        resolved = [
            emptyContext.contextID: emptyContext,
            projectContext.contextID: projectContext,
            conversationContext.contextID: conversationContext,
        ]
    }

    func makeViewModel(
        service: (any WorkspaceServing)? = nil,
        stateService: (any ClientWorkspaceStateServing)? = nil,
        fileSelection: @escaping WorkspaceFileSelectionHandler = { _, _, _ in }
    ) -> WorkspaceViewModel {
        WorkspaceViewModel(
            workspaceService: service ?? RecordingWorkspaceService(
                snapshot: snapshot,
                resolved: resolved
            ),
            stateCoordinator: WorkspaceStateCoordinator(
                clientState: WorkspaceClientState(),
                remote: stateService ?? self.stateService
            ),
            activeContexts: activeContexts,
            deviceID: deviceID,
            windowID: windowID,
            clientInstanceID: clientInstanceID,
            fileSelection: fileSelection
        )
    }
}

private actor MemoryClientWorkspaceStateService: ClientWorkspaceStateServing {
    var values: [ClientWorkspaceStateKey: ClientWorkspaceState] = [:]

    func loadClientState(_ key: ClientWorkspaceStateKey) -> ClientWorkspaceState? {
        values[key]
    }

    func saveClientState(_ state: ClientWorkspaceState) throws {
        let valid = try state.validated()
        values[valid.key] = valid
    }
}

private actor PausingClientWorkspaceStateService: ClientWorkspaceStateServing {
    private var values: [ClientWorkspaceStateKey: ClientWorkspaceState] = [:]
    private var pauseSave = false
    private var isPaused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func pauseNextSave() { pauseSave = true }

    func waitUntilSavePaused() async {
        if isPaused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }

    func resumeSave() {
        isPaused = false
        resumeWaiter?.resume()
        resumeWaiter = nil
    }

    func loadClientState(_ key: ClientWorkspaceStateKey) -> ClientWorkspaceState? {
        values[key]
    }

    func saveClientState(_ state: ClientWorkspaceState) async throws {
        let valid = try state.validated()
        if pauseSave {
            pauseSave = false
            isPaused = true
            pauseWaiter?.resume()
            pauseWaiter = nil
            await withCheckedContinuation { resumeWaiter = $0 }
        }
        values[valid.key] = valid
    }
}

@MainActor
private final class RecordingFileSelection {
    struct Request: Equatable {
        let contextID: WorkspaceContextID
        let tabID: TabID
        let documentID: DocumentID
    }

    var error: Error?
    private(set) var requests: [Request] = []

    func select(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) async throws {
        requests.append(.init(contextID: contextID, tabID: tabID, documentID: documentID))
        if let error { throw error }
    }
}

private actor RecordingWorkspaceService: WorkspaceServing {
    let snapshot: WorkspaceSnapshot
    let resolved: [WorkspaceContextID: ResolvedWorkspaceContext]

    init(
        snapshot: WorkspaceSnapshot,
        resolved: [WorkspaceContextID: ResolvedWorkspaceContext]
    ) {
        self.snapshot = snapshot
        self.resolved = resolved
    }

    func addProject(bookmark: Data, displayName: String) async throws -> ProjectSnapshot {
        throw WorkspaceRepositoryError.projectNotFound
    }

    func listWorkspace() async throws -> WorkspaceSnapshot { snapshot }

    func createDirectConversation(projectID: ProjectID) async throws -> Conversation {
        throw WorkspaceRepositoryError.projectNotFound
    }

    func renameConversation(id: ConversationID, title: String) async throws {}

    func resolveContext(_ id: WorkspaceContextID) async throws -> ResolvedWorkspaceContext {
        guard let value = resolved[id] else { throw WorkspaceRepositoryError.projectNotFound }
        return value
    }

    func performFileOperation(
        context: RequestContext,
        operation: FileOperation
    ) async throws -> FileOperationResult {
        throw FileOperationError.environmentNotRegistered
    }
}

private actor PausingWorkspaceService: WorkspaceServing {
    let snapshot: WorkspaceSnapshot
    let resolved: [WorkspaceContextID: ResolvedWorkspaceContext]
    private var pausedContext: WorkspaceContextID?
    private var isPaused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(
        snapshot: WorkspaceSnapshot,
        resolved: [WorkspaceContextID: ResolvedWorkspaceContext]
    ) {
        self.snapshot = snapshot
        self.resolved = resolved
    }

    func pauseNextResolution(of contextID: WorkspaceContextID) {
        pausedContext = contextID
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pauseContinuation = $0 }
    }

    func resumeResolution() {
        isPaused = false
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func addProject(bookmark: Data, displayName: String) async throws -> ProjectSnapshot {
        throw WorkspaceRepositoryError.projectNotFound
    }

    func listWorkspace() async throws -> WorkspaceSnapshot { snapshot }

    func createDirectConversation(projectID: ProjectID) async throws -> Conversation {
        throw WorkspaceRepositoryError.projectNotFound
    }

    func renameConversation(id: ConversationID, title: String) async throws {}

    func resolveContext(_ id: WorkspaceContextID) async throws -> ResolvedWorkspaceContext {
        if pausedContext == id {
            pausedContext = nil
            isPaused = true
            pauseContinuation?.resume()
            pauseContinuation = nil
            await withCheckedContinuation { resumeContinuation = $0 }
        }
        guard let value = resolved[id] else { throw WorkspaceRepositoryError.projectNotFound }
        return value
    }

    func performFileOperation(
        context: RequestContext,
        operation: FileOperation
    ) async throws -> FileOperationResult {
        throw FileOperationError.environmentNotRegistered
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<E: Error>(
    _ expected: E.Type,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)")
    } catch is E {
    } catch {
        XCTFail("Expected \(expected), got \(error)")
    }
}

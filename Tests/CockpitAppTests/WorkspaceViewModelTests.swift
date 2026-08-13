import Foundation
import XCTest
import CockpitClientCore
import CockpitHostCore
import CockpitProtocol
import CockpitTerminalCore
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
        XCTAssertEqual(
            NewTabPickerController.options,
            [.file, .shell, .codex, .claude, .reattach]
        )
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

    func testPersistedFileSelectionRoutesThroughRestoreAwareTabCommandsAndLatestIntentWins() async throws {
        let fixture = try WorkspaceModelFixture()
        let seed = fixture.makeViewModel()
        try await seed.loadWorkspace()
        try await seed.selectContext(.project(fixture.project.projectID))

        let firstTab = try await seed.openNewTabPicker()
        let firstDocument = DocumentID()
        try await seed.replaceNewTabPicker(firstTab, with: .file(firstDocument))
        let secondTab = try await seed.openNewTabPicker()
        let secondDocument = DocumentID()
        try await seed.replaceNewTabPicker(secondTab, with: .file(secondDocument))
        try await seed.selectTab(firstTab)

        let commands = RecordingWorkspaceTabCommands()
        let legacySelection = RecordingFileSelection()
        let rebuilt = fixture.makeViewModel(
            tabCommands: commands,
            fileSelection: legacySelection.select
        )
        try await rebuilt.loadWorkspace()
        try await rebuilt.selectContext(.project(fixture.project.projectID))

        XCTAssertEqual(commands.selectedFileTabIDs, [firstTab])
        XCTAssertEqual(legacySelection.requests, [])
        XCTAssertEqual(rebuilt.selectedTabID, firstTab)

        commands.pauseNextFileSelection()
        let stale = Task { try await rebuilt.selectTab(secondTab) }
        await commands.waitUntilFileSelectionPaused()
        try await rebuilt.selectTab(firstTab)
        commands.resumeFileSelection()

        await XCTAssertThrowsErrorAsync(CancellationError.self) {
            try await stale.value
        }
        XCTAssertEqual(commands.selectedFileTabIDs, [firstTab, secondTab, firstTab])
        XCTAssertEqual(rebuilt.selectedTabID, firstTab)
        XCTAssertEqual(rebuilt.currentTabs.map(\.id), [firstTab, secondTab])
    }

    func testExplicitMissingDocumentRemovesStaleTabButValidationFailurePreservesIt() async throws {
        let missingFixture = try WorkspaceModelFixture()
        let missingSeed = missingFixture.makeViewModel()
        try await missingSeed.loadWorkspace()
        try await missingSeed.selectContext(.project(missingFixture.project.projectID))
        let missingTab = try await missingSeed.openNewTabPicker()
        try await missingSeed.replaceNewTabPicker(missingTab, with: .file(DocumentID()))

        let missingCommands = RecordingWorkspaceTabCommands()
        missingCommands.fileSelectionError = DocumentProtocolError.fileMissing
        let missingRebuilt = missingFixture.makeViewModel(tabCommands: missingCommands)
        try await missingRebuilt.loadWorkspace()
        do {
            _ = try await missingRebuilt.selectContext(.project(missingFixture.project.projectID))
            XCTFail("expected readable missing-file error")
        } catch let error as WorkspaceViewModelError {
            XCTAssertEqual(error, .fileMissing(path: nil))
            XCTAssertEqual(error.localizedDescription, "The file no longer exists in this project.")
        }
        let missingTabs = try await missingRebuilt.tabs(
            for: .project(missingFixture.project.projectID)
        )
        XCTAssertEqual(missingTabs, [])

        let invalidFixture = try WorkspaceModelFixture()
        let invalidSeed = invalidFixture.makeViewModel()
        try await invalidSeed.loadWorkspace()
        try await invalidSeed.selectContext(.project(invalidFixture.project.projectID))
        let invalidTab = try await invalidSeed.openNewTabPicker()
        try await invalidSeed.replaceNewTabPicker(invalidTab, with: .file(DocumentID()))

        let invalidCommands = RecordingWorkspaceTabCommands()
        invalidCommands.fileSelectionError = DocumentProtocolError.invalidValue
        let invalidRebuilt = invalidFixture.makeViewModel(tabCommands: invalidCommands)
        try await invalidRebuilt.loadWorkspace()
        await XCTAssertThrowsErrorAsync(DocumentProtocolError.self) {
            _ = try await invalidRebuilt.selectContext(.project(invalidFixture.project.projectID))
        }
        let invalidTabs = try await invalidRebuilt.tabs(
            for: .project(invalidFixture.project.projectID)
        )
        XCTAssertEqual(invalidTabs.map(\.id), [invalidTab])
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

    func testPickerChoiceRelocationAndCloseRouteThroughInjectedTabCommands() async throws {
        let fixture = try WorkspaceModelFixture()
        let commands = RecordingWorkspaceTabCommands()
        let viewModel = fixture.makeViewModel(tabCommands: commands)
        try await viewModel.loadWorkspace()
        let active = try await viewModel.selectContext(.project(fixture.project.projectID))
        let picker = try await viewModel.openNewTabPicker()
        let sessionID = TerminalSessionID()
        commands.createdKind = .shell(sessionID)

        try await viewModel.routeNewTabPickerChoice(
            .shell,
            tabID: picker,
            contextID: active.contextID
        )
        XCTAssertEqual(commands.createCalls, [
            .init(option: .shell, tabID: picker, contextID: active.contextID),
        ])
        XCTAssertEqual(viewModel.currentTabs.map(\.kind), [.shell(sessionID)])

        let operation = FileOperation.rename(
            source: try RelativePath("Old.swift"),
            newName: "New.swift"
        )
        try await viewModel.performRelocation(
            operation,
            workspaceContextID: active.contextID
        )
        XCTAssertEqual(commands.relocations, [
            .init(operation: operation, contextID: active.contextID),
        ])

        commands.closeResult = false
        let cancelled = try await viewModel.closeTab(picker)
        XCTAssertFalse(cancelled)
        XCTAssertEqual(viewModel.currentTabs.map(\.kind), [.shell(sessionID)])
        XCTAssertEqual(commands.preparedCloseTabIDs, [picker])
        XCTAssertEqual(commands.finalizedCloseTabIDs, [])
        commands.closeResult = true
        let closed = try await viewModel.closeTab(picker)
        XCTAssertTrue(closed)
        XCTAssertEqual(viewModel.currentTabs, [])
        XCTAssertNil(viewModel.selectedTabID)
        XCTAssertEqual(commands.preparedCloseTabIDs, [picker, picker])
        XCTAssertEqual(commands.finalizedCloseTabIDs, [picker])
    }

    func testCloseFinalizesOnlyAfterDurableRemovalAndNotAfterSaveFailure() async throws {
        let fixture = try WorkspaceModelFixture()
        let store = FailingClientWorkspaceStateService()
        let commands = RecordingWorkspaceTabCommands()
        let viewModel = fixture.makeViewModel(stateService: store, tabCommands: commands)
        try await viewModel.loadWorkspace()
        let active = try await viewModel.selectContext(.project(fixture.project.projectID))
        let picker = try await viewModel.openNewTabPicker()
        let sessionID = TerminalSessionID()
        commands.createdKind = .shell(sessionID)
        try await viewModel.routeNewTabPickerChoice(
            .shell,
            tabID: picker,
            contextID: active.contextID
        )

        await store.failNextSave()
        await XCTAssertThrowsErrorAsync(WorkspaceStateTestError.self) {
            _ = try await viewModel.closeTab(picker)
        }

        XCTAssertEqual(commands.preparedCloseTabIDs, [picker])
        XCTAssertEqual(commands.finalizedCloseTabIDs, [])
        XCTAssertEqual(viewModel.currentTabs.map(\.kind), [.shell(sessionID)])
        let durableTabs = try await viewModel.tabs(for: active.contextID)
        XCTAssertEqual(durableTabs.map(\.kind), [.shell(sessionID)])
    }

    func testClosePreparedBeforeContextSwitchDoesNotFinalizeOrRemoveOldTab() async throws {
        let fixture = try WorkspaceModelFixture()
        let commands = RecordingWorkspaceTabCommands()
        let viewModel = fixture.makeViewModel(tabCommands: commands)
        try await viewModel.loadWorkspace()
        let project = try await viewModel.selectContext(.project(fixture.project.projectID))
        let picker = try await viewModel.openNewTabPicker()
        let sessionID = TerminalSessionID()
        commands.createdKind = .shell(sessionID)
        try await viewModel.routeNewTabPickerChoice(
            .shell,
            tabID: picker,
            contextID: project.contextID
        )

        commands.pauseNextPrepareClose()
        let closing = Task { try await viewModel.closeTab(picker) }
        await commands.waitUntilPrepareClosePaused()
        _ = try await viewModel.selectContext(.conversation(fixture.conversation.id))
        commands.resumePrepareClose()

        await XCTAssertThrowsErrorAsync(CancellationError.self) {
            _ = try await closing.value
        }
        XCTAssertEqual(commands.finalizedCloseTabIDs, [])
        let durableTabs = try await viewModel.tabs(for: project.contextID)
        XCTAssertEqual(durableTabs.map(\.kind), [.shell(sessionID)])
    }

    func testCloseRollsDurableTabBackWhenReferenceFinalizationFails() async throws {
        let fixture = try WorkspaceModelFixture()
        let commands = RecordingWorkspaceTabCommands()
        let viewModel = fixture.makeViewModel(tabCommands: commands)
        try await viewModel.loadWorkspace()
        let active = try await viewModel.selectContext(.project(fixture.project.projectID))
        let picker = try await viewModel.openNewTabPicker()
        let sessionID = TerminalSessionID()
        commands.createdKind = .shell(sessionID)
        try await viewModel.routeNewTabPickerChoice(
            .shell,
            tabID: picker,
            contextID: active.contextID
        )
        commands.finalizeError = WorkspaceStateTestError.saveFailed

        await XCTAssertThrowsErrorAsync(WorkspaceStateTestError.self) {
            _ = try await viewModel.closeTab(picker)
        }

        XCTAssertEqual(commands.finalizedCloseTabIDs, [picker])
        XCTAssertEqual(viewModel.currentTabs.map(\.kind), [.shell(sessionID)])
        XCTAssertEqual(viewModel.selectedTabID, picker)
        let durableTabs = try await viewModel.tabs(for: active.contextID)
        XCTAssertEqual(durableTabs.map(\.kind), [.shell(sessionID)])
    }

    func testReattachExcludesCurrentTabsAndAgentRestartReplacesSameDurableTab() async throws {
        let fixture = try WorkspaceModelFixture()
        let commands = RecordingWorkspaceTabCommands()
        let viewModel = fixture.makeViewModel(tabCommands: commands)
        try await viewModel.loadWorkspace()
        let active = try await viewModel.selectContext(.project(fixture.project.projectID))

        let attachedPicker = try await viewModel.openNewTabPicker()
        let attachedSession = TerminalSessionID()
        commands.createdKind = .shell(attachedSession)
        try await viewModel.routeNewTabPickerChoice(
            .shell,
            tabID: attachedPicker,
            contextID: active.contextID
        )

        let reattachPicker = try await viewModel.openNewTabPicker()
        let detachedSession = TerminalSessionID()
        commands.reattachedKind = .claude(detachedSession)
        try await viewModel.routeNewTabPickerChoice(
            .reattach,
            tabID: reattachPicker,
            contextID: active.contextID
        )
        XCTAssertEqual(commands.reattachExclusions, [[attachedSession]])
        XCTAssertEqual(
            viewModel.currentTabs.map(\.kind),
            [.shell(attachedSession), .claude(detachedSession)]
        )

        let replacement = TerminalSessionID()
        commands.restartedKind = .codex(replacement)
        try await viewModel.restartTerminalTab(
            reattachPicker,
            replacing: detachedSession,
            switchingTo: .codex
        )
        XCTAssertEqual(commands.restartCalls.map(\.tabID), [reattachPicker])
        XCTAssertEqual(commands.restartCalls.map(\.profileID), [.codex])
        XCTAssertEqual(viewModel.currentTabs[1].id, reattachPicker)
        XCTAssertEqual(viewModel.currentTabs[1].kind, .codex(replacement))
        XCTAssertEqual(viewModel.selectedTabID, reattachPicker)

        let rebuilt = fixture.makeViewModel(tabCommands: commands)
        try await rebuilt.loadWorkspace()
        try await rebuilt.selectContext(active.contextID)
        XCTAssertEqual(rebuilt.currentTabs[1].id, reattachPicker)
        XCTAssertEqual(rebuilt.currentTabs[1].kind, .codex(replacement))
    }

    func testAgentRestartIsSingleFlightAndRejectsTheReplacedSessionID() async throws {
        let fixture = try WorkspaceModelFixture()
        let commands = RecordingWorkspaceTabCommands()
        let viewModel = fixture.makeViewModel(tabCommands: commands)
        try await viewModel.loadWorkspace()
        let active = try await viewModel.selectContext(.project(fixture.project.projectID))
        let picker = try await viewModel.openNewTabPicker()
        let original = TerminalSessionID()
        commands.createdKind = .codex(original)
        try await viewModel.routeNewTabPickerChoice(
            .codex,
            tabID: picker,
            contextID: active.contextID
        )
        let replacement = TerminalSessionID()
        commands.restartedKind = .codex(replacement)
        commands.pauseNextRestart()

        let first = Task {
            try await viewModel.restartTerminalTab(
                picker,
                replacing: original,
                switchingTo: nil
            )
        }
        await commands.waitUntilRestartPaused()
        await XCTAssertThrowsWorkspaceViewModelError(.commandInFlight) {
            try await viewModel.restartTerminalTab(
                picker,
                replacing: original,
                switchingTo: .claude
            )
        }
        commands.resumeRestart()
        try await first.value

        XCTAssertEqual(viewModel.currentTabs.map(\.kind), [.codex(replacement)])
        XCTAssertEqual(commands.restartCalls.count, 1)
        await XCTAssertThrowsWorkspaceViewModelError(.staleTerminalSession) {
            try await viewModel.restartTerminalTab(
                picker,
                replacing: original,
                switchingTo: nil
            )
        }
        XCTAssertEqual(commands.restartCalls.count, 1)
    }

    func testNewTabChoiceIsSingleFlightAndReleasesUncommittedFileAfterContextSwitch() async throws {
        let fixture = try WorkspaceModelFixture()
        let commands = RecordingWorkspaceTabCommands()
        let viewModel = fixture.makeViewModel(tabCommands: commands)
        try await viewModel.loadWorkspace()
        let active = try await viewModel.selectContext(.project(fixture.project.projectID))
        let picker = try await viewModel.openNewTabPicker()
        let documentID = DocumentID()
        commands.createdKind = .file(documentID)
        commands.pauseNextCreate()

        let first = Task {
            try await viewModel.routeNewTabPickerChoice(
                .file,
                tabID: picker,
                contextID: active.contextID
            )
        }
        await commands.waitUntilCreatePaused()
        await XCTAssertThrowsWorkspaceViewModelError(.commandInFlight) {
            try await viewModel.routeNewTabPickerChoice(
                .file,
                tabID: picker,
                contextID: active.contextID
            )
        }
        await XCTAssertThrowsWorkspaceViewModelError(.commandInFlight) {
            try await viewModel.routeNewTabPickerCancellation(
                tabID: picker,
                contextID: active.contextID
            )
        }
        await XCTAssertThrowsWorkspaceViewModelError(.commandInFlight) {
            _ = try await viewModel.closeTab(picker)
        }
        _ = try await viewModel.selectContext(.conversation(fixture.conversation.id))
        commands.resumeCreate()

        await XCTAssertThrowsErrorAsync(CancellationError.self) {
            try await first.value
        }
        XCTAssertEqual(commands.createCalls.count, 1)
        XCTAssertEqual(commands.finalizedCloseTabIDs, [picker])
        let projectTabs = try await viewModel.tabs(for: active.contextID)
        XCTAssertEqual(projectTabs.map(\.kind), [.newTabPicker])
    }

    func testCloseCannotPublishOlderStateOverAConcurrentTabMutation() async throws {
        let fixture = try WorkspaceModelFixture()
        let commands = RecordingWorkspaceTabCommands()
        let viewModel = fixture.makeViewModel(tabCommands: commands)
        try await viewModel.loadWorkspace()
        let active = try await viewModel.selectContext(.project(fixture.project.projectID))
        let firstTab = try await viewModel.openNewTabPicker()
        let sessionID = TerminalSessionID()
        commands.createdKind = .shell(sessionID)
        try await viewModel.routeNewTabPickerChoice(
            .shell,
            tabID: firstTab,
            contextID: active.contextID
        )
        commands.pauseNextFinalizeClose()

        let closing = Task { try await viewModel.closeTab(firstTab) }
        await commands.waitUntilFinalizeClosePaused()
        let latestPicker = try await viewModel.openNewTabPicker()
        commands.resumeFinalizeClose()
        let didClose = try await closing.value
        XCTAssertTrue(didClose)

        XCTAssertEqual(viewModel.currentTabs.map(\.kind), [.newTabPicker])
        XCTAssertEqual(viewModel.selectedTabID, latestPicker)
        let durableTabs = try await viewModel.tabs(for: active.contextID)
        XCTAssertEqual(durableTabs.map(\.kind), [.newTabPicker])
        XCTAssertEqual(durableTabs.map(\.id), [latestPicker])
    }

    func testRollbackInOneContextCannotSuppressAReservedPublicationInAnother() async throws {
        let fixture = try WorkspaceModelFixture()
        let commands = RecordingWorkspaceTabCommands()
        let viewModel = fixture.makeViewModel(tabCommands: commands)
        try await viewModel.loadWorkspace()
        let project = try await viewModel.selectContext(.project(fixture.project.projectID))
        let projectTabID = try await viewModel.openNewTabPicker()
        let sessionID = TerminalSessionID()
        commands.createdKind = .shell(sessionID)
        try await viewModel.routeNewTabPickerChoice(
            .shell,
            tabID: projectTabID,
            contextID: project.contextID
        )
        commands.pauseNextFinalizeClose()
        commands.finalizeError = WorkspaceStateTestError.saveFailed
        let closing = Task { try await viewModel.closeTab(projectTabID) }
        await commands.waitUntilFinalizeClosePaused()

        let conversation = try await viewModel.selectContext(
            .conversation(fixture.conversation.id)
        )
        let publication = WorkspacePublicationBarrier(
            contextID: conversation.contextID
        )
        viewModel.tabStatePublicationObserver = publication.observe
        publication.pauseNextObservation()
        let opening = Task { try await viewModel.openNewTabPicker() }
        await publication.waitUntilPaused()

        commands.resumeFinalizeClose()
        await XCTAssertThrowsErrorAsync(WorkspaceStateTestError.self) {
            _ = try await closing.value
        }
        publication.resume()
        let conversationTabID = try await opening.value
        viewModel.tabStatePublicationObserver = nil

        XCTAssertEqual(viewModel.currentTabs.map(\.id), [conversationTabID])
        XCTAssertEqual(viewModel.currentTabs.map(\.kind), [.newTabPicker])
        let durable = try await viewModel.tabs(for: conversation.contextID)
        XCTAssertEqual(durable.map(\.id), [conversationTabID])
    }

    func testCloseBindingFromPriorContextCannotDeleteSameTabIDInCurrentContext() async throws {
        let fixture = try WorkspaceModelFixture()
        let commands = RecordingWorkspaceTabCommands()
        let tabID = TabID()
        let projectSessionID = TerminalSessionID()
        let conversationSessionID = TerminalSessionID()
        let projectContextID = WorkspaceContextID.project(fixture.project.projectID)
        let conversationContextID = WorkspaceContextID.conversation(fixture.conversation.id)
        try await fixture.stateService.saveClientState(try testWorkspaceState(
            fixture: fixture,
            contextID: projectContextID,
            tabID: tabID,
            sessionID: projectSessionID
        ))
        try await fixture.stateService.saveClientState(try testWorkspaceState(
            fixture: fixture,
            contextID: conversationContextID,
            tabID: tabID,
            sessionID: conversationSessionID
        ))
        let viewModel = fixture.makeViewModel(tabCommands: commands)
        try await viewModel.loadWorkspace()
        let project = try await viewModel.selectContext(projectContextID)
        let clickedTab = try XCTUnwrap(viewModel.currentTabs.first)
        _ = try await viewModel.selectContext(conversationContextID)

        await XCTAssertThrowsErrorAsync(CancellationError.self) {
            _ = try await viewModel.closeTab(
                tabID,
                expectedTab: clickedTab,
                in: project
            )
        }

        let projectTabs = try await viewModel.tabs(for: projectContextID)
        let conversationTabs = try await viewModel.tabs(for: conversationContextID)
        XCTAssertEqual(projectTabs.map(\.kind), [
            .shell(projectSessionID),
        ])
        XCTAssertEqual(conversationTabs.map(\.kind), [
            .shell(conversationSessionID),
        ])
        XCTAssertEqual(commands.preparedCloseTabIDs, [])
        XCTAssertEqual(commands.finalizedCloseTabIDs, [])
    }

    func testProjectCommandIsSingleFlightAndCannotOverrideLaterSelection() async throws {
        let fixture = try WorkspaceModelFixture()
        let service = PausingCreationWorkspaceService(
            snapshot: fixture.snapshot,
            resolved: fixture.resolved,
            project: fixture.emptyProject,
            conversation: fixture.conversation
        )
        let viewModel = fixture.makeViewModel(
            service: service,
            projectDirectoryPicker: {
                ProjectDirectorySelection(
                    bookmark: Data("project".utf8),
                    displayName: "Project"
                )
            }
        )
        try await viewModel.loadWorkspace()
        _ = try await viewModel.selectContext(.project(fixture.project.projectID))
        await service.pauseNextProjectCreation()

        let first = Task { try await viewModel.addProject() }
        await service.waitUntilCreationPaused()
        await XCTAssertThrowsWorkspaceViewModelError(.commandInFlight) {
            _ = try await viewModel.addProject()
        }
        let latest = try await viewModel.selectContext(.conversation(fixture.conversation.id))
        await service.resumeCreation()

        await XCTAssertThrowsErrorAsync(CancellationError.self) {
            _ = try await first.value
        }
        let projectCreateCount = await service.projectCreateCount()
        XCTAssertEqual(projectCreateCount, 1)
        XCTAssertEqual(viewModel.activeContext, latest)
    }

    func testConversationCommandIsSingleFlightAndCannotOverrideLaterSelection() async throws {
        let fixture = try WorkspaceModelFixture()
        let service = PausingCreationWorkspaceService(
            snapshot: fixture.snapshot,
            resolved: fixture.resolved,
            project: fixture.emptyProject,
            conversation: fixture.conversation
        )
        let viewModel = fixture.makeViewModel(
            service: service,
            conversationProfilePicker: { .codex }
        )
        try await viewModel.loadWorkspace()
        _ = try await viewModel.selectContext(.project(fixture.project.projectID))
        await service.pauseNextConversationCreation()

        let first = Task {
            try await viewModel.createConversation(projectID: fixture.project.projectID)
        }
        await service.waitUntilCreationPaused()
        await XCTAssertThrowsWorkspaceViewModelError(.commandInFlight) {
            _ = try await viewModel.createConversation(projectID: fixture.project.projectID)
        }
        let latest = try await viewModel.selectContext(.project(fixture.emptyProject.projectID))
        await service.resumeCreation()

        await XCTAssertThrowsErrorAsync(CancellationError.self) {
            _ = try await first.value
        }
        let conversationCreateCount = await service.conversationCreateCount()
        XCTAssertEqual(conversationCreateCount, 1)
        XCTAssertEqual(viewModel.activeContext, latest)
    }
}

@MainActor
private func testWorkspaceState(
    fixture: WorkspaceModelFixture,
    contextID: WorkspaceContextID,
    tabID: TabID,
    sessionID: TerminalSessionID
) throws -> ClientWorkspaceState {
    try ClientWorkspaceState(
        validatingKey: ClientWorkspaceStateKey(
            deviceID: fixture.deviceID,
            windowID: fixture.windowID,
            workspaceContextID: contextID
        ),
        tabs: [
            TabRecord(
                validatingID: tabID,
                resource: .terminal(sessionID),
                terminalKind: .shell,
                fileViewState: nil
            ),
        ],
        selectedTabID: tabID,
        sidebar: SidebarState(isCollapsed: false),
        splitView: SplitViewState(
            validatingLeadingPaneWidth: 240,
            trailingPaneWidth: 300
        )
    )
}

@MainActor
private final class WorkspacePublicationBarrier {
    let contextID: WorkspaceContextID
    private var pauseNext = false
    private var isPaused = false
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    init(contextID: WorkspaceContextID) { self.contextID = contextID }

    func pauseNextObservation() { pauseNext = true }

    func observe(_ key: ClientWorkspaceStateKey, _ publication: UInt64) async {
        guard pauseNext, key.workspaceContextID == contextID else { return }
        pauseNext = false
        isPaused = true
        pauseWaiter?.resume()
        pauseWaiter = nil
        await withCheckedContinuation { resumeWaiter = $0 }
        isPaused = false
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
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
        tabCommands: (any TabCommanding)? = nil,
        projectDirectoryPicker: @escaping ProjectDirectoryPicker = ProjectCommandController.appKitDirectoryPicker,
        conversationProfilePicker: @escaping ConversationAgentProfilePicker = ConversationCommandController.appKitProfilePicker,
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
            tabCommands: tabCommands,
            projectDirectoryPicker: projectDirectoryPicker,
            conversationProfilePicker: conversationProfilePicker,
            fileSelection: fileSelection
        )
    }
}

@MainActor
private final class RecordingWorkspaceTabCommands: TabCommanding {
    struct CreateCall: Equatable {
        let option: NewTabPickerOption
        let tabID: TabID
        let contextID: WorkspaceContextID
    }

    struct Relocation: Equatable {
        let operation: FileOperation
        let contextID: WorkspaceContextID
    }

    struct RestartCall: Equatable {
        let tabID: TabID
        let profileID: AgentProfileID?
    }

    var createdKind: WorkspaceTabKind = .shell(TerminalSessionID())
    var reattachedKind: WorkspaceTabKind = .shell(TerminalSessionID())
    var restartedKind: WorkspaceTabKind = .codex(TerminalSessionID())
    var fileSelectionError: Error?
    var closeResult = true
    var finalizeError: Error?
    private(set) var createCalls: [CreateCall] = []
    private(set) var relocations: [Relocation] = []
    private(set) var reattachExclusions: [Set<TerminalSessionID>] = []
    private(set) var restartCalls: [RestartCall] = []
    private(set) var selectedFileTabIDs: [TabID] = []
    private(set) var preparedCloseTabIDs: [TabID] = []
    private(set) var finalizedCloseTabIDs: [TabID] = []
    private var pausePrepareClose = false
    private var prepareClosePaused = false
    private var prepareClosePauseWaiter: CheckedContinuation<Void, Never>?
    private var prepareCloseResumeWaiter: CheckedContinuation<Void, Never>?
    private var pauseCreate = false
    private var createPaused = false
    private var createPauseWaiter: CheckedContinuation<Void, Never>?
    private var createResumeWaiter: CheckedContinuation<Void, Never>?
    private var pauseFinalizeClose = false
    private var finalizeClosePaused = false
    private var finalizeClosePauseWaiter: CheckedContinuation<Void, Never>?
    private var finalizeCloseResumeWaiter: CheckedContinuation<Void, Never>?
    private var pauseRestart = false
    private var restartPaused = false
    private var restartPauseWaiter: CheckedContinuation<Void, Never>?
    private var restartResumeWaiter: CheckedContinuation<Void, Never>?
    private var pauseFileSelection = false
    private var fileSelectionPaused = false
    private var fileSelectionPauseWaiter: CheckedContinuation<Void, Never>?
    private var fileSelectionResumeWaiter: CheckedContinuation<Void, Never>?

    func selectFileTab(_ tab: WorkspaceTab, in active: ActiveContext) async throws {
        guard case .file = tab.kind else {
            throw WorkspaceViewModelError.invalidTabKind
        }
        selectedFileTabIDs.append(tab.id)
        if let fileSelectionError { throw fileSelectionError }
        if pauseFileSelection {
            pauseFileSelection = false
            fileSelectionPaused = true
            fileSelectionPauseWaiter?.resume()
            fileSelectionPauseWaiter = nil
            await withCheckedContinuation { fileSelectionResumeWaiter = $0 }
            fileSelectionPaused = false
        }
    }

    func pauseNextFileSelection() { pauseFileSelection = true }

    func waitUntilFileSelectionPaused() async {
        if fileSelectionPaused { return }
        await withCheckedContinuation { fileSelectionPauseWaiter = $0 }
    }

    func resumeFileSelection() {
        fileSelectionResumeWaiter?.resume()
        fileSelectionResumeWaiter = nil
    }

    func createTab(
        for option: NewTabPickerOption,
        tabID: TabID,
        in active: ActiveContext
    ) async throws -> WorkspaceTabKind {
        createCalls.append(.init(option: option, tabID: tabID, contextID: active.contextID))
        if pauseCreate {
            pauseCreate = false
            createPaused = true
            createPauseWaiter?.resume()
            createPauseWaiter = nil
            await withCheckedContinuation { createResumeWaiter = $0 }
            createPaused = false
        }
        return createdKind
    }

    func reattachTerminal(
        in active: ActiveContext,
        excluding sessionIDs: Set<TerminalSessionID>
    ) async throws -> WorkspaceTabKind {
        reattachExclusions.append(sessionIDs)
        return reattachedKind
    }

    func restartTerminal(
        _ tab: WorkspaceTab,
        in active: ActiveContext,
        switchingTo profileID: AgentProfileID?
    ) async throws -> WorkspaceTabKind {
        restartCalls.append(.init(tabID: tab.id, profileID: profileID))
        if pauseRestart {
            pauseRestart = false
            restartPaused = true
            restartPauseWaiter?.resume()
            restartPauseWaiter = nil
            await withCheckedContinuation { restartResumeWaiter = $0 }
            restartPaused = false
        }
        return restartedKind
    }

    func pauseNextRestart() { pauseRestart = true }

    func waitUntilRestartPaused() async {
        if restartPaused { return }
        await withCheckedContinuation { restartPauseWaiter = $0 }
    }

    func resumeRestart() {
        restartResumeWaiter?.resume()
        restartResumeWaiter = nil
    }

    func pauseNextPrepareClose() { pausePrepareClose = true }
    func pauseNextFinalizeClose() { pauseFinalizeClose = true }

    func pauseNextCreate() { pauseCreate = true }

    func waitUntilCreatePaused() async {
        if createPaused { return }
        await withCheckedContinuation { createPauseWaiter = $0 }
    }

    func resumeCreate() {
        createResumeWaiter?.resume()
        createResumeWaiter = nil
    }

    func waitUntilPrepareClosePaused() async {
        if prepareClosePaused { return }
        await withCheckedContinuation { prepareClosePauseWaiter = $0 }
    }

    func resumePrepareClose() {
        prepareCloseResumeWaiter?.resume()
        prepareCloseResumeWaiter = nil
    }

    func waitUntilFinalizeClosePaused() async {
        if finalizeClosePaused { return }
        await withCheckedContinuation { finalizeClosePauseWaiter = $0 }
    }

    func resumeFinalizeClose() {
        finalizeCloseResumeWaiter?.resume()
        finalizeCloseResumeWaiter = nil
    }

    func prepareClose(_ tab: WorkspaceTab, in active: ActiveContext) async throws -> Bool {
        preparedCloseTabIDs.append(tab.id)
        if pausePrepareClose {
            pausePrepareClose = false
            prepareClosePaused = true
            prepareClosePauseWaiter?.resume()
            prepareClosePauseWaiter = nil
            await withCheckedContinuation { prepareCloseResumeWaiter = $0 }
            prepareClosePaused = false
        }
        return closeResult
    }

    func finalizeClose(_ tab: WorkspaceTab, in active: ActiveContext) async throws {
        finalizedCloseTabIDs.append(tab.id)
        if pauseFinalizeClose {
            pauseFinalizeClose = false
            finalizeClosePaused = true
            finalizeClosePauseWaiter?.resume()
            finalizeClosePauseWaiter = nil
            await withCheckedContinuation { finalizeCloseResumeWaiter = $0 }
            finalizeClosePaused = false
        }
        if let finalizeError { throw finalizeError }
    }

    func performRelocation(
        _ operation: FileOperation,
        workspaceContextID: WorkspaceContextID
    ) async throws {
        relocations.append(.init(operation: operation, contextID: workspaceContextID))
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

private enum WorkspaceStateTestError: Error {
    case saveFailed
}

private actor FailingClientWorkspaceStateService: ClientWorkspaceStateServing {
    private var values: [ClientWorkspaceStateKey: ClientWorkspaceState] = [:]
    private var shouldFailNextSave = false

    func failNextSave() { shouldFailNextSave = true }

    func loadClientState(_ key: ClientWorkspaceStateKey) -> ClientWorkspaceState? {
        values[key]
    }

    func saveClientState(_ state: ClientWorkspaceState) throws {
        if shouldFailNextSave {
            shouldFailNextSave = false
            throw WorkspaceStateTestError.saveFailed
        }
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

private actor PausingCreationWorkspaceService: WorkspaceServing {
    enum PausedOperation: Equatable { case project, conversation }

    let snapshot: WorkspaceSnapshot
    let resolved: [WorkspaceContextID: ResolvedWorkspaceContext]
    let project: ProjectSnapshot
    let conversation: Conversation
    private var pausedOperation: PausedOperation?
    private var isPaused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var projectCount = 0
    private var conversationCount = 0

    init(
        snapshot: WorkspaceSnapshot,
        resolved: [WorkspaceContextID: ResolvedWorkspaceContext],
        project: ProjectSnapshot,
        conversation: Conversation
    ) {
        self.snapshot = snapshot
        self.resolved = resolved
        self.project = project
        self.conversation = conversation
    }

    func pauseNextProjectCreation() { pausedOperation = .project }
    func pauseNextConversationCreation() { pausedOperation = .conversation }
    func projectCreateCount() -> Int { projectCount }
    func conversationCreateCount() -> Int { conversationCount }

    func waitUntilCreationPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pauseContinuation = $0 }
    }

    func resumeCreation() {
        isPaused = false
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    private func pauseIfNeeded(_ operation: PausedOperation) async {
        guard pausedOperation == operation else { return }
        pausedOperation = nil
        isPaused = true
        pauseContinuation?.resume()
        pauseContinuation = nil
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func addProject(bookmark: Data, displayName: String) async -> ProjectSnapshot {
        projectCount += 1
        await pauseIfNeeded(.project)
        return project
    }

    func listWorkspace() -> WorkspaceSnapshot { snapshot }

    func createDirectConversation(projectID: ProjectID) async -> Conversation {
        conversationCount += 1
        await pauseIfNeeded(.conversation)
        return conversation
    }

    func renameConversation(id: ConversationID, title: String) {}

    func resolveContext(_ id: WorkspaceContextID) throws -> ResolvedWorkspaceContext {
        guard let value = resolved[id] else { throw WorkspaceRepositoryError.projectNotFound }
        return value
    }

    func performFileOperation(
        context: RequestContext,
        operation: FileOperation
    ) throws -> FileOperationResult {
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

@MainActor
private func XCTAssertThrowsWorkspaceViewModelError(
    _ expected: WorkspaceViewModelError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)")
    } catch let error as WorkspaceViewModelError {
        XCTAssertEqual(error, expected)
    } catch {
        XCTFail("Expected \(expected), got \(error)")
    }
}

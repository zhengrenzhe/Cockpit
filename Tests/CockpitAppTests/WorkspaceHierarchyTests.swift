import AppKit
import Foundation
import WebKit
import XCTest
import CockpitClientCore
import CockpitHostCore
import CockpitTypes
@testable import Cockpit

@MainActor
final class WorkspaceHierarchyTests: XCTestCase {
    func testWindowBuildsTheFrozenThreeColumnHierarchyWithOneMonacoController() throws {
        let fixture = try WorkspaceHierarchyFixture()
        let windowController = fixture.makeWindowController()
        windowController.loadWindow()

        let root = try XCTUnwrap(
            windowController.window?.contentViewController as? WorkspaceSplitViewController
        )
        XCTAssertEqual(root.splitViewItems.count, 3)
        XCTAssertTrue(root.splitViewItems[0].viewController === root.sidebarController)
        XCTAssertTrue(root.splitViewItems[1].viewController === root.tabStripController)
        XCTAssertTrue(root.splitViewItems[2].viewController === root.fileTreeController)
        XCTAssertNotNil(root.sidebarController.outlineView)
        XCTAssertNotNil(root.tabStripController.collectionView)
        XCTAssertNotNil(root.fileTreeController.outlineView)
        XCTAssertTrue(root.tabStripController.contentHostController === root.contentHostController)
        XCTAssertTrue(root.contentHostController.monacoController === fixture.monacoController)
        XCTAssertEqual(monacoDescendants(in: root).count, 1)
    }

    func testProjectRowWithoutConversationIsSelectableAndFileTreeFollowsActiveEnvironment() async throws {
        let fixture = try WorkspaceHierarchyFixture()
        let windowController = fixture.makeWindowController()
        try await windowController.start()
        let root = windowController.workspaceSplitViewController

        XCTAssertTrue(root.sidebarController.isSelectable(.project(fixture.emptyProject.projectID)))
        _ = try await fixture.viewModel.selectContext(.project(fixture.emptyProject.projectID))
        XCTAssertEqual(
            root.fileTreeController.providerEnvironmentID,
            fixture.emptyProject.resolvedContext.environmentID
        )

        _ = try await fixture.viewModel.selectContext(.conversation(fixture.conversation.id))
        XCTAssertEqual(
            root.fileTreeController.providerEnvironmentID,
            fixture.conversation.environmentID
        )
        XCTAssertEqual(
            fixture.providerFactory.requestedEnvironments,
            [
                fixture.emptyProject.resolvedContext.environmentID,
                fixture.conversation.environmentID,
            ]
        )
    }

    func testTerminalSelectionHidesButRetainsTheSingleMonacoAndItsBridge() throws {
        let fixture = try WorkspaceHierarchyFixture()
        let content = fixture.makeWindowController().workspaceSplitViewController.contentHostController
        let active = try fixture.project.resolvedContext.active(generation: 1)
        let documentID = DocumentID()
        let file = try WorkspaceTab(
            record: TabRecord(
                validatingID: TabID(),
                resource: .file(documentID),
                fileViewState: .initial()
            ),
            kind: .file(documentID)
        )
        let terminalSessionID = TerminalSessionID()
        let shell = try WorkspaceTab(
            record: TabRecord(
                validatingID: TabID(),
                resource: .terminal(terminalSessionID),
                fileViewState: nil
            ),
            kind: .shell(terminalSessionID)
        )
        weak var retainedMonaco = fixture.monacoController
        let bridge = fixture.monacoController.bridge

        content.show(file, in: active)
        XCTAssertFalse(fixture.monacoController.view.isHidden)
        content.show(shell, in: active)

        XCTAssertTrue(fixture.monacoController.view.isHidden)
        XCTAssertNotNil(retainedMonaco)
        XCTAssertTrue(content.monacoController === fixture.monacoController)
        XCTAssertTrue(content.monacoController.bridge === bridge)
    }

    func testNativeFileTabSelectionWaitsForExactMonacoAcknowledgementBeforePersisting() async throws {
        let fixture = try WorkspaceHierarchyFixture()
        let windowController = fixture.makeWindowController()
        try await windowController.start()
        _ = try await fixture.viewModel.selectContext(.project(fixture.project.projectID))

        let firstPicker = try await fixture.viewModel.openNewTabPicker()
        let firstDocument = DocumentID()
        try await fixture.viewModel.replaceNewTabPicker(
            firstPicker,
            with: .file(firstDocument)
        )
        let secondPicker = try await fixture.viewModel.openNewTabPicker()
        try await fixture.viewModel.replaceNewTabPicker(
            secondPicker,
            with: .file(DocumentID())
        )
        XCTAssertEqual(fixture.viewModel.selectedTabID, secondPicker)

        let tabStrip = windowController.workspaceSplitViewController.tabStripController
        tabStrip.collectionView(
            tabStrip.collectionView,
            didSelectItemsAt: [IndexPath(item: 0, section: 0)]
        )
        await fulfillment(
            of: [fixture.fileSelection.enteredExpectation],
            timeout: 1
        )
        let selected = try XCTUnwrap(fixture.fileSelection.entered)
        XCTAssertEqual(selected.contextID, .project(fixture.project.projectID))
        XCTAssertEqual(selected.tabID, firstPicker)
        XCTAssertEqual(selected.documentID, firstDocument)
        XCTAssertEqual(fixture.viewModel.selectedTabID, secondPicker)

        fixture.fileSelection.resume()
        await waitUntil { fixture.viewModel.selectedTabID == firstPicker }
        XCTAssertEqual(fixture.viewModel.selectedTabID, firstPicker)
    }

    func testTerminalCacheRetiresChangedSessionAndRemovedTab() throws {
        let fixture = try WorkspaceHierarchyFixture()
        let recorder = RecordingTerminalControllerFactory()
        let content = ContentHostController(
            monacoController: fixture.monacoController,
            clientInstanceID: ClientInstanceID(),
            terminalControllerFactory: { tab, _, _ in
                recorder.makeController(for: tab)
            },
            newTabPickerChoice: { _, _, _ in },
            newTabPickerCancellation: { _, _ in }
        )
        let active = try fixture.project.resolvedContext.active(generation: 1)
        let tabID = TabID()
        let first = try WorkspaceTab(
            record: TabRecord(
                validatingID: tabID,
                resource: .terminal(TerminalSessionID()),
                terminalKind: .shell,
                fileViewState: nil
            )
        )
        let second = try WorkspaceTab(
            record: TabRecord(
                validatingID: tabID,
                resource: .terminal(TerminalSessionID()),
                terminalKind: .shell,
                fileViewState: nil
            )
        )

        content.show(first, in: active)
        let firstController = try XCTUnwrap(recorder.controllers.first)
        content.show(second, in: active)

        XCTAssertEqual(recorder.controllers.count, 2)
        XCTAssertEqual(firstController.detachCount, 1)
        XCTAssertNil(firstController.parent)
        let secondController = try XCTUnwrap(recorder.controllers.last)

        content.synchronize(tabs: [], contextID: active.contextID)

        XCTAssertEqual(secondController.detachCount, 1)
        XCTAssertNil(secondController.parent)
    }

    func testNewTabPickerButtonsRouteExactTabContextChoiceAndCancel() async throws {
        let tabID = TabID()
        let contextID = WorkspaceContextID.project(ProjectID())
        let recorder = RecordingNewTabPickerActions()
        let controller = NewTabPickerController(
            tabID: tabID,
            contextID: contextID,
            onChoose: { option, routedTabID, routedContextID in
                recorder.recordChoice(
                    option,
                    tabID: routedTabID,
                    contextID: routedContextID
                )
            },
            onCancel: { routedTabID, routedContextID in
                recorder.recordCancel(
                    tabID: routedTabID,
                    contextID: routedContextID
                )
            }
        )
        controller.loadViewIfNeeded()

        let shell = try XCTUnwrap(
            descendantButtons(in: controller.view).first {
                $0.identifier?.rawValue == "new-tab-shell"
            }
        )
        let cancel = try XCTUnwrap(
            descendantButtons(in: controller.view).first {
                $0.identifier?.rawValue == "new-tab-cancel"
            }
        )
        shell.performClick(nil)
        await fulfillment(
            of: [recorder.choiceExpectation],
            timeout: 1
        )
        cancel.performClick(nil)
        await fulfillment(of: [recorder.cancelExpectation], timeout: 1)
        XCTAssertEqual(
            recorder.choice,
            .init(option: .shell, tabID: tabID, contextID: contextID)
        )
        XCTAssertEqual(
            recorder.cancellation,
            .init(tabID: tabID, contextID: contextID)
        )
    }

    func testAgentFailurePageOffersRetryAndSwitchAgentWithExactError() async throws {
        let tabID = TabID()
        let contextID = WorkspaceContextID.project(ProjectID())
        let launchError = NSError(
            domain: "dev.cockpit.agent-test",
            code: 91,
            userInfo: [NSLocalizedDescriptionKey: "fixture agent failed"]
        )
        let retry = FailingNewTabPickerActions(error: launchError, failureCount: 1)
        let retryController = NewTabPickerController(
            tabID: tabID,
            contextID: contextID,
            onChoose: retry.choose,
            onCancel: { _, _ in }
        )
        retryController.loadViewIfNeeded()
        try XCTUnwrap(
            descendantButtons(in: retryController.view).first {
                $0.identifier?.rawValue == "new-tab-codex"
            }
        ).performClick(nil)
        guard await waitUntil({
            descendantButtons(in: retryController.view).contains {
                $0.identifier?.rawValue == "new-tab-retry"
            }
        }) else { return }
        let message = descendantTextFields(in: retryController.view)
            .map(\.stringValue)
            .joined(separator: " ")
        XCTAssertTrue(message.contains(launchError.domain))
        XCTAssertTrue(message.contains(String(launchError.code)))
        XCTAssertTrue(message.contains(launchError.localizedDescription))
        try XCTUnwrap(
            descendantButtons(in: retryController.view).first {
                $0.identifier?.rawValue == "new-tab-retry"
            }
        ).performClick(nil)
        guard await waitUntil({ retry.choices == [.codex, .codex] }) else { return }

        let switching = FailingNewTabPickerActions(error: launchError, failureCount: 1)
        let switchController = NewTabPickerController(
            tabID: TabID(),
            contextID: contextID,
            onChoose: switching.choose,
            onCancel: { _, _ in }
        )
        switchController.loadViewIfNeeded()
        try XCTUnwrap(
            descendantButtons(in: switchController.view).first {
                $0.identifier?.rawValue == "new-tab-codex"
            }
        ).performClick(nil)
        guard await waitUntil({
            descendantButtons(in: switchController.view).contains {
                $0.identifier?.rawValue == "new-tab-switch-agent"
            }
        }) else { return }
        try XCTUnwrap(
            descendantButtons(in: switchController.view).first {
                $0.identifier?.rawValue == "new-tab-switch-agent"
            }
        ).performClick(nil)
        guard await waitUntil({ switching.choices == [.codex, .claude] }) else { return }
    }

    func testTabCollectionItemProvidesNativeCloseAffordanceWithExactContextBinding() throws {
        let tabID = TabID()
        let sessionID = TerminalSessionID()
        let tab = try WorkspaceTab(record: TabRecord(
            validatingID: tabID,
            resource: .terminal(sessionID),
            terminalKind: .shell,
            fileViewState: nil
        ))
        let projectID = ProjectID()
        let active = try ActiveContext(
            validating: .project(projectID),
            projectID: projectID,
            conversationID: nil,
            environmentID: EnvironmentID(),
            workspaceRootIdentity: "close-binding-root",
            generation: 7
        )
        let recorder = TabCloseRecorder()
        let item = WorkspaceTabCollectionItem()
        item.configure(
            title: "Shell",
            closeBinding: WorkspaceTabCloseBinding(tab: tab, activeContext: active)
        ) { recorder.values.append($0) }

        let close = try XCTUnwrap(
            descendantButtons(in: item.view).first {
                $0.identifier?.rawValue == "workspace-tab-close"
            }
        )
        close.performClick(nil)
        XCTAssertEqual(
            recorder.values,
            [WorkspaceTabCloseBinding(tab: tab, activeContext: active)]
        )
    }

    func testPureProjectSidebarNewTabActionOpensTheRealFiveChoicePicker() async throws {
        let fixture = try WorkspaceHierarchyFixture()
        let windowController = fixture.makeWindowController()
        try await windowController.start()
        _ = try await fixture.viewModel.selectContext(
            .project(fixture.emptyProject.projectID)
        )
        let root = windowController.workspaceSplitViewController
        let button = try XCTUnwrap(
            descendantButtons(in: root.sidebarController.view).first {
                $0.identifier?.rawValue == "workspace-new-tab"
            }
        )

        button.performClick(nil)
        guard await waitUntil({
            fixture.viewModel.currentTabs.map(\.kind) == [.newTabPicker]
        }) else { return }

        let picker = try XCTUnwrap(
            root.contentHostController.children.compactMap {
                $0 as? NewTabPickerController
            }.first
        )
        picker.loadViewIfNeeded()
        let identifiers = Set(descendantButtons(in: picker.view).compactMap {
            $0.identifier?.rawValue
        })
        XCTAssertTrue(identifiers.isSuperset(of: [
            "new-tab-file",
            "new-tab-shell",
            "new-tab-codex",
            "new-tab-claude",
            "new-tab-reattach",
        ]))
    }

    func testSidebarButtonsAndInlineRenameRouteExactNativeCommandsAndRestoreFailure() async throws {
        let fixture = try WorkspaceHierarchyFixture()
        try await fixture.viewModel.loadWorkspace()
        _ = try await fixture.viewModel.selectContext(.conversation(fixture.conversation.id))
        let actions = SidebarActionRecorder()
        let renameError = NSError(
            domain: "dev.cockpit.rename-test",
            code: 44,
            userInfo: [NSLocalizedDescriptionKey: "rename failed"]
        )
        let controller = WorkspaceSidebarController(
            viewModel: fixture.viewModel,
            addProject: actions.addProject,
            createConversation: actions.createConversation,
            renameConversation: actions.rename,
            presentError: actions.present
        )
        controller.loadViewIfNeeded()
        controller.update(
            projects: fixture.viewModel.projects,
            activeContext: fixture.viewModel.activeContext
        )

        try XCTUnwrap(
            descendantButtons(in: controller.view).first {
                $0.identifier?.rawValue == "workspace-add-project"
            }
        ).performClick(nil)
        guard await waitUntil({ actions.addProjectCount == 1 }) else { return }
        try XCTUnwrap(
            descendantButtons(in: controller.view).first {
                $0.identifier?.rawValue == "workspace-new-conversation"
            }
        ).performClick(nil)
        guard await waitUntil({
            actions.conversationProjectIDs == [fixture.project.projectID]
        }) else { return }

        let item = WorkspaceSidebarItem.conversation(fixture.conversation.id)
        let field = try XCTUnwrap(
            controller.outlineView(
                controller.outlineView,
                viewFor: controller.outlineView.outlineTableColumn,
                item: item
            ) as? NSTextField
        )
        XCTAssertTrue(field.isEditable)
        field.stringValue = "Renamed"
        field.delegate?.controlTextDidEndEditing?(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )
        guard await waitUntil({ actions.renames.count == 1 }) else { return }
        XCTAssertEqual(
            actions.renames,
            [.init(id: fixture.conversation.id, title: "Renamed")]
        )

        let blankField = try XCTUnwrap(
            controller.outlineView(
                controller.outlineView,
                viewFor: controller.outlineView.outlineTableColumn,
                item: item
            ) as? NSTextField
        )
        blankField.stringValue = " \t\n"
        blankField.delegate?.controlTextDidEndEditing?(
            Notification(name: NSControl.textDidEndEditingNotification, object: blankField)
        )
        XCTAssertEqual(actions.renames.count, 1)
        XCTAssertEqual(blankField.stringValue, fixture.conversation.title)
        XCTAssertEqual(
            actions.presentedErrors.first?.localizedDescription,
            "Conversation title cannot be empty."
        )

        actions.renameError = renameError
        let failedField = try XCTUnwrap(
            controller.outlineView(
                controller.outlineView,
                viewFor: controller.outlineView.outlineTableColumn,
                item: item
            ) as? NSTextField
        )
        failedField.stringValue = "Rejected"
        failedField.delegate?.controlTextDidEndEditing?(
            Notification(name: NSControl.textDidEndEditingNotification, object: failedField)
        )
        guard await waitUntil({ actions.presentedErrors.count == 2 }) else { return }
        XCTAssertEqual(failedField.stringValue, fixture.conversation.title)
        XCTAssertEqual(actions.presentedErrors[1].domain, renameError.domain)
        XCTAssertEqual(actions.presentedErrors[1].code, renameError.code)
        XCTAssertEqual(
            actions.presentedErrors[1].localizedDescription,
            renameError.localizedDescription
        )
    }

    func testConversationRenameIsSingleFlightWhileTheHostCommandIsPending() async throws {
        let fixture = try WorkspaceHierarchyFixture()
        try await fixture.viewModel.loadWorkspace()
        _ = try await fixture.viewModel.selectContext(.conversation(fixture.conversation.id))
        let actions = SidebarActionRecorder()
        let controller = WorkspaceSidebarController(
            viewModel: fixture.viewModel,
            addProject: actions.addProject,
            createConversation: actions.createConversation,
            renameConversation: actions.rename,
            presentError: actions.present
        )
        controller.loadViewIfNeeded()
        controller.update(
            projects: fixture.viewModel.projects,
            activeContext: fixture.viewModel.activeContext
        )
        let item = WorkspaceSidebarItem.conversation(fixture.conversation.id)
        let field = try XCTUnwrap(
            controller.outlineView(
                controller.outlineView,
                viewFor: controller.outlineView.outlineTableColumn,
                item: item
            ) as? NSTextField
        )
        actions.pauseNextRename()
        field.stringValue = "First"
        field.delegate?.controlTextDidEndEditing?(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )
        await actions.waitUntilRenamePaused()
        XCTAssertFalse(field.isEditable)

        field.stringValue = "Second"
        field.delegate?.controlTextDidEndEditing?(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )
        actions.resumeRename()
        guard await waitUntil({ actions.renames.count == 1 && field.isEditable }) else { return }
        XCTAssertEqual(
            actions.renames,
            [.init(id: fixture.conversation.id, title: "First")]
        )
    }

    func testFileTreeRelocationUsesExactInjectedPortForUnopenedFileAndDirectory() async throws {
        let fixture = try WorkspaceHierarchyFixture()
        let windowController = fixture.makeWindowController()
        try await windowController.start()
        _ = try await fixture.viewModel.selectContext(.conversation(fixture.conversation.id))
        let fileTree = windowController.workspaceSplitViewController.fileTreeController
        let file = try RelativePath("Sources/Unopened.swift")
        let directory = try RelativePath("Sources/Feature")

        try await fileTree.commitRename(source: file, newName: "Renamed.swift")
        try await fileTree.commitMove(
            source: directory,
            destinationDirectory: .relative(try RelativePath("Archive"))
        )

        XCTAssertEqual(
            fixture.relocation.requests,
            [
                .init(
                    operation: .rename(source: file, newName: "Renamed.swift"),
                    contextID: .conversation(fixture.conversation.id)
                ),
                .init(
                    operation: .move(
                        source: directory,
                        destinationDirectory: .relative(try RelativePath("Archive"))
                    ),
                    contextID: .conversation(fixture.conversation.id)
                ),
            ]
        )
    }

    func testFileTreeExpandsDirectoryThroughTheActiveProvider() async throws {
        let environmentID = EnvironmentID()
        let contextID = WorkspaceContextID.project(ProjectID())
        let active = try ActiveContext(
            validating: contextID,
            projectID: contextID.projectID,
            conversationID: nil,
            environmentID: environmentID,
            workspaceRootIdentity: "nested-root",
            generation: 1
        )
        let provider = try NestedFileTreeTransport(environmentID: environmentID)
        let controller = FileTreeViewController(
            relocationCoordinator: RecordingRelocationCoordinator()
        )
        controller.loadViewIfNeeded()
        controller.activate(
            FileTreeProviderBinding(environmentID: environmentID, provider: provider),
            context: active,
            acceptsGeneration: { $0 == active.generation }
        )
        guard await waitUntil({
            controller.outlineView(
                controller.outlineView,
                numberOfChildrenOfItem: nil
            ) == 1
        }) else { return }

        let directory = controller.outlineView(
            controller.outlineView,
            child: 0,
            ofItem: nil
        )
        XCTAssertTrue(
            controller.outlineView(controller.outlineView, isItemExpandable: directory)
        )
        controller.outlineView.expandItem(directory)
        guard await waitUntil({
            controller.outlineView(
                controller.outlineView,
                numberOfChildrenOfItem: directory
            ) == 1
        }) else { return }

        let nested = controller.outlineView(
            controller.outlineView,
            child: 0,
            ofItem: directory
        )
        let label = try XCTUnwrap(
            controller.outlineView(
                controller.outlineView,
                viewFor: controller.outlineView.outlineTableColumn,
                item: nested
            ) as? NSTextField
        )
        XCTAssertEqual(label.stringValue, "Sources/Nested.swift")
    }

    func testFileTreeInlineRenameRoutesExactNodeAndContext() async throws {
        let environmentID = EnvironmentID()
        let projectID = ProjectID()
        let active = try ActiveContext(
            validating: .project(projectID),
            projectID: projectID,
            conversationID: nil,
            environmentID: environmentID,
            workspaceRootIdentity: "rename-root",
            generation: 1
        )
        let relocation = RecordingRelocationCoordinator()
        let controller = FileTreeViewController(relocationCoordinator: relocation)
        controller.loadViewIfNeeded()
        controller.activate(
            FileTreeProviderBinding(
                environmentID: environmentID,
                provider: try NestedFileTreeTransport(environmentID: environmentID)
            ),
            context: active,
            acceptsGeneration: { $0 == active.generation }
        )
        guard await waitUntil({
            controller.outlineView(controller.outlineView, numberOfChildrenOfItem: nil) == 1
        }) else { return }
        let directory = controller.outlineView(
            controller.outlineView,
            child: 0,
            ofItem: nil
        )
        controller.outlineView.expandItem(directory)
        guard await waitUntil({
            controller.outlineView(
                controller.outlineView,
                numberOfChildrenOfItem: directory
            ) == 1
        }) else { return }
        let nested = controller.outlineView(
            controller.outlineView,
            child: 0,
            ofItem: directory
        )
        let field = try XCTUnwrap(
            controller.outlineView(
                controller.outlineView,
                viewFor: controller.outlineView.outlineTableColumn,
                item: nested
            ) as? NSTextField
        )
        XCTAssertTrue(field.isEditable)
        field.stringValue = "Renamed.swift"
        field.delegate?.controlTextDidEndEditing?(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )

        guard await waitUntil({ relocation.requests.count == 1 }) else { return }
        XCTAssertEqual(
            relocation.requests,
            [
                .init(
                    operation: .rename(
                        source: try RelativePath("Sources/Nested.swift"),
                        newName: "Renamed.swift"
                    ),
                    contextID: .project(projectID)
                ),
            ]
        )
    }

    func testFileTreeDragDropMovesExactSourceIntoDirectory() async throws {
        let environmentID = EnvironmentID()
        let projectID = ProjectID()
        let active = try ActiveContext(
            validating: .project(projectID),
            projectID: projectID,
            conversationID: nil,
            environmentID: environmentID,
            workspaceRootIdentity: "move-root",
            generation: 1
        )
        let relocation = RecordingRelocationCoordinator()
        let controller = FileTreeViewController(relocationCoordinator: relocation)
        controller.loadViewIfNeeded()
        controller.activate(
            FileTreeProviderBinding(
                environmentID: environmentID,
                provider: try MoveFileTreeTransport(environmentID: environmentID)
            ),
            context: active,
            acceptsGeneration: { $0 == active.generation }
        )
        guard await waitUntil({
            controller.outlineView(controller.outlineView, numberOfChildrenOfItem: nil) == 2
        }) else { return }
        let destination = controller.outlineView(
            controller.outlineView,
            child: 0,
            ofItem: nil
        )
        let source = controller.outlineView(
            controller.outlineView,
            child: 1,
            ofItem: nil
        )
        let writer = try XCTUnwrap(
            controller.outlineView(
                controller.outlineView,
                pasteboardWriterForItem: source
            )
        )
        let pasteboard = NSPasteboard(name: .init("cockpit-file-tree-move-test"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([writer]))
        let dragging = TestDraggingInfo(pasteboard: pasteboard)

        XCTAssertEqual(
            controller.outlineView(
                controller.outlineView,
                validateDrop: dragging,
                proposedItem: destination,
                proposedChildIndex: NSOutlineViewDropOnItemIndex
            ),
            .move
        )
        XCTAssertTrue(
            controller.outlineView(
                controller.outlineView,
                acceptDrop: dragging,
                item: destination,
                childIndex: NSOutlineViewDropOnItemIndex
            )
        )

        guard await waitUntil({ relocation.requests.count == 1 }) else { return }
        XCTAssertEqual(
            relocation.requests,
            [
                .init(
                    operation: .move(
                        source: try RelativePath("Loose.swift"),
                        destinationDirectory: .relative(try RelativePath("Archive"))
                    ),
                    contextID: .project(projectID)
                ),
            ]
        )
    }

    func testFileTreeRejectsRenameAndDragPayloadsFromPriorContextActivation() async throws {
        let firstEnvironmentID = EnvironmentID()
        let secondEnvironmentID = EnvironmentID()
        let firstProjectID = ProjectID()
        let secondProjectID = ProjectID()
        let first = try ActiveContext(
            validating: .project(firstProjectID),
            projectID: firstProjectID,
            conversationID: nil,
            environmentID: firstEnvironmentID,
            workspaceRootIdentity: "first-root",
            generation: 1
        )
        let second = try ActiveContext(
            validating: .project(secondProjectID),
            projectID: secondProjectID,
            conversationID: nil,
            environmentID: secondEnvironmentID,
            workspaceRootIdentity: "second-root",
            generation: 2
        )
        let relocation = RecordingRelocationCoordinator()
        let controller = FileTreeViewController(relocationCoordinator: relocation)
        controller.loadViewIfNeeded()
        controller.activate(
            FileTreeProviderBinding(
                environmentID: firstEnvironmentID,
                provider: try MoveFileTreeTransport(environmentID: firstEnvironmentID)
            ),
            context: first,
            acceptsGeneration: { $0 == first.generation }
        )
        guard await waitUntil({
            controller.outlineView(controller.outlineView, numberOfChildrenOfItem: nil) == 2
        }) else { return }
        let firstSource = controller.outlineView(
            controller.outlineView,
            child: 1,
            ofItem: nil
        )
        let staleField = try XCTUnwrap(
            controller.outlineView(
                controller.outlineView,
                viewFor: controller.outlineView.outlineTableColumn,
                item: firstSource
            ) as? NSTextField
        )
        let staleWriter = try XCTUnwrap(
            controller.outlineView(
                controller.outlineView,
                pasteboardWriterForItem: firstSource
            )
        )

        controller.activate(
            FileTreeProviderBinding(
                environmentID: secondEnvironmentID,
                provider: try MoveFileTreeTransport(
                    environmentID: secondEnvironmentID,
                    generation: second.generation
                )
            ),
            context: second,
            acceptsGeneration: { $0 == second.generation }
        )
        guard await waitUntil({
            controller.providerEnvironmentID == secondEnvironmentID
                && controller.outlineView(
                    controller.outlineView,
                    numberOfChildrenOfItem: nil
                ) == 2
        }) else { return }
        let secondDestination = controller.outlineView(
            controller.outlineView,
            child: 0,
            ofItem: nil
        )

        staleField.stringValue = "Renamed.swift"
        staleField.delegate?.controlTextDidEndEditing?(
            Notification(name: NSControl.textDidEndEditingNotification, object: staleField)
        )
        XCTAssertEqual(staleField.stringValue, "Loose.swift")

        let pasteboard = NSPasteboard(name: .init("cockpit-stale-file-tree-action-test"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([staleWriter]))
        let dragging = TestDraggingInfo(pasteboard: pasteboard)
        XCTAssertEqual(
            controller.outlineView(
                controller.outlineView,
                validateDrop: dragging,
                proposedItem: secondDestination,
                proposedChildIndex: NSOutlineViewDropOnItemIndex
            ),
            []
        )
        XCTAssertFalse(
            controller.outlineView(
                controller.outlineView,
                acceptDrop: dragging,
                item: secondDestination,
                childIndex: NSOutlineViewDropOnItemIndex
            )
        )
        XCTAssertEqual(relocation.requests, [])
    }
}

@MainActor
private final class WorkspaceHierarchyFixture {
    let emptyProject: ProjectSnapshot
    let project: ProjectSnapshot
    let conversation: Conversation
    let viewModel: WorkspaceViewModel
    let relocation = RecordingRelocationCoordinator()
    let providerFactory = RecordingProviderFactory()
    let fileSelection = PausingHierarchyFileSelection()
    let monacoController: MonacoEditorViewController

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
        conversation = Conversation(
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
        let service = RecordingHierarchyWorkspaceService(
            snapshot: [emptyProject, project],
            resolved: [
                emptyContext.contextID: emptyContext,
                projectContext.contextID: projectContext,
                conversationContext.contextID: conversationContext,
            ]
        )
        viewModel = WorkspaceViewModel(
            workspaceService: service,
            stateCoordinator: WorkspaceStateCoordinator(
                clientState: WorkspaceClientState(),
                remote: HierarchyClientWorkspaceStateService()
            ),
            activeContexts: ActiveContextController(),
            deviceID: DeviceID(),
            windowID: WindowID(),
            clientInstanceID: ClientInstanceID(),
            fileSelection: { [fileSelection] contextID, tabID, documentID in
                try await fileSelection.select(
                    contextID: contextID,
                    tabID: tabID,
                    documentID: documentID
                )
            }
        )
        let resolver = MonacoWindowSessionResolver(
            clientInstanceID: ClientInstanceID(),
            loadViewState: { _, _, _ in nil },
            storeViewState: { _, _, _, _ in }
        )
        monacoController = MonacoEditorViewController(
            bridge: MonacoBridge(resolver: resolver),
            runtimeBundleURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            webViewFactory: { WKWebView(frame: .zero, configuration: $0) }
        )
    }

    func makeWindowController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            viewModel: viewModel,
            monacoController: monacoController,
            relocationCoordinator: relocation,
            fileTreeProviderFactory: { [providerFactory] active in
                providerFactory.make(for: active.environmentID)
            },
            terminalControllerFactory: { _, _, _ in TestContentController() }
        )
    }
}

@MainActor
private final class RecordingProviderFactory {
    private(set) var requestedEnvironments: [EnvironmentID] = []

    func make(for environmentID: EnvironmentID) -> FileTreeProviderBinding {
        requestedEnvironments.append(environmentID)
        return FileTreeProviderBinding(
            environmentID: environmentID,
            provider: RecordingFileTreeTransport(environmentID: environmentID)
        )
    }
}

private actor RecordingFileTreeTransport: FileTreeDataTransport {
    let environmentID: EnvironmentID

    init(environmentID: EnvironmentID) { self.environmentID = environmentID }

    func children(at directory: WorkspaceDirectory) async throws -> FileTreeSnapshot {
        try FileTreeSnapshot(
            validating: environmentID,
            directory: directory,
            generation: 1,
            revision: 0,
            children: []
        )
    }

    nonisolated func changes(
        after revision: UInt64,
        expandedDirectories: Set<WorkspaceDirectory>
    ) -> AsyncThrowingStream<FileTreeDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor NestedFileTreeTransport: FileTreeDataTransport {
    let environmentID: EnvironmentID
    let root: FileTreeEntry
    let nested: FileTreeEntry

    init(environmentID: EnvironmentID) throws {
        self.environmentID = environmentID
        root = try FileTreeEntry(
            validating: FileTreeEntryIdentity(
                validating: environmentID,
                path: RelativePath("Sources")
            ),
            kind: .directory
        )
        nested = try FileTreeEntry(
            validating: FileTreeEntryIdentity(
                validating: environmentID,
                path: RelativePath("Sources/Nested.swift")
            ),
            kind: .file
        )
    }

    func children(at directory: WorkspaceDirectory) async throws -> FileTreeSnapshot {
        try FileTreeSnapshot(
            validating: environmentID,
            directory: directory,
            generation: 1,
            revision: directory == .root ? 1 : 2,
            children: directory == .root ? [root] : [nested]
        )
    }

    nonisolated func changes(
        after revision: UInt64,
        expandedDirectories: Set<WorkspaceDirectory>
    ) -> AsyncThrowingStream<FileTreeDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor MoveFileTreeTransport: FileTreeDataTransport {
    let environmentID: EnvironmentID
    let generation: UInt64
    let entries: [FileTreeEntry]

    init(environmentID: EnvironmentID, generation: UInt64 = 1) throws {
        self.environmentID = environmentID
        self.generation = generation
        entries = try [
            FileTreeEntry(
                validating: FileTreeEntryIdentity(
                    validating: environmentID,
                    path: RelativePath("Archive")
                ),
                kind: .directory
            ),
            FileTreeEntry(
                validating: FileTreeEntryIdentity(
                    validating: environmentID,
                    path: RelativePath("Loose.swift")
                ),
                kind: .file
            ),
        ]
    }

    func children(at directory: WorkspaceDirectory) async throws -> FileTreeSnapshot {
        try FileTreeSnapshot(
            validating: environmentID,
            directory: directory,
            generation: generation,
            revision: 1,
            children: directory == .root ? entries : []
        )
    }

    nonisolated func changes(
        after revision: UInt64,
        expandedDirectories: Set<WorkspaceDirectory>
    ) -> AsyncThrowingStream<FileTreeDelta, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class RecordingRelocationCoordinator: FileRelocationCoordinating {
    struct Request: Equatable {
        let operation: FileOperation
        let contextID: WorkspaceContextID
    }

    private(set) var requests: [Request] = []

    func performRelocation(
        _ operation: FileOperation,
        workspaceContextID: WorkspaceContextID
    ) async throws {
        requests.append(.init(operation: operation, contextID: workspaceContextID))
    }
}

private actor RecordingHierarchyWorkspaceService: WorkspaceServing {
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

private actor HierarchyClientWorkspaceStateService: ClientWorkspaceStateServing {
    private var values: [ClientWorkspaceStateKey: ClientWorkspaceState] = [:]

    func loadClientState(_ key: ClientWorkspaceStateKey) -> ClientWorkspaceState? {
        values[key]
    }

    func saveClientState(_ state: ClientWorkspaceState) throws {
        let valid = try state.validated()
        values[valid.key] = valid
    }
}

@MainActor
private final class PausingHierarchyFileSelection {
    struct Request: Equatable {
        let contextID: WorkspaceContextID
        let tabID: TabID
        let documentID: DocumentID
    }

    let enteredExpectation = XCTestExpectation(description: "file selection entered")
    private(set) var entered: Request?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func select(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) async throws {
        let request = Request(
            contextID: contextID,
            tabID: tabID,
            documentID: documentID
        )
        entered = request
        enteredExpectation.fulfill()
        await withCheckedContinuation { resumeContinuation = $0 }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

@MainActor
private final class TestContentController: NSViewController {
    override func loadView() { view = NSView() }
}

@MainActor
private final class RecordingTerminalControllerFactory {
    private(set) var controllers: [RecordingTerminalContentController] = []

    func makeController(for tab: WorkspaceTab) -> NSViewController {
        let controller = RecordingTerminalContentController(
            sessionID: try! XCTUnwrap(tab.kind.terminalSessionID)
        )
        controllers.append(controller)
        return controller
    }
}

@MainActor
private final class RecordingTerminalContentController: NSViewController,
    TerminalContentRetiring
{
    let sessionID: TerminalSessionID
    private(set) var detachCount = 0

    init(sessionID: TerminalSessionID) {
        self.sessionID = sessionID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() { view = NSView() }

    func detach() { detachCount += 1 }
}

@MainActor
private final class RecordingNewTabPickerActions {
    struct Choice: Equatable {
        let option: NewTabPickerOption
        let tabID: TabID
        let contextID: WorkspaceContextID
    }

    struct Cancellation: Equatable {
        let tabID: TabID
        let contextID: WorkspaceContextID
    }

    let choiceExpectation = XCTestExpectation(description: "picker choice")
    let cancelExpectation = XCTestExpectation(description: "picker cancel")
    private(set) var choice: Choice?
    private(set) var cancellation: Cancellation?

    func recordChoice(
        _ option: NewTabPickerOption,
        tabID: TabID,
        contextID: WorkspaceContextID
    ) {
        choice = Choice(option: option, tabID: tabID, contextID: contextID)
        choiceExpectation.fulfill()
    }

    func recordCancel(tabID: TabID, contextID: WorkspaceContextID) {
        cancellation = Cancellation(tabID: tabID, contextID: contextID)
        cancelExpectation.fulfill()
    }
}

@MainActor
private final class FailingNewTabPickerActions {
    let error: NSError
    var remainingFailures: Int
    private(set) var choices: [NewTabPickerOption] = []

    init(error: NSError, failureCount: Int) {
        self.error = error
        remainingFailures = failureCount
    }

    func choose(
        _ option: NewTabPickerOption,
        tabID: TabID,
        contextID: WorkspaceContextID
    ) async throws {
        choices.append(option)
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw error
        }
    }
}

@MainActor
private final class TabCloseRecorder {
    var values: [WorkspaceTabCloseBinding] = []
}

@MainActor
private final class SidebarActionRecorder {
    struct Rename: Equatable {
        let id: ConversationID
        let title: String
    }

    private(set) var addProjectCount = 0
    private(set) var conversationProjectIDs: [ProjectID] = []
    private(set) var renames: [Rename] = []
    private(set) var presentedErrors: [NSError] = []
    var renameError: NSError?
    private var pauseRename = false
    private var renamePaused = false
    private var renamePauseWaiter: CheckedContinuation<Void, Never>?
    private var renameResumeWaiter: CheckedContinuation<Void, Never>?

    func addProject() async throws { addProjectCount += 1 }
    func createConversation(_ projectID: ProjectID) async throws {
        conversationProjectIDs.append(projectID)
    }
    func pauseNextRename() { pauseRename = true }

    func waitUntilRenamePaused() async {
        if renamePaused { return }
        await withCheckedContinuation { renamePauseWaiter = $0 }
    }

    func resumeRename() {
        renameResumeWaiter?.resume()
        renameResumeWaiter = nil
    }

    func rename(_ id: ConversationID, _ title: String) async throws {
        renames.append(.init(id: id, title: title))
        if pauseRename {
            pauseRename = false
            renamePaused = true
            renamePauseWaiter?.resume()
            renamePauseWaiter = nil
            await withCheckedContinuation { renameResumeWaiter = $0 }
            renamePaused = false
        }
        if let renameError { throw renameError }
    }
    func present(_ error: any Error) { presentedErrors.append(error as NSError) }
}

@MainActor
private final class TestDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    nonisolated override func namesOfPromisedFilesDropped(
        atDestination dropDestination: URL
    ) -> [String]? { nil }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}

@MainActor
private func monacoDescendants(in root: NSViewController) -> [MonacoEditorViewController] {
    var values: [MonacoEditorViewController] = []
    if let monaco = root as? MonacoEditorViewController { values.append(monaco) }
    for child in root.children { values.append(contentsOf: monacoDescendants(in: child)) }
    return values
}

@MainActor
private func descendantButtons(in view: NSView) -> [NSButton] {
    var values: [NSButton] = []
    if let button = view as? NSButton { values.append(button) }
    for subview in view.subviews {
        values.append(contentsOf: descendantButtons(in: subview))
    }
    return values
}

@MainActor
private func descendantTextFields(in view: NSView) -> [NSTextField] {
    var values: [NSTextField] = []
    if let field = view as? NSTextField { values.append(field) }
    for subview in view.subviews {
        values.append(contentsOf: descendantTextFields(in: subview))
    }
    return values
}

@MainActor
@discardableResult
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if condition() { return true }
        await Task.yield()
    }
    XCTFail("condition was not satisfied")
    return false
}

private extension WorkspaceContextID {
    var projectID: ProjectID {
        guard case let .project(projectID) = self else {
            preconditionFailure("expected project context")
        }
        return projectID
    }
}

private extension ResolvedWorkspaceContext {
    func active(generation: UInt64) throws -> ActiveContext {
        try ActiveContext(
            validating: contextID,
            projectID: projectID,
            conversationID: conversationID,
            environmentID: environmentID,
            workspaceRootIdentity: workspaceRootIdentity,
            generation: generation
        )
    }
}

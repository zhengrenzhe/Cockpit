import Foundation
import XCTest
import CockpitHostCore
import CockpitTypes
@testable import Cockpit

@MainActor
final class ProjectCommandControllerTests: XCTestCase {
    func testAddProjectUsesSelectedBookmarkAndSelectsCreatedProjectContext() async throws {
        let fixture = try ProjectCommandFixture()
        let service = ProjectCommandWorkspaceService(snapshot: fixture.snapshot)
        let selection = ProjectSelectionRecorder()
        let controller = ProjectCommandController(
            workspaceService: service,
            directoryPicker: {
                ProjectDirectorySelection(
                    bookmark: fixture.bookmark,
                    displayName: "Workspace"
                )
            },
            selectContext: { contextID in
                selection.values.append(contextID)
            }
        )

        let result = try await controller.addProject()
        let commands = await service.recordedCommands()

        XCTAssertEqual(result, fixture.snapshot)
        XCTAssertEqual(
            commands,
            [.add(bookmark: fixture.bookmark, displayName: "Workspace")]
        )
        XCTAssertEqual(selection.values, [fixture.snapshot.resolvedContext.contextID])
    }

    func testCancelledProjectPickerDoesNotCallWorkspaceServiceOrChangeSelection() async throws {
        let fixture = try ProjectCommandFixture()
        let service = ProjectCommandWorkspaceService(snapshot: fixture.snapshot)
        let selection = ProjectSelectionRecorder()
        let controller = ProjectCommandController(
            workspaceService: service,
            directoryPicker: { nil },
            selectContext: { selection.values.append($0) }
        )

        let result = try await controller.addProject()
        XCTAssertNil(result)
        let commands = await service.recordedCommands()
        XCTAssertEqual(commands, [])
        XCTAssertEqual(selection.values, [])
    }

    func testCreatedProjectIsReportedBeforeSelectionFailure() async throws {
        let fixture = try ProjectCommandFixture()
        let service = ProjectCommandWorkspaceService(snapshot: fixture.snapshot)
        let selectionError = CocoaError(.coderInvalidValue)
        var created: [ProjectSnapshot] = []
        let controller = ProjectCommandController(
            workspaceService: service,
            directoryPicker: {
                ProjectDirectorySelection(
                    bookmark: fixture.bookmark,
                    displayName: "Workspace"
                )
            },
            projectCreated: { created.append($0) },
            selectContext: { _ in throw selectionError }
        )

        do {
            _ = try await controller.addProject()
            XCTFail("selection failure must propagate")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, selectionError.code)
        }
        XCTAssertEqual(created, [fixture.snapshot])
        let commandCount = await service.recordedCommands().count
        XCTAssertEqual(commandCount, 1)
    }
}

private struct ProjectCommandFixture {
    let bookmark = Data("project-bookmark".utf8)
    let snapshot: ProjectSnapshot

    init() throws {
        let projectID = ProjectID(
            UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        )
        let context = try ResolvedWorkspaceContext(
            validating: .project(projectID),
            projectID: projectID,
            conversationID: nil,
            environmentID: EnvironmentID(
                UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
            ),
            workspaceRootIdentity: "volume:fixture/file:project"
        )
        snapshot = ProjectSnapshot(
            projectID: projectID,
            displayName: "Workspace",
            resolvedContext: context,
            conversations: []
        )
    }
}

@MainActor
private final class ProjectSelectionRecorder {
    var values: [WorkspaceContextID] = []
}

private actor ProjectCommandWorkspaceService: WorkspaceServing {
    enum Command: Equatable {
        case add(bookmark: Data, displayName: String)
    }

    let snapshot: ProjectSnapshot
    private(set) var commands: [Command] = []

    init(snapshot: ProjectSnapshot) { self.snapshot = snapshot }

    func recordedCommands() -> [Command] { commands }

    func addProject(bookmark: Data, displayName: String) -> ProjectSnapshot {
        commands.append(.add(bookmark: bookmark, displayName: displayName))
        return snapshot
    }

    func listWorkspace() -> WorkspaceSnapshot { [snapshot] }
    func createDirectConversation(projectID: ProjectID) throws -> Conversation {
        throw CocoaError(.featureUnsupported)
    }
    func renameConversation(id: ConversationID, title: String) throws {
        throw CocoaError(.featureUnsupported)
    }
    func resolveContext(_ id: WorkspaceContextID) -> ResolvedWorkspaceContext {
        snapshot.resolvedContext
    }
    func performFileOperation(
        context: RequestContext,
        operation: FileOperation
    ) throws -> FileOperationResult {
        throw CocoaError(.featureUnsupported)
    }
}

import Foundation
import XCTest
import CockpitHostCore
import CockpitTerminalCore
import CockpitTypes
@testable import Cockpit

@MainActor
final class ConversationCommandControllerTests: XCTestCase {
    func testNewConversationChoosesProfileSelectsContextThenLaunchesFirstAgent() async throws {
        let fixture = try ConversationCommandFixture()
        let service = ConversationCommandWorkspaceService(conversation: fixture.conversation)
        let flow = ConversationFlowRecorder(active: fixture.active)
        let controller = ConversationCommandController(
            workspaceService: service,
            profilePicker: { .claude },
            selectContext: { contextID in
                flow.events.append(.selected(contextID))
                return flow.active
            },
            launchFirstAgent: { conversation, active, profile in
                flow.events.append(.launched(conversation.id, active.contextID, profile))
            },
            presentLaunchFailure: { _, _, _ in
                XCTFail("successful launch must not present an error")
            }
        )

        let result = try await controller.createConversation(projectID: fixture.projectID)
        let createdProjectIDs = await service.recordedProjectIDs()

        XCTAssertEqual(result, fixture.conversation)
        XCTAssertEqual(createdProjectIDs, [fixture.projectID])
        XCTAssertEqual(
            flow.events,
            [
                .selected(.conversation(fixture.conversation.id)),
                .launched(
                    fixture.conversation.id,
                    .conversation(fixture.conversation.id),
                    .claude
                ),
            ]
        )
    }

    func testFirstAgentFailureKeepsCreatedConversationAndPresentsExactError() async throws {
        let fixture = try ConversationCommandFixture()
        let service = ConversationCommandWorkspaceService(conversation: fixture.conversation)
        let flow = ConversationFlowRecorder(active: fixture.active)
        let launchError = NSError(
            domain: "dev.cockpit.agent-fixture",
            code: 73,
            userInfo: [NSLocalizedDescriptionKey: "fixture launch failed"]
        )
        let controller = ConversationCommandController(
            workspaceService: service,
            profilePicker: { .codex },
            selectContext: { _ in flow.active },
            launchFirstAgent: { _, _, _ in throw launchError },
            presentLaunchFailure: { conversation, profile, error in
                flow.failure = .init(
                    conversationID: conversation.id,
                    profileID: profile,
                    domain: (error as NSError).domain,
                    code: (error as NSError).code,
                    message: (error as NSError).localizedDescription
                )
            }
        )

        let result = try await controller.createConversation(projectID: fixture.projectID)
        let createdProjectIDs = await service.recordedProjectIDs()

        XCTAssertEqual(result, fixture.conversation)
        XCTAssertEqual(createdProjectIDs, [fixture.projectID])
        XCTAssertEqual(
            flow.failure,
            .init(
                conversationID: fixture.conversation.id,
                profileID: .codex,
                domain: launchError.domain,
                code: launchError.code,
                message: launchError.localizedDescription
            )
        )
    }

    func testCancelledAgentProfilePickerDoesNotCreateConversation() async throws {
        let fixture = try ConversationCommandFixture()
        let service = ConversationCommandWorkspaceService(conversation: fixture.conversation)
        let controller = ConversationCommandController(
            workspaceService: service,
            profilePicker: { nil },
            selectContext: { _ in fixture.active },
            launchFirstAgent: { _, _, _ in XCTFail("cancel must not launch") },
            presentLaunchFailure: { _, _, _ in XCTFail("cancel must not fail") }
        )

        let result = try await controller.createConversation(projectID: fixture.projectID)
        XCTAssertNil(result)
        let createdProjectIDs = await service.recordedProjectIDs()
        XCTAssertEqual(createdProjectIDs, [])
    }

    func testCreatedConversationIsReportedBeforeSelectionFailure() async throws {
        let fixture = try ConversationCommandFixture()
        let service = ConversationCommandWorkspaceService(conversation: fixture.conversation)
        let selectionError = CocoaError(.coderInvalidValue)
        var created: [Conversation] = []
        let controller = ConversationCommandController(
            workspaceService: service,
            profilePicker: { .codex },
            conversationCreated: { created.append($0) },
            selectContext: { _ in throw selectionError },
            launchFirstAgent: { _, _, _ in XCTFail("selection failure must not launch") },
            presentLaunchFailure: { _, _, _ in XCTFail("selection failure is not launch failure") }
        )

        do {
            _ = try await controller.createConversation(projectID: fixture.projectID)
            XCTFail("selection failure must propagate")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, selectionError.code)
        }
        XCTAssertEqual(created, [fixture.conversation])
        let projectIDs = await service.recordedProjectIDs()
        XCTAssertEqual(projectIDs, [fixture.projectID])
    }
}

private struct ConversationCommandFixture {
    let projectID = ProjectID(
        UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    )
    let conversation: Conversation
    let resolved: ResolvedWorkspaceContext
    let active: ActiveContext

    init() throws {
        let conversationID = ConversationID(
            UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        )
        let environmentID = EnvironmentID(
            UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
        )
        conversation = Conversation(
            id: conversationID,
            projectID: projectID,
            environmentID: environmentID,
            title: "新任务",
            lifecycleState: .active,
            deletionOperationID: nil,
            createdAt: Date(timeIntervalSince1970: 42)
        )
        resolved = try ResolvedWorkspaceContext(
            validating: .conversation(conversationID),
            projectID: projectID,
            conversationID: conversationID,
            environmentID: environmentID,
            workspaceRootIdentity: "volume:fixture/file:conversation"
        )
        active = try ActiveContext(
            validating: resolved.contextID,
            projectID: projectID,
            conversationID: conversationID,
            environmentID: environmentID,
            workspaceRootIdentity: resolved.workspaceRootIdentity,
            generation: 7
        )
    }
}

@MainActor
private final class ConversationFlowRecorder {
    enum Event: Equatable {
        case selected(WorkspaceContextID)
        case launched(ConversationID, WorkspaceContextID, AgentProfileID)
    }

    struct Failure: Equatable {
        let conversationID: ConversationID
        let profileID: AgentProfileID
        let domain: String
        let code: Int
        let message: String
    }

    let active: ActiveContext
    var events: [Event] = []
    var failure: Failure?

    init(active: ActiveContext) { self.active = active }
}

private actor ConversationCommandWorkspaceService: WorkspaceServing {
    let conversation: Conversation
    private(set) var createdProjectIDs: [ProjectID] = []

    init(conversation: Conversation) { self.conversation = conversation }

    func recordedProjectIDs() -> [ProjectID] { createdProjectIDs }

    func addProject(bookmark: Data, displayName: String) throws -> ProjectSnapshot {
        throw CocoaError(.featureUnsupported)
    }
    func listWorkspace() -> WorkspaceSnapshot { [] }
    func createDirectConversation(projectID: ProjectID) -> Conversation {
        createdProjectIDs.append(projectID)
        return conversation
    }
    func renameConversation(id: ConversationID, title: String) throws {
        throw CocoaError(.featureUnsupported)
    }
    func resolveContext(_ id: WorkspaceContextID) throws -> ResolvedWorkspaceContext {
        throw CocoaError(.featureUnsupported)
    }
    func performFileOperation(
        context: RequestContext,
        operation: FileOperation
    ) throws -> FileOperationResult {
        throw CocoaError(.featureUnsupported)
    }
}

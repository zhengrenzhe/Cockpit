import AppKit
import CockpitHostCore
import CockpitTerminalCore
import CockpitTypes

typealias ConversationAgentProfilePicker = @MainActor @Sendable () async throws
    -> AgentProfileID?
typealias ConversationCreatedObserver = @MainActor @Sendable (Conversation) async throws -> Void
typealias ConversationContextSelector = @MainActor @Sendable (WorkspaceContextID) async throws
    -> ActiveContext
typealias ConversationFirstAgentLauncher = @MainActor @Sendable (
    Conversation,
    ActiveContext,
    AgentProfileID
) async throws -> Void
typealias ConversationLaunchFailurePresenter = @MainActor @Sendable (
    Conversation,
    AgentProfileID,
    any Error
) -> Void

@MainActor
final class ConversationCommandController {
    private let workspaceService: any WorkspaceServing
    private let profilePicker: ConversationAgentProfilePicker
    private let conversationCreated: ConversationCreatedObserver
    private let selectContext: ConversationContextSelector
    private let launchFirstAgent: ConversationFirstAgentLauncher
    private let presentLaunchFailure: ConversationLaunchFailurePresenter

    init(
        workspaceService: any WorkspaceServing,
        profilePicker: @escaping ConversationAgentProfilePicker,
        conversationCreated: @escaping ConversationCreatedObserver = { _ in },
        selectContext: @escaping ConversationContextSelector,
        launchFirstAgent: @escaping ConversationFirstAgentLauncher,
        presentLaunchFailure: @escaping ConversationLaunchFailurePresenter
    ) {
        self.workspaceService = workspaceService
        self.profilePicker = profilePicker
        self.conversationCreated = conversationCreated
        self.selectContext = selectContext
        self.launchFirstAgent = launchFirstAgent
        self.presentLaunchFailure = presentLaunchFailure
    }

    func createConversation(projectID: ProjectID) async throws -> Conversation? {
        guard let profileID = try await profilePicker() else { return nil }
        let conversation = try await workspaceService.createDirectConversation(
            projectID: projectID
        )
        try await conversationCreated(conversation)
        let active = try await selectContext(.conversation(conversation.id))
        do {
            try await launchFirstAgent(conversation, active, profileID)
        } catch {
            presentLaunchFailure(conversation, profileID, error)
        }
        return conversation
    }

    static func appKitProfilePicker() async throws -> AgentProfileID? {
        let alert = NSAlert()
        alert.messageText = "New Conversation"
        alert.informativeText = "Choose the first agent."
        alert.addButton(withTitle: "Codex")
        alert.addButton(withTitle: "Claude")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .codex
        case .alertSecondButtonReturn: return .claude
        default: return nil
        }
    }
}

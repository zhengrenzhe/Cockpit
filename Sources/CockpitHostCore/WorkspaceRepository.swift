import Foundation
import CockpitTypes

public struct Project: Hashable, Sendable {
    public let id: ProjectID
    public let displayName: String
    public let rootBookmark: Data
    public let canonicalRootIdentity: String
    public let baseEnvironmentID: EnvironmentID
    public let createdAt: Date

    public init(
        id: ProjectID,
        displayName: String,
        rootBookmark: Data,
        canonicalRootIdentity: String,
        baseEnvironmentID: EnvironmentID,
        createdAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.rootBookmark = rootBookmark
        self.canonicalRootIdentity = canonicalRootIdentity
        self.baseEnvironmentID = baseEnvironmentID
        self.createdAt = createdAt
    }
}

public struct Environment: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case direct
        case worktree
    }

    public let id: EnvironmentID
    public let projectID: ProjectID
    public let kind: Kind
    public let workspaceRoot: String
    public let workspaceRootIdentity: String
    public let gitCommonDirectory: String?
    public let worktreeBranch: String?

    public init(
        id: EnvironmentID,
        projectID: ProjectID,
        kind: Kind,
        workspaceRoot: String,
        workspaceRootIdentity: String,
        gitCommonDirectory: String?,
        worktreeBranch: String?
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.workspaceRoot = workspaceRoot
        self.workspaceRootIdentity = workspaceRootIdentity
        self.gitCommonDirectory = gitCommonDirectory
        self.worktreeBranch = worktreeBranch
    }
}

public enum ConversationLifecycleState: Hashable, Sendable {
    case active
    case deleting(phase: String)
}

public struct Conversation: Hashable, Sendable {
    public let id: ConversationID
    public let projectID: ProjectID
    public let environmentID: EnvironmentID
    public let title: String
    public let lifecycleState: ConversationLifecycleState
    public let deletionOperationID: DeletionOperationID?
    public let createdAt: Date

    public init(
        id: ConversationID,
        projectID: ProjectID,
        environmentID: EnvironmentID,
        title: String,
        lifecycleState: ConversationLifecycleState,
        deletionOperationID: DeletionOperationID?,
        createdAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.environmentID = environmentID
        self.title = title
        self.lifecycleState = lifecycleState
        self.deletionOperationID = deletionOperationID
        self.createdAt = createdAt
    }
}

public struct NewProject: Hashable, Sendable {
    public let displayName: String
    public let rootBookmark: Data
    public let canonicalRootIdentity: String
    public let workspaceRoot: String
    public let gitCommonDirectory: String?

    public init(
        displayName: String,
        rootBookmark: Data,
        canonicalRootIdentity: String,
        workspaceRoot: String,
        gitCommonDirectory: String?
    ) {
        self.displayName = displayName
        self.rootBookmark = rootBookmark
        self.canonicalRootIdentity = canonicalRootIdentity
        self.workspaceRoot = workspaceRoot
        self.gitCommonDirectory = gitCommonDirectory
    }
}

public struct NewConversation: Hashable, Sendable {
    public let projectID: ProjectID
    public let title: String

    public init(projectID: ProjectID, title: String) {
        self.projectID = projectID
        self.title = title
    }
}

public enum WorkspaceRepositoryError: Error, Equatable, Sendable {
    case phaseOneProjectLimit
    case projectNotFound
    case conversationNotFound
    case invalidStoredValue
}

public protocol DocumentLocatorUpdating: Sendable {
    func relocateDocumentLocators(
        in environmentID: EnvironmentID,
        from source: RelativePath,
        to destination: RelativePath
    ) async throws
}

public protocol WorkspaceRepository: DocumentLocatorUpdating, Sendable {
    func createProjectWithDirectEnvironment(_ input: NewProject) async throws -> Project
    func listProjects() async throws -> [Project]
    func createConversation(_ input: NewConversation) async throws -> Conversation
    func listConversations(projectID: ProjectID) async throws -> [Conversation]
    func renameConversation(id: ConversationID, title: String) async throws
    func resolve(_ contextID: WorkspaceContextID) async throws -> ResolvedWorkspaceContext
    func loadClientState(_ key: ClientWorkspaceStateKey) async throws -> ClientWorkspaceState?
    func saveClientState(_ state: ClientWorkspaceState) async throws
}

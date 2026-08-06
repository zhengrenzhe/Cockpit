import Foundation
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
    func resolve(bookmark: Data) throws -> ResolvedProjectRoot
}

public protocol WorkspaceKernelRegistering: Sendable {
    func register(environmentID: EnvironmentID, root: ResolvedProjectRoot) async
}

public actor WorkspaceService: WorkspaceServing {
    private let repository: any WorkspaceRepository
    private let rootResolver: any ProjectRootResolving
    private let kernelRegistry: any WorkspaceKernelRegistering

    public init(
        repository: any WorkspaceRepository,
        rootResolver: any ProjectRootResolving,
        kernelRegistry: any WorkspaceKernelRegistering
    ) {
        self.repository = repository
        self.rootResolver = rootResolver
        self.kernelRegistry = kernelRegistry
    }

    public func addProject(
        bookmark: Data,
        displayName: String
    ) async throws -> ProjectSnapshot {
        let root = try rootResolver.resolve(bookmark: bookmark)
        let project = try await repository.createProjectWithDirectEnvironment(
            NewProject(
                displayName: displayName,
                rootBookmark: bookmark,
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

import Foundation
import Testing
import CockpitTypes
@testable import CockpitWorkspace
@testable import CockpitHostCore

@Test func addingProjectCreatesSelectableProjectContextWithoutConversationOrTerminalCreation() async throws {
    let repository = InMemoryWorkspaceRepository()
    let registry = WorkspaceKernelRegistry()
    let service = WorkspaceService(
        repository: repository,
        rootResolver: FixedProjectRootResolver(root: makeResolvedRoot()),
        kernelRegistry: registry
    )

    let added = try await service.addProject(
        bookmark: Data([0x01, 0x02]),
        displayName: "Cockpit"
    )

    #expect(added.displayName == "Cockpit")
    #expect(added.resolvedContext.contextID == .project(added.projectID))
    #expect(added.conversations.isEmpty)
    #expect(await repository.createdConversationCount == 0)
    let workspace = try await service.listWorkspace()
    #expect(workspace.map(\.projectID) == [added.projectID])
    #expect(workspace[0].resolvedContext == added.resolvedContext)
}

@Test func directConversationsReuseProjectEnvironmentAndActualKernelInstance() async throws {
    let repository = InMemoryWorkspaceRepository()
    let registry = WorkspaceKernelRegistry()
    let service = WorkspaceService(
        repository: repository,
        rootResolver: FixedProjectRootResolver(root: makeResolvedRoot()),
        kernelRegistry: registry
    )
    let project = try await service.addProject(bookmark: Data([0x01]), displayName: "Cockpit")

    let first = try await service.createDirectConversation(projectID: project.projectID)
    let second = try await service.createDirectConversation(projectID: project.projectID)
    let projectContext = try await service.resolveContext(.project(project.projectID))
    let firstContext = try await service.resolveContext(.conversation(first.id))
    let secondContext = try await service.resolveContext(.conversation(second.id))

    #expect(first.title == "新任务")
    #expect(second.title == "新任务")
    #expect(first.environmentID == projectContext.environmentID)
    #expect(second.environmentID == projectContext.environmentID)
    #expect(firstContext.environmentID == projectContext.environmentID)
    #expect(secondContext.environmentID == projectContext.environmentID)
    let projectKernel = await registry.kernel(for: projectContext.environmentID)
    let firstKernel = await registry.kernel(for: firstContext.environmentID)
    let secondKernel = await registry.kernel(for: secondContext.environmentID)
    #expect(projectKernel != nil)
    #expect(projectKernel === firstKernel)
    #expect(firstKernel === secondKernel)

    let workspace = try await service.listWorkspace()
    #expect(workspace.map(\.projectID) == [project.projectID])
    #expect(workspace[0].conversations.map(\.id) == [first.id, second.id])
}

@Test func servicePreservesInjectedBookmarkCocoaErrorDomainAndCode() async {
    let expected = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
    let service = WorkspaceService(
        repository: InMemoryWorkspaceRepository(),
        rootResolver: FailingProjectRootResolver(error: expected),
        kernelRegistry: WorkspaceKernelRegistry()
    )

    do {
        _ = try await service.addProject(bookmark: Data([0x01]), displayName: "Missing")
        Issue.record("Expected bookmark resolution to fail")
    } catch {
        let actual = error as NSError
        #expect(actual.domain == NSCocoaErrorDomain)
        #expect(actual.code == NSFileReadNoSuchFileError)
    }
}

@Test func securityScopedResolverPreservesFoundationCorruptBookmarkError() {
    do {
        _ = try SecurityScopedProjectRootResolver().resolve(
            bookmark: Data([0xFF, 0x00, 0x01])
        )
        Issue.record("Expected corrupt bookmark resolution to fail")
    } catch {
        let actual = error as NSError
        #expect(actual.domain == NSCocoaErrorDomain)
        #expect(actual.code == 259)
    }
}

@Test func securityScopedResolverStartsAndStopsResolvedURLExactlyOnce() throws {
    try withSecurityScopeFixture(isDirectory: true) { url in
        let boundary = RecordingSecurityScopeBoundary(resolvedURL: url)
        let resolver = SecurityScopedProjectRootResolver(boundary: boundary)
        var root: ResolvedProjectRoot? = try resolver.resolve(bookmark: Data([0x01]))

        #expect(boundary.startURLs == [url])
        #expect(boundary.stopURLs.isEmpty)
        #expect(boundary.usedWithSecurityScope)
        #expect(boundary.usedWithoutImplicitStartAccessing)
        root = nil
        withExtendedLifetime(root) {}

        #expect(boundary.startURLs == [url])
        #expect(boundary.stopURLs == [url])
    }
}

@Test func securityScopedResolverBalancesResolvedURLWhenInspectionThrows() throws {
    try withSecurityScopeFixture(isDirectory: false) { url in
        let boundary = RecordingSecurityScopeBoundary(resolvedURL: url)
        let resolver = SecurityScopedProjectRootResolver(boundary: boundary)

        #expect(throws: CocoaError.self) {
            _ = try resolver.resolve(bookmark: Data([0x01]))
        }
        #expect(boundary.startURLs == [url])
        #expect(boundary.stopURLs == [url])
    }
}

@Test func securityScopedResolverFailsClosedWhenManualAccessCannotStart() throws {
    try withSecurityScopeFixture(isDirectory: true) { url in
        let boundary = RecordingSecurityScopeBoundary(
            resolvedURL: url,
            startAccessResult: false
        )
        let resolver = SecurityScopedProjectRootResolver(boundary: boundary)

        do {
            _ = try resolver.resolve(bookmark: Data([0x01]))
            Issue.record("Expected manual security-scope start to fail")
        } catch {
            let actual = error as NSError
            #expect(actual.domain == NSCocoaErrorDomain)
            #expect(actual.code == CocoaError.Code.fileReadNoPermission.rawValue)
        }
        #expect(boundary.startURLs == [url])
        #expect(boundary.stopURLs.isEmpty)
    }
}

@Test func staleBookmarkFailsAddProjectBeforeStartingSecurityScope() async throws {
    let url = try makeSecurityScopeFixture(isDirectory: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let boundary = RecordingSecurityScopeBoundary(resolvedURL: url, isStale: true)
    let service = WorkspaceService(
        repository: InMemoryWorkspaceRepository(),
        rootResolver: SecurityScopedProjectRootResolver(boundary: boundary),
        kernelRegistry: WorkspaceKernelRegistry()
    )

    do {
        _ = try await service.addProject(bookmark: Data([0x01]), displayName: "Stale")
        Issue.record("Expected stale bookmark to fail addProject")
    } catch {
        let actual = error as NSError
        #expect(actual.domain == NSCocoaErrorDomain)
        #expect(actual.code == CocoaError.Code.fileReadCorruptFile.rawValue)
    }
    #expect(boundary.startURLs.isEmpty)
    #expect(boundary.stopURLs.isEmpty)
}

@Test func stalePersistedBookmarkFailsListWorkspaceBeforeStartingSecurityScope() async throws {
    let url = try makeSecurityScopeFixture(isDirectory: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let repository = InMemoryWorkspaceRepository()
    _ = try await repository.createProjectWithDirectEnvironment(
        NewProject(
            displayName: "Persisted",
            rootBookmark: Data([0x02]),
            canonicalRootIdentity: "volume:test/file:persisted",
            workspaceRoot: url.path,
            gitCommonDirectory: nil
        )
    )
    let boundary = RecordingSecurityScopeBoundary(resolvedURL: url, isStale: true)
    let service = WorkspaceService(
        repository: repository,
        rootResolver: SecurityScopedProjectRootResolver(boundary: boundary),
        kernelRegistry: WorkspaceKernelRegistry()
    )

    do {
        _ = try await service.listWorkspace()
        Issue.record("Expected stale persisted bookmark to fail listWorkspace")
    } catch {
        let actual = error as NSError
        #expect(actual.domain == NSCocoaErrorDomain)
        #expect(actual.code == CocoaError.Code.fileReadCorruptFile.rawValue)
    }
    #expect(boundary.startURLs.isEmpty)
    #expect(boundary.stopURLs.isEmpty)
}

private final class TestProjectRootAccessToken: ProjectRootAccessToken, @unchecked Sendable {}

private final class RecordingSecurityScopeBoundary:
    SecurityScopedBookmarkAccessing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let resolvedURL: URL
    private let startAccessResult: Bool
    private let isStale: Bool
    private var resolutionOptions: URL.BookmarkResolutionOptions = []
    private var recordedStartURLs: [URL] = []
    private var recordedStopURLs: [URL] = []

    init(
        resolvedURL: URL,
        startAccessResult: Bool = true,
        isStale: Bool = false
    ) {
        self.resolvedURL = resolvedURL
        self.startAccessResult = startAccessResult
        self.isStale = isStale
    }

    func resolve(
        bookmark: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> SecurityScopedBookmarkResolution {
        lock.withLock { resolutionOptions = options }
        return SecurityScopedBookmarkResolution(url: resolvedURL, isStale: isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { recordedStartURLs.append(url) }
        return startAccessResult
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { recordedStopURLs.append(url) }
    }

    var startURLs: [URL] { lock.withLock { recordedStartURLs } }
    var stopURLs: [URL] { lock.withLock { recordedStopURLs } }
    var usedWithSecurityScope: Bool {
        lock.withLock { resolutionOptions.contains(.withSecurityScope) }
    }
    var usedWithoutImplicitStartAccessing: Bool {
        lock.withLock { resolutionOptions.contains(.withoutImplicitStartAccessing) }
    }
}

private func withSecurityScopeFixture(
    isDirectory: Bool,
    body: (URL) throws -> Void
) throws {
    let url = try makeSecurityScopeFixture(isDirectory: isDirectory)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}

private func makeSecurityScopeFixture(isDirectory: Bool) throws -> URL {
    let url = URL(
        fileURLWithPath: "/private/tmp/cockpit-security-scope-tests.\(UUID().uuidString)",
        isDirectory: isDirectory
    )
    if isDirectory {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    } else {
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    }
    return url
}

private func makeResolvedRoot() -> ResolvedProjectRoot {
    ResolvedProjectRoot(
        canonicalAbsolutePath: "/private/tmp/Cockpit",
        canonicalRootIdentity: "volume:test/file:cockpit",
        gitCommonDirectory: "/private/tmp/Cockpit/.git",
        accessToken: TestProjectRootAccessToken()
    )
}

private struct FixedProjectRootResolver: ProjectRootResolving {
    let root: ResolvedProjectRoot

    func resolve(bookmark: Data) throws -> ResolvedProjectRoot { root }
}

private struct FailingProjectRootResolver: ProjectRootResolving {
    let error: NSError

    func resolve(bookmark: Data) throws -> ResolvedProjectRoot { throw error }
}

private actor InMemoryWorkspaceRepository: WorkspaceRepository {
    private var projects: [Project] = []
    private var conversations: [Conversation] = []
    private var clientStates: [ClientWorkspaceStateKey: ClientWorkspaceState] = [:]

    var createdConversationCount: Int { conversations.count }

    func createProjectWithDirectEnvironment(_ input: NewProject) throws -> Project {
        if !projects.isEmpty { throw WorkspaceRepositoryError.phaseOneProjectLimit }
        let project = Project(
            id: ProjectID(),
            displayName: input.displayName,
            rootBookmark: input.rootBookmark,
            canonicalRootIdentity: input.canonicalRootIdentity,
            baseEnvironmentID: EnvironmentID(),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        projects.append(project)
        return project
    }

    func listProjects() -> [Project] { projects }

    func createConversation(_ input: NewConversation) throws -> Conversation {
        guard let project = projects.first(where: { $0.id == input.projectID }) else {
            throw WorkspaceRepositoryError.projectNotFound
        }
        let conversation = Conversation(
            id: ConversationID(),
            projectID: project.id,
            environmentID: project.baseEnvironmentID,
            title: input.title,
            lifecycleState: .active,
            deletionOperationID: nil,
            createdAt: Date(timeIntervalSince1970: Double(conversations.count + 2))
        )
        conversations.append(conversation)
        return conversation
    }

    func listConversations(projectID: ProjectID) -> [Conversation] {
        conversations.filter { $0.projectID == projectID }
    }

    func renameConversation(id: ConversationID, title: String) throws {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceRepositoryError.conversationNotFound
        }
        let current = conversations[index]
        conversations[index] = Conversation(
            id: current.id,
            projectID: current.projectID,
            environmentID: current.environmentID,
            title: title,
            lifecycleState: current.lifecycleState,
            deletionOperationID: current.deletionOperationID,
            createdAt: current.createdAt
        )
    }

    func resolve(_ contextID: WorkspaceContextID) throws -> ResolvedWorkspaceContext {
        switch contextID {
        case let .project(projectID):
            guard let project = projects.first(where: { $0.id == projectID }) else {
                throw WorkspaceRepositoryError.projectNotFound
            }
            return try ResolvedWorkspaceContext(
                validating: contextID,
                projectID: project.id,
                conversationID: nil,
                environmentID: project.baseEnvironmentID,
                workspaceRootIdentity: project.canonicalRootIdentity
            )
        case let .conversation(conversationID):
            guard let conversation = conversations.first(where: { $0.id == conversationID }),
                  let project = projects.first(where: { $0.id == conversation.projectID })
            else {
                throw WorkspaceRepositoryError.conversationNotFound
            }
            return try ResolvedWorkspaceContext(
                validating: contextID,
                projectID: project.id,
                conversationID: conversation.id,
                environmentID: conversation.environmentID,
                workspaceRootIdentity: project.canonicalRootIdentity
            )
        }
    }

    func loadClientState(_ key: ClientWorkspaceStateKey) throws -> ClientWorkspaceState? {
        try clientStates[key]?.validated()
    }

    func saveClientState(_ state: ClientWorkspaceState) throws {
        let valid = try state.validated()
        clientStates[valid.key] = valid
    }
}

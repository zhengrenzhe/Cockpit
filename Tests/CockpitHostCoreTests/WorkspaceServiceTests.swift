import Foundation
import Testing
import CockpitTypes
@testable import CockpitWorkspace
@testable import CockpitHostCore

@Test func hostOwnedClientWorkspaceStateRoundTripsThroughRepository() async throws {
    let repository = InMemoryWorkspaceRepository()
    let service = WorkspaceService(
        repository: repository,
        rootResolver: FixedProjectRootResolver(root: makeResolvedRoot()),
        kernelRegistry: WorkspaceKernelRegistry()
    )
    let projectID = ProjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000901")!)
    let key = ClientWorkspaceStateKey(
        deviceID: DeviceID(UUID(uuidString: "00000000-0000-0000-0000-000000000902")!),
        windowID: WindowID(UUID(uuidString: "00000000-0000-0000-0000-000000000903")!),
        workspaceContextID: .project(projectID)
    )
    let tab = try TabRecord(
        validatingID: TabID(UUID(uuidString: "00000000-0000-0000-0000-000000000904")!),
        resource: .terminal(TerminalSessionID(UUID(uuidString: "00000000-0000-0000-0000-000000000905")!)),
        terminalKind: .claude,
        fileViewState: nil
    )
    let state = try ClientWorkspaceState(
        validatingKey: key,
        tabs: [tab],
        selectedTabID: tab.id,
        sidebar: SidebarState(isCollapsed: true),
        splitView: SplitViewState(
            validatingLeadingPaneWidth: 212,
            trailingPaneWidth: 344
        )
    )

    #expect(try await service.loadClientState(key) == nil)
    try await service.saveClientState(state)
    #expect(try await service.loadClientState(key) == state)
}

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

@Test func addingProjectPersistsTheRootResolversImportedBookmark() async throws {
    let clientBookmark = Data([0x01, 0x02])
    let persistentBookmark = Data([0x09, 0x08])
    let repository = InMemoryWorkspaceRepository()
    let resolver = RecordingImportingProjectRootResolver(
        root: makeResolvedRoot(),
        persistentBookmark: persistentBookmark
    )
    let service = WorkspaceService(
        repository: repository,
        rootResolver: resolver,
        kernelRegistry: WorkspaceKernelRegistry()
    )

    _ = try await service.addProject(
        bookmark: clientBookmark,
        displayName: "Cockpit"
    )

    let projects = await repository.listProjects()
    #expect(resolver.importedBookmarks == [clientBookmark])
    #expect(resolver.resolvedBookmarks.isEmpty)
    #expect(projects.map(\.rootBookmark) == [persistentBookmark])
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

@Test func securityScopedResolverImportsClientBookmarkIntoHostSecurityScope() throws {
    try withSecurityScopeFixture(isDirectory: true) { url in
        let clientBookmark = Data([0x01, 0x02])
        let persistentBookmark = Data([0x09, 0x08])
        let boundary = RecordingSecurityScopeBoundary(
            resolvedURL: url,
            createdBookmark: persistentBookmark
        )
        let resolver = SecurityScopedProjectRootResolver(boundary: boundary)
        var imported: (persistentBookmark: Data, root: ResolvedProjectRoot)? =
            try resolver.importBookmark(clientBookmark)

        #expect(imported?.persistentBookmark == persistentBookmark)
        #expect(
            boundary.resolutionOptionHistory.map(\.rawValue) == [
                URL.BookmarkResolutionOptions.withoutUI.rawValue,
                (
                    URL.BookmarkResolutionOptions.withSecurityScope.union(
                        .withoutImplicitStartAccessing
                    )
                ).rawValue,
            ]
        )
        #expect(boundary.createdURLs == [url])
        #expect(
            boundary.creationOptionHistory.map(\.rawValue) == [
                URL.BookmarkCreationOptions.withSecurityScope.rawValue
            ]
        )
        #expect(boundary.startURLs == [url])
        #expect(boundary.stopURLs.isEmpty)

        imported = nil
        withExtendedLifetime(imported) {}
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

@Test func securityScopedExecutableResolverFailsClosedWhenManualAccessCannotStart() throws {
    try withSecurityScopeFixture(isDirectory: false) { url in
        let boundary = RecordingSecurityScopeBoundary(
            resolvedURL: url,
            startAccessResult: false
        )
        let resolver = SecurityScopedExecutableBookmarkResolver(boundary: boundary)

        do {
            _ = try resolver.resolve(bookmark: Data([0x02]))
            Issue.record("Expected executable security-scope start to fail")
        } catch {
            let actual = error as NSError
            #expect(actual.domain == NSCocoaErrorDomain)
            #expect(actual.code == CocoaError.Code.fileReadNoPermission.rawValue)
        }
        #expect(boundary.startURLs == [url])
        #expect(boundary.stopURLs.isEmpty)
    }
}

@Test func securityScopedExecutableResolverCanonicalizesAndStopsExactlyOnce() throws {
    try withSecurityScopeFixture(isDirectory: false) { url in
        let boundary = RecordingSecurityScopeBoundary(resolvedURL: url)
        let resolver = SecurityScopedExecutableBookmarkResolver(boundary: boundary)

        let resolved = try resolver.resolve(bookmark: Data([0x03]))

        #expect(resolved == url.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(boundary.startURLs == [url])
        #expect(boundary.stopURLs == [url])
        #expect(boundary.usedWithSecurityScope)
        #expect(boundary.usedWithoutImplicitStartAccessing)
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

@Test func fileOperationsRejectContextEnvironmentMismatchBeforeRoutingAndAcceptBothContextKinds() async throws {
    let repository = InMemoryWorkspaceRepository()
    let registry = RecordingFileOperationRegistry()
    let service = WorkspaceService(
        repository: repository,
        rootResolver: FixedProjectRootResolver(root: makeResolvedRoot()),
        kernelRegistry: registry
    )
    let project = try await service.addProject(bookmark: Data([0x01]), displayName: "Cockpit")
    let conversation = try await service.createDirectConversation(projectID: project.projectID)
    let environmentID = project.resolvedContext.environmentID
    let projectContext = try makeFileOperationRequestContext(
        workspaceContextID: .project(project.projectID),
        environmentID: environmentID
    )
    let conversationContext = try makeFileOperationRequestContext(
        workspaceContextID: .conversation(conversation.id),
        environmentID: environmentID
    )

    #expect(
        try await service.performFileOperation(
            context: projectContext,
            operation: .createDirectory(parent: .root, name: "project")
        ) == .created(path: RelativePath("project"), kind: .directory)
    )
    #expect(
        try await service.performFileOperation(
            context: conversationContext,
            operation: .createFile(parent: .root, name: "conversation")
        ) == .created(path: RelativePath("conversation"), kind: .file)
    )

    let mismatched = try makeFileOperationRequestContext(
        workspaceContextID: .project(project.projectID),
        environmentID: EnvironmentID()
    )
    await #expect(throws: FileOperationError.contextEnvironmentMismatch) {
        _ = try await service.performFileOperation(
            context: mismatched,
            operation: .createFile(parent: .root, name: "rejected")
        )
    }
    #expect(await registry.performedNames == ["project", "conversation"])
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
    private let createdBookmark: Data
    private var recordedResolutionOptions: [URL.BookmarkResolutionOptions] = []
    private var recordedCreationOptions: [URL.BookmarkCreationOptions] = []
    private var recordedCreatedURLs: [URL] = []
    private var recordedStartURLs: [URL] = []
    private var recordedStopURLs: [URL] = []

    init(
        resolvedURL: URL,
        startAccessResult: Bool = true,
        isStale: Bool = false,
        createdBookmark: Data = Data([0xEE])
    ) {
        self.resolvedURL = resolvedURL
        self.startAccessResult = startAccessResult
        self.isStale = isStale
        self.createdBookmark = createdBookmark
    }

    func resolve(
        bookmark: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> SecurityScopedBookmarkResolution {
        lock.withLock { recordedResolutionOptions.append(options) }
        return SecurityScopedBookmarkResolution(url: resolvedURL, isStale: isStale)
    }

    func createBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions
    ) throws -> Data {
        lock.withLock {
            recordedCreatedURLs.append(url)
            recordedCreationOptions.append(options)
        }
        return createdBookmark
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
    var resolutionOptionHistory: [URL.BookmarkResolutionOptions] {
        lock.withLock { recordedResolutionOptions }
    }
    var creationOptionHistory: [URL.BookmarkCreationOptions] {
        lock.withLock { recordedCreationOptions }
    }
    var createdURLs: [URL] { lock.withLock { recordedCreatedURLs } }
    var usedWithSecurityScope: Bool {
        lock.withLock { recordedResolutionOptions.last?.contains(.withSecurityScope) == true }
    }
    var usedWithoutImplicitStartAccessing: Bool {
        lock.withLock {
            recordedResolutionOptions.last?.contains(.withoutImplicitStartAccessing) == true
        }
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

private func makeFileOperationRequestContext(
    workspaceContextID: WorkspaceContextID,
    environmentID: EnvironmentID
) throws -> RequestContext {
    try RequestContext(
        validating: .current,
        clientInstanceID: ClientInstanceID(),
        windowID: WindowID(),
        workspaceContextID: workspaceContextID,
        environmentID: environmentID,
        activeContextGeneration: 1,
        requestID: RequestID()
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

private final class RecordingImportingProjectRootResolver:
    ProjectRootResolving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let root: ResolvedProjectRoot
    private let persistentBookmark: Data
    private var recordedImportedBookmarks: [Data] = []
    private var recordedResolvedBookmarks: [Data] = []

    init(root: ResolvedProjectRoot, persistentBookmark: Data) {
        self.root = root
        self.persistentBookmark = persistentBookmark
    }

    func importBookmark(
        _ bookmark: Data
    ) throws -> (persistentBookmark: Data, root: ResolvedProjectRoot) {
        lock.withLock { recordedImportedBookmarks.append(bookmark) }
        return (persistentBookmark, root)
    }

    func resolve(bookmark: Data) throws -> ResolvedProjectRoot {
        lock.withLock { recordedResolvedBookmarks.append(bookmark) }
        return root
    }

    var importedBookmarks: [Data] { lock.withLock { recordedImportedBookmarks } }
    var resolvedBookmarks: [Data] { lock.withLock { recordedResolvedBookmarks } }
}

private actor RecordingFileOperationRegistry: WorkspaceKernelRegistering {
    private(set) var performedNames: [String] = []
    func register(environmentID: EnvironmentID, root: ResolvedProjectRoot) {}
    func perform(_ operation: FileOperation, in environmentID: EnvironmentID) throws -> FileOperationResult {
        switch operation {
        case let .createFile(_, name):
            performedNames.append(name)
            return .created(path: try RelativePath(name), kind: .file)
        case let .createDirectory(_, name):
            performedNames.append(name)
            return .created(path: try RelativePath(name), kind: .directory)
        default:
            throw FileOperationError.invalidPath
        }
    }
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

    func relocateDocumentLocators(
        in environmentID: EnvironmentID,
        from source: RelativePath,
        to destination: RelativePath
    ) {}
}

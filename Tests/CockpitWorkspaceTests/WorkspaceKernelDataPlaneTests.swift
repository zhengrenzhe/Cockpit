import Foundation
import Testing
import CockpitClientCore
import CockpitHostCore
import CockpitProtocol
import CockpitTypes
@testable import CockpitWorkspace

@Test func workspaceKernelDataPlaneRoutesEveryDocumentOperationThroughTheRegisteredKernel() async throws {
    let fixture = try await WorkspaceDataPlaneFixture()
    defer { fixture.remove() }
    let service = fixture.service

    let opened = try await service.openDocument(binding: fixture.binding, at: fixture.path)
    let kernel = try #require(await fixture.registry.kernel(for: fixture.environmentID))
    let registry = try #require(kernel.documentRegistry)
    #expect(await registry.document(id: opened.documentID) != nil)
    #expect(try await service.snapshot(binding: fixture.binding, documentID: opened.documentID) == opened)

    let lease = try await service.acquireEditLease(binding: fixture.binding, documentID: opened.documentID)
    #expect(lease.clientInstanceID == fixture.binding.clientInstanceID)
    let acknowledgement = try await service.apply(
        binding: fixture.binding,
        transaction: EditTransaction(
            validatingDocumentID: opened.documentID,
            editLeaseID: lease.id,
            baseVersion: 0,
            clientSequence: 1,
            changes: [try UTF16TextEdit(validatingOffset: 3, length: 0, replacement: "d")]
        )
    )
    #expect(acknowledgement.documentVersion == 1)
    #expect(try await service.flush(
        binding: fixture.binding,
        documentID: opened.documentID,
        through: 1
    ) == 1)

    let dirty = try await service.snapshot(binding: fixture.binding, documentID: opened.documentID)
    let saved = try await service.save(
        binding: fixture.binding,
        documentID: opened.documentID,
        expectedFingerprint: try #require(dirty.observedDiskFingerprint)
    )
    #expect(saved.text == "abcd")
    #expect(saved.dirtyState == .clean)

    try Data("replacement".utf8).write(to: fixture.documentURL)
    let discarded = try await service.discard(binding: fixture.binding, documentID: opened.documentID)
    #expect(discarded.text == "replacement")

    let nextClient = ClientInstanceID()
    let transferred = try await service.transferEditLease(
        binding: fixture.binding,
        documentID: opened.documentID,
        from: lease.id,
        to: nextClient
    )
    #expect(transferred.clientInstanceID == nextClient)
    #expect(await fixture.workspace.resolveCount == 9)
}

@Test func workspaceKernelDataPlaneTracksViewerContextsUntilEachConnectionCloses() async throws {
    let fixture = try await WorkspaceDataPlaneFixture()
    defer { fixture.remove() }
    let firstConnection = UUID()
    let secondConnection = UUID()
    let first = try await fixture.service.openDocument(
        binding: fixture.binding,
        at: fixture.path
    )
    try await fixture.service.registerDocumentViewer(
        connectionID: firstConnection,
        binding: fixture.binding,
        documentID: first.documentID
    )

    let conversationID = ConversationID()
    let secondContext = WorkspaceContextID.conversation(conversationID)
    let secondBinding = try HostDataPlaneBinding(
        validatingClientInstanceID: ClientInstanceID(),
        windowID: WindowID(),
        workspaceContextID: secondContext,
        environmentID: fixture.environmentID,
        activeContextGeneration: 4
    )
    await fixture.workspace.setResolvedContext(try ResolvedWorkspaceContext(
        validating: secondContext,
        projectID: fixture.resolvedContext.projectID,
        conversationID: conversationID,
        environmentID: fixture.environmentID,
        workspaceRootIdentity: fixture.root.path
    ))
    let second = try await fixture.service.openDocument(
        binding: secondBinding,
        at: fixture.path
    )
    try await fixture.service.registerDocumentViewer(
        connectionID: secondConnection,
        binding: secondBinding,
        documentID: second.documentID
    )

    var states = try await fixture.registry.documentDeletionStates(
        in: fixture.environmentID,
        documentIDs: [first.documentID]
    )
    #expect(states.count == 1)
    #expect(states[0].liveViewerContexts == [fixture.contextID, secondContext])

    await fixture.service.removeDocumentViewer(
        connectionID: firstConnection,
        documentID: first.documentID
    )
    states = try await fixture.registry.documentDeletionStates(
        in: fixture.environmentID,
        documentIDs: [first.documentID]
    )
    #expect(states[0].liveViewerContexts == [secondContext])

    await fixture.service.removeDocumentViewers(connectionID: secondConnection)
    states = try await fixture.registry.documentDeletionStates(
        in: fixture.environmentID,
        documentIDs: [first.documentID]
    )
    #expect(states[0].liveViewerContexts.isEmpty)
}

@Test func conversationDeletionReservationDrainsAdmittedEditAndBlocksLaterDataPlaneWork() async throws {
    let fixture = try await WorkspaceDataPlaneFixture()
    defer { fixture.remove() }
    let opened = try await fixture.service.openDocument(
        binding: fixture.binding,
        at: fixture.path
    )
    let editLease = try await fixture.service.acquireEditLease(
        binding: fixture.binding,
        documentID: opened.documentID
    )
    let kernel = try #require(await fixture.registry.kernel(for: fixture.environmentID))
    let registry = try #require(kernel.documentRegistry)
    let document = try #require(await registry.document(id: opened.documentID))
    let expectedStates = try await registry.deletionStates(
        documentIDs: [opened.documentID],
        includingViewerContext: fixture.contextID
    )
    let admitted = try await registry.acquireOperation(contextID: fixture.contextID)
    let preparationID = UUID()
    let reservation = Task {
        try await registry.reserveConversationDeletion(
            preparationID: preparationID,
            targetContextID: fixture.contextID,
            expectedDocumentStates: expectedStates
        )
    }
    for _ in 0..<1_000 where await registry.pendingDeletionReservationCount == 0 {
        await Task.yield()
    }
    #expect(await registry.pendingDeletionReservationCount == 1)

    let laterSnapshot = Task {
        try await fixture.service.snapshot(
            binding: fixture.binding,
            documentID: opened.documentID
        )
    }
    for _ in 0..<1_000 where await registry.pendingDocumentOperationCount == 0 {
        await Task.yield()
    }
    #expect(await registry.pendingDocumentOperationCount == 1)

    _ = try await document.apply(
        EditTransaction(
            validatingDocumentID: opened.documentID,
            editLeaseID: editLease.id,
            baseVersion: opened.documentVersion,
            clientSequence: 1,
            changes: [try UTF16TextEdit(
                validatingOffset: 3,
                length: 0,
                replacement: "d"
            )]
        ),
        authorizedClient: fixture.binding.clientInstanceID
    )
    await registry.releaseOperation(admitted)

    await #expect(throws: ConversationDeletionError.stalePreparation) {
        _ = try await reservation.value
    }
    #expect(try await laterSnapshot.value.documentVersion == 1)
}

@Test func workspaceKernelDataPlaneRejectsContextEnvironmentAndUnopenedDocumentBeforeActorMutation() async throws {
    let fixture = try await WorkspaceDataPlaneFixture()
    defer { fixture.remove() }
    let otherContext = WorkspaceContextID.project(ProjectID())
    await fixture.workspace.setResolvedContext(try ResolvedWorkspaceContext(
        validating: otherContext,
        projectID: {
            guard case let .project(id) = otherContext else { fatalError() }
            return id
        }(),
        conversationID: nil,
        environmentID: fixture.environmentID,
        workspaceRootIdentity: fixture.root.path
    ))
    await #expect(throws: HostDataPlaneServiceError.contextMismatch) {
        _ = try await fixture.service.openDocument(binding: fixture.binding, at: fixture.path)
    }
    #expect(await fixture.repository.findOrCreateCount == 0)

    await fixture.workspace.setResolvedContext(fixture.resolvedContext)
    let wrongEnvironmentBinding = try HostDataPlaneBinding(
        validatingClientInstanceID: fixture.binding.clientInstanceID,
        windowID: fixture.binding.windowID,
        workspaceContextID: fixture.binding.workspaceContextID,
        environmentID: EnvironmentID(),
        activeContextGeneration: fixture.binding.activeContextGeneration
    )
    await #expect(throws: HostDataPlaneServiceError.environmentMismatch) {
        _ = try await fixture.service.openDocument(binding: wrongEnvironmentBinding, at: fixture.path)
    }
    #expect(await fixture.repository.findOrCreateCount == 0)

    await #expect(throws: HostDataPlaneServiceError.documentNotOpen) {
        _ = try await fixture.service.snapshot(binding: fixture.binding, documentID: DocumentID())
    }
    #expect(await fixture.repository.compareAndSetCount == 0)
}

@Test func workspaceKernelDataPlaneUsesBindingClientForLeaseAndAuthorizedActorCalls() async throws {
    let fixture = try await WorkspaceDataPlaneFixture()
    defer { fixture.remove() }
    let opened = try await fixture.service.openDocument(binding: fixture.binding, at: fixture.path)
    let lease = try await fixture.service.acquireEditLease(binding: fixture.binding, documentID: opened.documentID)
    let compareAndSetCount = await fixture.repository.compareAndSetCount
    let forgedOwner = ClientInstanceID()
    let forgedBinding = try HostDataPlaneBinding(
        validatingClientInstanceID: forgedOwner,
        windowID: fixture.binding.windowID,
        workspaceContextID: fixture.binding.workspaceContextID,
        environmentID: fixture.binding.environmentID,
        activeContextGeneration: fixture.binding.activeContextGeneration
    )

    await #expect(throws: DocumentProtocolError.invalidLease) {
        _ = try await fixture.service.apply(
            binding: forgedBinding,
            transaction: EditTransaction(
                validatingDocumentID: opened.documentID,
                editLeaseID: lease.id,
                baseVersion: 0,
                clientSequence: 1,
                changes: [try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "forged")]
            )
        )
    }
    #expect(await fixture.repository.compareAndSetCount == compareAndSetCount)
    #expect(try Data(contentsOf: fixture.documentURL) == Data("abc".utf8))
    #expect((try await fixture.recoveryLog(for: opened.documentID).recover()).records.isEmpty)
}

@Test func workspaceKernelDataPlaneMapsOnlyConcreteCommittedRecoveryErrorToSharedBoundary() async throws {
    let fixture = try await WorkspaceDataPlaneFixture()
    defer { fixture.remove() }
    let opened = try await fixture.service.openDocument(binding: fixture.binding, at: fixture.path)
    let lease = try await fixture.service.acquireEditLease(binding: fixture.binding, documentID: opened.documentID)
    await fixture.repository.failNextCompareAndSet()
    let transaction = try EditTransaction(
        validatingDocumentID: opened.documentID,
        editLeaseID: lease.id,
        baseVersion: 0,
        clientSequence: 1,
        changes: [try UTF16TextEdit(validatingOffset: 3, length: 0, replacement: "d")]
    )

    do {
        _ = try await fixture.service.apply(binding: fixture.binding, transaction: transaction)
        Issue.record("Expected shared committed recovery error")
    } catch let error as HostDataPlaneDocumentError {
        guard case let .committedRecoveryRequired(acknowledgement) = error else {
            Issue.record("Unexpected shared document error")
            return
        }
        #expect(acknowledgement.documentID == opened.documentID)
        #expect(acknowledgement.clientSequence == 1)
        #expect(acknowledgement.documentVersion == 1)
    }
    #expect((try await fixture.recoveryLog(for: opened.documentID).recover()).records.count == 1)
}

@Test func workspaceKernelDataPlaneRoutesFileTreeGenerationAndRevision() async throws {
    let fixture = try await WorkspaceDataPlaneFixture()
    defer { fixture.remove() }
    let snapshot = try await fixture.service.fileTreeChildren(binding: fixture.binding, at: .root)
    #expect(snapshot.environmentID == fixture.environmentID)
    #expect(snapshot.generation == fixture.binding.activeContextGeneration)
    #expect(snapshot.children.contains { $0.identity.path == fixture.path })

    let kernel = try #require(await fixture.registry.kernel(for: fixture.environmentID))
    let stream = fixture.service.fileTreeChanges(binding: fixture.binding, after: snapshot.revision)
    let waiting = Task { () throws -> FileTreeDelta? in
        var iterator = stream.makeAsyncIterator()
        return try await iterator.next()
    }
    for _ in 0..<1_000 where await kernel.fileTreeProvider.subscriptionCount == 0 {
        await Task.yield()
    }
    #expect(await kernel.fileTreeProvider.subscriptionCount == 1)
    waiting.cancel()
    _ = try? await waiting.value
    for _ in 0..<1_000 where await kernel.fileTreeProvider.subscriptionCount != 0 {
        await Task.yield()
    }
    #expect(await kernel.fileTreeProvider.subscriptionCount == 0)

    let unavailable = fixture.service.fileTreeChanges(
        binding: fixture.binding,
        after: snapshot.revision + 1
    )
    var iterator = unavailable.makeAsyncIterator()
    await #expect(throws: FileTreeProviderError.revisionUnavailable(
        requested: snapshot.revision + 1,
        current: snapshot.revision
    )) {
        _ = try await iterator.next()
    }
}

@Test func workspaceKernelDataPlaneFileTreeTransportCarriesExpandedDirectorySnapshot() async throws {
    let environmentID = EnvironmentID()
    let directory = WorkspaceDirectory.relative(try RelativePath("Sources"))
    let delta = try FileTreeDelta(
        validating: environmentID,
        directory: directory,
        revision: 2,
        mutations: [.insert(try FileTreeEntry(
            validating: FileTreeEntryIdentity(
                validating: environmentID,
                path: RelativePath("Sources/main.swift")
            ),
            kind: .file
        ))]
    )
    let transport: any FileTreeDataTransport = WorkspaceDataPlaneFileTreeTransport(
        snapshot: try FileTreeSnapshot(
            validating: environmentID,
            directory: directory,
            generation: 1,
            revision: 1,
            children: []
        ),
        delta: delta
    )
    #expect(try await transport.children(at: directory).directory == directory)
    let stream = transport.changes(after: 1, expandedDirectories: [directory])
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next() == delta)
}

private final class WorkspaceDataPlaneRootToken: ProjectRootAccessToken, @unchecked Sendable {}

private actor WorkspaceDataPlaneWorkspace: WorkspaceServing {
    private var resolved: ResolvedWorkspaceContext
    private(set) var resolveCount = 0

    init(resolved: ResolvedWorkspaceContext) { self.resolved = resolved }

    func setResolvedContext(_ value: ResolvedWorkspaceContext) { resolved = value }
    func resolveContext(_ id: WorkspaceContextID) throws -> ResolvedWorkspaceContext {
        resolveCount += 1
        return resolved
    }
    func addProject(bookmark: Data, displayName: String) throws -> ProjectSnapshot { throw WorkspaceRepositoryError.projectNotFound }
    func listWorkspace() throws -> WorkspaceSnapshot { [] }
    func createDirectConversation(projectID: ProjectID) throws -> Conversation { throw WorkspaceRepositoryError.projectNotFound }
    func renameConversation(id: ConversationID, title: String) throws {}
    func performFileOperation(context: RequestContext, operation: FileOperation) throws -> FileOperationResult {
        throw FileOperationError.environmentNotRegistered
    }
}

private actor WorkspaceDataPlaneMetadataRepository: DocumentMetadataRepository {
    private let initialDocumentID: DocumentID
    private var values: [DocumentID: DocumentMetadata] = [:]
    private var failNext = false
    private(set) var findOrCreateCount = 0
    private(set) var compareAndSetCount = 0

    init(documentID: DocumentID) { initialDocumentID = documentID }

    func findOrCreateDocument(in environmentID: EnvironmentID, at path: RelativePath) throws -> DocumentMetadata {
        findOrCreateCount += 1
        if let value = values.values.first(where: { $0.environmentID == environmentID && $0.relativePath == path }) {
            return value
        }
        let value = try DocumentMetadata(
            validatingDocumentID: values.isEmpty ? initialDocumentID : DocumentID(),
            environmentID: environmentID,
            relativePath: path,
            documentVersion: 0,
            persistedVersion: 0,
            dirtyState: .clean,
            editLeaseID: nil
        )
        values[value.documentID] = value
        return value
    }

    func loadDocument(id: DocumentID) -> DocumentMetadata? { values[id] }

    func compareAndSetDocumentMetadata(
        _ metadata: DocumentMetadata,
        expectedDocumentVersion: UInt64,
        expectedEditLeaseID: EditLeaseID?
    ) throws {
        compareAndSetCount += 1
        if failNext {
            failNext = false
            throw DocumentMetadataRepositoryError.stale
        }
        guard let current = values[metadata.documentID],
              current.documentVersion == expectedDocumentVersion,
              current.editLeaseID == expectedEditLeaseID
        else { throw DocumentMetadataRepositoryError.stale }
        values[metadata.documentID] = metadata
    }

    func repairDocumentMetadata(_ metadata: DocumentMetadata) { values[metadata.documentID] = metadata }
    func relocateDocumentLocators(in environmentID: EnvironmentID, from source: RelativePath, to destination: RelativePath) {}
    func failNextCompareAndSet() { failNext = true }
}

private final class WorkspaceDataPlaneFixture: @unchecked Sendable {
    let root: URL
    let recoveryRoot: URL
    let documentURL: URL
    let path = try! RelativePath("document.txt")
    let environmentID = EnvironmentID()
    let documentID = DocumentID()
    let contextID: WorkspaceContextID
    let resolvedContext: ResolvedWorkspaceContext
    let binding: HostDataPlaneBinding
    let repository: WorkspaceDataPlaneMetadataRepository
    let registry: WorkspaceKernelRegistry
    let workspace: WorkspaceDataPlaneWorkspace
    let service: WorkspaceHostDataPlaneService

    init() async throws {
        root = URL(fileURLWithPath: "/private/tmp/cockpit-data-plane.\(UUID().uuidString)", isDirectory: true)
        recoveryRoot = URL(fileURLWithPath: "/private/tmp/cockpit-data-plane-recovery.\(UUID().uuidString)", isDirectory: true)
        documentURL = root.appendingPathComponent(path.string)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: false)
        try Data("abc".utf8).write(to: documentURL)
        let projectID = ProjectID()
        contextID = .project(projectID)
        resolvedContext = try ResolvedWorkspaceContext(
            validating: contextID,
            projectID: projectID,
            conversationID: nil,
            environmentID: environmentID,
            workspaceRootIdentity: root.path
        )
        binding = try HostDataPlaneBinding(
            validatingClientInstanceID: ClientInstanceID(),
            windowID: WindowID(),
            workspaceContextID: contextID,
            environmentID: environmentID,
            activeContextGeneration: 3
        )
        repository = WorkspaceDataPlaneMetadataRepository(documentID: documentID)
        registry = WorkspaceKernelRegistry(
            documentLocatorUpdater: repository,
            documentMetadataRepository: repository,
            documentRecoveryRoot: recoveryRoot
        )
        workspace = WorkspaceDataPlaneWorkspace(resolved: resolvedContext)
        service = WorkspaceHostDataPlaneService(workspaceService: workspace, kernelRegistry: registry)
        await registry.register(
            environmentID: environmentID,
            root: ResolvedProjectRoot(
                canonicalAbsolutePath: root.path,
                canonicalRootIdentity: root.path,
                gitCommonDirectory: nil,
                accessToken: WorkspaceDataPlaneRootToken()
            )
        )
    }

    func recoveryLog(for documentID: DocumentID) -> DocumentRecoveryLog {
        DocumentRecoveryLog(rootURL: recoveryRoot, documentID: documentID)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: recoveryRoot)
    }
}

private struct WorkspaceDataPlaneFileTreeTransport: FileTreeDataTransport {
    let snapshot: FileTreeSnapshot
    let delta: FileTreeDelta

    func children(at directory: WorkspaceDirectory) async throws -> FileTreeSnapshot { snapshot }

    func changes(
        after revision: UInt64,
        expandedDirectories: Set<WorkspaceDirectory>
    ) -> AsyncThrowingStream<FileTreeDelta, Error> {
        AsyncThrowingStream { continuation in
            guard revision == snapshot.revision,
                  expandedDirectories == [snapshot.directory]
            else {
                continuation.finish(throwing: FileTreeProviderError.revisionUnavailable(
                    requested: revision,
                    current: snapshot.revision
                ))
                return
            }
            continuation.yield(delta)
            continuation.finish()
        }
    }
}

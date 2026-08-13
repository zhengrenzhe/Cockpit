import Foundation
import CockpitHostCore
import CockpitProtocol
import CockpitTypes

public final class WorkspaceKernel: @unchecked Sendable {
    let root: ResolvedProjectRoot
    let fileTreeProvider: FileTreeProvider
    private let eventSource: FileSystemEventSource
    private let reconciler: FileTreeReconciler
    let fileOperationCoordinator: FileOperationCoordinator
    public let documentRegistry: DocumentRegistry?

    init(
        environmentID: EnvironmentID,
        root: ResolvedProjectRoot,
        documentLocatorUpdater: any DocumentLocatorUpdating,
        documentMetadataRepository: (any DocumentMetadataRepository)?,
        documentRecoveryRoot: URL?
    ) {
        self.root = root
        let provider = FileTreeProvider(
            environmentID: environmentID,
            rootURL: URL(fileURLWithPath: root.canonicalAbsolutePath, isDirectory: true),
            rootAccessToken: root.accessToken
        )
        let eventSource = FileSystemEventSource(
            rootURL: URL(fileURLWithPath: root.canonicalAbsolutePath, isDirectory: true)
        )
        let rootHandle = WorkspaceRootHandle(
            rootURL: URL(fileURLWithPath: root.canonicalAbsolutePath, isDirectory: true)
        )
        let documentRegistry: DocumentRegistry?
        if let documentMetadataRepository, let documentRecoveryRoot {
            documentRegistry = DocumentRegistry(
                environmentID: environmentID,
                documentServing: rootHandle,
                metadataRepository: documentMetadataRepository,
                recoveryRoot: documentRecoveryRoot
            )
        } else {
            documentRegistry = nil
        }
        self.documentRegistry = documentRegistry
        fileTreeProvider = provider
        fileOperationCoordinator = FileOperationCoordinator(
            environmentID: environmentID,
            rootHandle: rootHandle,
            documentLocatorUpdater: documentLocatorUpdater,
            fileTreeProvider: provider,
            documentRegistry: documentRegistry
        )
        self.eventSource = eventSource
        reconciler = FileTreeReconciler(
            provider: provider,
            invalidations: eventSource.invalidations,
            documentRegistry: documentRegistry
        )
    }

    deinit {
        eventSource.cancel()
        reconciler.cancelAndWait()
    }
}

public actor WorkspaceKernelRegistry: WorkspaceKernelRegistering {
    private var kernels: [EnvironmentID: WorkspaceKernel] = [:]
    private let documentLocatorUpdater: any DocumentLocatorUpdating
    private let documentMetadataRepository: (any DocumentMetadataRepository)?
    private let documentRecoveryRoot: URL?

    public init() {
        documentLocatorUpdater = NoOpDocumentLocatorUpdater()
        documentMetadataRepository = nil
        documentRecoveryRoot = nil
    }

    public init(documentLocatorUpdater: any DocumentLocatorUpdating) {
        self.documentLocatorUpdater = documentLocatorUpdater
        documentMetadataRepository = nil
        documentRecoveryRoot = nil
    }

    public init(
        documentLocatorUpdater: any DocumentLocatorUpdating,
        documentMetadataRepository: any DocumentMetadataRepository,
        documentRecoveryRoot: URL
    ) {
        self.documentLocatorUpdater = documentLocatorUpdater
        self.documentMetadataRepository = documentMetadataRepository
        self.documentRecoveryRoot = documentRecoveryRoot
    }

    public func register(environmentID: EnvironmentID, root: ResolvedProjectRoot) {
        guard kernels[environmentID] == nil else { return }
        kernels[environmentID] = WorkspaceKernel(
            environmentID: environmentID,
            root: root,
            documentLocatorUpdater: documentLocatorUpdater,
            documentMetadataRepository: documentMetadataRepository,
            documentRecoveryRoot: documentRecoveryRoot
        )
    }

    public func kernel(for environmentID: EnvironmentID) -> WorkspaceKernel? {
        kernels[environmentID]
    }

    func coordinator(for environmentID: EnvironmentID) -> FileOperationCoordinator? {
        kernels[environmentID]?.fileOperationCoordinator
    }

    public func perform(
        _ operation: FileOperation,
        in environmentID: EnvironmentID
    ) async throws -> FileOperationResult {
        guard let kernel = kernels[environmentID] else {
            throw FileOperationError.environmentNotRegistered
        }
        guard let registry = kernel.documentRegistry else {
            return try await kernel.fileOperationCoordinator.perform(operation)
        }
        let lease = try await registry.acquireOperation(contextID: nil)
        do {
            let result = try await kernel.fileOperationCoordinator.perform(operation)
            await registry.releaseOperation(lease)
            return result
        } catch {
            await registry.releaseOperation(lease)
            throw error
        }
    }

    public func perform(
        _ operation: FileOperation,
        in environmentID: EnvironmentID,
        contextID: WorkspaceContextID
    ) async throws -> FileOperationResult {
        guard let coordinator = kernels[environmentID]?.fileOperationCoordinator else {
            throw FileOperationError.environmentNotRegistered
        }
        guard let registry = kernels[environmentID]?.documentRegistry else {
            return try await coordinator.perform(operation)
        }
        let lease = try await registry.acquireOperation(contextID: contextID)
        do {
            let result = try await coordinator.perform(operation)
            await registry.releaseOperation(lease)
            return result
        } catch {
            await registry.releaseOperation(lease)
            throw error
        }
    }

    public func documentDeletionStates(
        in environmentID: EnvironmentID,
        documentIDs: Set<DocumentID>
    ) async throws -> [DocumentDeletionState] {
        guard let registry = kernels[environmentID]?.documentRegistry else { return [] }
        let lease = try await registry.acquireOperation(contextID: nil)
        do {
            let states = try await registry.deletionStates(documentIDs: documentIDs)
            await registry.releaseOperation(lease)
            return states
        } catch {
            await registry.releaseOperation(lease)
            throw error
        }
    }

    public func documentDeletionStates(
        in environmentID: EnvironmentID,
        documentIDs: Set<DocumentID>,
        includingViewerContext contextID: WorkspaceContextID
    ) async throws -> [DocumentDeletionState] {
        guard let registry = kernels[environmentID]?.documentRegistry else { return [] }
        let lease = try await registry.acquireOperation(contextID: nil)
        do {
            let states = try await registry.deletionStates(
                documentIDs: documentIDs,
                includingViewerContext: contextID
            )
            await registry.releaseOperation(lease)
            return states
        } catch {
            await registry.releaseOperation(lease)
            throw error
        }
    }

    public func reserveConversationDeletion(
        in environmentID: EnvironmentID,
        preparationID: UUID,
        targetContextID: WorkspaceContextID,
        expectedDocumentStates: [DocumentDeletionState]
    ) async throws -> ConversationDeletionDocumentReservation {
        guard let registry = kernels[environmentID]?.documentRegistry else {
            throw HostDataPlaneServiceError.documentNotOpen
        }
        return try await registry.reserveConversationDeletion(
            preparationID: preparationID,
            targetContextID: targetContextID,
            expectedDocumentStates: expectedDocumentStates
        )
    }

    public func commitConversationDeletion(
        _ reservation: ConversationDeletionDocumentReservation,
        blocking targetContextID: WorkspaceContextID
    ) async {
        await kernels[reservation.environmentID]?.documentRegistry?
            .commitConversationDeletion(reservation, blocking: targetContextID)
    }

    public func cancelConversationDeletion(
        _ reservation: ConversationDeletionDocumentReservation
    ) async {
        await kernels[reservation.environmentID]?.documentRegistry?
            .cancelConversationDeletion(reservation)
    }

    func registerDocumentViewer(
        connectionID: UUID,
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) async throws {
        guard let registry = kernels[binding.environmentID]?.documentRegistry else {
            throw HostDataPlaneServiceError.documentNotOpen
        }
        try await registry.registerViewer(
            connectionID: connectionID,
            contextID: binding.workspaceContextID,
            clientInstanceID: binding.clientInstanceID,
            documentID: documentID
        )
    }

    func removeDocumentViewers(connectionID: UUID) async {
        for kernel in kernels.values {
            await kernel.documentRegistry?.removeViewers(connectionID: connectionID)
        }
    }

    func removeDocumentViewer(
        connectionID: UUID,
        documentID: DocumentID
    ) async {
        for kernel in kernels.values {
            await kernel.documentRegistry?.removeViewer(
                connectionID: connectionID,
                documentID: documentID
            )
        }
    }
}

private struct NoOpDocumentLocatorUpdater: DocumentLocatorUpdating {
    func relocateDocumentLocators(
        in environmentID: EnvironmentID,
        from source: RelativePath,
        to destination: RelativePath
    ) async throws {}
}

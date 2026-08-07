import Foundation
import CockpitHostCore
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
        guard let coordinator = kernels[environmentID]?.fileOperationCoordinator else {
            throw FileOperationError.environmentNotRegistered
        }
        return try await coordinator.perform(operation)
    }
}

private struct NoOpDocumentLocatorUpdater: DocumentLocatorUpdating {
    func relocateDocumentLocators(
        in environmentID: EnvironmentID,
        from source: RelativePath,
        to destination: RelativePath
    ) async throws {}
}

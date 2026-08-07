import Foundation
import CockpitHostCore
import CockpitTypes

public final class WorkspaceKernel: @unchecked Sendable {
    let root: ResolvedProjectRoot
    let fileTreeProvider: FileTreeProvider
    private let eventSource: FileSystemEventSource
    private let reconciler: FileTreeReconciler
    let fileOperationCoordinator: FileOperationCoordinator

    init(
        environmentID: EnvironmentID,
        root: ResolvedProjectRoot,
        documentLocatorUpdater: any DocumentLocatorUpdating
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
        fileTreeProvider = provider
        fileOperationCoordinator = FileOperationCoordinator(
            environmentID: environmentID,
            rootHandle: WorkspaceRootHandle(
                rootURL: URL(fileURLWithPath: root.canonicalAbsolutePath, isDirectory: true)
            ),
            documentLocatorUpdater: documentLocatorUpdater,
            fileTreeProvider: provider
        )
        self.eventSource = eventSource
        reconciler = FileTreeReconciler(
            provider: provider,
            invalidations: eventSource.invalidations
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

    public init() {
        documentLocatorUpdater = NoOpDocumentLocatorUpdater()
    }

    public init(documentLocatorUpdater: any DocumentLocatorUpdating) {
        self.documentLocatorUpdater = documentLocatorUpdater
    }

    public func register(environmentID: EnvironmentID, root: ResolvedProjectRoot) {
        guard kernels[environmentID] == nil else { return }
        kernels[environmentID] = WorkspaceKernel(
            environmentID: environmentID,
            root: root,
            documentLocatorUpdater: documentLocatorUpdater
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

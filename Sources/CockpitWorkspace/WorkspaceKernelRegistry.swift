import Foundation
import CockpitHostCore
import CockpitTypes

public final class WorkspaceKernel: @unchecked Sendable {
    let root: ResolvedProjectRoot
    let fileTreeProvider: FileTreeProvider
    private let eventSource: FileSystemEventSource
    private let reconciler: FileTreeReconciler

    init(environmentID: EnvironmentID, root: ResolvedProjectRoot) {
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

    public init() {}

    public func register(environmentID: EnvironmentID, root: ResolvedProjectRoot) {
        guard kernels[environmentID] == nil else { return }
        kernels[environmentID] = WorkspaceKernel(environmentID: environmentID, root: root)
    }

    public func kernel(for environmentID: EnvironmentID) -> WorkspaceKernel? {
        kernels[environmentID]
    }
}

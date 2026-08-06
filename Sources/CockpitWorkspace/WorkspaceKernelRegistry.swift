import CockpitHostCore
import CockpitTypes

public final class WorkspaceKernel: @unchecked Sendable {
    let root: ResolvedProjectRoot

    init(root: ResolvedProjectRoot) {
        self.root = root
    }
}

public actor WorkspaceKernelRegistry: WorkspaceKernelRegistering {
    private var kernels: [EnvironmentID: WorkspaceKernel] = [:]

    public init() {}

    public func register(environmentID: EnvironmentID, root: ResolvedProjectRoot) {
        guard kernels[environmentID] == nil else { return }
        kernels[environmentID] = WorkspaceKernel(root: root)
    }

    public func kernel(for environmentID: EnvironmentID) -> WorkspaceKernel? {
        kernels[environmentID]
    }
}

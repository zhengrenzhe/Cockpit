import CockpitHostCore
import CockpitTypes

actor FileOperationCoordinator {
    private let environmentID: EnvironmentID
    private let rootHandle: any FileOperationPhysicallyPerforming
    private let documentLocatorUpdater: any DocumentLocatorUpdating
    private let fileTreeProvider: FileTreeProvider
    private let operationGate = FileTreeOperationGate()

    init(
        environmentID: EnvironmentID,
        rootHandle: any FileOperationPhysicallyPerforming,
        documentLocatorUpdater: any DocumentLocatorUpdating,
        fileTreeProvider: FileTreeProvider
    ) {
        self.environmentID = environmentID
        self.rootHandle = rootHandle
        self.documentLocatorUpdater = documentLocatorUpdater
        self.fileTreeProvider = fileTreeProvider
    }

    func perform(_ operation: FileOperation) async throws -> FileOperationResult {
        try await operationGate.acquire()
        do {
            try Task.checkCancellation()
            let lease = try await fileTreeProvider.acquireExternalMutationLease()
            do {
                let physical = try await rootHandle.perform(operation)
                if case let .relocated(source, destination) = physical.result {
                    try await documentLocatorUpdater.relocateDocumentLocators(
                        in: environmentID,
                        from: source,
                        to: destination
                    )
                }
                try await fileTreeProvider.completeExternalMutation(
                    operation: operation,
                    physical: physical,
                    lease: lease
                )
                await operationGate.release()
                return physical.result
            } catch {
                await fileTreeProvider.cancelExternalMutation(lease)
                throw error
            }
        } catch {
            await operationGate.release()
            throw error
        }
    }

    func waitUntilOperationIsQueued() async {
        while await operationGate.waiterCount == 0 {
            await Task.yield()
        }
    }
}

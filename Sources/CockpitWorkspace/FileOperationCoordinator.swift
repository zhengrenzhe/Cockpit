import CockpitHostCore
import CockpitTypes

actor FileOperationCoordinator {
    private let environmentID: EnvironmentID
    private let rootHandle: any FileOperationPhysicallyPerforming
    private let documentLocatorUpdater: any DocumentLocatorUpdating
    private let fileTreeProvider: FileTreeProvider
    private let documentRegistry: DocumentRegistry?
    private let operationGate = FileTreeOperationGate()
    private var recoveryRequired: FileOperationRecoveryRequiredError?

    init(
        environmentID: EnvironmentID,
        rootHandle: any FileOperationPhysicallyPerforming,
        documentLocatorUpdater: any DocumentLocatorUpdating,
        fileTreeProvider: FileTreeProvider,
        documentRegistry: DocumentRegistry? = nil
    ) {
        self.environmentID = environmentID
        self.rootHandle = rootHandle
        self.documentLocatorUpdater = documentLocatorUpdater
        self.fileTreeProvider = fileTreeProvider
        self.documentRegistry = documentRegistry
    }

    func perform(_ operation: FileOperation) async throws -> FileOperationResult {
        if let recoveryRequired { throw recoveryRequired }
        try await operationGate.acquire()
        do {
            if let recoveryRequired { throw recoveryRequired }
            try Task.checkCancellation()
            let relocation = try operation.validatedRelocation
            let documentMutationLease: DocumentInternalMutationLease?
            if let relocation {
                documentMutationLease = await documentRegistry?.acquireInternalMutationLease(
                    from: relocation.source,
                    to: relocation.destination
                )
            } else {
                documentMutationLease = await documentRegistry?.acquireInternalMutationLease()
            }
            do {
                if let relocation {
                    try await documentLocatorUpdater.preflightDocumentLocatorRelocation(
                        in: environmentID,
                        from: relocation.source,
                        to: relocation.destination
                    )
                    try Task.checkCancellation()
                }
                let lease = try await fileTreeProvider.acquireExternalMutationLease()
                do {
                try Task.checkCancellation()
                let physical = try await rootHandle.perform(operation)
                let completion = Task { [documentLocatorUpdater, environmentID, fileTreeProvider, documentRegistry] in
                    do {
                        let staged = try await fileTreeProvider.stageExternalMutation(
                            operation: operation,
                            physical: physical,
                            lease: lease
                        )
                        if case let .relocated(source, destination) = physical.result {
                            try await documentLocatorUpdater.relocateDocumentLocators(
                                in: environmentID,
                                from: source,
                                to: destination
                            )
                            await documentRegistry?.relocateOpenDocuments(
                                from: source,
                                to: destination
                            )
                        }
                        await fileTreeProvider.commitExternalMutation(staged, lease: lease)
                        return PostPhysicalCompletion.success
                    } catch {
                        return .failed(error)
                    }
                }
                switch await completion.value {
                case .success:
                    if let documentMutationLease {
                        await documentRegistry?.releaseInternalMutationLease(documentMutationLease)
                    }
                    await operationGate.release()
                    return physical.result
                case let .failed(originalError):
                    let fatal = FileOperationRecoveryRequiredError(
                        originalOperation: operation,
                        state: .committed(physical.result),
                        originalError: originalError
                    )
                    recoveryRequired = fatal
                    if let documentMutationLease {
                        await documentRegistry?.failInternalMutationLease(documentMutationLease)
                    }
                    throw fatal
                }
                } catch {
                    await fileTreeProvider.cancelExternalMutation(lease)
                    if let fatal = error as? FileOperationRecoveryRequiredError {
                        recoveryRequired = fatal
                        if let documentMutationLease {
                            await documentRegistry?.failInternalMutationLease(documentMutationLease)
                        }
                    } else if let documentMutationLease {
                        await documentRegistry?.releaseInternalMutationLease(documentMutationLease)
                    }
                    throw error
                }
            } catch {
                if let documentMutationLease {
                    await documentRegistry?.releaseInternalMutationLease(documentMutationLease)
                }
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

private enum PostPhysicalCompletion: @unchecked Sendable {
    case success
    case failed(any Error)
}

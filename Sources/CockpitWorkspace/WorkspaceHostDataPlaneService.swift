import CockpitHostCore
import CockpitProtocol
import CockpitTypes

public struct WorkspaceHostDataPlaneService: HostDataPlaneServing {
    private let workspaceService: any WorkspaceServing
    private let kernelRegistry: WorkspaceKernelRegistry

    public init(
        workspaceService: any WorkspaceServing,
        kernelRegistry: WorkspaceKernelRegistry
    ) {
        self.workspaceService = workspaceService
        self.kernelRegistry = kernelRegistry
    }

    public func openDocument(
        binding: HostDataPlaneBinding,
        at path: RelativePath
    ) async throws -> DocumentSnapshot {
        let kernel = try await resolveKernel(for: binding)
        guard let registry = kernel.documentRegistry else {
            throw HostDataPlaneServiceError.documentNotOpen
        }
        let document = try await registry.open(at: path)
        return await document.snapshot()
    }

    public func snapshot(
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) async throws -> DocumentSnapshot {
        let document = try await openDocument(id: documentID, binding: binding)
        return await document.snapshot()
    }

    public func acquireEditLease(
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) async throws -> EditLease {
        let document = try await openDocument(id: documentID, binding: binding)
        return try await document.acquireEditLease(client: binding.clientInstanceID)
    }

    public func transferEditLease(
        binding: HostDataPlaneBinding,
        documentID: DocumentID,
        from leaseID: EditLeaseID,
        to client: ClientInstanceID
    ) async throws -> EditLease {
        let document = try await openDocument(id: documentID, binding: binding)
        return try await document.transferEditLease(
            from: leaseID,
            to: client,
            authorizedClient: binding.clientInstanceID
        )
    }

    public func apply(
        binding: HostDataPlaneBinding,
        transaction: EditTransaction
    ) async throws -> EditAcknowledgement {
        let document = try await openDocument(id: transaction.documentID, binding: binding)
        do {
            return try await document.apply(
                transaction,
                authorizedClient: binding.clientInstanceID
            )
        } catch let error as DocumentCommitRecoveryRequiredError {
            throw HostDataPlaneDocumentError.committedRecoveryRequired(
                error.committedAcknowledgement
            )
        }
    }

    public func flush(
        binding: HostDataPlaneBinding,
        documentID: DocumentID,
        through clientSequence: UInt64
    ) async throws -> UInt64 {
        let document = try await openDocument(id: documentID, binding: binding)
        return try await document.flush(
            through: clientSequence,
            authorizedClient: binding.clientInstanceID
        )
    }

    public func save(
        binding: HostDataPlaneBinding,
        documentID: DocumentID,
        expectedFingerprint: DiskFingerprint
    ) async throws -> DocumentSnapshot {
        let document = try await openDocument(id: documentID, binding: binding)
        return try await document.save(
            expectedFingerprint: expectedFingerprint,
            authorizedClient: binding.clientInstanceID
        )
    }

    public func discard(
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) async throws -> DocumentSnapshot {
        let document = try await openDocument(id: documentID, binding: binding)
        return try await document.discard(authorizedClient: binding.clientInstanceID)
    }

    public func fileTreeChildren(
        binding: HostDataPlaneBinding,
        at directory: WorkspaceDirectory
    ) async throws -> FileTreeSnapshot {
        let kernel = try await resolveKernel(for: binding)
        return try await kernel.fileTreeProvider.children(
            environmentID: binding.environmentID,
            at: directory,
            generation: binding.activeContextGeneration
        )
    }

    public func fileTreeChanges(
        binding: HostDataPlaneBinding,
        after revision: UInt64
    ) -> AsyncThrowingStream<FileTreeDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let kernel = try await resolveKernel(for: binding)
                    var iterator = kernel.fileTreeProvider.changes(
                        environmentID: binding.environmentID,
                        after: revision
                    ).makeAsyncIterator()
                    while let delta = try await iterator.next() {
                        if case .terminated = continuation.yield(delta) { return }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func openDocument(
        id documentID: DocumentID,
        binding: HostDataPlaneBinding
    ) async throws -> DocumentActor {
        let kernel = try await resolveKernel(for: binding)
        guard let registry = kernel.documentRegistry,
              let document = await registry.document(id: documentID)
        else {
            throw HostDataPlaneServiceError.documentNotOpen
        }
        return document
    }

    private func resolveKernel(
        for binding: HostDataPlaneBinding
    ) async throws -> WorkspaceKernel {
        let context = try await workspaceService.resolveContext(binding.workspaceContextID)
        guard context.contextID == binding.workspaceContextID else {
            throw HostDataPlaneServiceError.contextMismatch
        }
        guard context.environmentID == binding.environmentID else {
            throw HostDataPlaneServiceError.environmentMismatch
        }
        guard let kernel = await kernelRegistry.kernel(for: binding.environmentID) else {
            throw HostDataPlaneServiceError.environmentMismatch
        }
        return kernel
    }
}

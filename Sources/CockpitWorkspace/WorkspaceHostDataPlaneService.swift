import Foundation
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
        try await withDocumentOperation(binding: binding) { registry in
            let document = try await registry.open(at: path)
            return await document.snapshot()
        }
    }

    public func registerDocumentViewer(
        connectionID: UUID,
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) async throws {
        try await kernelRegistry.registerDocumentViewer(
            connectionID: connectionID,
            binding: binding,
            documentID: documentID
        )
    }

    public func removeDocumentViewers(connectionID: UUID) async {
        await kernelRegistry.removeDocumentViewers(connectionID: connectionID)
    }

    public func removeDocumentViewer(
        connectionID: UUID,
        documentID: DocumentID
    ) async {
        await kernelRegistry.removeDocumentViewer(
            connectionID: connectionID,
            documentID: documentID
        )
    }

    public func snapshot(
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) async throws -> DocumentSnapshot {
        try await withOpenDocument(binding: binding, documentID: documentID) {
            await $0.snapshot()
        }
    }

    public func acquireEditLease(
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) async throws -> EditLease {
        try await withOpenDocument(binding: binding, documentID: documentID) {
            try await $0.acquireEditLease(client: binding.clientInstanceID)
        }
    }

    public func transferEditLease(
        binding: HostDataPlaneBinding,
        documentID: DocumentID,
        from leaseID: EditLeaseID,
        to client: ClientInstanceID
    ) async throws -> EditLease {
        try await withOpenDocument(binding: binding, documentID: documentID) {
            try await $0.transferEditLease(
                from: leaseID,
                to: client,
                authorizedClient: binding.clientInstanceID
            )
        }
    }

    public func apply(
        binding: HostDataPlaneBinding,
        transaction: EditTransaction
    ) async throws -> EditAcknowledgement {
        try await withOpenDocument(binding: binding, documentID: transaction.documentID) {
            do {
                return try await $0.apply(
                    transaction,
                    authorizedClient: binding.clientInstanceID
                )
            } catch let error as DocumentCommitRecoveryRequiredError {
                throw HostDataPlaneDocumentError.committedRecoveryRequired(
                    error.committedAcknowledgement
                )
            }
        }
    }

    public func flush(
        binding: HostDataPlaneBinding,
        documentID: DocumentID,
        through clientSequence: UInt64
    ) async throws -> UInt64 {
        try await withOpenDocument(binding: binding, documentID: documentID) {
            try await $0.flush(
                through: clientSequence,
                authorizedClient: binding.clientInstanceID
            )
        }
    }

    public func save(
        binding: HostDataPlaneBinding,
        documentID: DocumentID,
        expectedFingerprint: DiskFingerprint
    ) async throws -> DocumentSnapshot {
        try await withOpenDocument(binding: binding, documentID: documentID) {
            try await $0.save(
                expectedFingerprint: expectedFingerprint,
                authorizedClient: binding.clientInstanceID
            )
        }
    }

    public func discard(
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) async throws -> DocumentSnapshot {
        try await withOpenDocument(binding: binding, documentID: documentID) {
            try await $0.discard(authorizedClient: binding.clientInstanceID)
        }
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

    private func withDocumentOperation<T: Sendable>(
        binding: HostDataPlaneBinding,
        _ operation: @Sendable (DocumentRegistry) async throws -> T
    ) async throws -> T {
        let kernel = try await resolveKernel(for: binding)
        guard let registry = kernel.documentRegistry else {
            throw HostDataPlaneServiceError.documentNotOpen
        }
        let lease = try await registry.acquireOperation(
            contextID: binding.workspaceContextID
        )
        do {
            let result = try await operation(registry)
            await registry.releaseOperation(lease)
            return result
        } catch {
            await registry.releaseOperation(lease)
            throw error
        }
    }

    private func withOpenDocument<T: Sendable>(
        binding: HostDataPlaneBinding,
        documentID: DocumentID,
        _ operation: @Sendable (DocumentActor) async throws -> T
    ) async throws -> T {
        try await withDocumentOperation(binding: binding) { registry in
            let document = try await registry.restoreDocument(id: documentID)
            return try await operation(document)
        }
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

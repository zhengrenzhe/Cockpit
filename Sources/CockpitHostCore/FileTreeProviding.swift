import CockpitTypes

public enum FileTreeProviderError: Error, Equatable, Sendable {
    case environmentMismatch
    case zeroGeneration
    case symbolicLinkTraversal
    case revisionUnavailable(requested: UInt64, current: UInt64)
}

public protocol FileTreeProviding: Sendable {
    func children(
        environmentID: EnvironmentID,
        at directory: WorkspaceDirectory,
        generation: UInt64
    ) async throws -> FileTreeSnapshot

    func changes(
        environmentID: EnvironmentID,
        after revision: UInt64
    ) -> AsyncThrowingStream<FileTreeDelta, Error>
}

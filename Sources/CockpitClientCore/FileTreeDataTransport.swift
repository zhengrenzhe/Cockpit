import CockpitTypes

public protocol FileTreeDataTransport: Sendable {
    func children(at directory: WorkspaceDirectory) async throws -> FileTreeSnapshot
    func changes(
        after revision: UInt64,
        expandedDirectories: Set<WorkspaceDirectory>
    ) -> AsyncThrowingStream<FileTreeDelta, Error>
}

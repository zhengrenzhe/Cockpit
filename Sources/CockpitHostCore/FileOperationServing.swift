import CockpitTypes

public enum FileOperationError: Error, Equatable, Sendable {
    case invalidName
    case invalidPath
    case symbolicLinkTraversal
    case moveIntoDescendant
    case identityChanged
    case contextEnvironmentMismatch
    case environmentNotRegistered
}

public enum FileOperation: Hashable, Sendable {
    case createFile(parent: WorkspaceDirectory, name: String)
    case createDirectory(parent: WorkspaceDirectory, name: String)
    case rename(source: RelativePath, newName: String)
    case move(source: RelativePath, destinationDirectory: WorkspaceDirectory)
    case trash(path: RelativePath)
}

public enum FileOperationResult: Hashable, Sendable {
    case created(path: RelativePath, kind: FileTreeEntryKind)
    case relocated(from: RelativePath, to: RelativePath)
    case trashed(path: RelativePath)
}

public protocol FileOperationServing: Sendable {
    func perform(
        _ operation: FileOperation,
        in environmentID: EnvironmentID
    ) async throws -> FileOperationResult
}

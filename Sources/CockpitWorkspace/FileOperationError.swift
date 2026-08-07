import CockpitHostCore
import CockpitTypes

extension FileOperationError {
    static func invalidPath(_ error: any Error) -> FileOperationError {
        if let error = error as? FileOperationError { return error }
        return .invalidPath
    }
}

extension FileOperation {
    var validatedRelocation: (source: RelativePath, destination: RelativePath)? {
        get throws {
            switch self {
            case let .rename(source, newName):
                let source = try validatedFileOperationPath(source)
                let name = try validatedFileOperationName(newName)
                let components = source.string.split(separator: "/")
                let destination = components.count == 1
                    ? try RelativePath(name)
                    : try RelativePath(components.dropLast().joined(separator: "/") + "/" + name)
                return (source, destination)
            case let .move(source, destinationDirectory):
                let source = try validatedFileOperationPath(source)
                let directory: WorkspaceDirectory
                do { directory = try destinationDirectory.validated() }
                catch { throw FileOperationError.invalidPath }
                let name = String(source.string.split(separator: "/").last!)
                let destination: RelativePath = switch directory {
                case .root: try RelativePath(name)
                case let .relative(parent): try RelativePath(parent.string + "/" + name)
                }
                return (source, destination)
            default:
                return nil
            }
        }
    }
}

private func validatedFileOperationPath(_ path: RelativePath) throws -> RelativePath {
    guard !path.string.contains("\0") else { throw FileOperationError.invalidPath }
    do { return try RelativePath(path.string) }
    catch { throw FileOperationError.invalidPath }
}

private func validatedFileOperationName(_ name: String) throws -> String {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
        throw FileOperationError.invalidName
    }
    return name
}

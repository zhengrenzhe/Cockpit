import CockpitHostCore

extension FileOperationError {
    static func invalidPath(_ error: any Error) -> FileOperationError {
        if let error = error as? FileOperationError { return error }
        return .invalidPath
    }
}

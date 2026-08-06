public struct RelativePath: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Error: Swift.Error, Equatable {
        case empty
        case absolute
        case parentTraversal
    }

    public let string: String

    public init(_ input: String) throws {
        guard !input.isEmpty else { throw Error.empty }
        guard !input.hasPrefix("/") else { throw Error.absolute }

        var normalized: [Substring] = []
        for component in input.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { throw Error.parentTraversal }
            normalized.append(component)
        }

        guard !normalized.isEmpty else { throw Error.empty }
        string = normalized.joined(separator: "/")
    }

    public var description: String { string }
}

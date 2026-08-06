public struct SQLiteMigration: Sendable {
    public let version: Int64
    public let statements: [String]

    public init(version: Int64, statements: [String]) {
        self.version = version
        self.statements = statements
    }
}

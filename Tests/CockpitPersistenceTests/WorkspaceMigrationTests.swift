import Foundation
import Testing
@testable import CockpitPersistence

@Test func workspaceMigrationV1CreatesOnlyTheApprovedTables() async throws {
    try await withMigrationDatabase { databaseURL in
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try await connection.applyMigrations(WorkspaceMigrations.all)

        #expect(try await connection.tableNames() == [
            "conversation_deletions",
            "conversations",
            "documents",
            "environments",
            "projects",
            "schema_migrations",
        ])
    }
}

@Test func failedMigrationRollsBackItsSchemaChanges() async throws {
    try await withMigrationDatabase { databaseURL in
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        let brokenMigration = SQLiteMigration(
            version: 1,
            statements: [
                "CREATE TABLE must_be_rolled_back (id TEXT PRIMARY KEY)",
                "THIS IS NOT SQL",
            ]
        )

        await #expect(throws: (any Error).self) {
            try await connection.applyMigrations([brokenMigration])
        }
        #expect(try await connection.tableNames() == [])
    }
}

private func withMigrationDatabase(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = URL(
        fileURLWithPath: "/private/tmp/cockpit-workspace-migration-tests.\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("workspace.sqlite"))
}

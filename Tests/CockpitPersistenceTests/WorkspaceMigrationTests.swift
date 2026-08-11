import Foundation
import SQLite3
import Testing
@testable import CockpitPersistence

@Test func workspaceMigrationsCreateOnlyTheApprovedTables() async throws {
    try await withMigrationDatabase { databaseURL in
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try await connection.applyMigrations(WorkspaceMigrations.all)

        #expect(try await connection.tableNames() == [
            "client_workspace_states",
            "conversation_deletions",
            "conversations",
            "documents",
            "environments",
            "projects",
            "schema_migrations",
        ])
        #expect(
            try await connection.integerValue(for: "SELECT MAX(version) FROM schema_migrations") == 3
        )
    }
}

@Test func workspaceMigrationV3PreservesDeletionIdentityAfterConversationRemoval() async throws {
    try await withMigrationDatabase { databaseURL in
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try await connection.applyMigrations(Array(WorkspaceMigrations.all.prefix(2)))
        try await connection.withImmediateTransaction { connection in
            try connection.execute(
                """
                INSERT INTO projects (
                    id, display_name, root_bookmark, canonical_root_identity,
                    base_environment_id, created_at
                ) VALUES ('00000000-0000-4000-8000-000000000001', 'Persisted', X'01',
                          'root-v3', '00000000-0000-4000-8000-000000000002', 1)
                """
            )
            try connection.execute(
                """
                INSERT INTO environments (
                    id, project_id, kind, workspace_root, workspace_root_identity,
                    git_common_directory, worktree_branch
                ) VALUES ('00000000-0000-4000-8000-000000000002',
                          '00000000-0000-4000-8000-000000000001', 'direct', '/tmp/project',
                          'root-v3', NULL, NULL)
                """
            )
            try connection.execute(
                """
                INSERT INTO conversations (
                    id, project_id, environment_id, title, lifecycle_state,
                    deletion_phase, deletion_operation_id, created_at
                ) VALUES ('00000000-0000-4000-8000-000000000003',
                          '00000000-0000-4000-8000-000000000001',
                          '00000000-0000-4000-8000-000000000002', 'Deleting', 'deleting',
                          'terminatingSessions', '00000000-0000-4000-8000-000000000004', 2)
                """
            )
            try connection.execute(
                """
                INSERT INTO conversation_deletions (operation_id, conversation_id, phase)
                VALUES ('00000000-0000-4000-8000-000000000004',
                        '00000000-0000-4000-8000-000000000003', 'terminatingSessions')
                """
            )
        }

        try await connection.applyMigrations(WorkspaceMigrations.all)
        try await connection.execute(
            "DELETE FROM conversations WHERE id = '00000000-0000-4000-8000-000000000003'"
        )

        let rows = try await connection.query(
            """
            SELECT conversation_id, project_id, environment_id, phase
            FROM conversation_deletions
            WHERE operation_id = '00000000-0000-4000-8000-000000000004'
            """
        )
        #expect(rows.count == 1)
        #expect(text(in: rows[0], at: 0) == "00000000-0000-4000-8000-000000000003")
        #expect(text(in: rows[0], at: 1) == "00000000-0000-4000-8000-000000000001")
        #expect(text(in: rows[0], at: 2) == "00000000-0000-4000-8000-000000000002")
        #expect(text(in: rows[0], at: 3) == "terminatingSessions")
    }
}

@Test func workspaceMigrationUpgradesV1DataToV2AndCreatesExactClientStateSchema() async throws {
    try await withMigrationDatabase { databaseURL in
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try await connection.applyMigrations([WorkspaceMigrations.all[0]])
        try await connection.withImmediateTransaction { connection in
            try connection.execute(
                """
                INSERT INTO projects (
                    id, display_name, root_bookmark, canonical_root_identity,
                    base_environment_id, created_at
                ) VALUES ('project-v1', 'Persisted', X'01', 'root-v1', 'environment-v1', 1)
                """
            )
            try connection.execute(
                """
                INSERT INTO environments (
                    id, project_id, kind, workspace_root, workspace_root_identity,
                    git_common_directory, worktree_branch
                ) VALUES ('environment-v1', 'project-v1', 'direct', '/tmp/project', 'root-v1', NULL, NULL)
                """
            )
        }

        try await connection.applyMigrations(WorkspaceMigrations.all)

        #expect(try await connection.textValue(for: "SELECT display_name FROM projects") == "Persisted")
        #expect(try await connection.query("SELECT version FROM schema_migrations ORDER BY version").compactMap { integer(in: $0, at: 0) } == [1, 2, 3])
        let tableInfo = try await connection.query("PRAGMA table_info(client_workspace_states)")
        #expect(tableInfo.compactMap { text(in: $0, at: 1) } == [
            "device_id", "window_id", "context_kind", "context_id", "state_json",
        ])
        #expect(tableInfo.compactMap { integer(in: $0, at: 5) } == [1, 2, 3, 4, 0])
        await #expect(throws: (any Error).self) {
            try await connection.execute(
                """
                INSERT INTO client_workspace_states (
                    device_id, window_id, context_kind, context_id, state_json
                ) VALUES ('device', 'window', 'environment', 'context', '{}')
                """
            )
        }
    }
}

@Test func failedV2MigrationLeavesV1DataWithoutV2TableOrVersion() async throws {
    try await withMigrationDatabase { databaseURL in
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try await connection.applyMigrations([WorkspaceMigrations.all[0]])
        let brokenV2 = SQLiteMigration(
            version: 2,
            statements: [
                "CREATE TABLE client_workspace_states (id TEXT PRIMARY KEY)",
                "THIS IS NOT SQL",
            ]
        )

        await #expect(throws: (any Error).self) {
            try await connection.applyMigrations([brokenV2])
        }

        #expect(try await connection.tableNames().contains("client_workspace_states") == false)
        #expect(try await connection.query("SELECT version FROM schema_migrations ORDER BY version").compactMap { integer(in: $0, at: 0) } == [1])
        #expect(try await connection.tableNames().contains("projects"))
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

@Test func documentsMigrationUsesEnvironmentLocatorAndApprovedPersistentState() async throws {
    try await withMigrationDatabase { databaseURL in
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try await connection.applyMigrations(WorkspaceMigrations.all)

        let tableInfo = try await connection.query("PRAGMA table_info(documents)")
        #expect(tableInfo.compactMap { text(in: $0, at: 1) } == [
            "id",
            "environment_id",
            "relative_path",
            "document_version",
            "persisted_version",
            "dirty_state",
            "edit_lease_id",
        ])
        #expect(integer(in: tableInfo[6], at: 3) == 0)

        let foreignKeys = try await connection.query("PRAGMA foreign_key_list(documents)")
        #expect(foreignKeys.count == 1)
        #expect(text(in: foreignKeys[0], at: 2) == "environments")
        #expect(text(in: foreignKeys[0], at: 3) == "environment_id")
        #expect(text(in: foreignKeys[0], at: 4) == "id")

        let indexes = try await connection.query("PRAGMA index_list(documents)")
        let uniqueIndexName = indexes.first { integer(in: $0, at: 2) == 1 }
            .flatMap { text(in: $0, at: 1) }
        let indexName = try #require(uniqueIndexName)
        let indexedColumns = try await connection.query("PRAGMA index_info('\(indexName)')")
        #expect(indexedColumns.compactMap { text(in: $0, at: 2) } == [
            "environment_id",
            "relative_path",
        ])

        await #expect(throws: (any Error).self) {
            try await insertDocument(
                connection,
                id: "foreign-key-document",
                environmentID: "missing-environment",
                relativePath: "Sources/App.swift",
                documentVersion: 0,
                persistedVersion: 0,
                dirtyState: "clean"
            )
        }
    }
}

@Test func environmentsMigrationAllowsMissingGitCommonDirectory() async throws {
    try await withMigrationDatabase { databaseURL in
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try await connection.applyMigrations(WorkspaceMigrations.all)

        let tableInfo = try await connection.query("PRAGMA table_info(environments)")
        let gitCommonDirectoryColumn = try #require(
            tableInfo.first { text(in: $0, at: 1) == "git_common_directory" }
        )
        #expect(integer(in: gitCommonDirectoryColumn, at: 3) == 0)
        #expect(await connection.close() == SQLITE_OK)
    }
}

@Test func documentsMigrationEnforcesLocatorDirtyStateAndNonnegativeVersions() async throws {
    try await withMigrationDatabase { databaseURL in
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try await connection.applyMigrations(WorkspaceMigrations.all)
        try await connection.execute("PRAGMA foreign_keys=OFF")

        try await insertDocument(
            connection,
            id: "document-1",
            environmentID: "environment-1",
            relativePath: "Sources/App.swift",
            documentVersion: 3,
            persistedVersion: 2,
            dirtyState: "dirty"
        )
        try await insertDocument(
            connection,
            id: "clean-document",
            environmentID: "environment-1",
            relativePath: "Sources/Clean.swift",
            documentVersion: 0,
            persistedVersion: 0,
            dirtyState: "clean"
        )
        try await insertDocument(
            connection,
            id: "conflict-document",
            environmentID: "environment-1",
            relativePath: "Sources/Conflict.swift",
            documentVersion: 1,
            persistedVersion: 1,
            dirtyState: "conflict"
        )
        try await insertDocument(
            connection,
            id: "missing-document",
            environmentID: "environment-1",
            relativePath: "Sources/Missing.swift",
            documentVersion: 2,
            persistedVersion: 2,
            dirtyState: "missing"
        )
        await #expect(throws: (any Error).self) {
            try await insertDocument(
                connection,
                id: "document-2",
                environmentID: "environment-1",
                relativePath: "Sources/App.swift",
                documentVersion: 3,
                persistedVersion: 2,
                dirtyState: "dirty"
            )
        }
        await #expect(throws: (any Error).self) {
            try await insertDocument(
                connection,
                id: "document-3",
                environmentID: "environment-1",
                relativePath: "Sources/Other.swift",
                documentVersion: 0,
                persistedVersion: 0,
                dirtyState: "unknown"
            )
        }
        await #expect(throws: (any Error).self) {
            try await insertDocument(
                connection,
                id: "document-4",
                environmentID: "environment-1",
                relativePath: "Sources/Negative.swift",
                documentVersion: -1,
                persistedVersion: 0,
                dirtyState: "clean"
            )
        }
        await #expect(throws: (any Error).self) {
            try await insertDocument(
                connection,
                id: "document-5",
                environmentID: "environment-1",
                relativePath: "Sources/PersistedNegative.swift",
                documentVersion: 0,
                persistedVersion: -1,
                dirtyState: "clean"
            )
        }
    }
}

private func insertDocument(
    _ connection: SQLiteConnection,
    id: String,
    environmentID: String,
    relativePath: String,
    documentVersion: Int64,
    persistedVersion: Int64,
    dirtyState: String
) async throws {
    try await connection.execute(
        """
        INSERT INTO documents (
            id, environment_id, relative_path, document_version,
            persisted_version, dirty_state, edit_lease_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
            .text(id),
            .text(environmentID),
            .text(relativePath),
            .integer(documentVersion),
            .integer(persistedVersion),
            .text(dirtyState),
            .null,
        ]
    )
}

private func text(in row: [SQLiteColumn], at index: Int) -> String? {
    guard row.indices.contains(index), case let .text(value) = row[index] else { return nil }
    return value
}

private func integer(in row: [SQLiteColumn], at index: Int) -> Int64? {
    guard row.indices.contains(index), case let .integer(value) = row[index] else { return nil }
    return value
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

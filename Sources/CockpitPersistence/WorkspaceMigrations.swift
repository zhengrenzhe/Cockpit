enum WorkspaceMigrations {
    static let all = [version1, version2, version3]

    private static let version1 = SQLiteMigration(
        version: 1,
        statements: [
            """
            CREATE TABLE schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE projects (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                root_bookmark BLOB NOT NULL,
                canonical_root_identity TEXT NOT NULL UNIQUE,
                base_environment_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE (id, base_environment_id),
                FOREIGN KEY (id, base_environment_id)
                    REFERENCES environments (project_id, id)
                    DEFERRABLE INITIALLY DEFERRED
            )
            """,
            """
            CREATE TABLE environments (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('direct', 'worktree')),
                workspace_root TEXT NOT NULL,
                workspace_root_identity TEXT NOT NULL UNIQUE,
                git_common_directory TEXT,
                worktree_branch TEXT,
                UNIQUE (project_id, id),
                FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE
            )
            """,
            """
            CREATE TABLE conversations (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                environment_id TEXT NOT NULL,
                title TEXT NOT NULL,
                lifecycle_state TEXT NOT NULL CHECK (lifecycle_state IN ('active', 'deleting')),
                deletion_phase TEXT,
                deletion_operation_id TEXT,
                created_at REAL NOT NULL,
                CHECK (
                    (lifecycle_state = 'active' AND deletion_phase IS NULL AND deletion_operation_id IS NULL)
                    OR
                    (lifecycle_state = 'deleting' AND deletion_phase IS NOT NULL AND deletion_operation_id IS NOT NULL)
                ),
                FOREIGN KEY (project_id, environment_id)
                    REFERENCES projects (id, base_environment_id),
                UNIQUE (deletion_operation_id)
            )
            """,
            """
            CREATE TABLE documents (
                id TEXT PRIMARY KEY,
                environment_id TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                document_version INTEGER NOT NULL CHECK (document_version >= 0),
                persisted_version INTEGER NOT NULL CHECK (persisted_version >= 0),
                dirty_state TEXT NOT NULL CHECK (dirty_state IN ('clean', 'dirty', 'conflict', 'missing')),
                edit_lease_id TEXT,
                UNIQUE (environment_id, relative_path),
                FOREIGN KEY (environment_id) REFERENCES environments (id)
            )
            """,
            """
            CREATE TABLE conversation_deletions (
                operation_id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL UNIQUE,
                phase TEXT NOT NULL,
                FOREIGN KEY (conversation_id) REFERENCES conversations (id) ON DELETE CASCADE
            )
            """,
        ]
    )

    private static let version2 = SQLiteMigration(
        version: 2,
        statements: [
            """
            CREATE TABLE client_workspace_states (
                device_id TEXT NOT NULL,
                window_id TEXT NOT NULL,
                context_kind TEXT NOT NULL CHECK (context_kind IN ('project', 'conversation')),
                context_id TEXT NOT NULL,
                state_json TEXT NOT NULL,
                PRIMARY KEY (device_id, window_id, context_kind, context_id)
            )
            """,
        ]
    )

    private static let version3 = SQLiteMigration(
        version: 3,
        statements: [
            """
            CREATE TABLE conversation_deletions_v3 (
                operation_id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL UNIQUE,
                project_id TEXT NOT NULL,
                environment_id TEXT NOT NULL,
                phase TEXT NOT NULL CHECK (
                    phase IN (
                        'deleting', 'terminatingSessions', 'purgingTerminalRecords',
                        'removingClientState', 'deleted'
                    )
                )
            )
            """,
            """
            INSERT INTO conversation_deletions_v3 (
                operation_id, conversation_id, project_id, environment_id, phase
            )
            SELECT d.operation_id, d.conversation_id, c.project_id, c.environment_id, d.phase
            FROM conversation_deletions AS d
            JOIN conversations AS c ON c.id = d.conversation_id
            """,
            "DROP TABLE conversation_deletions",
            "ALTER TABLE conversation_deletions_v3 RENAME TO conversation_deletions",
        ]
    )
}

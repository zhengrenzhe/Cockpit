enum WorkspaceMigrations {
    static let all = [version1]

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
                git_common_directory TEXT NOT NULL,
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
}

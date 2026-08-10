import Foundation

enum TerminalMigrations {
    static let all = [version1]

    private static let version1 = SQLiteMigration(
        version: 1,
        statements: [
            """
            CREATE TABLE terminal_schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE terminal_sessions (
                session_id TEXT PRIMARY KEY,
                context_kind TEXT NOT NULL CHECK (context_kind IN ('project', 'conversation')),
                context_id TEXT NOT NULL,
                environment_id TEXT NOT NULL,
                protocol_major INTEGER NOT NULL CHECK (protocol_major > 0 AND protocol_major <= 65535),
                protocol_minor INTEGER NOT NULL CHECK (protocol_minor >= 0 AND protocol_minor <= 65535),
                launch_spec BLOB NOT NULL CHECK (length(launch_spec) > 0),
                worker_id TEXT,
                lifecycle_state TEXT NOT NULL CHECK (
                    lifecycle_state IN ('preparing', 'committed', 'running', 'exited', 'terminated', 'interrupted')
                ),
                start_nonce BLOB NOT NULL CHECK (length(start_nonce) = 16),
                process_id INTEGER,
                process_group_id INTEGER,
                exit_status INTEGER,
                latest_sequence BLOB NOT NULL CHECK (length(latest_sequence) = 8),
                archive_manifest TEXT,
                CHECK (
                    (process_id IS NULL AND process_group_id IS NULL)
                    OR (
                        process_id IS NOT NULL
                        AND process_group_id IS NOT NULL
                        AND process_id > 0
                        AND process_group_id > 0
                        AND process_id = process_group_id
                    )
                )
            )
            """,
            """
            CREATE TABLE terminal_idempotency (
                request_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL UNIQUE,
                FOREIGN KEY (session_id) REFERENCES terminal_sessions (session_id) ON DELETE CASCADE
            )
            """,
            """
            CREATE TABLE agent_executables (
                profile_id TEXT PRIMARY KEY CHECK (profile_id IN ('codex', 'claude')),
                canonical_path TEXT NOT NULL CHECK (
                    length(canonical_path) > 1
                    AND substr(canonical_path, 1, 1) = '/'
                    AND instr(canonical_path, '//') = 0
                    AND instr(canonical_path, '/../') = 0
                    AND instr(canonical_path, '/./') = 0
                    AND canonical_path NOT LIKE '%/..'
                    AND canonical_path NOT LIKE '%/.'
                )
            )
            """,
            "CREATE INDEX terminal_sessions_context_idx ON terminal_sessions (context_kind, context_id, session_id)",
            "CREATE INDEX terminal_sessions_lifecycle_idx ON terminal_sessions (lifecycle_state, session_id)",
        ]
    )
}

extension SQLiteConnection {
    func applyTerminalMigrations(_ migrations: [SQLiteMigration]) throws {
        let hasMigrationTable = try query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'terminal_schema_migrations' LIMIT 1"
        ).isEmpty == false
        var appliedVersions: Set<Int64> = []
        if hasMigrationTable {
            appliedVersions = Set(
                try query("SELECT version FROM terminal_schema_migrations").compactMap { row in
                    guard let first = row.first, case let .integer(version) = first else { return nil }
                    return version
                }
            )
        }

        for migration in migrations.sorted(by: { $0.version < $1.version })
        where !appliedVersions.contains(migration.version) {
            try withImmediateTransaction { connection in
                for statement in migration.statements {
                    try connection.execute(statement)
                }
                try connection.execute(
                    "INSERT INTO terminal_schema_migrations (version, applied_at) VALUES (?, ?)",
                    bindings: [.integer(migration.version), .real(Date().timeIntervalSince1970)]
                )
            }
        }
    }
}

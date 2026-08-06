import Foundation
import SQLite3

struct SQLiteFailure: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite error \(code): \(message)" }
}

enum SQLiteValue: Sendable {
    case text(String)
    case blob(Data)
    case real(Double)
    case integer(Int64)
    case null
}

enum SQLiteColumn: Sendable {
    case text(String)
    case blob(Data)
    case real(Double)
    case integer(Int64)
    case null
}

actor SQLiteConnection {
    private let handle: SQLiteDatabaseHandle
    private var database: OpaquePointer { handle.pointer! }

    init(databaseURL: URL) throws {
        var openedDatabase: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let openedDatabase { sqlite3_close(openedDatabase) }
            throw SQLiteFailure(code: result, message: message)
        }
        do {
            try Self.execute("PRAGMA journal_mode=WAL", on: openedDatabase)
            try Self.execute("PRAGMA foreign_keys=ON", on: openedDatabase)
            try Self.execute("PRAGMA busy_timeout=5000", on: openedDatabase)
        } catch {
            sqlite3_close(openedDatabase)
            throw error
        }
        handle = SQLiteDatabaseHandle(openedDatabase)
    }

    func close() -> Int32 {
        handle.close()
    }

    func textValue(for sql: String) throws -> String? {
        guard let first = try query(sql).first?.first else { return nil }
        if case let .text(value) = first { return value }
        return nil
    }

    func integerValue(for sql: String) throws -> Int64? {
        guard let first = try query(sql).first?.first else { return nil }
        if case let .integer(value) = first { return value }
        return nil
    }

    func tableNames() throws -> [String] {
        try query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).compactMap { row in
            guard let first = row.first, case let .text(name) = first else { return nil }
            return name
        }
    }

    func applyMigrations(_ migrations: [SQLiteMigration]) throws {
        let hasMigrationTable = try query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations' LIMIT 1"
        ).isEmpty == false
        var appliedVersions: Set<Int64> = []
        if hasMigrationTable {
            appliedVersions = Set(try query("SELECT version FROM schema_migrations").compactMap { row in
                guard let first = row.first, case let .integer(version) = first else { return nil }
                return version
            })
        }

        for migration in migrations.sorted(by: { $0.version < $1.version })
        where !appliedVersions.contains(migration.version) {
            try withImmediateTransaction { connection in
                for statement in migration.statements {
                    try connection.execute(statement)
                }
                try connection.execute(
                    "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                    bindings: [.integer(migration.version), .real(Date().timeIntervalSince1970)]
                )
            }
        }
    }

    func withImmediateTransaction<T: Sendable>(
        _ body: @Sendable (isolated SQLiteConnection) throws -> T
    ) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body(self)
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw failure(code: result) }
    }

    func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[SQLiteColumn]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [[SQLiteColumn]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure(code: result) }
            rows.append((0..<sqlite3_column_count(statement)).map { index in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    .text(String(
                        decoding: UnsafeBufferPointer(
                            start: sqlite3_column_text(statement, index),
                            count: Int(sqlite3_column_bytes(statement, index))
                        ),
                        as: UTF8.self
                    ))
                case SQLITE_BLOB:
                    .blob(Data(
                        bytes: sqlite3_column_blob(statement, index),
                        count: Int(sqlite3_column_bytes(statement, index))
                    ))
                default: .null
                }
            })
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw failure(code: result) }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        guard sqlite3_bind_parameter_count(statement) == values.count else {
            throw SQLiteFailure(code: SQLITE_MISUSE, message: "Binding count mismatch")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text):
                let utf8 = text.utf8CString
                let byteCount = utf8.count - 1
                guard byteCount <= Int(Int32.max) else {
                    throw SQLiteFailure(code: SQLITE_TOOBIG, message: "UTF-8 value exceeds SQLite limit")
                }
                result = utf8.withUnsafeBufferPointer { buffer in
                    sqlite3_bind_text(
                        statement,
                        index,
                        buffer.baseAddress,
                        Int32(byteCount),
                        transient
                    )
                }
            case let .blob(data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
                }
            case let .real(real): result = sqlite3_bind_double(statement, index, real)
            case let .integer(integer): result = sqlite3_bind_int64(statement, index, integer)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw failure(code: result) }
        }
    }

    private func failure(code: Int32) -> SQLiteFailure {
        SQLiteFailure(code: code, message: String(cString: sqlite3_errmsg(database)))
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteFailure(code: result, message: String(cString: sqlite3_errmsg(database)))
        }
    }
}

private final class SQLiteDatabaseHandle: @unchecked Sendable {
    private(set) var pointer: OpaquePointer?

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    func close() -> Int32 {
        guard let pointer else { return SQLITE_OK }
        let result = sqlite3_close(pointer)
        if result == SQLITE_OK {
            self.pointer = nil
        }
        return result
    }

    deinit {
        if let pointer {
            sqlite3_close(pointer)
        }
    }
}

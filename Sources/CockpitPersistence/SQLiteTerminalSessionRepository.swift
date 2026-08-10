import Foundation
import SQLite3
import CockpitTerminalCore
import CockpitTypes

public actor SQLiteTerminalSessionRepository: TerminalSessionRepository, AgentExecutableRepository {
    private static let recordColumns = """
        session_id, context_kind, context_id, environment_id,
        protocol_major, protocol_minor, launch_spec, worker_id,
        lifecycle_state, start_nonce, process_id, process_group_id,
        exit_status, latest_sequence, archive_manifest
        """

    private let connection: SQLiteConnection

    public init(databaseURL: URL) async throws {
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        do {
            try await connection.applyTerminalMigrations(TerminalMigrations.all)
        } catch {
            _ = await connection.close()
            throw error
        }
        self.connection = connection
    }

    func close() async -> Int32 {
        await connection.close()
    }

    @discardableResult
    public func insertPreparing(
        _ record: TerminalSessionRecord,
        idempotencyKey: RequestID
    ) async throws -> TerminalSessionRecord {
        guard record.lifecycleState == .preparing,
              record.workerID == nil,
              record.processIdentity == nil,
              record.exitStatus == nil,
              record.latestSequence == 0,
              record.archiveManifest == nil
        else {
            throw TerminalSessionRepositoryError.recordMustBePreparing
        }
        let context = Self.contextParts(record.contextID)
        return try await connection.withImmediateTransaction { connection in
            let existing = try connection.query(
                """
                SELECT \(Self.recordColumns)
                FROM terminal_sessions
                WHERE session_id = (
                    SELECT session_id FROM terminal_idempotency WHERE request_id = ?
                )
                """,
                bindings: [.text(idempotencyKey.description)]
            )
            if let row = existing.first {
                guard existing.count == 1 else {
                    throw TerminalSessionRepositoryError.corruptRecord
                }
                return try Self.decodeRecord(row)
            }

            try connection.execute(
                """
                INSERT INTO terminal_sessions (
                    session_id, context_kind, context_id, environment_id,
                    protocol_major, protocol_minor, launch_spec, worker_id,
                    lifecycle_state, start_nonce, process_id, process_group_id,
                    exit_status, latest_sequence, archive_manifest
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(record.sessionID.description),
                    .text(context.kind),
                    .text(context.id),
                    .text(record.environmentID.description),
                    .integer(Int64(record.protocolVersion.major)),
                    .integer(Int64(record.protocolVersion.minor)),
                    .blob(record.launchSpecData),
                    .null,
                    .text(TerminalLifecycleState.preparing.rawValue),
                    .blob(record.startNonce),
                    .null,
                    .null,
                    .null,
                    .blob(Self.encodeSequence(0)),
                    .null,
                ]
            )
            try connection.execute(
                "INSERT INTO terminal_idempotency (request_id, session_id) VALUES (?, ?)",
                bindings: [.text(idempotencyKey.description), .text(record.sessionID.description)]
            )
            return record
        }
    }

    public func markCommitted(
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID
    ) async throws {
        try await connection.withImmediateTransaction { connection in
            let row = try Self.requireStateRow(connection: connection, sessionID: sessionID)
            let current = try Self.lifecycle(row[0])
            let currentWorker = try Self.optionalID(row[1], as: WorkerInstanceID.self)
            switch current {
            case .preparing:
                try connection.execute(
                    "UPDATE terminal_sessions SET lifecycle_state = ?, worker_id = ? WHERE session_id = ?",
                    bindings: [
                        .text(TerminalLifecycleState.committed.rawValue),
                        .text(workerID.description),
                        .text(sessionID.description),
                    ]
                )
            case .committed where currentWorker == workerID:
                return
            case .committed:
                throw TerminalSessionRepositoryError.workerMismatch
            default:
                throw TerminalSessionRepositoryError.invalidTransition(
                    current: current,
                    requested: .committed
                )
            }
        }
    }

    public func markRunning(
        sessionID: TerminalSessionID,
        identity: CLIProcessIdentity
    ) async throws {
        try await connection.withImmediateTransaction { connection in
            let rows = try connection.query(
                "SELECT lifecycle_state, process_id, process_group_id FROM terminal_sessions WHERE session_id = ?",
                bindings: [.text(sessionID.description)]
            )
            guard let row = rows.first, row.count == 3 else {
                throw TerminalSessionRepositoryError.recordNotFound
            }
            let current = try Self.lifecycle(row[0])
            switch current {
            case .committed:
                try connection.execute(
                    """
                    UPDATE terminal_sessions
                    SET lifecycle_state = ?, process_id = ?, process_group_id = ?
                    WHERE session_id = ?
                    """,
                    bindings: [
                        .text(TerminalLifecycleState.running.rawValue),
                        .integer(Int64(identity.processID)),
                        .integer(Int64(identity.processGroupID)),
                        .text(sessionID.description),
                    ]
                )
            case .running:
                let existing = try Self.processIdentity(process: row[1], group: row[2])
                guard existing == identity else {
                    throw TerminalSessionRepositoryError.processIdentityMismatch
                }
            default:
                throw TerminalSessionRepositoryError.invalidTransition(
                    current: current,
                    requested: .running
                )
            }
        }
    }

    public func finish(
        sessionID: TerminalSessionID,
        state: TerminalLifecycleState,
        exitStatus: Int32?,
        latestSequence: UInt64,
        archiveManifest: RelativeArchivePath?
    ) async throws {
        guard Self.finalStates.contains(state) else {
            throw TerminalSessionRepositoryError.invalidFinalState
        }
        try await connection.withImmediateTransaction { connection in
            let rows = try connection.query(
                "SELECT lifecycle_state, latest_sequence FROM terminal_sessions WHERE session_id = ?",
                bindings: [.text(sessionID.description)]
            )
            guard let row = rows.first, row.count == 2 else {
                throw TerminalSessionRepositoryError.recordNotFound
            }
            let current = try Self.lifecycle(row[0])
            let currentSequence = try Self.sequence(row[1])
            guard latestSequence >= currentSequence else {
                throw TerminalSessionRepositoryError.sequenceRegression
            }
            let allowed = switch current {
            case .preparing, .committed: state == .interrupted
            case .running: true
            case state: true
            default: false
            }
            guard allowed else {
                throw TerminalSessionRepositoryError.invalidTransition(
                    current: current,
                    requested: state
                )
            }
            try connection.execute(
                """
                UPDATE terminal_sessions
                SET lifecycle_state = ?, exit_status = ?, latest_sequence = ?, archive_manifest = ?
                WHERE session_id = ?
                """,
                bindings: [
                    .text(state.rawValue),
                    exitStatus.map { .integer(Int64($0)) } ?? .null,
                    .blob(Self.encodeSequence(latestSequence)),
                    archiveManifest.map { .text($0.rawValue) } ?? .null,
                    .text(sessionID.description),
                ]
            )
        }
    }

    public func activeRecords() async throws -> [TerminalSessionRecord] {
        let rows = try await connection.query(
            """
            SELECT \(Self.recordColumns)
            FROM terminal_sessions
            WHERE lifecycle_state IN ('preparing', 'committed', 'running')
            ORDER BY session_id
            """
        )
        return try rows.map(Self.decodeRecord)
    }

    public func records(contextID: WorkspaceContextID) async throws -> [TerminalSessionRecord] {
        let context = Self.contextParts(contextID)
        let rows = try await connection.query(
            """
            SELECT \(Self.recordColumns)
            FROM terminal_sessions
            WHERE context_kind = ? AND context_id = ?
            ORDER BY session_id
            """,
            bindings: [.text(context.kind), .text(context.id)]
        )
        return try rows.map(Self.decodeRecord)
    }

    public func storeCanonicalExecutable(
        _ path: String,
        for profileID: AgentProfileID
    ) async throws {
        guard Self.isCanonicalAbsolutePath(path) else {
            throw TerminalSessionRepositoryError.invalidCanonicalExecutablePath
        }
        try await connection.execute(
            """
            INSERT INTO agent_executables (profile_id, canonical_path)
            VALUES (?, ?)
            ON CONFLICT(profile_id) DO UPDATE SET canonical_path = excluded.canonical_path
            """,
            bindings: [.text(profileID.rawValue), .text(path)]
        )
    }

    public func canonicalExecutable(for profileID: AgentProfileID) async throws -> String? {
        let rows = try await connection.query(
            "SELECT canonical_path FROM agent_executables WHERE profile_id = ?",
            bindings: [.text(profileID.rawValue)]
        )
        guard rows.count <= 1 else {
            throw TerminalSessionRepositoryError.corruptRecord
        }
        guard let row = rows.first else { return nil }
        guard row.count == 1,
              let path = Self.text(row[0]),
              Self.isCanonicalAbsolutePath(path)
        else {
            throw TerminalSessionRepositoryError.corruptRecord
        }
        return path
    }

    private static let finalStates: Set<TerminalLifecycleState> = [
        .exited, .terminated, .interrupted,
    ]

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private static func requireStateRow(
        connection: isolated SQLiteConnection,
        sessionID: TerminalSessionID
    ) throws -> [SQLiteColumn] {
        let rows = try connection.query(
            "SELECT lifecycle_state, worker_id FROM terminal_sessions WHERE session_id = ?",
            bindings: [.text(sessionID.description)]
        )
        guard let row = rows.first, row.count == 2 else {
            throw TerminalSessionRepositoryError.recordNotFound
        }
        return row
    }

    private static func contextParts(_ contextID: WorkspaceContextID) -> (kind: String, id: String) {
        switch contextID {
        case let .project(id): ("project", id.description)
        case let .conversation(id): ("conversation", id.description)
        }
    }

    private static func decodeRecord(_ row: [SQLiteColumn]) throws -> TerminalSessionRecord {
        guard row.count == 15,
              let sessionID = try id(row[0], as: TerminalSessionID.self),
              let contextKind = text(row[1]),
              let contextUUID = uuid(row[2]),
              let environmentID = try id(row[3], as: EnvironmentID.self),
              let protocolMajor = integer(row[4]).flatMap(UInt16.init(exactly:)),
              let protocolMinor = integer(row[5]).flatMap(UInt16.init(exactly:)),
              let launchSpec = blob(row[6]),
              let stateText = text(row[8]),
              let lifecycleState = TerminalLifecycleState(rawValue: stateText),
              let startNonce = blob(row[9]),
              let latestSequence = try? sequence(row[13])
        else {
            throw TerminalSessionRepositoryError.corruptRecord
        }
        let contextID: WorkspaceContextID
        switch contextKind {
        case "project": contextID = .project(ProjectID(contextUUID))
        case "conversation": contextID = .conversation(ConversationID(contextUUID))
        default: throw TerminalSessionRepositoryError.corruptRecord
        }
        let processIdentity = try processIdentity(process: row[10], group: row[11])
        let exitStatus: Int32?
        if case .null = row[12] {
            exitStatus = nil
        } else {
            guard let value = integer(row[12]).flatMap(Int32.init(exactly:)) else {
                throw TerminalSessionRepositoryError.corruptRecord
            }
            exitStatus = value
        }
        let archiveManifest: RelativeArchivePath?
        if case .null = row[14] {
            archiveManifest = nil
        } else {
            guard let value = text(row[14]), let path = RelativeArchivePath(rawValue: value) else {
                throw TerminalSessionRepositoryError.corruptRecord
            }
            archiveManifest = path
        }
        return try TerminalSessionRecord(
            validatingSessionID: sessionID,
            contextID: contextID,
            environmentID: environmentID,
            protocolVersion: ProtocolVersion(major: protocolMajor, minor: protocolMinor),
            launchSpecData: launchSpec,
            lifecycleState: lifecycleState,
            startNonce: startNonce,
            workerID: try optionalID(row[7], as: WorkerInstanceID.self),
            processIdentity: processIdentity,
            exitStatus: exitStatus,
            latestSequence: latestSequence,
            archiveManifest: archiveManifest
        )
    }

    private static func lifecycle(_ column: SQLiteColumn) throws -> TerminalLifecycleState {
        guard let value = text(column), let state = TerminalLifecycleState(rawValue: value) else {
            throw TerminalSessionRepositoryError.corruptRecord
        }
        return state
    }

    private static func processIdentity(
        process: SQLiteColumn,
        group: SQLiteColumn
    ) throws -> CLIProcessIdentity? {
        if case .null = process, case .null = group { return nil }
        guard let processID = integer(process).flatMap(Int32.init(exactly:)),
              let processGroupID = integer(group).flatMap(Int32.init(exactly:))
        else {
            throw TerminalSessionRepositoryError.corruptRecord
        }
        return try CLIProcessIdentity(
            validatingProcessID: processID,
            processGroupID: processGroupID
        )
    }

    private static func optionalID<Scope>(
        _ column: SQLiteColumn,
        as _: CockpitID<Scope>.Type
    ) throws -> CockpitID<Scope>? {
        if case .null = column { return nil }
        return try id(column, as: CockpitID<Scope>.self)
    }

    private static func id<Scope>(
        _ column: SQLiteColumn,
        as _: CockpitID<Scope>.Type
    ) throws -> CockpitID<Scope>? {
        guard let value = text(column), let value = UUID(uuidString: value) else {
            throw TerminalSessionRepositoryError.corruptRecord
        }
        return CockpitID<Scope>(value)
    }

    private static func uuid(_ column: SQLiteColumn) -> UUID? {
        text(column).flatMap(UUID.init(uuidString:))
    }

    private static func text(_ column: SQLiteColumn) -> String? {
        guard case let .text(value) = column else { return nil }
        return value
    }

    private static func blob(_ column: SQLiteColumn) -> Data? {
        guard case let .blob(value) = column else { return nil }
        return value
    }

    private static func integer(_ column: SQLiteColumn) -> Int64? {
        guard case let .integer(value) = column else { return nil }
        return value
    }

    private static func encodeSequence(_ value: UInt64) -> Data {
        Data((0..<8).map { offset in
            UInt8(truncatingIfNeeded: value >> UInt64((7 - offset) * 8))
        })
    }

    private static func sequence(_ column: SQLiteColumn) throws -> UInt64 {
        guard let data = blob(column), data.count == 8 else {
            throw TerminalSessionRepositoryError.corruptRecord
        }
        return data.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

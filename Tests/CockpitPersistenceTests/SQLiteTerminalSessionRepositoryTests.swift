import Foundation
import SQLite3
import Testing
import CockpitTerminalCore
import CockpitTypes
@testable import CockpitPersistence

@Suite("SQLiteTerminalSessionRepositoryTests")
struct SQLiteTerminalSessionRepositoryTests {
    @Test func migrationCreatesOnlyTheFrozenTerminalTables() async throws {
        try await withTerminalDatabase { databaseURL in
            let repository = try await SQLiteTerminalSessionRepository(databaseURL: databaseURL)
            let inspection = try SQLiteConnection(databaseURL: databaseURL)

            #expect(try await inspection.tableNames() == [
                "agent_executables",
                "terminal_idempotency",
                "terminal_schema_migrations",
                "terminal_sessions",
            ])
            #expect(
                try await inspection.integerValue(
                    for: "SELECT version FROM terminal_schema_migrations"
                ) == 1
            )

            #expect(await inspection.close() == SQLITE_OK)
            #expect(await repository.close() == SQLITE_OK)
        }
    }

    @Test func legalLifecyclePersistsAndIllegalRollbackFailsClosed() async throws {
        try await withTerminalDatabase { databaseURL in
            let repository = try await SQLiteTerminalSessionRepository(databaseURL: databaseURL)
            let preparing = try makePreparingRecord(
                sessionID: fixedSession(0x11),
                contextID: .project(ProjectID(fixedUUID(0x21))),
                nonceByte: 0x31
            )
            let workerID = WorkerInstanceID(fixedUUID(0x41))
            let identity = try CLIProcessIdentity(validatingProcessID: 101, processGroupID: 101)

            try await repository.insertPreparing(
                preparing,
                idempotencyKey: RequestID(fixedUUID(0x51))
            )
            #expect(try await repository.activeRecords() == [preparing])

            try await repository.markCommitted(sessionID: preparing.sessionID, workerID: workerID)
            var record = try #require(try await repository.activeRecords().first)
            #expect(record.lifecycleState == .committed)
            #expect(record.workerID == workerID)

            try await repository.markRunning(sessionID: preparing.sessionID, identity: identity)
            record = try #require(try await repository.activeRecords().first)
            #expect(record.lifecycleState == .running)
            #expect(record.processIdentity == identity)

            await #expect(
                throws: TerminalSessionRepositoryError.invalidTransition(
                    current: .running,
                    requested: .committed
                )
            ) {
                try await repository.markCommitted(
                    sessionID: preparing.sessionID,
                    workerID: workerID
                )
            }

            let archive = try RelativeArchivePath(validating: "sessions/11/manifest.json")
            try await repository.finish(
                sessionID: preparing.sessionID,
                state: .exited,
                exitStatus: 0,
                latestSequence: UInt64.max,
                archiveManifest: archive
            )
            #expect(try await repository.activeRecords().isEmpty)

            let finished = try #require(
                try await repository.records(contextID: preparing.contextID).first
            )
            #expect(finished.lifecycleState == .exited)
            #expect(finished.exitStatus == 0)
            #expect(finished.latestSequence == UInt64.max)
            #expect(finished.archiveManifest == archive)

            await #expect(
                throws: TerminalSessionRepositoryError.invalidTransition(
                    current: .exited,
                    requested: .running
                )
            ) {
                try await repository.markRunning(
                    sessionID: preparing.sessionID,
                    identity: identity
                )
            }
            #expect(await repository.close() == SQLITE_OK)
        }
    }

    @Test func idempotencyKeepsOriginalSessionAndNonceAcrossReopen() async throws {
        try await withTerminalDatabase { databaseURL in
            let requestID = RequestID(fixedUUID(0x61))
            let contextID = WorkspaceContextID.conversation(ConversationID(fixedUUID(0x71)))
            let original = try makePreparingRecord(
                sessionID: fixedSession(0x81),
                contextID: contextID,
                nonceByte: 0x91
            )
            let conflictingRetry = try makePreparingRecord(
                sessionID: fixedSession(0x82),
                contextID: contextID,
                nonceByte: 0x92
            )
            let unrelated = try makePreparingRecord(
                sessionID: fixedSession(0x83),
                contextID: contextID,
                nonceByte: 0x93
            )

            let first = try await SQLiteTerminalSessionRepository(databaseURL: databaseURL)
            let inserted = try await first.insertPreparing(original, idempotencyKey: requestID)
            _ = try await first.insertPreparing(
                unrelated,
                idempotencyKey: RequestID(fixedUUID(0x62))
            )
            let retried = try await first.insertPreparing(conflictingRetry, idempotencyKey: requestID)
            #expect(inserted == original)
            #expect(retried == original)
            #expect(try await first.activeRecords() == [original, unrelated])
            #expect(await first.close() == SQLITE_OK)

            let reopened = try await SQLiteTerminalSessionRepository(databaseURL: databaseURL)
            let persisted = try await reopened.activeRecords()
            #expect(persisted == [original, unrelated])
            #expect(persisted.first?.startNonce == Data(repeating: 0x91, count: 16))

            let reopenedRetry = try await reopened.insertPreparing(
                conflictingRetry,
                idempotencyKey: requestID
            )
            #expect(reopenedRetry == original)
            #expect(reopenedRetry.sessionID == original.sessionID)
            #expect(reopenedRetry.startNonce == Data(repeating: 0x91, count: 16))
            #expect(try await reopened.activeRecords() == [original, unrelated])
            #expect(await reopened.close() == SQLITE_OK)
        }
    }

    @Test func interruptionTransitionsAreLegalAndTerminalStatesCannotBeReclassified() async throws {
        try await withTerminalDatabase { databaseURL in
            let repository = try await SQLiteTerminalSessionRepository(databaseURL: databaseURL)
            let contextID = WorkspaceContextID.project(ProjectID(fixedUUID(0xA0)))
            let preparing = try makePreparingRecord(
                sessionID: fixedSession(0xA1),
                contextID: contextID,
                nonceByte: 0xB1
            )
            let committed = try makePreparingRecord(
                sessionID: fixedSession(0xA2),
                contextID: contextID,
                nonceByte: 0xB2
            )
            let terminated = try makePreparingRecord(
                sessionID: fixedSession(0xA3),
                contextID: contextID,
                nonceByte: 0xB3
            )
            let workerID = WorkerInstanceID(fixedUUID(0xC1))

            try await repository.insertPreparing(preparing, idempotencyKey: RequestID(fixedUUID(0xD1)))
            try await repository.finish(
                sessionID: preparing.sessionID,
                state: .interrupted,
                exitStatus: nil,
                latestSequence: 0,
                archiveManifest: nil
            )

            try await repository.insertPreparing(committed, idempotencyKey: RequestID(fixedUUID(0xD2)))
            try await repository.markCommitted(sessionID: committed.sessionID, workerID: workerID)
            try await repository.finish(
                sessionID: committed.sessionID,
                state: .interrupted,
                exitStatus: nil,
                latestSequence: 0,
                archiveManifest: nil
            )

            try await repository.insertPreparing(terminated, idempotencyKey: RequestID(fixedUUID(0xD3)))
            try await repository.markCommitted(sessionID: terminated.sessionID, workerID: workerID)
            try await repository.markRunning(
                sessionID: terminated.sessionID,
                identity: try CLIProcessIdentity(validatingProcessID: 303, processGroupID: 303)
            )
            try await repository.finish(
                sessionID: terminated.sessionID,
                state: .terminated,
                exitStatus: 15,
                latestSequence: 9,
                archiveManifest: nil
            )

            await #expect(
                throws: TerminalSessionRepositoryError.invalidTransition(
                    current: .terminated,
                    requested: .exited
                )
            ) {
                try await repository.finish(
                    sessionID: terminated.sessionID,
                    state: .exited,
                    exitStatus: 0,
                    latestSequence: 9,
                    archiveManifest: nil
                )
            }

            let terminalStates = try await repository.records(contextID: contextID)
                .map(\.lifecycleState)
            #expect(terminalStates == [.interrupted, .interrupted, .terminated])
            #expect(await repository.close() == SQLITE_OK)
        }
    }

    @Test func processIdentityRequiresTheCLIToLeadItsOwnProcessGroupAtEveryBoundary() async throws {
        #expect(throws: TerminalSessionRecordError.invalidProcessIdentity) {
            _ = try CLIProcessIdentity(validatingProcessID: 404, processGroupID: 405)
        }
        #expect(throws: TerminalSessionRecordError.invalidProcessIdentity) {
            _ = try JSONDecoder().decode(
                CLIProcessIdentity.self,
                from: Data(#"{"processID":404,"processGroupID":405}"#.utf8)
            )
        }

        try await withTerminalDatabase { databaseURL in
            let repository = try await SQLiteTerminalSessionRepository(databaseURL: databaseURL)
            let record = try makePreparingRecord(
                sessionID: fixedSession(0xE1),
                contextID: .project(ProjectID(fixedUUID(0xE2))),
                nonceByte: 0xE3
            )
            try await repository.insertPreparing(record, idempotencyKey: RequestID(fixedUUID(0xE4)))
            try await repository.markCommitted(
                sessionID: record.sessionID,
                workerID: WorkerInstanceID(fixedUUID(0xE5))
            )
            let inspection = try SQLiteConnection(databaseURL: databaseURL)
            await #expect(throws: (any Error).self) {
                try await inspection.execute(
                    "UPDATE terminal_sessions SET process_id = 404, process_group_id = 405 WHERE session_id = '\(record.sessionID.description)'"
                )
            }
            #expect(await inspection.close() == SQLITE_OK)
            #expect(await repository.close() == SQLITE_OK)
        }
    }

    @Test func agentExecutablePortPersistsOnlyTypedCanonicalAbsolutePaths() async throws {
        try await withTerminalDatabase { databaseURL in
            let first = try await SQLiteTerminalSessionRepository(databaseURL: databaseURL)
            #expect(try await first.canonicalExecutable(for: .codex) == nil)
            #expect(try await first.canonicalExecutable(for: .claude) == nil)

            try await first.storeCanonicalExecutable(
                "/Applications/Codex.app/Contents/MacOS/codex",
                for: .codex
            )
            try await first.storeCanonicalExecutable(
                "/opt/homebrew/bin/codex",
                for: .codex
            )
            await #expect(
                throws: TerminalSessionRepositoryError.invalidCanonicalExecutablePath
            ) {
                try await first.storeCanonicalExecutable("bin/claude", for: .claude)
            }
            #expect(await first.close() == SQLITE_OK)

            let reopened = try await SQLiteTerminalSessionRepository(databaseURL: databaseURL)
            #expect(
                try await reopened.canonicalExecutable(for: .codex)
                    == "/opt/homebrew/bin/codex"
            )
            #expect(try await reopened.canonicalExecutable(for: .claude) == nil)

            let inspection = try SQLiteConnection(databaseURL: databaseURL)
            await #expect(throws: (any Error).self) {
                try await inspection.execute(
                    "INSERT INTO agent_executables (profile_id, canonical_path) VALUES ('other', '/tmp/other')"
                )
            }
            await #expect(throws: (any Error).self) {
                try await inspection.execute(
                    "INSERT INTO agent_executables (profile_id, canonical_path) VALUES ('claude', 'bin/claude')"
                )
            }
            #expect(await inspection.close() == SQLITE_OK)
            #expect(await reopened.close() == SQLITE_OK)
        }
    }
}

private func makePreparingRecord(
    sessionID: TerminalSessionID,
    contextID: WorkspaceContextID,
    nonceByte: UInt8
) throws -> TerminalSessionRecord {
    try TerminalSessionRecord(
        validatingSessionID: sessionID,
        contextID: contextID,
        environmentID: EnvironmentID(fixedUUID(0x01)),
        protocolVersion: .current,
        launchSpecData: Data(#"{"executable":"/bin/zsh","arguments":["-l"]}"#.utf8),
        lifecycleState: .preparing,
        startNonce: Data(repeating: nonceByte, count: 16)
    )
}

private func fixedSession(_ lastByte: UInt8) -> TerminalSessionID {
    TerminalSessionID(fixedUUID(lastByte))
}

private func fixedUUID(_ lastByte: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, lastByte))
}

private func withTerminalDatabase(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = URL(
        fileURLWithPath: "/private/tmp/cockpit-terminal-repository-tests.\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("terminal.sqlite"))
}

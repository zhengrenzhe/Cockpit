import Foundation
import Testing
@testable import CockpitPersistence

@Test func sqliteConnectionEnablesRequiredPragmas() async throws {
    try await withTemporaryDatabase { databaseURL in
        let connection = try SQLiteConnection(databaseURL: databaseURL)

        #expect(try await connection.textValue(for: "PRAGMA journal_mode") == "wal")
        #expect(try await connection.integerValue(for: "PRAGMA foreign_keys") == 1)
        #expect(try await connection.integerValue(for: "PRAGMA busy_timeout") == 5_000)
    }
}

private func withTemporaryDatabase(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = URL(
        fileURLWithPath: "/private/tmp/cockpit-sqlite-connection-tests.\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("workspace.sqlite"))
}

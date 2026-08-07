import Darwin
import Foundation
import Testing
import CockpitProtocol
import CockpitTypes
@testable import CockpitWorkspace

@Test func documentRecoveryAppendUsesDurableDelimitedRecordsAndOwnerOnlyPermissions() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let log = DocumentRecoveryLog(rootURL: fixture.root, documentID: fixture.documentID)

    try await log.append(documentVersion: 1, clientSequence: 10, utf8EditPayload: Data("first".utf8))
    try await log.append(documentVersion: 2, clientSequence: 11, utf8EditPayload: Data("second".utf8))
    let recovered = try await log.recover()

    #expect(recovered.records.map(\.documentVersion) == [1, 2])
    #expect(recovered.records.map(\.clientSequence) == [10, 11])
    #expect(recovered.records.map(\.utf8EditPayload) == [Data("first".utf8), Data("second".utf8)])
    #expect(recovered.diagnostics.isEmpty)
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.recordsURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
}

@Test func documentRecoveryAppendFsyncFailureNeverAcknowledges() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let log = DocumentRecoveryLog(
        rootURL: fixture.root,
        documentID: fixture.documentID,
        injectedFailure: .appendSync
    )

    await #expect(throws: (any Error).self) {
        try await log.append(documentVersion: 1, clientSequence: 1, utf8EditPayload: Data("edit".utf8))
    }
}

@Test func documentRecoveryCleanEOFAndTruncatedTailStopAtLastCompleteRecord() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let log = DocumentRecoveryLog(rootURL: fixture.root, documentID: fixture.documentID)
    try await log.append(documentVersion: 1, clientSequence: 1, utf8EditPayload: Data("one".utf8))
    let completeSize = try Data(contentsOf: fixture.recordsURL).count
    try FileHandle(forWritingTo: fixture.recordsURL).seekToEndAndWrite(Data([0x05, 0x0A]))

    let recovered = try await log.recover()
    #expect(recovered.records.map(\.documentVersion) == [1])
    #expect(recovered.diagnostics == [.truncatedTail(byteOffset: UInt64(completeSize))])
}

@Test func documentRecoveryCompleteCorruptionAndSequenceViolationStopAtFirstBadRecord() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let first = try DocumentMessages.encodeDelimited(
        DocumentRecoveryRecord(
            documentID: fixture.documentID,
            documentVersion: 1,
            clientSequence: 1,
            utf8EditPayload: Data("one".utf8)
        )
    )
    let outOfOrder = try DocumentMessages.encodeDelimited(
        DocumentRecoveryRecord(
            documentID: fixture.documentID,
            documentVersion: 1,
            clientSequence: 2,
            utf8EditPayload: Data("duplicate-version".utf8)
        )
    )
    let later = try DocumentMessages.encodeDelimited(
        DocumentRecoveryRecord(
            documentID: fixture.documentID,
            documentVersion: 3,
            clientSequence: 3,
            utf8EditPayload: Data("later".utf8)
        )
    )
    try (first + outOfOrder + later).write(to: fixture.recordsURL)

    let recovered = try await DocumentRecoveryLog(
        rootURL: fixture.root,
        documentID: fixture.documentID
    ).recover()
    #expect(recovered.records.map(\.documentVersion) == [1])
    #expect(recovered.diagnostics == [.corruptRecord(byteOffset: UInt64(first.count))])
}

@Test func documentRecoveryCheckpointPublishesBaselineThenCompactsPersistedRecords() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let log = DocumentRecoveryLog(rootURL: fixture.root, documentID: fixture.documentID)
    for version in 1...3 {
        try await log.append(
            documentVersion: UInt64(version),
            clientSequence: UInt64(version),
            utf8EditPayload: Data("edit-\(version)".utf8)
        )
    }

    let diagnostic = try await log.checkpoint(
        persistedDocumentVersion: 2,
        persistedClientSequence: 2,
        diskFingerprint: try recoveryFingerprint()
    )
    let recovered = try await log.recover()

    #expect(diagnostic == nil)
    #expect(recovered.checkpoint?.persistedDocumentVersion == 2)
    #expect(recovered.records.map(\.documentVersion) == [3])
    #expect(recovered.diagnostics.isEmpty)
}

@Test func documentRecoveryCommittedCheckpointWithDeferredCompactionNeverReplaysPersistedEdits() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let initial = DocumentRecoveryLog(rootURL: fixture.root, documentID: fixture.documentID)
    try await initial.append(documentVersion: 1, clientSequence: 1, utf8EditPayload: Data("one".utf8))
    try await initial.append(documentVersion: 2, clientSequence: 2, utf8EditPayload: Data("two".utf8))
    let failing = DocumentRecoveryLog(
        rootURL: fixture.root,
        documentID: fixture.documentID,
        injectedFailure: .compactionAfterCheckpointCommit
    )

    let diagnostic = try await failing.checkpoint(
        persistedDocumentVersion: 1,
        persistedClientSequence: 1,
        diskFingerprint: try recoveryFingerprint()
    )
    let recovered = try await initial.recover()

    #expect(diagnostic == .compactionDeferred)
    #expect(recovered.records.map(\.documentVersion) == [2])
    #expect(recovered.diagnostics == [.compactionDeferred])
}

@Test func documentRecoveryCheckpointDefersCompactionAtHandWrittenMalformedRecord() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let log = DocumentRecoveryLog(rootURL: fixture.root, documentID: fixture.documentID)
    try await log.append(documentVersion: 1, clientSequence: 1, utf8EditPayload: Data("one".utf8))
    let malformedOffset = UInt64(try Data(contentsOf: fixture.recordsURL).count)
    let handle = try FileHandle(forWritingTo: fixture.recordsURL)
    try handle.seekToEndAndWrite(Data([0x01, 0x00]))

    let diagnostic = try await log.checkpoint(
        persistedDocumentVersion: 1,
        persistedClientSequence: 1,
        diskFingerprint: try recoveryFingerprint()
    )
    let recovered = try await log.recover()

    #expect(diagnostic == .compactionDeferred)
    #expect(recovered.records.isEmpty)
    #expect(recovered.diagnostics.contains(.corruptRecord(byteOffset: malformedOffset)))
}

private final class RecoveryFixture {
    let root: URL
    let documentID: DocumentID
    var recordsURL: URL {
        root.appendingPathComponent("\(documentID.description).records.ckdr")
    }
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/cockpit-recovery-tests.\(UUID().uuidString)", isDirectory: true)
        documentID = DocumentID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000012")))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func recoveryFingerprint() throws -> DiskFingerprint {
    DiskFingerprint(
        deviceID: 9,
        inode: 10,
        byteCount: 11,
        modificationTimeSeconds: -12,
        modificationTimeNanoseconds: 13,
        contentSHA256: try SHA256Digest(validating: Data(0..<32))
    )
}

private extension FileHandle {
    func seekToEndAndWrite(_ data: Data) throws {
        defer { try? close() }
        try seekToEnd()
        try write(contentsOf: data)
    }
}

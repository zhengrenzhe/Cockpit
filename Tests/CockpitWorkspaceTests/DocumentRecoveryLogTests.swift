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
    let recorder = RecoverySyscallRecorder()
    let log = DocumentRecoveryLog(
        rootURL: fixture.root,
        documentID: fixture.documentID,
        systemCalls: recoverySystemCalls(recorder: recorder, failAppendSync: true)
    )

    await #expect(throws: (any Error).self) {
        try await log.append(documentVersion: 1, clientSequence: 1, utf8EditPayload: Data("edit".utf8))
    }
    #expect(recorder.events == [.write, .fsync])
}

@Test func documentRecoveryPartialWritesStillFsyncTheCompleteRecordBeforeAcknowledgement() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let recorder = RecoverySyscallRecorder()
    let log = DocumentRecoveryLog(
        rootURL: fixture.root,
        documentID: fixture.documentID,
        systemCalls: recoverySystemCalls(recorder: recorder, maximumWrite: 3)
    )

    try await log.append(
        documentVersion: 1,
        clientSequence: 1,
        utf8EditPayload: Data("partial-write".utf8)
    )
    let recovered = try await log.recover()

    #expect(recorder.events.last == .fsync)
    #expect(recorder.events.filter { $0 == .write }.count > 1)
    #expect(recovered.records.map(\.utf8EditPayload) == [Data("partial-write".utf8)])
}

@Test func documentRecoveryCheckpointUsesRealWriteSyncRenameRootSyncOrderingTwice() async throws {
    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    let recorder = RecoverySyscallRecorder()
    let log = DocumentRecoveryLog(
        rootURL: fixture.root,
        documentID: fixture.documentID,
        systemCalls: recoverySystemCalls(recorder: recorder)
    )
    try await log.append(documentVersion: 1, clientSequence: 1, utf8EditPayload: Data("one".utf8))
    try await log.append(documentVersion: 2, clientSequence: 2, utf8EditPayload: Data("two".utf8))
    recorder.reset()

    let diagnostic = try await log.checkpoint(
        persistedDocumentVersion: 1,
        persistedClientSequence: 1,
        diskFingerprint: try recoveryFingerprint()
    )

    #expect(diagnostic == nil)
    #expect(recorder.events == [.write, .fsync, .rename, .fsync, .write, .fsync, .rename, .fsync])
}

@Test func documentRecoveryHandWrittenLiteralFramesRejectFrozenMalformedWireAtFirstRecord() async throws {
    let valid = try hexData(
        "620a04434b445210011a2430303030303030302d303030302d303030302d303030302d30303030303030303030313220012801322003396d54c8480d4b1302b80c8d9f37ce88b14244581b020c3ade292b4196a4c53a0c7b2265646974223a2278227d"
    )
    var wrongMagic = valid
    wrongMagic[3] = 0x58
    var wrongVersion = valid
    wrongVersion[8] = 0x02
    var wrongIdentity = valid
    wrongIdentity[46] = 0x33
    var wrongHash = valid
    wrongHash[53] ^= 0xFF
    var unknownField = valid
    unknownField[0] = 0x65
    unknownField.append(contentsOf: [0x98, 0x06, 0x01])

    for bytes in [wrongMagic, wrongVersion, wrongIdentity, wrongHash, unknownField] {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        try bytes.write(to: fixture.recordsURL)
        let recovered = try await DocumentRecoveryLog(
            rootURL: fixture.root,
            documentID: fixture.documentID
        ).recover()
        #expect(recovered.records.isEmpty)
        #expect(recovered.diagnostics == [.corruptRecord(byteOffset: 0)])
    }

    let fixture = try RecoveryFixture()
    defer { fixture.remove() }
    try valid.write(to: fixture.recordsURL)
    let recovered = try await DocumentRecoveryLog(
        rootURL: fixture.root,
        documentID: fixture.documentID
    ).recover()
    #expect(recovered.records.map(\.utf8EditPayload) == [Data(#"{"edit":"x"}"#.utf8)])
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
        systemCalls: recoverySystemCalls(
            recorder: RecoverySyscallRecorder(),
            failRenameNumber: 2
        )
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

private enum RecoverySyscallEvent: Equatable {
    case write
    case fsync
    case rename
}

private final class RecoverySyscallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecoverySyscallEvent] = []
    var events: [RecoverySyscallEvent] { lock.withLock { storage } }
    func append(_ event: RecoverySyscallEvent) { lock.withLock { storage.append(event) } }
    func reset() { lock.withLock { storage.removeAll() } }
}

private func recoverySystemCalls(
    recorder: RecoverySyscallRecorder,
    maximumWrite: Int? = nil,
    failAppendSync: Bool = false,
    failRenameNumber: Int? = nil
) -> RecoveryLogSystemCalls {
    let renameCounter = LockedTestCounter()
    return RecoveryLogSystemCalls(
        write: { descriptor, pointer, count in
            recorder.append(.write)
            return Darwin.write(descriptor, pointer, min(count, maximumWrite ?? count))
        },
        fsync: { descriptor in
            recorder.append(.fsync)
            if failAppendSync {
                errno = EIO
                return -1
            }
            return Darwin.fsync(descriptor)
        },
        rename: { source, destination in
            recorder.append(.rename)
            if renameCounter.increment() == failRenameNumber {
                errno = EIO
                return -1
            }
            return Darwin.rename(source, destination)
        }
    )
}

private final class LockedTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

private func hexData(_ hex: String) throws -> Data {
    guard hex.count.isMultiple(of: 2) else { throw CocoaError(.coderInvalidValue) }
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else {
            throw CocoaError(.coderInvalidValue)
        }
        data.append(byte)
        index = next
    }
    return data
}

private extension FileHandle {
    func seekToEndAndWrite(_ data: Data) throws {
        defer { try? close() }
        try seekToEnd()
        try write(contentsOf: data)
    }
}

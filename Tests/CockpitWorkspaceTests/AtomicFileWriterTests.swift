import Darwin
import Foundation
import Testing
import CockpitHostCore
import CockpitProtocol
import CockpitTypes
@testable import CockpitWorkspace

@Test func atomicFileWriterReplacesInSameDirectoryPreservesPermissionsAndReturnsFingerprint() throws {
    let fixture = try AtomicWriterFixture()
    defer { fixture.remove() }
    try chmod(fixture.target.path, 0o666).throwIfNonzero()
    let rootFD = try fixture.openRoot()
    defer { close(rootFD) }
    let before = try AtomicFileWriter.snapshot(rootFD: rootFD, path: RelativePath("nested/file.txt"))

    let after = try AtomicFileWriter(rootFD: rootFD).write(
        Data("replacement".utf8),
        to: RelativePath("nested/file.txt"),
        expectedFingerprint: before.fingerprint
    )

    #expect(try Data(contentsOf: fixture.target) == Data("replacement".utf8))
    #expect(after.byteCount == 11)
    #expect(after.contentSHA256 != before.fingerprint.contentSHA256)
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.target.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o666)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.nested.path).allSatisfy { !$0.hasPrefix(".cockpit-save-") })
}

@Test func atomicFileWriterMismatchCreatesNoTempAndLeavesTargetUnchanged() throws {
    let fixture = try AtomicWriterFixture()
    defer { fixture.remove() }
    let rootFD = try fixture.openRoot()
    defer { close(rootFD) }
    let wrong = try DiskFingerprint(
        deviceID: 0,
        inode: 0,
        byteCount: 0,
        modificationTimeSeconds: 0,
        modificationTimeNanoseconds: 0,
        contentSHA256: SHA256Digest(validating: Data(repeating: 0, count: 32))
    )

    #expect(throws: DocumentStorageError.fingerprintMismatch(
        expected: wrong,
        actual: try AtomicFileWriter.snapshot(rootFD: rootFD, path: RelativePath("nested/file.txt")).fingerprint
    )) {
        _ = try AtomicFileWriter(rootFD: rootFD).write(
            Data("replacement".utf8),
            to: RelativePath("nested/file.txt"),
            expectedFingerprint: wrong
        )
    }
    #expect(try Data(contentsOf: fixture.target) == Data("original".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.nested.path) == ["file.txt"])
}

@Test func atomicFileWriterPreCommitFailuresPreserveOriginalAndReportRetainedStagingPath() throws {
    for failure in [AtomicFileWriterInjectedFailure.write, .tempSync, .rename] {
        let fixture = try AtomicWriterFixture()
        defer { fixture.remove() }
        let rootFD = try fixture.openRoot()
        defer { close(rootFD) }
        let before = try AtomicFileWriter.snapshot(rootFD: rootFD, path: RelativePath("nested/file.txt"))

        do {
            _ = try AtomicFileWriter(rootFD: rootFD, injectedFailure: failure).write(
                Data("replacement".utf8),
                to: RelativePath("nested/file.txt"),
                expectedFingerprint: before.fingerprint
            )
            Issue.record("Expected recovery-required error")
        } catch let error as DocumentWriteRecoveryRequiredError {
            guard case let .staged(path) = error.state else {
                Issue.record("Expected retained staged path")
                continue
            }
            #expect(path.string.hasPrefix("nested/.cockpit-save-"))
            #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(path.string).path))
        }
        #expect(try Data(contentsOf: fixture.target) == Data("original".utf8))
    }
}

@Test func atomicFileWriterParentSyncFailureReportsCommittedFingerprintWithoutRollback() throws {
    let fixture = try AtomicWriterFixture()
    defer { fixture.remove() }
    let rootFD = try fixture.openRoot()
    defer { close(rootFD) }
    let before = try AtomicFileWriter.snapshot(rootFD: rootFD, path: RelativePath("nested/file.txt"))

    do {
        _ = try AtomicFileWriter(rootFD: rootFD, injectedFailure: .parentSync).write(
            Data("replacement".utf8),
            to: RelativePath("nested/file.txt"),
            expectedFingerprint: before.fingerprint
        )
        Issue.record("Expected durability-unknown error")
    } catch let error as DocumentWriteRecoveryRequiredError {
        guard case let .committedButDurabilityUnknown(fingerprint) = error.state else {
            Issue.record("Expected committed fingerprint")
            return
        }
        #expect(fingerprint.byteCount == 11)
    }
    #expect(try Data(contentsOf: fixture.target) == Data("replacement".utf8))
}

private final class AtomicWriterFixture {
    let root: URL
    let nested: URL
    let target: URL
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/cockpit-atomic-writer-tests.\(UUID().uuidString)", isDirectory: true)
        nested = root.appendingPathComponent("nested", isDirectory: true)
        target = nested.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: target)
    }
    func openRoot() throws -> Int32 {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return fd
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private extension Int32 {
    func throwIfNonzero() throws {
        guard self == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

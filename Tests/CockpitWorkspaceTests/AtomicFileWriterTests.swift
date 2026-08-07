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
    let recorder = AtomicSyscallRecorder()

    let after = try AtomicFileWriter(
        rootFD: rootFD,
        systemCalls: atomicSystemCalls(recorder: recorder, maximumWrite: 3)
    ).write(
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
    #expect(recorder.events.filter { if case .write = $0 { true } else { false } }.count > 1)
    #expect(Array(recorder.events.suffix(3)).map(\.kind) == [.tempFsync, .rename, .parentFsync])
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
    for failure in [AtomicBoundaryFailure.write, .tempFsync, .rename] {
        let fixture = try AtomicWriterFixture()
        defer { fixture.remove() }
        let rootFD = try fixture.openRoot()
        defer { close(rootFD) }
        let before = try AtomicFileWriter.snapshot(rootFD: rootFD, path: RelativePath("nested/file.txt"))

        do {
            _ = try AtomicFileWriter(
                rootFD: rootFD,
                systemCalls: atomicSystemCalls(
                    recorder: AtomicSyscallRecorder(),
                    failure: failure
                )
            ).write(
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
        _ = try AtomicFileWriter(
            rootFD: rootFD,
            systemCalls: atomicSystemCalls(
                recorder: AtomicSyscallRecorder(),
                failure: .parentFsync
            )
        ).write(
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

@Test func atomicFileWriterFinalTargetReplacementFailsFingerprintGateAndPreservesStage() throws {
    let fixture = try AtomicWriterFixture()
    defer { fixture.remove() }
    let rootFD = try fixture.openRoot()
    defer { close(rootFD) }
    let before = try AtomicFileWriter.snapshot(rootFD: rootFD, path: RelativePath("nested/file.txt"))
    let moved = fixture.nested.appendingPathComponent("file.original")
    let hooks = AtomicFileWriterHooks(beforeCommitValidation: { _ in
        try! FileManager.default.moveItem(at: fixture.target, to: moved)
        try! Data("external-replacement".utf8).write(to: fixture.target)
    })

    do {
        _ = try AtomicFileWriter(rootFD: rootFD, hooks: hooks).write(
            Data("saved".utf8),
            to: RelativePath("nested/file.txt"),
            expectedFingerprint: before.fingerprint
        )
        Issue.record("Expected fingerprint conflict")
    } catch let error as DocumentWriteRecoveryRequiredError {
        guard case .staged = error.state else {
            Issue.record("Expected retained staged write")
            return
        }
        guard case .fingerprintMismatch = error.originalError as? DocumentStorageError else {
            Issue.record("Expected fingerprint mismatch as original error")
            return
        }
    }
    #expect(try Data(contentsOf: fixture.target) == Data("external-replacement".utf8))
    #expect(try Data(contentsOf: moved) == Data("original".utf8))
}

@Test func atomicFileWriterAncestorMoveNeverCreatesOrRenamesThroughEscapedParentFD() throws {
    let fixture = try AtomicWriterFixture()
    defer { fixture.remove() }
    let escaped = fixture.root.appendingPathExtension("escaped-nested")
    defer { try? FileManager.default.removeItem(at: escaped) }
    let rootFD = try fixture.openRoot()
    defer { close(rootFD) }
    let before = try AtomicFileWriter.snapshot(rootFD: rootFD, path: RelativePath("nested/file.txt"))
    let hooks = AtomicFileWriterHooks(beforeCommitValidation: { _ in
        try! FileManager.default.moveItem(at: fixture.nested, to: escaped)
        try! FileManager.default.createDirectory(at: fixture.nested, withIntermediateDirectories: false)
        try! Data("external-replacement".utf8).write(to: fixture.target)
    })

    do {
        _ = try AtomicFileWriter(rootFD: rootFD, hooks: hooks).write(
            Data("saved".utf8),
            to: RelativePath("nested/file.txt"),
            expectedFingerprint: before.fingerprint
        )
        Issue.record("Expected escaped-parent conflict")
    } catch let error as DocumentWriteRecoveryRequiredError {
        #expect(error.state == .stagedLocationUnknown)
    }

    #expect(try Data(contentsOf: fixture.target) == Data("external-replacement".utf8))
    #expect(try Data(contentsOf: escaped.appendingPathComponent("file.txt")) == Data("original".utf8))
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: escaped.path)
            .contains { $0.hasPrefix(".cockpit-save-") }
    )
}

@Test func atomicFileWriterPostRenameParentMoveFsyncsRetainedMutatedDirectory() throws {
    let fixture = try AtomicWriterFixture()
    defer { fixture.remove() }
    let escaped = fixture.root.appendingPathExtension("committed-parent")
    defer { try? FileManager.default.removeItem(at: escaped) }
    let originalParentInode = try inode(at: fixture.nested)
    let rootFD = try fixture.openRoot()
    defer { close(rootFD) }
    let before = try AtomicFileWriter.snapshot(rootFD: rootFD, path: RelativePath("nested/file.txt"))
    let recorder = AtomicSyscallRecorder()
    let hooks = AtomicFileWriterHooks(afterRename: {
        try! FileManager.default.moveItem(at: fixture.nested, to: escaped)
        try! FileManager.default.createDirectory(at: fixture.nested, withIntermediateDirectories: false)
    })

    _ = try AtomicFileWriter(
        rootFD: rootFD,
        systemCalls: atomicSystemCalls(recorder: recorder),
        hooks: hooks
    ).write(
        Data("saved".utf8),
        to: RelativePath("nested/file.txt"),
        expectedFingerprint: before.fingerprint
    )

    #expect(recorder.events.contains(.parentFsync(inode: originalParentInode)))
    #expect(try Data(contentsOf: escaped.appendingPathComponent("file.txt")) == Data("saved".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.nested.path).isEmpty)
}

@Test func atomicFileWriterStagedNameReplacementReportsLocationUnknownWithoutDeletingEitherFile() throws {
    let fixture = try AtomicWriterFixture()
    defer { fixture.remove() }
    let rootFD = try fixture.openRoot()
    defer { close(rootFD) }
    let before = try AtomicFileWriter.snapshot(rootFD: rootFD, path: RelativePath("nested/file.txt"))
    let action = StagedNameReplacementAction(root: fixture.root)
    let hooks = AtomicFileWriterHooks(beforeStagedState: { action.replace(path: $0) })

    do {
        _ = try AtomicFileWriter(
            rootFD: rootFD,
            systemCalls: atomicSystemCalls(
                recorder: AtomicSyscallRecorder(),
                failure: .rename
            ),
            hooks: hooks
        ).write(
            Data("saved".utf8),
            to: RelativePath("nested/file.txt"),
            expectedFingerprint: before.fingerprint
        )
        Issue.record("Expected rename failure")
    } catch let error as DocumentWriteRecoveryRequiredError {
        #expect(error.state == .stagedLocationUnknown)
    }
    #expect(try Data(contentsOf: action.movedURL) == Data("saved".utf8))
    #expect(try Data(contentsOf: action.replacementURL) == Data("decoy".utf8))
    #expect(try Data(contentsOf: fixture.target) == Data("original".utf8))
}

@Test func atomicFileWriterSnapshotDetectsMutationBetweenReadAndSecondFstat() throws {
    let fixture = try AtomicWriterFixture()
    defer { fixture.remove() }
    let rootFD = try fixture.openRoot()
    defer { close(rootFD) }
    let hooks = AtomicFileWriterHooks(afterSnapshotRead: {
        let handle = try! FileHandle(forWritingTo: fixture.target)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: Data("-changed".utf8))
        try! handle.close()
    })

    #expect(throws: DocumentStorageError.unstableRead) {
        _ = try AtomicFileWriter.snapshot(
            rootFD: rootFD,
            path: RelativePath("nested/file.txt"),
            hooks: hooks
        )
    }
}

private final class AtomicWriterFixture: @unchecked Sendable {
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

private enum AtomicBoundaryFailure {
    case write
    case tempFsync
    case rename
    case parentFsync
}

private enum AtomicSyscallEvent: Equatable {
    case write
    case tempFsync
    case rename
    case parentFsync(inode: UInt64)

    var kind: AtomicSyscallKind {
        switch self {
        case .write: .write
        case .tempFsync: .tempFsync
        case .rename: .rename
        case .parentFsync: .parentFsync
        }
    }
}

private enum AtomicSyscallKind: Equatable {
    case write
    case tempFsync
    case rename
    case parentFsync
}

private final class AtomicSyscallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AtomicSyscallEvent] = []
    var events: [AtomicSyscallEvent] { lock.withLock { storage } }
    func append(_ event: AtomicSyscallEvent) { lock.withLock { storage.append(event) } }
}

private func atomicSystemCalls(
    recorder: AtomicSyscallRecorder,
    maximumWrite: Int? = nil,
    failure: AtomicBoundaryFailure? = nil
) -> AtomicFileWriterSystemCalls {
    AtomicFileWriterSystemCalls(
        write: { descriptor, pointer, count in
            recorder.append(.write)
            if failure == .write {
                errno = EIO
                return -1
            }
            return Darwin.write(descriptor, pointer, min(count, maximumWrite ?? count))
        },
        fsync: { descriptor in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { return -1 }
            if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                recorder.append(.parentFsync(inode: UInt64(metadata.st_ino)))
                if failure == .parentFsync {
                    errno = EIO
                    return -1
                }
            } else {
                recorder.append(.tempFsync)
                if failure == .tempFsync {
                    errno = EIO
                    return -1
                }
            }
            return Darwin.fsync(descriptor)
        },
        rename: { sourceRoot, source, destinationRoot, destination, flags in
            recorder.append(.rename)
            if failure == .rename {
                errno = EIO
                return -1
            }
            return renameatx_np(sourceRoot, source, destinationRoot, destination, flags)
        }
    )
}

private final class StagedNameReplacementAction: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private var moved: URL?
    private var replacement: URL?
    var movedURL: URL { lock.withLock { moved! } }
    var replacementURL: URL { lock.withLock { replacement! } }
    init(root: URL) { self.root = root }
    func replace(path: RelativePath) {
        lock.withLock {
            let source = root.appendingPathComponent(path.string)
            let movedURL = source.appendingPathExtension("moved")
            try! FileManager.default.moveItem(at: source, to: movedURL)
            try! Data("decoy".utf8).write(to: source)
            moved = movedURL
            replacement = source
        }
    }
}

private func inode(at url: URL) throws -> UInt64 {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return UInt64(metadata.st_ino)
}

private extension Int32 {
    func throwIfNonzero() throws {
        guard self == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

import Darwin
import Foundation
import Testing
import CockpitProtocol
import CockpitTypes
@testable import CockpitTerminalCore

@Suite("TerminalArchiveTests")
struct TerminalArchiveTests {
    @Test func terminalArchivePublishesImmutableContentAndProtobufManifest() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.cleanup() }
        let sessionID = TerminalSessionID()
        let workerID = WorkerInstanceID()
        let first = Data("scrollback-one".utf8)
        let second = Data("scrollback-two".utf8)
        let snapshot = Data("authoritative-snapshot".utf8)

        let manifest = try fixture.store.publish(
            sessionID: sessionID,
            workerID: workerID,
            chunks: [
                try TerminalArchiveChunkData(
                    firstOutputSequence: 1,
                    lastOutputSequence: 10,
                    data: first
                ),
                try TerminalArchiveChunkData(
                    firstOutputSequence: 21,
                    lastOutputSequence: 25,
                    data: second
                ),
            ],
            firstOutputSequence: 1,
            latestOutputSequence: 30,
            finalSnapshot: snapshot,
            exitStatus: .exited(0),
            completedAt: Date(timeIntervalSince1970: 20_000)
        )

        #expect(manifest.terminalSessionID == sessionID)
        #expect(manifest.workerInstanceID == workerID)
        #expect(manifest.chunks.map(\.name) == [
            "00000000000000000001.ckgs",
            "00000000000000000021.ckgs",
        ])
        #expect(try fixture.store.verifiedManifest(sessionID: sessionID) == manifest)
        let session = fixture.archives.appendingPathComponent(sessionID.description)
        let chunks = session.appendingPathComponent("chunks")
        #expect(try permissions(session.path) == 0o700)
        #expect(try permissions(chunks.path) == 0o700)
        for file in [
            chunks.appendingPathComponent("00000000000000000001.ckgs"),
            chunks.appendingPathComponent("00000000000000000021.ckgs"),
            session.appendingPathComponent("final-snapshot.ckgf"),
            session.appendingPathComponent("manifest.pb"),
        ] {
            #expect(try permissions(file.path) == 0o600)
        }

        let manifestData = try Data(contentsOf: session.appendingPathComponent("manifest.pb"))
        let wire = try CPTerminalArchiveManifest(serializedBytes: manifestData)
        #expect(try TerminalMessages.decode(wire, negotiatedVersion: .current) == manifest)
    }

    @Test func terminalArchiveRejectsSymlinkAndOutsideApplicationSupportRoots() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outside.path)
        #expect(throws: TerminalArchiveError.invalidRoot) {
            _ = try TerminalArchiveStore(
                applicationSupportRoot: fixture.applicationSupport.path,
                terminalArchivesRoot: outside.path
            )
        }

        let link = fixture.root.appendingPathComponent("archive-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.archives)
        #expect(throws: TerminalArchiveError.invalidRoot) {
            _ = try TerminalArchiveStore(
                applicationSupportRoot: fixture.applicationSupport.path,
                terminalArchivesRoot: link.path
            )
        }
    }

    @Test func terminalArchiveNeverPublishesManifestAfterIncompleteContentWrite() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.cleanup() }
        let sessionID = TerminalSessionID()
        let session = fixture.archives.appendingPathComponent(sessionID.description)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: session.path)
        let external = fixture.root.appendingPathComponent("external-chunks")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: session.appendingPathComponent("chunks"),
            withDestinationURL: external
        )

        #expect(throws: TerminalArchiveError.self) {
            _ = try fixture.store.publish(
                sessionID: sessionID,
                workerID: WorkerInstanceID(),
                chunks: [
                    try TerminalArchiveChunkData(
                        firstOutputSequence: 1,
                        lastOutputSequence: 1,
                        data: Data("chunk".utf8)
                    ),
                ],
                firstOutputSequence: 1,
                latestOutputSequence: 1,
                finalSnapshot: Data("snapshot".utf8),
                exitStatus: .exited(1),
                completedAt: Date(timeIntervalSince1970: 20_000)
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: session.appendingPathComponent("manifest.pb").path
        ))
    }

    @Test func terminalArchiveRejectsTamperedChunkAndOpensSnapshotReadOnly() throws {
        let fixture = try ArchiveFixture()
        defer { fixture.cleanup() }
        let sessionID = TerminalSessionID()
        let snapshot = Data("read-only-snapshot".utf8)
        _ = try fixture.store.publish(
            sessionID: sessionID,
            workerID: WorkerInstanceID(),
            chunks: [
                try TerminalArchiveChunkData(
                    firstOutputSequence: 1,
                    lastOutputSequence: 2,
                    data: Data("original".utf8)
                ),
            ],
            firstOutputSequence: 1,
            latestOutputSequence: 2,
            finalSnapshot: snapshot,
            exitStatus: .signaled(SIGTERM),
            completedAt: Date(timeIntervalSince1970: 20_000)
        )

        let handle = try fixture.store.openFinalSnapshot(sessionID: sessionID)
        #expect(try handle.readAll() == snapshot)
        var byte: UInt8 = 0
        errno = 0
        let writeResult = withUnsafeBytes(of: &byte) {
            Darwin.write(handle.fileDescriptor, $0.baseAddress, $0.count)
        }
        #expect(writeResult == -1)
        #expect(errno == EBADF)

        let chunk = fixture.archives
            .appendingPathComponent(sessionID.description)
            .appendingPathComponent("chunks/00000000000000000001.ckgs")
        try Data("tampered".utf8).write(to: chunk)
        #expect(throws: TerminalArchiveError.integrityMismatch) {
            _ = try fixture.store.verifiedManifest(sessionID: sessionID)
        }
    }
}

private final class ArchiveFixture {
    let root: URL
    let applicationSupport: URL
    let archives: URL
    let store: TerminalArchiveStore

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/cockpit-archive.\(UUID().uuidString)")
        applicationSupport = root.appendingPathComponent("ApplicationSupport")
        archives = applicationSupport.appendingPathComponent("TerminalArchives")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        for directory in [root, applicationSupport, archives] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        store = try TerminalArchiveStore(
            applicationSupportRoot: applicationSupport.path,
            terminalArchivesRoot: archives.path
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func permissions(_ path: String) throws -> mode_t {
    var value = stat()
    guard lstat(path, &value) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return value.st_mode & 0o777
}

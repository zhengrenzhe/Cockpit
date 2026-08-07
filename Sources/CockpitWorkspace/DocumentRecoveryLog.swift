import Darwin
import Foundation
import CockpitProtocol
import CockpitTypes

public enum DocumentRecoveryDiagnostic: Hashable, Sendable {
    case truncatedTail(byteOffset: UInt64)
    case corruptRecord(byteOffset: UInt64)
    case compactionDeferred
}

public struct DocumentRecoveryResult: Sendable {
    public let checkpoint: DocumentRecoveryCheckpoint?
    public let records: [DocumentRecoveryRecord]
    public let diagnostics: [DocumentRecoveryDiagnostic]

    public init(
        checkpoint: DocumentRecoveryCheckpoint?,
        records: [DocumentRecoveryRecord],
        diagnostics: [DocumentRecoveryDiagnostic]
    ) {
        self.checkpoint = checkpoint
        self.records = records
        self.diagnostics = diagnostics
    }
}

enum DocumentRecoveryLogInjectedFailure: Sendable {
    case appendSync
    case compactionAfterCheckpointCommit
}

public final class DocumentRecoveryLog: @unchecked Sendable {
    private let rootURL: URL
    private let documentID: DocumentID
    private let injectedFailure: DocumentRecoveryLogInjectedFailure?
    private let queue = DispatchQueue(label: "com.openai.cockpit.document-recovery")

    public init(rootURL: URL, documentID: DocumentID) {
        self.rootURL = rootURL.standardizedFileURL
        self.documentID = documentID
        self.injectedFailure = nil
    }

    init(
        rootURL: URL,
        documentID: DocumentID,
        injectedFailure: DocumentRecoveryLogInjectedFailure
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.documentID = documentID
        self.injectedFailure = injectedFailure
    }

    public func append(
        documentVersion: UInt64,
        clientSequence: UInt64,
        utf8EditPayload: Data
    ) async throws {
        try await onQueue {
            let record = try DocumentRecoveryRecord(
                documentID: self.documentID,
                documentVersion: documentVersion,
                clientSequence: clientSequence,
                utf8EditPayload: utf8EditPayload
            )
            let frame = try DocumentMessages.encodeDelimited(record)
            let fd = open(
                self.recordsURL.path,
                O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
            guard fd >= 0 else { throw Self.posixError(errno) }
            defer { close(fd) }
            guard fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw Self.posixError(errno)
            }
            try Self.writeAll(frame, descriptor: fd)
            if self.injectedFailure == .appendSync {
                throw Self.injectedError("append-fsync")
            }
            try Self.synchronize(fd)
        }
    }

    public func recover() async throws -> DocumentRecoveryResult {
        try await onQueue { try self.recoverSynchronously() }
    }

    public func checkpoint(
        persistedDocumentVersion: UInt64,
        persistedClientSequence: UInt64,
        diskFingerprint: DiskFingerprint
    ) async throws -> DocumentRecoveryDiagnostic? {
        try await onQueue {
            let checkpoint = try DocumentRecoveryCheckpoint(
                documentID: self.documentID,
                persistedDocumentVersion: persistedDocumentVersion,
                persistedClientSequence: persistedClientSequence,
                diskFingerprint: diskFingerprint
            )
            let checkpointFrame = try DocumentMessages.encodeDelimited(checkpoint)
            try self.publishAtomically(checkpointFrame, to: self.checkpointURL)

            if self.injectedFailure == .compactionAfterCheckpointCommit {
                return .compactionDeferred
            }

            do {
                let recovered = try self.recoverSynchronously()
                if recovered.diagnostics.contains(where: {
                    switch $0 {
                    case .truncatedTail, .corruptRecord: true
                    case .compactionDeferred: false
                    }
                }) {
                    return .compactionDeferred
                }
                let remaining = recovered.records.filter {
                    $0.documentVersion > persistedDocumentVersion
                        && $0.clientSequence > persistedClientSequence
                }
                var compacted = Data()
                for record in remaining {
                    compacted.append(try DocumentMessages.encodeDelimited(record))
                }
                try self.publishAtomically(compacted, to: self.recordsURL)
                return nil
            } catch {
                return .compactionDeferred
            }
        }
    }

    private var recordsURL: URL {
        rootURL.appendingPathComponent("\(documentID.description).records.ckdr")
    }

    private var checkpointURL: URL {
        rootURL.appendingPathComponent("\(documentID.description).checkpoint.ckdr")
    }

    private func recoverSynchronously() throws -> DocumentRecoveryResult {
        var diagnostics: [DocumentRecoveryDiagnostic] = []
        var checkpoint: DocumentRecoveryCheckpoint?
        if fileExists(checkpointURL) {
            do {
                let data = try readFile(checkpointURL)
                let decoded = try DocumentMessages.decodeDelimitedCheckpoint(data)
                guard decoded.consumedBytes == data.count,
                      decoded.value.documentID == documentID
                else { throw DocumentDelimitedError.malformed }
                checkpoint = decoded.value
            } catch {
                diagnostics.append(.corruptRecord(byteOffset: 0))
            }
        }

        guard fileExists(recordsURL) else {
            return DocumentRecoveryResult(
                checkpoint: checkpoint,
                records: [],
                diagnostics: diagnostics
            )
        }

        let data = try readFile(recordsURL)
        var offset = 0
        var records: [DocumentRecoveryRecord] = []
        var previousDocumentVersion = checkpoint?.persistedDocumentVersion ?? 0
        var previousClientSequence = checkpoint?.persistedClientSequence ?? 0
        var skippedPersistedRecord = false
        while offset < data.count {
            let frameStart = offset
            do {
                let decoded = try DocumentMessages.decodeDelimitedRecord(data.subdata(in: offset..<data.count))
                offset += decoded.consumedBytes
                let record = decoded.value
                guard record.documentID == documentID else {
                    diagnostics.append(.corruptRecord(byteOffset: UInt64(frameStart)))
                    break
                }
                if let checkpoint,
                   record.documentVersion <= checkpoint.persistedDocumentVersion,
                   record.clientSequence <= checkpoint.persistedClientSequence {
                    skippedPersistedRecord = true
                    continue
                }
                guard record.documentVersion > previousDocumentVersion,
                      record.clientSequence > previousClientSequence
                else {
                    diagnostics.append(.corruptRecord(byteOffset: UInt64(frameStart)))
                    break
                }
                records.append(record)
                previousDocumentVersion = record.documentVersion
                previousClientSequence = record.clientSequence
            } catch DocumentDelimitedError.truncated {
                diagnostics.append(.truncatedTail(byteOffset: UInt64(frameStart)))
                break
            } catch {
                diagnostics.append(.corruptRecord(byteOffset: UInt64(frameStart)))
                break
            }
        }
        if skippedPersistedRecord { diagnostics.append(.compactionDeferred) }
        return DocumentRecoveryResult(
            checkpoint: checkpoint,
            records: records,
            diagnostics: diagnostics
        )
    }

    private func publishAtomically(_ data: Data, to destination: URL) throws {
        let temporary = rootURL.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard fd >= 0 else { throw Self.posixError(errno) }
        var renamed = false
        defer {
            close(fd)
            if !renamed { try? FileManager.default.removeItem(at: temporary) }
        }
        guard fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw Self.posixError(errno)
        }
        try Self.writeAll(data, descriptor: fd)
        try Self.synchronize(fd)
        guard rename(temporary.path, destination.path) == 0 else {
            throw Self.posixError(errno)
        }
        renamed = true
        let rootFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Self.posixError(errno) }
        defer { close(rootFD) }
        try Self.synchronize(rootFD)
    }

    private func readFile(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posixError(errno) }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw Self.posixError(errno) }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw Self.posixError(EINVAL)
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Self.posixError(errno) }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func fileExists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    private func onQueue<Result: Sendable>(
        _ body: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Swift.Result { try body() }) }
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError(count == 0 ? EIO : errno) }
                offset += count
            }
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while true {
            if fsync(descriptor) == 0 { return }
            if errno == EINTR { continue }
            throw posixError(errno)
        }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func injectedError(_ operation: String) -> NSError {
        NSError(domain: "CockpitDocumentRecoveryInjected", code: Int(EIO), userInfo: ["operation": operation])
    }
}

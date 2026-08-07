import CryptoKit
import Foundation
import CockpitTypes

public struct DiskFingerprint: Hashable, Codable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64
    public let byteCount: UInt64
    public let modificationTimeSeconds: Int64
    public let modificationTimeNanoseconds: UInt32
    public let contentSHA256: CockpitTypes.SHA256Digest

    public init(
        deviceID: UInt64,
        inode: UInt64,
        byteCount: UInt64,
        modificationTimeSeconds: Int64,
        modificationTimeNanoseconds: UInt32,
        contentSHA256: CockpitTypes.SHA256Digest
    ) {
        precondition(modificationTimeNanoseconds < 1_000_000_000)
        self.deviceID = deviceID
        self.inode = inode
        self.byteCount = byteCount
        self.modificationTimeSeconds = modificationTimeSeconds
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.contentSHA256 = contentSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nanoseconds = try container.decode(UInt32.self, forKey: .modificationTimeNanoseconds)
        guard nanoseconds < 1_000_000_000 else {
            throw DecodingError.dataCorruptedError(
                forKey: .modificationTimeNanoseconds,
                in: container,
                debugDescription: "invalid modification time nanoseconds"
            )
        }
        self.init(
            deviceID: try container.decode(UInt64.self, forKey: .deviceID),
            inode: try container.decode(UInt64.self, forKey: .inode),
            byteCount: try container.decode(UInt64.self, forKey: .byteCount),
            modificationTimeSeconds: try container.decode(Int64.self, forKey: .modificationTimeSeconds),
            modificationTimeNanoseconds: nanoseconds,
            contentSHA256: try container.decode(SHA256Digest.self, forKey: .contentSHA256)
        )
    }
}

public struct DocumentRecoveryRecord: Hashable, Sendable {
    public let documentID: DocumentID
    public let documentVersion: UInt64
    public let clientSequence: UInt64
    public let recordSHA256: CockpitTypes.SHA256Digest
    public let utf8EditPayload: Data

    public init(
        documentID: DocumentID,
        documentVersion: UInt64,
        clientSequence: UInt64,
        utf8EditPayload: Data
    ) throws {
        guard documentVersion > 0, clientSequence > 0,
              validEditPayload(utf8EditPayload)
        else { throw ProtocolMappingError.invalidValue("document_recovery_record") }
        self.documentID = documentID
        self.documentVersion = documentVersion
        self.clientSequence = clientSequence
        self.utf8EditPayload = utf8EditPayload
        self.recordSHA256 = try recoveryRecordDigest(
            documentID: documentID,
            documentVersion: documentVersion,
            clientSequence: clientSequence,
            payload: utf8EditPayload
        )
    }
}

public struct DocumentRecoveryCheckpoint: Hashable, Sendable {
    public let documentID: DocumentID
    public let persistedDocumentVersion: UInt64
    public let persistedClientSequence: UInt64
    public let diskFingerprint: DiskFingerprint
    public let checkpointSHA256: CockpitTypes.SHA256Digest

    public init(
        documentID: DocumentID,
        persistedDocumentVersion: UInt64,
        persistedClientSequence: UInt64,
        diskFingerprint: DiskFingerprint
    ) throws {
        guard persistedDocumentVersion > 0, persistedClientSequence > 0,
              diskFingerprint.modificationTimeNanoseconds < 1_000_000_000
        else { throw ProtocolMappingError.invalidValue("document_recovery_checkpoint") }
        self.documentID = documentID
        self.persistedDocumentVersion = persistedDocumentVersion
        self.persistedClientSequence = persistedClientSequence
        self.diskFingerprint = diskFingerprint
        self.checkpointSHA256 = try recoveryCheckpointDigest(
            documentID: documentID,
            persistedDocumentVersion: persistedDocumentVersion,
            persistedClientSequence: persistedClientSequence,
            diskFingerprint: diskFingerprint
        )
    }
}

public struct DelimitedDocumentValue<Value: Sendable>: Sendable {
    public let value: Value
    public let consumedBytes: Int
}

public enum DocumentDelimitedError: Error, Equatable, Sendable {
    case truncated
    case malformed
}

public enum DocumentMessages {
    public static func encode(_ value: DocumentID) -> String {
        value.description
    }

    public static func decode(_ value: String) throws -> DocumentID {
        try decodeID(value, field: "document_id")
    }

    public static func encode(_ value: DocumentRecoveryRecord) throws -> CPDocumentRecoveryRecord {
        var message = CPDocumentRecoveryRecord()
        message.magic = recoveryMagic
        message.formatVersion = recoveryFormatVersion
        message.documentID = value.documentID.description
        message.documentVersion = value.documentVersion
        message.clientSequence = value.clientSequence
        message.recordSha256 = value.recordSHA256.bytes
        message.utf8EditPayload = value.utf8EditPayload
        return message
    }

    public static func decode(_ message: CPDocumentRecoveryRecord) throws -> DocumentRecoveryRecord {
        try rejectUnknownFields(message.unknownFields.data, field: "document_recovery_record")
        guard message.magic == recoveryMagic,
              message.formatVersion == recoveryFormatVersion,
              message.documentVersion > 0,
              message.clientSequence > 0,
              message.recordSha256.count == 32,
              validEditPayload(message.utf8EditPayload)
        else { throw ProtocolMappingError.invalidValue("document_recovery_record") }
        let documentID = try canonicalDocumentID(message.documentID)
        let value = try DocumentRecoveryRecord(
            documentID: documentID,
            documentVersion: message.documentVersion,
            clientSequence: message.clientSequence,
            utf8EditPayload: message.utf8EditPayload
        )
        guard value.recordSHA256.bytes == message.recordSha256 else {
            throw ProtocolMappingError.invalidValue("document_recovery_record.record_sha256")
        }
        return value
    }

    public static func encode(
        _ value: DocumentRecoveryCheckpoint
    ) throws -> CPDocumentRecoveryCheckpoint {
        var message = CPDocumentRecoveryCheckpoint()
        message.magic = recoveryMagic
        message.formatVersion = recoveryFormatVersion
        message.documentID = value.documentID.description
        message.persistedDocumentVersion = value.persistedDocumentVersion
        message.persistedClientSequence = value.persistedClientSequence
        message.deviceID = value.diskFingerprint.deviceID
        message.inode = value.diskFingerprint.inode
        message.byteCount = value.diskFingerprint.byteCount
        message.modificationTimeSeconds = value.diskFingerprint.modificationTimeSeconds
        message.modificationTimeNanoseconds = value.diskFingerprint.modificationTimeNanoseconds
        message.contentSha256 = value.diskFingerprint.contentSHA256.bytes
        message.checkpointSha256 = value.checkpointSHA256.bytes
        return message
    }

    public static func decode(
        _ message: CPDocumentRecoveryCheckpoint
    ) throws -> DocumentRecoveryCheckpoint {
        try rejectUnknownFields(message.unknownFields.data, field: "document_recovery_checkpoint")
        guard message.magic == recoveryMagic,
              message.formatVersion == recoveryFormatVersion,
              message.persistedDocumentVersion > 0,
              message.persistedClientSequence > 0,
              message.modificationTimeNanoseconds < 1_000_000_000,
              message.contentSha256.count == 32,
              message.checkpointSha256.count == 32
        else { throw ProtocolMappingError.invalidValue("document_recovery_checkpoint") }
        let fingerprint = DiskFingerprint(
            deviceID: message.deviceID,
            inode: message.inode,
            byteCount: message.byteCount,
            modificationTimeSeconds: message.modificationTimeSeconds,
            modificationTimeNanoseconds: message.modificationTimeNanoseconds,
            contentSHA256: try digest(message.contentSha256, field: "content_sha256")
        )
        let value = try DocumentRecoveryCheckpoint(
            documentID: canonicalDocumentID(message.documentID),
            persistedDocumentVersion: message.persistedDocumentVersion,
            persistedClientSequence: message.persistedClientSequence,
            diskFingerprint: fingerprint
        )
        guard value.checkpointSHA256.bytes == message.checkpointSha256 else {
            throw ProtocolMappingError.invalidValue("document_recovery_checkpoint.checkpoint_sha256")
        }
        return value
    }

    public static func encodeDelimited(_ value: DocumentRecoveryRecord) throws -> Data {
        try frame(encode(value).serializedData())
    }

    public static func encodeDelimited(_ value: DocumentRecoveryCheckpoint) throws -> Data {
        try frame(encode(value).serializedData())
    }

    public static func decodeDelimitedRecord(
        _ data: Data
    ) throws -> DelimitedDocumentValue<DocumentRecoveryRecord> {
        let body = try unframe(data)
        let message: CPDocumentRecoveryRecord
        do { message = try CPDocumentRecoveryRecord(serializedBytes: body.body) }
        catch { throw DocumentDelimitedError.malformed }
        do {
            return DelimitedDocumentValue(value: try decode(message), consumedBytes: body.consumed)
        } catch let error as ProtocolMappingError {
            throw error
        } catch {
            throw DocumentDelimitedError.malformed
        }
    }

    public static func decodeDelimitedCheckpoint(
        _ data: Data
    ) throws -> DelimitedDocumentValue<DocumentRecoveryCheckpoint> {
        let body = try unframe(data)
        let message: CPDocumentRecoveryCheckpoint
        do { message = try CPDocumentRecoveryCheckpoint(serializedBytes: body.body) }
        catch { throw DocumentDelimitedError.malformed }
        do {
            return DelimitedDocumentValue(value: try decode(message), consumedBytes: body.consumed)
        } catch let error as ProtocolMappingError {
            throw error
        } catch {
            throw DocumentDelimitedError.malformed
        }
    }
}

private let recoveryMagic = Data("CKDR".utf8)
private let recoveryFormatVersion: UInt32 = 1

private func validEditPayload(_ data: Data) -> Bool {
    !data.isEmpty && !data.contains(0) && String(data: data, encoding: .utf8) != nil
}

private func canonicalDocumentID(_ value: String) throws -> DocumentID {
    let result: DocumentID = try decodeID(value, field: "document_id")
    guard value == result.description else {
        throw ProtocolMappingError.invalidIdentifier("document_id")
    }
    return result
}

private func digest(_ data: Data, field: String) throws -> CockpitTypes.SHA256Digest {
    do { return try CockpitTypes.SHA256Digest(validating: data) }
    catch { throw ProtocolMappingError.invalidValue(field) }
}

private func recoveryRecordDigest(
    documentID: DocumentID,
    documentVersion: UInt64,
    clientSequence: UInt64,
    payload: Data
) throws -> CockpitTypes.SHA256Digest {
    var data = Data("CKDR-RECORD\0".utf8)
    data.appendBigEndian(recoveryFormatVersion)
    data.append(uuidBytes(documentID.rawValue))
    data.appendBigEndian(documentVersion)
    data.appendBigEndian(clientSequence)
    data.appendBigEndian(UInt64(payload.count))
    data.append(payload)
    return try CockpitTypes.SHA256Digest(validating: Data(SHA256.hash(data: data)))
}

private func recoveryCheckpointDigest(
    documentID: DocumentID,
    persistedDocumentVersion: UInt64,
    persistedClientSequence: UInt64,
    diskFingerprint: DiskFingerprint
) throws -> CockpitTypes.SHA256Digest {
    var data = Data("CKDR-CHECKPOINT\0".utf8)
    data.appendBigEndian(recoveryFormatVersion)
    data.append(uuidBytes(documentID.rawValue))
    data.appendBigEndian(persistedDocumentVersion)
    data.appendBigEndian(persistedClientSequence)
    data.appendBigEndian(diskFingerprint.deviceID)
    data.appendBigEndian(diskFingerprint.inode)
    data.appendBigEndian(diskFingerprint.byteCount)
    data.appendBigEndian(UInt64(bitPattern: diskFingerprint.modificationTimeSeconds))
    data.appendBigEndian(diskFingerprint.modificationTimeNanoseconds)
    data.append(diskFingerprint.contentSHA256.bytes)
    return try CockpitTypes.SHA256Digest(validating: Data(SHA256.hash(data: data)))
}

private func uuidBytes(_ value: UUID) -> Data {
    var uuid = value.uuid
    return withUnsafeBytes(of: &uuid) { Data($0) }
}

private func frame(_ body: Data) throws -> Data {
    var value = UInt64(body.count)
    var framed = Data()
    repeat {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        framed.append(byte)
    } while value != 0
    framed.append(body)
    return framed
}

private func unframe(_ data: Data) throws -> (body: Data, consumed: Int) {
    var length: UInt64 = 0
    var shift: UInt64 = 0
    var prefixCount = 0
    for byte in data.prefix(10) {
        let payload = UInt64(byte & 0x7F)
        guard shift < 64, payload <= (UInt64.max >> shift) else {
            throw DocumentDelimitedError.malformed
        }
        length |= payload << shift
        prefixCount += 1
        if byte & 0x80 == 0 {
            if prefixCount > 1, payload == 0 { throw DocumentDelimitedError.malformed }
            guard length <= UInt64(Int.max) else { throw DocumentDelimitedError.malformed }
            guard length <= UInt64(data.count - prefixCount) else {
                throw DocumentDelimitedError.truncated
            }
            let end = prefixCount + Int(length)
            return (data.subdata(in: prefixCount..<end), end)
        }
        shift += 7
    }
    if data.count < 10 { throw DocumentDelimitedError.truncated }
    throw DocumentDelimitedError.malformed
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}

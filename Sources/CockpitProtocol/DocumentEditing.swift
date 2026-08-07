import Foundation
import CockpitTypes

public let documentJavaScriptMaximum: UInt64 = 9_007_199_254_740_991

public enum DocumentDirtyState: String, Codable, Hashable, Sendable {
    case clean
    case dirty
    case conflict
    case missing
}

public enum DocumentMaintenanceState: String, Codable, Hashable, Sendable {
    case truncatedRecoveryTail
    case corruptRecoveryRecord
    case compactionDeferred
}

public enum DocumentProtocolError: Error, Hashable, Sendable {
    case invalidValue
    case unknownFields
    case invalidLease
    case leaseHeld
    case baseVersionMismatch(expected: UInt64, actual: UInt64)
    case sequenceGap(expected: UInt64, actual: UInt64)
    case duplicateMismatch
    case staleSequence
    case recoveryRequired
    case resynchronizing
    case readOnly
    case fileMissing
}

public struct UTF16TextEdit: Hashable, Sendable {
    public let offset: UInt64
    public let length: UInt64
    public let replacement: String

    public init(validatingOffset offset: UInt64, length: UInt64, replacement: String) throws {
        guard offset <= documentJavaScriptMaximum,
              length <= documentJavaScriptMaximum,
              offset <= documentJavaScriptMaximum - length,
              !replacement.contains("\r"),
              !replacement.contains("\0")
        else { throw DocumentProtocolError.invalidValue }
        self.offset = offset
        self.length = length
        self.replacement = replacement
    }
}

public struct EditLease: Hashable, Sendable {
    public let id: EditLeaseID
    public let documentID: DocumentID
    public let clientInstanceID: ClientInstanceID

    public init(
        validatingID id: EditLeaseID,
        documentID: DocumentID,
        clientInstanceID: ClientInstanceID
    ) throws {
        self.id = id
        self.documentID = documentID
        self.clientInstanceID = clientInstanceID
    }
}

public struct EditTransaction: Hashable, Sendable {
    public let documentID: DocumentID
    public let editLeaseID: EditLeaseID
    public let baseVersion: UInt64
    public let clientSequence: UInt64
    public let changes: [UTF16TextEdit]

    public init(
        validatingDocumentID documentID: DocumentID,
        editLeaseID: EditLeaseID,
        baseVersion: UInt64,
        clientSequence: UInt64,
        changes: [UTF16TextEdit]
    ) throws {
        guard baseVersion <= documentJavaScriptMaximum,
              clientSequence > 0,
              clientSequence <= documentJavaScriptMaximum,
              !changes.isEmpty
        else { throw DocumentProtocolError.invalidValue }
        var previousOffset: UInt64?
        var previousEnd: UInt64?
        for change in changes {
            if let previousOffset, change.offset <= previousOffset {
                throw DocumentProtocolError.invalidValue
            }
            if let previousEnd, change.offset < previousEnd {
                throw DocumentProtocolError.invalidValue
            }
            previousOffset = change.offset
            previousEnd = change.offset + change.length
        }
        self.documentID = documentID
        self.editLeaseID = editLeaseID
        self.baseVersion = baseVersion
        self.clientSequence = clientSequence
        self.changes = changes
    }
}

public struct EditAcknowledgement: Hashable, Sendable {
    public let documentID: DocumentID
    public let clientSequence: UInt64
    public let documentVersion: UInt64

    public init(
        validatingDocumentID documentID: DocumentID,
        clientSequence: UInt64,
        documentVersion: UInt64
    ) throws {
        guard clientSequence > 0,
              clientSequence <= documentJavaScriptMaximum,
              documentVersion <= documentJavaScriptMaximum,
              clientSequence <= documentVersion
        else { throw DocumentProtocolError.invalidValue }
        self.documentID = documentID
        self.clientSequence = clientSequence
        self.documentVersion = documentVersion
    }
}

public struct DocumentSnapshot: Hashable, Sendable {
    public let documentID: DocumentID
    public let environmentID: EnvironmentID
    public let relativePath: RelativePath
    public let text: String
    public let documentVersion: UInt64
    public let persistedVersion: UInt64
    public let lastAcceptedClientSequence: UInt64
    public let dirtyState: DocumentDirtyState
    public let observedDiskFingerprint: DiskFingerprint?
    public let currentLease: EditLease?
    public let maintenance: [DocumentMaintenanceState]

    public init(
        validatingDocumentID documentID: DocumentID,
        environmentID: EnvironmentID,
        relativePath: RelativePath,
        text: String,
        documentVersion: UInt64,
        persistedVersion: UInt64,
        lastAcceptedClientSequence: UInt64,
        dirtyState: DocumentDirtyState,
        observedDiskFingerprint: DiskFingerprint?,
        currentLease: EditLease?,
        maintenance: [DocumentMaintenanceState]
    ) throws {
        guard documentVersion <= documentJavaScriptMaximum,
              persistedVersion <= documentVersion,
              lastAcceptedClientSequence <= documentJavaScriptMaximum,
              lastAcceptedClientSequence <= documentVersion,
              !text.contains("\r"),
              !text.contains("\0"),
              currentLease?.documentID == documentID || currentLease == nil
        else { throw DocumentProtocolError.invalidValue }
        self.documentID = documentID
        self.environmentID = environmentID
        self.relativePath = relativePath
        self.text = text
        self.documentVersion = documentVersion
        self.persistedVersion = persistedVersion
        self.lastAcceptedClientSequence = lastAcceptedClientSequence
        self.dirtyState = dirtyState
        self.observedDiskFingerprint = observedDiskFingerprint
        self.currentLease = currentLease
        self.maintenance = maintenance
    }
}

public enum DocumentEditing {
    public static func encodeRecoveryPayload(_ transaction: EditTransaction) throws -> Data {
        let wire = TransactionWire(transaction)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(wire)
    }

    public static func decodeRecoveryPayload(_ data: Data) throws -> EditTransaction {
        guard !data.isEmpty, !data.contains(0), String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(TransactionWire.CodingKeys.allCases.map(\.rawValue)),
              let rawChanges = object["changes"] as? [[String: Any]],
              rawChanges.allSatisfy({
                  Set($0.keys) == Set(ChangeWire.CodingKeys.allCases.map(\.rawValue))
              })
        else { throw DocumentProtocolError.unknownFields }
        let wire: TransactionWire
        do { wire = try JSONDecoder().decode(TransactionWire.self, from: data) }
        catch { throw DocumentProtocolError.invalidValue }
        let transaction = try wire.transaction()
        guard try encodeRecoveryPayload(transaction) == data else {
            throw DocumentProtocolError.invalidValue
        }
        return transaction
    }
}

private struct TransactionWire: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case baseVersion, changes, clientSequence, documentID, editLeaseID
    }

    let baseVersion: UInt64
    let changes: [ChangeWire]
    let clientSequence: UInt64
    let documentID: String
    let editLeaseID: String

    init(_ transaction: EditTransaction) {
        baseVersion = transaction.baseVersion
        changes = transaction.changes.map(ChangeWire.init)
        clientSequence = transaction.clientSequence
        documentID = transaction.documentID.description
        editLeaseID = transaction.editLeaseID.description
    }

    func transaction() throws -> EditTransaction {
        guard let documentUUID = UUID(uuidString: documentID),
              let leaseUUID = UUID(uuidString: editLeaseID),
              DocumentID(documentUUID).description == documentID,
              EditLeaseID(leaseUUID).description == editLeaseID
        else { throw DocumentProtocolError.invalidValue }
        return try EditTransaction(
            validatingDocumentID: DocumentID(documentUUID),
            editLeaseID: EditLeaseID(leaseUUID),
            baseVersion: baseVersion,
            clientSequence: clientSequence,
            changes: try changes.map { try $0.edit() }
        )
    }
}

private struct ChangeWire: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable { case length, offset, replacement }

    let length: UInt64
    let offset: UInt64
    let replacement: String

    init(_ edit: UTF16TextEdit) {
        length = edit.length
        offset = edit.offset
        replacement = edit.replacement
    }

    func edit() throws -> UTF16TextEdit {
        try UTF16TextEdit(validatingOffset: offset, length: length, replacement: replacement)
    }
}

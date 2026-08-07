import Foundation
import CockpitHostCore
import CockpitProtocol
import CockpitTypes

public struct DocumentCommitRecoveryRequiredError: Error, Sendable {
    public let committedAcknowledgement: EditAcknowledgement

    public init(committedAcknowledgement: EditAcknowledgement) {
        self.committedAcknowledgement = committedAcknowledgement
    }
}

public enum ExternalDocumentChange: Sendable {
    case present(DocumentFileSnapshot)
    case missing
}

public actor DocumentActor {
    private var metadata: DocumentMetadata
    private let documentServing: any DocumentServing
    private let recoveryLog: DocumentRecoveryLog
    private let metadataRepository: any DocumentMetadataRepository
    private var buffer: DocumentTextBuffer
    private var signature: UTF8Signature
    private var observedFingerprint: DiskFingerprint?
    private var lastAcceptedClientSequence: UInt64
    private var currentLease: EditLease?
    private var maintenance: [DocumentMaintenanceState]
    private var lastTransaction: EditTransaction?
    private var lastAcknowledgement: EditAcknowledgement?
    private var recoveryRequired = false
    private var operationBusy = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    private init(
        metadata: DocumentMetadata,
        documentServing: any DocumentServing,
        recoveryLog: DocumentRecoveryLog,
        metadataRepository: any DocumentMetadataRepository,
        buffer: DocumentTextBuffer,
        signature: UTF8Signature,
        observedFingerprint: DiskFingerprint?,
        lastAcceptedClientSequence: UInt64,
        maintenance: [DocumentMaintenanceState],
        lastTransaction: EditTransaction?,
        lastAcknowledgement: EditAcknowledgement?,
        recoveryRequired: Bool
    ) {
        self.metadata = metadata
        self.documentServing = documentServing
        self.recoveryLog = recoveryLog
        self.metadataRepository = metadataRepository
        self.buffer = buffer
        self.signature = signature
        self.observedFingerprint = observedFingerprint
        self.lastAcceptedClientSequence = lastAcceptedClientSequence
        self.currentLease = nil
        self.maintenance = maintenance
        self.lastTransaction = lastTransaction
        self.lastAcknowledgement = lastAcknowledgement
        self.recoveryRequired = recoveryRequired
    }

    public static func open(
        metadata: DocumentMetadata,
        documentServing: any DocumentServing,
        recoveryLog: DocumentRecoveryLog,
        metadataRepository: any DocumentMetadataRepository
    ) async throws -> DocumentActor {
        let recovered = try await recoveryLog.recover()
        let disk: DocumentFileSnapshot?
        do {
            disk = try await documentServing.readDocument(at: metadata.relativePath)
        } catch {
            guard Self.isMissingFileError(error) else { throw error }
            disk = nil
        }
        var maintenance = recovered.diagnostics.map(Self.maintenanceState)
        var decoded: DecodedDocument
        var version: UInt64
        var persistedVersion: UInt64
        var sequence: UInt64
        var dirty: DocumentDirtyState
        var lastTransaction: EditTransaction?
        var lastAcknowledgement: EditAcknowledgement?
        var didReplayRecord = false
        var encounteredRecoveryCorruption = recovered.diagnostics.contains { diagnostic in
            switch diagnostic {
            case .truncatedTail, .corruptRecord: true
            case .compactionDeferred: false
            }
        }

        if let checkpoint = recovered.checkpoint {
            decoded = try DocumentCodec.decode(DocumentFileSnapshot(
                data: checkpoint.persistedDocumentBytes,
                fingerprint: checkpoint.diskFingerprint
            ))
            var restoredBuffer = try DocumentTextBuffer(
                validatingText: decoded.text,
                lineEndings: decoded.lineEndings
            )
            version = checkpoint.persistedDocumentVersion
            persistedVersion = checkpoint.persistedDocumentVersion
            sequence = checkpoint.persistedClientSequence
            for record in recovered.records {
                do {
                    let transaction = try DocumentEditing.decodeRecoveryPayload(record.utf8EditPayload)
                    guard transaction.documentID == metadata.documentID,
                          transaction.baseVersion == version,
                          transaction.clientSequence == sequence + 1,
                          record.documentVersion == version + 1,
                          record.clientSequence == transaction.clientSequence
                    else { throw DocumentProtocolError.recoveryRequired }
                    restoredBuffer = try applying(transaction.changes, to: restoredBuffer)
                    version = record.documentVersion
                    sequence = record.clientSequence
                    lastTransaction = transaction
                    lastAcknowledgement = try EditAcknowledgement(
                        validatingDocumentID: metadata.documentID,
                        clientSequence: sequence,
                        documentVersion: version
                    )
                    didReplayRecord = true
                } catch {
                    maintenance.append(.corruptRecoveryRecord)
                    encounteredRecoveryCorruption = true
                    break
                }
            }
            decoded = DecodedDocument(
                text: restoredBuffer.text,
                signature: decoded.signature,
                lineEndings: restoredBuffer.lineEndings,
                diskFingerprint: checkpoint.diskFingerprint
            )
            if let disk {
                if disk.fingerprint != checkpoint.diskFingerprint {
                    dirty = .conflict
                } else if didReplayRecord {
                    dirty = .dirty
                } else if checkpoint.persistedDocumentVersion == metadata.documentVersion,
                          metadata.persistedVersion < checkpoint.persistedDocumentVersion,
                          metadata.dirtyState != .clean {
                    dirty = .conflict
                } else {
                    dirty = .clean
                }
            } else {
                dirty = .missing
            }
        } else {
            guard recovered.records.isEmpty,
                  metadata.documentVersion == 0,
                  metadata.persistedVersion == 0,
                  metadata.dirtyState == .clean
            else { throw DocumentProtocolError.recoveryRequired }
            guard let disk else { throw DocumentProtocolError.fileMissing }
            decoded = try DocumentCodec.decode(disk)
            version = 0
            persistedVersion = 0
            sequence = 0
            dirty = .clean
            if let diagnostic = try await recoveryLog.checkpoint(
                persistedDocumentVersion: 0,
                persistedClientSequence: 0,
                diskFingerprint: disk.fingerprint,
                persistedDocumentBytes: disk.data
            ) {
                maintenance.append(Self.maintenanceState(diagnostic))
            }
        }

        let repaired = try DocumentMetadata(
            validatingDocumentID: metadata.documentID,
            environmentID: metadata.environmentID,
            relativePath: metadata.relativePath,
            documentVersion: version,
            persistedVersion: persistedVersion,
            dirtyState: dirty,
            editLeaseID: nil
        )
        try await metadataRepository.repairDocumentMetadata(repaired)
        return try DocumentActor(
            metadata: repaired,
            documentServing: documentServing,
            recoveryLog: recoveryLog,
            metadataRepository: metadataRepository,
            buffer: DocumentTextBuffer(validatingText: decoded.text, lineEndings: decoded.lineEndings),
            signature: decoded.signature,
            observedFingerprint: disk?.fingerprint,
            lastAcceptedClientSequence: sequence,
            maintenance: Array(Set(maintenance)).sorted { $0.rawValue < $1.rawValue },
            lastTransaction: lastTransaction,
            lastAcknowledgement: lastAcknowledgement,
            recoveryRequired: encounteredRecoveryCorruption
        )
    }

    public func snapshot() -> DocumentSnapshot {
        try! DocumentSnapshot(
            validatingDocumentID: metadata.documentID,
            environmentID: metadata.environmentID,
            relativePath: metadata.relativePath,
            text: buffer.text,
            documentVersion: metadata.documentVersion,
            persistedVersion: metadata.persistedVersion,
            lastAcceptedClientSequence: lastAcceptedClientSequence,
            dirtyState: metadata.dirtyState,
            observedDiskFingerprint: observedFingerprint,
            currentLease: currentLease,
            maintenance: maintenance
        )
    }

    public func acquireEditLease(client: ClientInstanceID) async throws -> EditLease {
        await enterOperation()
        defer { leaveOperation() }
        try requireOperational()
        if let currentLease {
            guard currentLease.clientInstanceID == client else { throw DocumentProtocolError.leaseHeld }
            return currentLease
        }
        let lease = try EditLease(
            validatingID: EditLeaseID(),
            documentID: metadata.documentID,
            clientInstanceID: client
        )
        let replacement = try replacingMetadata(editLeaseID: lease.id)
        try await metadataRepository.compareAndSetDocumentMetadata(
            replacement,
            expectedDocumentVersion: metadata.documentVersion,
            expectedEditLeaseID: nil
        )
        metadata = replacement
        currentLease = lease
        return lease
    }

    public func transferEditLease(from leaseID: EditLeaseID, to client: ClientInstanceID) async throws -> EditLease {
        await enterOperation()
        defer { leaveOperation() }
        return try await transferEditLeaseLocked(from: leaseID, to: client)
    }

    public func apply(_ transaction: EditTransaction) async throws -> EditAcknowledgement {
        await enterOperation()
        defer { leaveOperation() }
        return try await applyLocked(transaction)
    }

    public func flush(through clientSequence: UInt64) async throws -> UInt64 {
        await enterOperation()
        defer { leaveOperation() }
        return try flushLocked(through: clientSequence)
    }

    public func save(expectedFingerprint: DiskFingerprint) async throws -> DocumentSnapshot {
        await enterOperation()
        defer { leaveOperation() }
        return try await saveLocked(expectedFingerprint: expectedFingerprint)
    }

    public func discard() async throws -> DocumentSnapshot {
        await enterOperation()
        defer { leaveOperation() }
        return try await discardLocked()
    }

    public func transferEditLease(
        from leaseID: EditLeaseID,
        to client: ClientInstanceID,
        authorizedClient: ClientInstanceID
    ) async throws -> EditLease {
        await enterOperation()
        defer { leaveOperation() }
        try requireAuthorizedLeaseOwner(authorizedClient)
        return try await transferEditLeaseLocked(from: leaseID, to: client)
    }

    public func apply(
        _ transaction: EditTransaction,
        authorizedClient: ClientInstanceID
    ) async throws -> EditAcknowledgement {
        await enterOperation()
        defer { leaveOperation() }
        try requireAuthorizedLeaseOwner(authorizedClient)
        return try await applyLocked(transaction)
    }

    public func flush(
        through clientSequence: UInt64,
        authorizedClient: ClientInstanceID
    ) async throws -> UInt64 {
        await enterOperation()
        defer { leaveOperation() }
        try requireAuthorizedLeaseOwner(authorizedClient)
        return try flushLocked(through: clientSequence)
    }

    public func save(
        expectedFingerprint: DiskFingerprint,
        authorizedClient: ClientInstanceID
    ) async throws -> DocumentSnapshot {
        await enterOperation()
        defer { leaveOperation() }
        try requireAuthorizedLeaseOwner(authorizedClient)
        return try await saveLocked(expectedFingerprint: expectedFingerprint)
    }

    public func discard(
        authorizedClient: ClientInstanceID
    ) async throws -> DocumentSnapshot {
        await enterOperation()
        defer { leaveOperation() }
        try requireAuthorizedLeaseOwner(authorizedClient)
        return try await discardLocked()
    }

    public func handleExternalChange(_ change: ExternalDocumentChange) async throws -> DocumentSnapshot {
        await enterOperation()
        defer { leaveOperation() }
        try requireOperational()
        do {
            switch change {
            case .missing:
                if observedFingerprint == nil, metadata.dirtyState == .missing { return snapshot() }
                let old = metadata
                let replacement = try replacingMetadata(dirtyState: .missing)
                try await metadataRepository.compareAndSetDocumentMetadata(
                    replacement,
                    expectedDocumentVersion: old.documentVersion,
                    expectedEditLeaseID: old.editLeaseID
                )
                observedFingerprint = nil
                metadata = replacement
            case let .present(file):
                if file.fingerprint == observedFingerprint { return snapshot() }
                let reloadsMissingClean = metadata.dirtyState == .missing
                    && metadata.documentVersion == metadata.persistedVersion
                if metadata.dirtyState == .clean || reloadsMissingClean {
                    let decoded = try DocumentCodec.decode(file)
                    let old = metadata
                    let nextVersion = metadata.documentVersion + 1
                    if let diagnostic = try await recoveryLog.checkpoint(
                        persistedDocumentVersion: nextVersion,
                        persistedClientSequence: lastAcceptedClientSequence,
                        diskFingerprint: file.fingerprint,
                        persistedDocumentBytes: file.data
                    ) { addMaintenance(Self.maintenanceState(diagnostic)) }
                    let replacementBuffer = try DocumentTextBuffer(
                        validatingText: decoded.text,
                        lineEndings: decoded.lineEndings
                    )
                    let replacement = try replacingMetadata(
                        documentVersion: nextVersion,
                        persistedVersion: nextVersion,
                        dirtyState: .clean
                    )
                    try await metadataRepository.compareAndSetDocumentMetadata(
                        replacement,
                        expectedDocumentVersion: old.documentVersion,
                        expectedEditLeaseID: old.editLeaseID
                    )
                    buffer = replacementBuffer
                    signature = decoded.signature
                    observedFingerprint = file.fingerprint
                    metadata = replacement
                } else {
                    let old = metadata
                    let replacement = try replacingMetadata(dirtyState: .conflict)
                    try await metadataRepository.compareAndSetDocumentMetadata(
                        replacement,
                        expectedDocumentVersion: old.documentVersion,
                        expectedEditLeaseID: old.editLeaseID
                    )
                    observedFingerprint = file.fingerprint
                    metadata = replacement
                }
            }
            return snapshot()
        } catch {
            recoveryRequired = true
            throw error
        }
    }

    func updateRelativePath(_ path: RelativePath) {
        metadata = try! DocumentMetadata(
            validatingDocumentID: metadata.documentID,
            environmentID: metadata.environmentID,
            relativePath: path,
            documentVersion: metadata.documentVersion,
            persistedVersion: metadata.persistedVersion,
            dirtyState: metadata.dirtyState,
            editLeaseID: metadata.editLeaseID
        )
    }

    private func requireAuthorizedLeaseOwner(_ authorizedClient: ClientInstanceID) throws {
        guard currentLease?.clientInstanceID == authorizedClient else {
            throw DocumentProtocolError.invalidLease
        }
    }

    private func transferEditLeaseLocked(
        from leaseID: EditLeaseID,
        to client: ClientInstanceID
    ) async throws -> EditLease {
        try requireOperational()
        guard currentLease?.id == leaseID else { throw DocumentProtocolError.invalidLease }
        let lease = try EditLease(
            validatingID: EditLeaseID(),
            documentID: metadata.documentID,
            clientInstanceID: client
        )
        let replacement = try replacingMetadata(editLeaseID: lease.id)
        try await metadataRepository.compareAndSetDocumentMetadata(
            replacement,
            expectedDocumentVersion: metadata.documentVersion,
            expectedEditLeaseID: leaseID
        )
        metadata = replacement
        currentLease = lease
        return lease
    }

    private func applyLocked(_ transaction: EditTransaction) async throws -> EditAcknowledgement {
        try requireOperational()
        if transaction.clientSequence == lastAcceptedClientSequence {
            guard transaction == lastTransaction, let lastAcknowledgement else {
                throw DocumentProtocolError.duplicateMismatch
            }
            return lastAcknowledgement
        }
        guard transaction.documentID == metadata.documentID,
              transaction.editLeaseID == currentLease?.id
        else { throw DocumentProtocolError.invalidLease }
        let expectedSequence = lastAcceptedClientSequence + 1
        guard transaction.clientSequence == expectedSequence else {
            if transaction.clientSequence < expectedSequence { throw DocumentProtocolError.staleSequence }
            throw DocumentProtocolError.sequenceGap(expected: expectedSequence, actual: transaction.clientSequence)
        }
        guard transaction.baseVersion == metadata.documentVersion else {
            throw DocumentProtocolError.baseVersionMismatch(
                expected: metadata.documentVersion,
                actual: transaction.baseVersion
            )
        }
        guard metadata.documentVersion < documentJavaScriptMaximum else {
            throw DocumentProtocolError.invalidValue
        }

        let candidate = try Self.applying(transaction.changes, to: buffer)
        let nextVersion = metadata.documentVersion + 1
        let payload = try DocumentEditing.encodeRecoveryPayload(transaction)
        do {
            try await recoveryLog.append(
                documentVersion: nextVersion,
                clientSequence: transaction.clientSequence,
                utf8EditPayload: payload
            )
        } catch {
            recoveryRequired = true
            throw error
        }

        let oldMetadata = metadata
        let acknowledgement = try EditAcknowledgement(
            validatingDocumentID: metadata.documentID,
            clientSequence: transaction.clientSequence,
            documentVersion: nextVersion
        )
        buffer = candidate
        lastAcceptedClientSequence = transaction.clientSequence
        lastTransaction = transaction
        lastAcknowledgement = acknowledgement
        metadata = try replacingMetadata(
            documentVersion: nextVersion,
            dirtyState: .dirty
        )
        do {
            try await metadataRepository.compareAndSetDocumentMetadata(
                metadata,
                expectedDocumentVersion: oldMetadata.documentVersion,
                expectedEditLeaseID: oldMetadata.editLeaseID
            )
        } catch {
            recoveryRequired = true
            throw DocumentCommitRecoveryRequiredError(committedAcknowledgement: acknowledgement)
        }
        return acknowledgement
    }

    private func flushLocked(through clientSequence: UInt64) throws -> UInt64 {
        try requireOperational()
        guard clientSequence <= lastAcceptedClientSequence else {
            throw DocumentProtocolError.sequenceGap(
                expected: lastAcceptedClientSequence + 1,
                actual: clientSequence
            )
        }
        return metadata.documentVersion
    }

    private func saveLocked(expectedFingerprint: DiskFingerprint) async throws -> DocumentSnapshot {
        try requireOperational()
        guard let currentObservedFingerprint = observedFingerprint else {
            throw DocumentProtocolError.fileMissing
        }
        guard currentObservedFingerprint == expectedFingerprint else {
            throw DocumentStorageError.fingerprintMismatch(
                expected: expectedFingerprint,
                actual: currentObservedFingerprint
            )
        }
        let bytes = try DocumentCodec.encode(
            text: buffer.text,
            signature: signature,
            lineEndings: buffer.lineEndings
        )
        let fingerprint: DiskFingerprint
        let diagnostic: DocumentRecoveryDiagnostic?
        do {
            fingerprint = try await documentServing.atomicallyWriteDocument(
                bytes,
                to: metadata.relativePath,
                expectedFingerprint: expectedFingerprint
            )
            diagnostic = try await recoveryLog.checkpoint(
                persistedDocumentVersion: metadata.documentVersion,
                persistedClientSequence: lastAcceptedClientSequence,
                diskFingerprint: fingerprint,
                persistedDocumentBytes: bytes
            )
        } catch {
            recoveryRequired = true
            metadata = try replacingMetadata(dirtyState: .conflict)
            try? await metadataRepository.repairDocumentMetadata(metadata)
            throw error
        }
        let old = metadata
        let replacement = try replacingMetadata(
            persistedVersion: metadata.documentVersion,
            dirtyState: .clean
        )
        do {
            try await metadataRepository.compareAndSetDocumentMetadata(
                replacement,
                expectedDocumentVersion: old.documentVersion,
                expectedEditLeaseID: old.editLeaseID
            )
        } catch {
            recoveryRequired = true
            throw DocumentProtocolError.recoveryRequired
        }
        metadata = replacement
        observedFingerprint = fingerprint
        if let diagnostic { addMaintenance(Self.maintenanceState(diagnostic)) }
        return snapshot()
    }

    private func discardLocked() async throws -> DocumentSnapshot {
        try requireOperational()
        let disk: DocumentFileSnapshot
        do {
            disk = try await documentServing.readDocument(at: metadata.relativePath)
        } catch {
            guard Self.isMissingFileError(error) else { throw error }
            throw DocumentProtocolError.fileMissing
        }
        let decoded = try DocumentCodec.decode(disk)
        guard metadata.documentVersion < documentJavaScriptMaximum else {
            throw DocumentProtocolError.invalidValue
        }
        let nextVersion = metadata.documentVersion + 1
        let diagnostic: DocumentRecoveryDiagnostic?
        do {
            diagnostic = try await recoveryLog.checkpoint(
                persistedDocumentVersion: nextVersion,
                persistedClientSequence: lastAcceptedClientSequence,
                diskFingerprint: disk.fingerprint,
                persistedDocumentBytes: disk.data
            )
        } catch {
            recoveryRequired = true
            throw error
        }
        let old = metadata
        let replacement = try replacingMetadata(
            documentVersion: nextVersion,
            persistedVersion: nextVersion,
            dirtyState: .clean
        )
        let replacementBuffer = try DocumentTextBuffer(
            validatingText: decoded.text,
            lineEndings: decoded.lineEndings
        )
        do {
            try await metadataRepository.compareAndSetDocumentMetadata(
                replacement,
                expectedDocumentVersion: old.documentVersion,
                expectedEditLeaseID: old.editLeaseID
            )
        } catch {
            buffer = replacementBuffer
            signature = decoded.signature
            observedFingerprint = disk.fingerprint
            metadata = replacement
            if let diagnostic { addMaintenance(Self.maintenanceState(diagnostic)) }
            recoveryRequired = true
            throw DocumentProtocolError.recoveryRequired
        }
        buffer = replacementBuffer
        signature = decoded.signature
        observedFingerprint = disk.fingerprint
        metadata = replacement
        if let diagnostic { addMaintenance(Self.maintenanceState(diagnostic)) }
        return snapshot()
    }

    private func replacingMetadata(
        documentVersion: UInt64? = nil,
        persistedVersion: UInt64? = nil,
        dirtyState: DocumentDirtyState? = nil,
        editLeaseID: EditLeaseID?? = nil
    ) throws -> DocumentMetadata {
        try DocumentMetadata(
            validatingDocumentID: metadata.documentID,
            environmentID: metadata.environmentID,
            relativePath: metadata.relativePath,
            documentVersion: documentVersion ?? metadata.documentVersion,
            persistedVersion: persistedVersion ?? metadata.persistedVersion,
            dirtyState: dirtyState ?? metadata.dirtyState,
            editLeaseID: editLeaseID ?? metadata.editLeaseID
        )
    }

    private func requireOperational() throws {
        if recoveryRequired { throw DocumentProtocolError.recoveryRequired }
    }

    private func enterOperation() async {
        if !operationBusy { operationBusy = true; return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func leaveOperation() {
        if operationWaiters.isEmpty { operationBusy = false }
        else { operationWaiters.removeFirst().resume() }
    }

    private func addMaintenance(_ state: DocumentMaintenanceState) {
        if !maintenance.contains(state) { maintenance.append(state) }
    }

    private static func applying(
        _ changes: [UTF16TextEdit],
        to original: DocumentTextBuffer
    ) throws -> DocumentTextBuffer {
        var result = original
        for change in changes.reversed() {
            guard change.offset <= UInt64(Int.max), change.length <= UInt64(Int.max) else {
                throw DocumentProtocolError.invalidValue
            }
            let lower = Int(change.offset)
            let upper = lower + Int(change.length)
            try result.replaceUTF16(range: lower..<upper, with: change.replacement)
        }
        return result
    }

    private static func maintenanceState(_ diagnostic: DocumentRecoveryDiagnostic) -> DocumentMaintenanceState {
        switch diagnostic {
        case .truncatedTail: .truncatedRecoveryTail
        case .corruptRecord: .corruptRecoveryRecord
        case .compactionDeferred: .compactionDeferred
        }
    }

    private static func isMissingFileError(_ error: any Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
            || (value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoSuchFileError)
    }
}

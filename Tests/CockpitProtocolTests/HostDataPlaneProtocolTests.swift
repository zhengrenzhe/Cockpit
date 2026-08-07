import Foundation
import SwiftProtobuf
import Testing
import CockpitProtocol
import CockpitTypes

@Test func hostDataPlaneProtocolUsesTheExistingExactFrameAndFeature() throws {
    let fixture = Data([
        0x43, 0x4B, 0x50, 0x54,
        0x00, 0x01,
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x05,
    ])
    let header = try FrameHeader(decoding: fixture)

    #expect(FrameHeader.encodedLength == 32)
    #expect(FrameHeader.maximumPayloadLength == 16_777_216)
    #expect(header.flags == 0)
    #expect(header.channel == .documentEdits)
    #expect(header.sequence == 1)
    #expect(header.acknowledgement == 0)
    #expect(header.payloadLength == 5)
    #expect(header.encoded() == fixture)
    #expect(ProtocolVersion.current == ProtocolVersion(major: 1, minor: 1))
    #expect(ProtocolFeature.hostDataPlane.rawValue == "host-data-plane")
}

@Test func hostDataPlaneProtocolFreezesEnumNumbersAndEveryOneOfTag() throws {
    let errorCodes: [(CPDataPlaneErrorCode, Int)] = [
        (.unspecified, 0), (.malformedMessage, 1), (.wrongChannel, 2),
        (.sequenceViolation, 3), (.ackViolation, 4), (.unauthorizedPeer, 5),
        (.invalidTicket, 6), (.ticketExpired, 7), (.ticketReplay, 8),
        (.contextMismatch, 9), (.environmentMismatch, 10), (.generationMismatch, 11),
        (.requestIDReuse, 12), (.documentNotOpen, 20), (.documentInvalidValue, 21),
        (.documentInvalidLease, 22), (.documentLeaseHeld, 23),
        (.documentBaseVersionMismatch, 24), (.documentSequenceGap, 25),
        (.documentDuplicateMismatch, 26), (.documentStaleSequence, 27),
        (.documentRecoveryRequired, 28), (.documentResynchronizing, 29),
        (.documentReadOnly, 30), (.documentFileMissing, 31),
        (.documentFingerprintMismatch, 32), (.treeZeroGeneration, 40),
        (.treeSymbolicLink, 41), (.treeRevisionUnavailable, 42),
        (.treeEventSourceUnavailable, 43), (.treeEnumerationFailed, 44),
        (.treeBackpressure, 45), (.requestCancelled, 50), (.internal, 60),
    ]
    #expect(errorCodes.allSatisfy { $0.0.rawValue == $0.1 })
    #expect(CPDocumentDirtyStateValue.clean.rawValue == 1)
    #expect(CPDocumentDirtyStateValue.dirty.rawValue == 2)
    #expect(CPDocumentDirtyStateValue.conflict.rawValue == 3)
    #expect(CPDocumentDirtyStateValue.missing.rawValue == 4)
    #expect(CPDocumentMaintenanceStateValue.truncatedRecoveryTail.rawValue == 1)
    #expect(CPDocumentMaintenanceStateValue.corruptRecoveryRecord.rawValue == 2)
    #expect(CPDocumentMaintenanceStateValue.compactionDeferred.rawValue == 3)
    #expect(CPWorkspaceDirectoryKind.root.rawValue == 1)
    #expect(CPWorkspaceDirectoryKind.relative.rawValue == 2)
    #expect(CPFileTreeEntryKindValue.file.rawValue == 1)
    #expect(CPFileTreeEntryKindValue.directory.rawValue == 2)
    #expect(CPFileTreeEntryKindValue.symbolicLink.rawValue == 3)

    let controlTags = try [
        CPHostDataPlaneControlEnvelope.OneOf_Payload.handshakeRequest(.init()),
        .handshakeResponse(.init()), .authenticate(.init()), .authenticated(.init()), .error(.init()),
    ].map { payload -> [UInt8] in
        var value = CPHostDataPlaneControlEnvelope(); value.payload = payload
        return Array(try value.serializedData())
    }
    #expect(controlTags.map(\.first) == [0x0A, 0x12, 0x1A, 0x22, 0x2A])

    let documentTags = try [
        CPDocumentEnvelope.OneOf_Payload.openRequest(.init()), .snapshotRequest(.init()),
        .acquireLeaseRequest(.init()), .transferLeaseRequest(.init()), .applyRequest(.init()),
        .flushRequest(.init()), .saveRequest(.init()), .discardRequest(.init()),
        .snapshotResult(.init()), .leaseResult(.init()), .acknowledgementResult(.init()),
        .flushResult(.init()), .error(.init()),
    ].map { payload -> [UInt8] in
        var value = CPDocumentEnvelope(); value.payload = payload
        return Array(try value.serializedData())
    }
    #expect(documentTags.map { Array($0.prefix(2)) } == [
        [0x52, 0x00], [0x5A, 0x00], [0x62, 0x00], [0x6A, 0x00],
        [0x72, 0x00], [0x7A, 0x00], [0x82, 0x01], [0x8A, 0x01],
        [0xF2, 0x01], [0xFA, 0x01], [0x82, 0x02], [0x8A, 0x02], [0xC2, 0x02],
    ])

    let treeTags = try [
        CPFileTreeEnvelope.OneOf_Payload.childrenRequest(.init()), .subscribeRequest(.init()),
        .deltaAck(.init()), .cancelRequest(.init()), .snapshotResult(.init()),
        .subscriptionAccepted(.init()), .deltaEvent(.init()), .ackAccepted(.init()),
        .cancelled(.init()), .error(.init()),
    ].map { payload -> [UInt8] in
        var value = CPFileTreeEnvelope(); value.payload = payload
        return Array(try value.serializedData())
    }
    #expect(treeTags.map { Array($0.prefix(2)) } == [
        [0x52, 0x00], [0x5A, 0x00], [0x62, 0x00], [0x6A, 0x00],
        [0xF2, 0x01], [0xFA, 0x01], [0x82, 0x02], [0x8A, 0x02],
        [0x92, 0x02], [0xC2, 0x02],
    ])

    let mutationTags = try [
        CPFileTreeMutationValue.OneOf_Mutation.insert(.init()),
        .remove(.init()), .update(.init()),
    ].map { mutation -> UInt8? in
        var value = CPFileTreeMutationValue(); value.mutation = mutation
        return try value.serializedData().first
    }
    #expect(mutationTags == [0x0A, 0x12, 0x1A])
}

@Test func hostDataPlaneProtocolFreezesEveryUnspecifiedEnumNumber() {
    #expect(CPDocumentDirtyStateValue.unspecified.rawValue == 0)
    #expect(CPDocumentMaintenanceStateValue.unspecified.rawValue == 0)
    #expect(CPWorkspaceDirectoryKind.unspecified.rawValue == 0)
    #expect(CPFileTreeEntryKindValue.unspecified.rawValue == 0)
}

@Test func hostDataPlaneProtocolFreezesEveryNonOneOfFieldNumberWithExactBytes() throws {
    var binding = CPDataPlaneBinding()
    binding.clientInstanceID = "x"; try hostDataPlaneProtocolExpectBytes(binding, [0x0A, 0x01, 0x78])
    binding = .init(); binding.windowID = "x"; try hostDataPlaneProtocolExpectBytes(binding, [0x12, 0x01, 0x78])
    binding = .init(); binding.workspaceContextID = .init(); try hostDataPlaneProtocolExpectBytes(binding, [0x1A, 0x00])
    binding = .init(); binding.environmentID = "x"; try hostDataPlaneProtocolExpectBytes(binding, [0x22, 0x01, 0x78])
    binding = .init(); binding.activeContextGeneration = 1; try hostDataPlaneProtocolExpectBytes(binding, [0x28, 0x01])

    var ticketRequest = CPHostDataPlaneTicketRequest()
    ticketRequest.context = .init(); try hostDataPlaneProtocolExpectBytes(ticketRequest, [0x0A, 0x00])
    var ticketResponse = CPHostDataPlaneTicketResponse()
    ticketResponse.socketPath = "x"; try hostDataPlaneProtocolExpectBytes(ticketResponse, [0x0A, 0x01, 0x78])
    ticketResponse = .init(); ticketResponse.ticket = "x"; try hostDataPlaneProtocolExpectBytes(ticketResponse, [0x12, 0x01, 0x78])
    ticketResponse = .init(); ticketResponse.validForMilliseconds = 1; try hostDataPlaneProtocolExpectBytes(ticketResponse, [0x18, 0x01])

    var authenticate = CPHostDataPlaneAuthenticate()
    authenticate.ticket = "x"; try hostDataPlaneProtocolExpectBytes(authenticate, [0x0A, 0x01, 0x78])
    authenticate = .init(); authenticate.binding = .init(); try hostDataPlaneProtocolExpectBytes(authenticate, [0x12, 0x00])
    var authenticated = CPHostDataPlaneAuthenticated()
    authenticated.binding = .init(); try hostDataPlaneProtocolExpectBytes(authenticated, [0x0A, 0x00])

    var error = CPDataPlaneError()
    error.code = .malformedMessage; try hostDataPlaneProtocolExpectBytes(error, [0x08, 0x01])
    error = .init(); error.expected = 1; try hostDataPlaneProtocolExpectBytes(error, [0x10, 0x01])
    error = .init(); error.actual = 1; try hostDataPlaneProtocolExpectBytes(error, [0x18, 0x01])
    error = .init(); error.committedAcknowledgement = .init(); try hostDataPlaneProtocolExpectBytes(error, [0x22, 0x00])

    var change = CPUTF16TextChange()
    change.offset = 1; try hostDataPlaneProtocolExpectBytes(change, [0x08, 0x01])
    change = .init(); change.length = 1; try hostDataPlaneProtocolExpectBytes(change, [0x10, 0x01])
    change = .init(); change.replacement = "x"; try hostDataPlaneProtocolExpectBytes(change, [0x1A, 0x01, 0x78])

    var fingerprint = CPDiskFingerprintValue()
    fingerprint.deviceID = 1; try hostDataPlaneProtocolExpectBytes(fingerprint, [0x08, 0x01])
    fingerprint = .init(); fingerprint.inode = 1; try hostDataPlaneProtocolExpectBytes(fingerprint, [0x10, 0x01])
    fingerprint = .init(); fingerprint.byteCount = 1; try hostDataPlaneProtocolExpectBytes(fingerprint, [0x18, 0x01])
    fingerprint = .init(); fingerprint.modificationTimeSeconds = -1; try hostDataPlaneProtocolExpectBytes(fingerprint, [0x20, 0x01])
    fingerprint = .init(); fingerprint.modificationTimeNanoseconds = 1; try hostDataPlaneProtocolExpectBytes(fingerprint, [0x28, 0x01])
    fingerprint = .init(); fingerprint.contentSha256 = Data([1]); try hostDataPlaneProtocolExpectBytes(fingerprint, [0x32, 0x01, 0x01])

    var lease = CPEditLeaseValue()
    lease.editLeaseID = "x"; try hostDataPlaneProtocolExpectBytes(lease, [0x0A, 0x01, 0x78])
    lease = .init(); lease.documentID = "x"; try hostDataPlaneProtocolExpectBytes(lease, [0x12, 0x01, 0x78])
    lease = .init(); lease.clientInstanceID = "x"; try hostDataPlaneProtocolExpectBytes(lease, [0x1A, 0x01, 0x78])

    var snapshot = CPDocumentSnapshotValue()
    snapshot.documentID = "x"; try hostDataPlaneProtocolExpectBytes(snapshot, [0x0A, 0x01, 0x78])
    snapshot = .init(); snapshot.environmentID = "x"; try hostDataPlaneProtocolExpectBytes(snapshot, [0x12, 0x01, 0x78])
    snapshot = .init(); snapshot.relativePath = "x"; try hostDataPlaneProtocolExpectBytes(snapshot, [0x1A, 0x01, 0x78])
    snapshot = .init(); snapshot.text = "x"; try hostDataPlaneProtocolExpectBytes(snapshot, [0x22, 0x01, 0x78])
    snapshot = .init(); snapshot.documentVersion = 1; try hostDataPlaneProtocolExpectBytes(snapshot, [0x28, 0x01])
    snapshot = .init(); snapshot.persistedVersion = 1; try hostDataPlaneProtocolExpectBytes(snapshot, [0x30, 0x01])
    snapshot = .init(); snapshot.lastAcceptedClientSequence = 1; try hostDataPlaneProtocolExpectBytes(snapshot, [0x38, 0x01])
    snapshot = .init(); snapshot.dirtyState = .clean; try hostDataPlaneProtocolExpectBytes(snapshot, [0x40, 0x01])
    snapshot = .init(); snapshot.observedDiskFingerprint = .init(); try hostDataPlaneProtocolExpectBytes(snapshot, [0x4A, 0x00])
    snapshot = .init(); snapshot.currentLease = .init(); try hostDataPlaneProtocolExpectBytes(snapshot, [0x52, 0x00])
    snapshot = .init(); snapshot.maintenance = [.truncatedRecoveryTail]; try hostDataPlaneProtocolExpectBytes(snapshot, [0x5A, 0x01, 0x01])

    var acknowledgement = CPDocumentAcknowledgement()
    acknowledgement.documentID = "x"; try hostDataPlaneProtocolExpectBytes(acknowledgement, [0x0A, 0x01, 0x78])
    acknowledgement = .init(); acknowledgement.clientSequence = 1; try hostDataPlaneProtocolExpectBytes(acknowledgement, [0x10, 0x01])
    acknowledgement = .init(); acknowledgement.documentVersion = 1; try hostDataPlaneProtocolExpectBytes(acknowledgement, [0x18, 0x01])

    var open = CPDocumentOpenRequest(); open.relativePath = "x"; try hostDataPlaneProtocolExpectBytes(open, [0x0A, 0x01, 0x78])
    var snapshotRequest = CPDocumentSnapshotRequest(); snapshotRequest.documentID = "x"; try hostDataPlaneProtocolExpectBytes(snapshotRequest, [0x0A, 0x01, 0x78])
    var acquire = CPDocumentAcquireLeaseRequest(); acquire.documentID = "x"; try hostDataPlaneProtocolExpectBytes(acquire, [0x0A, 0x01, 0x78])
    var transfer = CPDocumentTransferLeaseRequest()
    transfer.documentID = "x"; try hostDataPlaneProtocolExpectBytes(transfer, [0x0A, 0x01, 0x78])
    transfer = .init(); transfer.fromEditLeaseID = "x"; try hostDataPlaneProtocolExpectBytes(transfer, [0x12, 0x01, 0x78])
    transfer = .init(); transfer.targetClientInstanceID = "x"; try hostDataPlaneProtocolExpectBytes(transfer, [0x1A, 0x01, 0x78])

    var apply = CPDocumentApplyRequest()
    apply.documentID = "x"; try hostDataPlaneProtocolExpectBytes(apply, [0x0A, 0x01, 0x78])
    apply = .init(); apply.editLeaseID = "x"; try hostDataPlaneProtocolExpectBytes(apply, [0x12, 0x01, 0x78])
    apply = .init(); apply.baseVersion = 1; try hostDataPlaneProtocolExpectBytes(apply, [0x18, 0x01])
    apply = .init(); apply.clientSequence = 1; try hostDataPlaneProtocolExpectBytes(apply, [0x20, 0x01])
    apply = .init(); apply.changes = [.init()]; try hostDataPlaneProtocolExpectBytes(apply, [0x2A, 0x00])

    var flush = CPDocumentFlushRequest()
    flush.documentID = "x"; try hostDataPlaneProtocolExpectBytes(flush, [0x0A, 0x01, 0x78])
    flush = .init(); flush.throughClientSequence = 1; try hostDataPlaneProtocolExpectBytes(flush, [0x10, 0x01])
    var flushResult = CPDocumentFlushResult(); flushResult.documentVersion = 1; try hostDataPlaneProtocolExpectBytes(flushResult, [0x08, 0x01])
    var save = CPDocumentSaveRequest()
    save.documentID = "x"; try hostDataPlaneProtocolExpectBytes(save, [0x0A, 0x01, 0x78])
    save = .init(); save.expectedFingerprint = .init(); try hostDataPlaneProtocolExpectBytes(save, [0x12, 0x00])
    var discard = CPDocumentDiscardRequest(); discard.documentID = "x"; try hostDataPlaneProtocolExpectBytes(discard, [0x0A, 0x01, 0x78])
    var documentEnvelope = CPDocumentEnvelope()
    documentEnvelope.requestID = "x"; try hostDataPlaneProtocolExpectBytes(documentEnvelope, [0x0A, 0x01, 0x78])
    documentEnvelope = .init(); documentEnvelope.binding = .init(); try hostDataPlaneProtocolExpectBytes(documentEnvelope, [0x12, 0x00])

    var directory = CPWorkspaceDirectoryValue()
    directory.kind = .root; try hostDataPlaneProtocolExpectBytes(directory, [0x08, 0x01])
    directory = .init(); directory.relativePath = ""; try hostDataPlaneProtocolExpectBytes(directory, [0x12, 0x00])
    var identity = CPFileTreeEntryIdentityValue()
    identity.environmentID = "x"; try hostDataPlaneProtocolExpectBytes(identity, [0x0A, 0x01, 0x78])
    identity = .init(); identity.relativePath = "x"; try hostDataPlaneProtocolExpectBytes(identity, [0x12, 0x01, 0x78])
    var entry = CPFileTreeEntryValue()
    entry.identity = .init(); try hostDataPlaneProtocolExpectBytes(entry, [0x0A, 0x00])
    entry = .init(); entry.kind = .file; try hostDataPlaneProtocolExpectBytes(entry, [0x10, 0x01])

    var treeSnapshot = CPFileTreeSnapshotValue()
    treeSnapshot.environmentID = "x"; try hostDataPlaneProtocolExpectBytes(treeSnapshot, [0x0A, 0x01, 0x78])
    treeSnapshot = .init(); treeSnapshot.directory = .init(); try hostDataPlaneProtocolExpectBytes(treeSnapshot, [0x12, 0x00])
    treeSnapshot = .init(); treeSnapshot.generation = 1; try hostDataPlaneProtocolExpectBytes(treeSnapshot, [0x18, 0x01])
    treeSnapshot = .init(); treeSnapshot.revision = 1; try hostDataPlaneProtocolExpectBytes(treeSnapshot, [0x20, 0x01])
    treeSnapshot = .init(); treeSnapshot.children = [.init()]; try hostDataPlaneProtocolExpectBytes(treeSnapshot, [0x2A, 0x00])
    var delta = CPFileTreeDeltaValue()
    delta.environmentID = "x"; try hostDataPlaneProtocolExpectBytes(delta, [0x0A, 0x01, 0x78])
    delta = .init(); delta.directory = .init(); try hostDataPlaneProtocolExpectBytes(delta, [0x12, 0x00])
    delta = .init(); delta.revision = 1; try hostDataPlaneProtocolExpectBytes(delta, [0x18, 0x01])
    delta = .init(); delta.mutations = [.init()]; try hostDataPlaneProtocolExpectBytes(delta, [0x22, 0x00])

    var children = CPFileTreeChildrenRequest(); children.directory = .init(); try hostDataPlaneProtocolExpectBytes(children, [0x0A, 0x00])
    var subscribe = CPFileTreeSubscribeRequest(); subscribe.afterRevision = 1; try hostDataPlaneProtocolExpectBytes(subscribe, [0x08, 0x01])
    var accepted = CPFileTreeSubscriptionAccepted()
    accepted.subscriptionID = "x"; try hostDataPlaneProtocolExpectBytes(accepted, [0x0A, 0x01, 0x78])
    accepted = .init(); accepted.revision = 1; try hostDataPlaneProtocolExpectBytes(accepted, [0x10, 0x01])
    var event = CPFileTreeDeltaEvent()
    event.subscriptionID = "x"; try hostDataPlaneProtocolExpectBytes(event, [0x0A, 0x01, 0x78])
    event = .init(); event.eventID = "x"; try hostDataPlaneProtocolExpectBytes(event, [0x12, 0x01, 0x78])
    event = .init(); event.delta = .init(); try hostDataPlaneProtocolExpectBytes(event, [0x1A, 0x00])
    var deltaAck = CPFileTreeDeltaAck()
    deltaAck.subscriptionID = "x"; try hostDataPlaneProtocolExpectBytes(deltaAck, [0x0A, 0x01, 0x78])
    deltaAck = .init(); deltaAck.eventID = "x"; try hostDataPlaneProtocolExpectBytes(deltaAck, [0x12, 0x01, 0x78])
    deltaAck = .init(); deltaAck.revision = 1; try hostDataPlaneProtocolExpectBytes(deltaAck, [0x18, 0x01])
    var ackAccepted = CPFileTreeAckAccepted()
    ackAccepted.subscriptionID = "x"; try hostDataPlaneProtocolExpectBytes(ackAccepted, [0x0A, 0x01, 0x78])
    ackAccepted = .init(); ackAccepted.eventID = "x"; try hostDataPlaneProtocolExpectBytes(ackAccepted, [0x12, 0x01, 0x78])
    ackAccepted = .init(); ackAccepted.revision = 1; try hostDataPlaneProtocolExpectBytes(ackAccepted, [0x18, 0x01])
    var cancel = CPFileTreeCancelRequest(); cancel.subscriptionID = "x"; try hostDataPlaneProtocolExpectBytes(cancel, [0x0A, 0x01, 0x78])
    var cancelled = CPFileTreeCancelled(); cancelled.subscriptionID = "x"; try hostDataPlaneProtocolExpectBytes(cancelled, [0x0A, 0x01, 0x78])
    var treeEnvelope = CPFileTreeEnvelope()
    treeEnvelope.requestID = "x"; try hostDataPlaneProtocolExpectBytes(treeEnvelope, [0x0A, 0x01, 0x78])
    treeEnvelope = .init(); treeEnvelope.binding = .init(); try hostDataPlaneProtocolExpectBytes(treeEnvelope, [0x12, 0x00])
}

@Test func hostDataPlaneProtocolKeepsAcquireLeaseFieldTwoReserved() throws {
    let values = hostDataPlaneProtocolFixture()
    let requestID = RequestID(uuid("34000000-0000-4000-8000-000000000001"))
    let fieldTwoEncodings: [[UInt8]] = [
        [0x10, 0x01],
        [0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x12, 0x00],
        [0x15, 0x00, 0x00, 0x00, 0x00],
    ]

    for fieldTwoEncoding in fieldTwoEncodings {
        var request = CPDocumentAcquireLeaseRequest()
        request.documentID = values.documentID.description
        var bytes = try request.serializedData()
        bytes.append(contentsOf: fieldTwoEncoding)
        request = try CPDocumentAcquireLeaseRequest(serializedBytes: bytes)
        hostDataPlaneProtocolExpectMappingError(
            .unknownFields("document_acquire_lease_request"),
            "acquire lease field 2 wire type \(fieldTwoEncoding[0] & 0x07)"
        ) {
            _ = try HostDataPlaneMessages.decodeDocumentEnvelope(
                hostDataPlaneProtocolDocumentBytes(values, requestID, .acquireLeaseRequest(request))
            )
        }
    }
}

@Test func hostDataPlaneProtocolRoundTripsBindingAndDocumentDomainValuesExactly() throws {
    let values = hostDataPlaneProtocolFixture()
    let wireBinding = try HostDataPlaneMessages.encode(values.binding)
    #expect(try HostDataPlaneMessages.decode(wireBinding) == values.binding)

    let edit = try UTF16TextEdit(validatingOffset: 2, length: 1, replacement: "Z")
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(edit)) == edit)
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(values.fingerprint)) == values.fingerprint)
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(values.lease)) == values.lease)
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(values.snapshot)) == values.snapshot)
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(values.acknowledgement)) == values.acknowledgement)

    let transaction = try EditTransaction(
        validatingDocumentID: values.documentID,
        editLeaseID: values.lease.id,
        baseVersion: 1,
        clientSequence: 2,
        changes: [edit]
    )
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(transaction)) == transaction)

    let canonicalBytes = try wireBinding.serializedData()
    #expect(try HostDataPlaneMessages.encode(HostDataPlaneMessages.decode(wireBinding)).serializedData() == canonicalBytes)
}

@Test func hostDataPlaneProtocolValidatesEveryDocumentOperationAndResult() throws {
    let values = hostDataPlaneProtocolFixture()
    let requestID = RequestID(uuid("aaaaaaaa-0000-4000-8000-000000000001"))
    let transaction = try EditTransaction(
        validatingDocumentID: values.documentID,
        editLeaseID: values.lease.id,
        baseVersion: 1,
        clientSequence: 2,
        changes: [try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x")]
    )
    var open = CPDocumentOpenRequest(); open.relativePath = values.path.string
    var snapshot = CPDocumentSnapshotRequest(); snapshot.documentID = values.documentID.description
    var acquire = CPDocumentAcquireLeaseRequest(); acquire.documentID = values.documentID.description
    var transfer = CPDocumentTransferLeaseRequest()
    transfer.documentID = values.documentID.description
    transfer.fromEditLeaseID = values.lease.id.description
    transfer.targetClientInstanceID = ClientInstanceID(uuid("aaaaaaaa-0000-4000-8000-000000000002")).description
    var flush = CPDocumentFlushRequest(); flush.documentID = values.documentID.description; flush.throughClientSequence = 1
    var save = CPDocumentSaveRequest(); save.documentID = values.documentID.description; save.expectedFingerprint = try HostDataPlaneMessages.encode(values.fingerprint)
    var discard = CPDocumentDiscardRequest(); discard.documentID = values.documentID.description
    var flushResult = CPDocumentFlushResult(); flushResult.documentVersion = 1
    var error = CPDataPlaneError(); error.code = .documentInvalidLease

    let payloads: [CPDocumentEnvelope.OneOf_Payload] = [
        .openRequest(open), .snapshotRequest(snapshot), .acquireLeaseRequest(acquire),
        .transferLeaseRequest(transfer), .applyRequest(try HostDataPlaneMessages.encode(transaction)),
        .flushRequest(flush), .saveRequest(save), .discardRequest(discard),
        .snapshotResult(try HostDataPlaneMessages.encode(values.snapshot)),
        .leaseResult(try HostDataPlaneMessages.encode(values.lease)),
        .acknowledgementResult(try HostDataPlaneMessages.encode(values.acknowledgement)),
        .flushResult(flushResult), .error(error),
    ]

    for payload in payloads {
        var envelope = CPDocumentEnvelope()
        envelope.requestID = requestID.description
        envelope.binding = try HostDataPlaneMessages.encode(values.binding)
        envelope.payload = payload
        let original = try envelope.serializedData()
        let validated = try HostDataPlaneMessages.decodeDocumentEnvelope(original)
        #expect(try validated.serializedData() == original)
    }
}

@Test func hostDataPlaneProtocolRoundTripsFileTreeAndSubscriptionLifecycle() throws {
    let values = hostDataPlaneProtocolFixture()
    let directory = WorkspaceDirectory.relative(try RelativePath("Sources"))
    let identity = try FileTreeEntryIdentity(validating: values.binding.environmentID, path: values.path)
    let entry = try FileTreeEntry(validating: identity, kind: .file)
    let snapshot = try FileTreeSnapshot(
        validating: values.binding.environmentID,
        directory: directory,
        generation: values.binding.activeContextGeneration,
        revision: 0,
        children: [entry]
    )
    let delta = try FileTreeDelta(
        validating: values.binding.environmentID,
        directory: directory,
        revision: 1,
        mutations: [.update(entry)]
    )
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(directory)) == directory)
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(identity)) == identity)
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(entry)) == entry)
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(FileTreeMutation.update(entry))) == .update(entry))
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(snapshot)) == snapshot)
    #expect(try HostDataPlaneMessages.decode(HostDataPlaneMessages.encode(delta)) == delta)

    let subscriptionID = RequestID(uuid("bbbbbbbb-0000-4000-8000-000000000001"))
    let eventID = RequestID(uuid("bbbbbbbb-0000-4000-8000-000000000002"))
    var children = CPFileTreeChildrenRequest(); children.directory = try HostDataPlaneMessages.encode(directory)
    var subscribe = CPFileTreeSubscribeRequest(); subscribe.afterRevision = 0
    var accepted = CPFileTreeSubscriptionAccepted(); accepted.subscriptionID = subscriptionID.description; accepted.revision = 0
    var event = CPFileTreeDeltaEvent(); event.subscriptionID = subscriptionID.description; event.eventID = eventID.description; event.delta = try HostDataPlaneMessages.encode(delta)
    var ack = CPFileTreeDeltaAck(); ack.subscriptionID = subscriptionID.description; ack.eventID = eventID.description; ack.revision = 1
    var ackAccepted = CPFileTreeAckAccepted(); ackAccepted.subscriptionID = subscriptionID.description; ackAccepted.eventID = eventID.description; ackAccepted.revision = 1
    var cancel = CPFileTreeCancelRequest(); cancel.subscriptionID = subscriptionID.description
    var cancelled = CPFileTreeCancelled(); cancelled.subscriptionID = subscriptionID.description
    var error = CPDataPlaneError(); error.code = .treeBackpressure

    let payloads: [(RequestID, CPFileTreeEnvelope.OneOf_Payload)] = [
        (RequestID(), .childrenRequest(children)), (subscriptionID, .subscribeRequest(subscribe)),
        (RequestID(), .deltaAck(ack)), (RequestID(), .cancelRequest(cancel)),
        (RequestID(), .snapshotResult(try HostDataPlaneMessages.encode(snapshot))),
        (subscriptionID, .subscriptionAccepted(accepted)), (eventID, .deltaEvent(event)),
        (RequestID(), .ackAccepted(ackAccepted)), (RequestID(), .cancelled(cancelled)),
        (RequestID(), .error(error)),
    ]
    for (requestID, payload) in payloads {
        var envelope = CPFileTreeEnvelope()
        envelope.requestID = requestID.description
        envelope.binding = try HostDataPlaneMessages.encode(values.binding)
        envelope.payload = payload
        let bytes = try envelope.serializedData()
        #expect(try HostDataPlaneMessages.decodeFileTreeEnvelope(bytes).serializedData() == bytes)
    }
}

@Test func hostDataPlaneProtocolRejectsUnknownFieldsAtEveryValidatedMessageLayer() throws {
    let values = hostDataPlaneProtocolFixture()
    let binding = try HostDataPlaneMessages.encode(values.binding)

    var bindingWithNestedUnknown = binding
    bindingWithNestedUnknown.workspaceContextID = try hostDataPlaneProtocolAddingUnknownField(binding.workspaceContextID)
    hostDataPlaneProtocolExpectMappingError(.unknownFields("workspace_context_id"), "binding.workspace_context_id") {
        _ = try HostDataPlaneMessages.decode(bindingWithNestedUnknown)
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("data_plane_binding"), "data_plane_binding") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(binding))
    }

    let change = try HostDataPlaneMessages.encode(UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x"))
    hostDataPlaneProtocolExpectMappingError(.unknownFields("utf16_text_change"), "utf16_text_change") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(change))
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("disk_fingerprint"), "disk_fingerprint") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(values.fingerprint)))
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("edit_lease"), "edit_lease") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(values.lease)))
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("document_snapshot"), "document_snapshot") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(values.snapshot)))
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("document_acknowledgement"), "document_acknowledgement") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(values.acknowledgement)))
    }
    let transaction = try EditTransaction(
        validatingDocumentID: values.documentID,
        editLeaseID: values.lease.id,
        baseVersion: 1,
        clientSequence: 2,
        changes: [try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x")]
    )
    hostDataPlaneProtocolExpectMappingError(.unknownFields("document_apply_request"), "document_apply_request") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(transaction)))
    }

    let directory = WorkspaceDirectory.relative(try RelativePath("Sources"))
    let identity = try FileTreeEntryIdentity(validating: values.binding.environmentID, path: values.path)
    let entry = try FileTreeEntry(validating: identity, kind: .file)
    let treeSnapshot = try FileTreeSnapshot(
        validating: values.binding.environmentID,
        directory: directory,
        generation: values.binding.activeContextGeneration,
        revision: 1,
        children: [entry]
    )
    let delta = try FileTreeDelta(
        validating: values.binding.environmentID,
        directory: directory,
        revision: 1,
        mutations: [.update(entry)]
    )
    hostDataPlaneProtocolExpectMappingError(.unknownFields("workspace_directory"), "workspace_directory") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(directory)))
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("file_tree_entry_identity"), "file_tree_entry_identity") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(identity)))
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("file_tree_entry"), "file_tree_entry") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(entry)))
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("file_tree_mutation"), "file_tree_mutation") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(FileTreeMutation.update(entry))))
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("file_tree_snapshot"), "file_tree_snapshot") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(treeSnapshot)))
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("file_tree_delta"), "file_tree_delta") {
        _ = try HostDataPlaneMessages.decode(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(delta)))
    }

    var handshakeRequest = CPHandshakeRequest()
    handshakeRequest.protocolMajor = 1
    handshakeRequest.protocolMinor = 1
    handshakeRequest.deviceID = DeviceID(uuid("20000000-0000-4000-8000-000000000001")).description
    handshakeRequest.requestedFeatures = [ProtocolFeature.hostDataPlane.rawValue]
    var handshakeResponse = CPHandshakeResponse()
    handshakeResponse.protocolMajor = 1
    handshakeResponse.protocolMinor = 1
    handshakeResponse.connectionID = ConnectionID(uuid("20000000-0000-4000-8000-000000000002")).description
    handshakeResponse.acceptedFeatures = [ProtocolFeature.hostDataPlane.rawValue]
    handshakeResponse.serviceKind = "host-data-plane"
    var authenticate = CPHostDataPlaneAuthenticate(); authenticate.ticket = "ticket"; authenticate.binding = binding
    var authenticated = CPHostDataPlaneAuthenticated(); authenticated.binding = binding
    var error = CPDataPlaneError(); error.code = .invalidTicket

    let controlUnknownCases: [(String, ProtocolMappingError, CPHostDataPlaneControlEnvelope.OneOf_Payload)] = [
        ("handshake_request", .unknownFields("handshake_request"), .handshakeRequest(try hostDataPlaneProtocolAddingUnknownField(handshakeRequest))),
        ("handshake_response", .unknownFields("handshake_response"), .handshakeResponse(try hostDataPlaneProtocolAddingUnknownField(handshakeResponse))),
        ("host_data_plane_authenticate", .unknownFields("host_data_plane_authenticate"), .authenticate(try hostDataPlaneProtocolAddingUnknownField(authenticate))),
        ("host_data_plane_authenticated", .unknownFields("host_data_plane_authenticated"), .authenticated(try hostDataPlaneProtocolAddingUnknownField(authenticated))),
        ("data_plane_error", .unknownFields("data_plane_error"), .error(try hostDataPlaneProtocolAddingUnknownField(error))),
    ]
    for (name, expected, payload) in controlUnknownCases {
        hostDataPlaneProtocolExpectMappingError(expected, name) {
            _ = try HostDataPlaneMessages.decodeControlEnvelope(hostDataPlaneProtocolControlBytes(payload))
        }
    }
    var control = CPHostDataPlaneControlEnvelope(); control.handshakeRequest = handshakeRequest
    hostDataPlaneProtocolExpectMappingError(.unknownFields("host_data_plane_control_envelope"), "control_envelope") {
        _ = try HostDataPlaneMessages.decodeControlEnvelope(try hostDataPlaneProtocolAddingUnknownField(control).serializedData())
    }

    let requestID = RequestID(uuid("20000000-0000-4000-8000-000000000003"))
    var open = CPDocumentOpenRequest(); open.relativePath = values.path.string
    var snapshotRequest = CPDocumentSnapshotRequest(); snapshotRequest.documentID = values.documentID.description
    var acquire = CPDocumentAcquireLeaseRequest(); acquire.documentID = values.documentID.description
    var transfer = CPDocumentTransferLeaseRequest()
    transfer.documentID = values.documentID.description
    transfer.fromEditLeaseID = values.lease.id.description
    transfer.targetClientInstanceID = values.binding.clientInstanceID.description
    var flush = CPDocumentFlushRequest(); flush.documentID = values.documentID.description; flush.throughClientSequence = 1
    var save = CPDocumentSaveRequest(); save.documentID = values.documentID.description; save.expectedFingerprint = try HostDataPlaneMessages.encode(values.fingerprint)
    var discard = CPDocumentDiscardRequest(); discard.documentID = values.documentID.description
    var flushResult = CPDocumentFlushResult(); flushResult.documentVersion = 1
    let documentUnknownCases: [(String, ProtocolMappingError, CPDocumentEnvelope.OneOf_Payload)] = [
        ("document_open_request", .unknownFields("document_open_request"), .openRequest(try hostDataPlaneProtocolAddingUnknownField(open))),
        ("document_snapshot_request", .unknownFields("document_snapshot_request"), .snapshotRequest(try hostDataPlaneProtocolAddingUnknownField(snapshotRequest))),
        ("document_acquire_lease_request", .unknownFields("document_acquire_lease_request"), .acquireLeaseRequest(try hostDataPlaneProtocolAddingUnknownField(acquire))),
        ("document_transfer_lease_request", .unknownFields("document_transfer_lease_request"), .transferLeaseRequest(try hostDataPlaneProtocolAddingUnknownField(transfer))),
        ("document_apply_request", .unknownFields("document_apply_request"), .applyRequest(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(transaction)))),
        ("document_flush_request", .unknownFields("document_flush_request"), .flushRequest(try hostDataPlaneProtocolAddingUnknownField(flush))),
        ("document_save_request", .unknownFields("document_save_request"), .saveRequest(try hostDataPlaneProtocolAddingUnknownField(save))),
        ("document_discard_request", .unknownFields("document_discard_request"), .discardRequest(try hostDataPlaneProtocolAddingUnknownField(discard))),
        ("document_snapshot", .unknownFields("document_snapshot"), .snapshotResult(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(values.snapshot)))),
        ("edit_lease", .unknownFields("edit_lease"), .leaseResult(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(values.lease)))),
        ("document_acknowledgement", .unknownFields("document_acknowledgement"), .acknowledgementResult(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(values.acknowledgement)))),
        ("document_flush_result", .unknownFields("document_flush_result"), .flushResult(try hostDataPlaneProtocolAddingUnknownField(flushResult))),
        ("data_plane_error", .unknownFields("data_plane_error"), .error(try hostDataPlaneProtocolAddingUnknownField(error))),
    ]
    for (name, expected, payload) in documentUnknownCases {
        hostDataPlaneProtocolExpectMappingError(expected, name) {
            _ = try HostDataPlaneMessages.decodeDocumentEnvelope(hostDataPlaneProtocolDocumentBytes(values, requestID, payload))
        }
    }
    var documentEnvelope = CPDocumentEnvelope()
    documentEnvelope.requestID = requestID.description
    documentEnvelope.binding = binding
    documentEnvelope.openRequest = open
    hostDataPlaneProtocolExpectMappingError(.unknownFields("document_envelope"), "document_envelope") {
        _ = try HostDataPlaneMessages.decodeDocumentEnvelope(try hostDataPlaneProtocolAddingUnknownField(documentEnvelope).serializedData())
    }

    let subscriptionID = RequestID(uuid("20000000-0000-4000-8000-000000000004"))
    let eventID = RequestID(uuid("20000000-0000-4000-8000-000000000005"))
    var children = CPFileTreeChildrenRequest(); children.directory = try HostDataPlaneMessages.encode(directory)
    var subscribe = CPFileTreeSubscribeRequest(); subscribe.afterRevision = 1
    var deltaAck = CPFileTreeDeltaAck(); deltaAck.subscriptionID = subscriptionID.description; deltaAck.eventID = eventID.description; deltaAck.revision = 1
    var cancel = CPFileTreeCancelRequest(); cancel.subscriptionID = subscriptionID.description
    var accepted = CPFileTreeSubscriptionAccepted(); accepted.subscriptionID = subscriptionID.description; accepted.revision = 1
    var event = CPFileTreeDeltaEvent(); event.subscriptionID = subscriptionID.description; event.eventID = eventID.description; event.delta = try HostDataPlaneMessages.encode(delta)
    var ackAccepted = CPFileTreeAckAccepted(); ackAccepted.subscriptionID = subscriptionID.description; ackAccepted.eventID = eventID.description; ackAccepted.revision = 1
    var cancelled = CPFileTreeCancelled(); cancelled.subscriptionID = subscriptionID.description
    let treeUnknownCases: [(String, RequestID, ProtocolMappingError, CPFileTreeEnvelope.OneOf_Payload)] = [
        ("file_tree_children_request", requestID, .unknownFields("file_tree_children_request"), .childrenRequest(try hostDataPlaneProtocolAddingUnknownField(children))),
        ("file_tree_subscribe_request", requestID, .unknownFields("file_tree_subscribe_request"), .subscribeRequest(try hostDataPlaneProtocolAddingUnknownField(subscribe))),
        ("file_tree_delta_ack", requestID, .unknownFields("file_tree_delta_ack"), .deltaAck(try hostDataPlaneProtocolAddingUnknownField(deltaAck))),
        ("file_tree_cancel_request", requestID, .unknownFields("file_tree_cancel_request"), .cancelRequest(try hostDataPlaneProtocolAddingUnknownField(cancel))),
        ("file_tree_snapshot", requestID, .unknownFields("file_tree_snapshot"), .snapshotResult(try hostDataPlaneProtocolAddingUnknownField(HostDataPlaneMessages.encode(treeSnapshot)))),
        ("file_tree_subscription_accepted", subscriptionID, .unknownFields("file_tree_subscription_accepted"), .subscriptionAccepted(try hostDataPlaneProtocolAddingUnknownField(accepted))),
        ("file_tree_delta_event", eventID, .unknownFields("file_tree_delta_event"), .deltaEvent(try hostDataPlaneProtocolAddingUnknownField(event))),
        ("file_tree_ack_accepted", requestID, .unknownFields("file_tree_ack_accepted"), .ackAccepted(try hostDataPlaneProtocolAddingUnknownField(ackAccepted))),
        ("file_tree_cancelled", requestID, .unknownFields("file_tree_cancelled"), .cancelled(try hostDataPlaneProtocolAddingUnknownField(cancelled))),
        ("data_plane_error", requestID, .unknownFields("data_plane_error"), .error(try hostDataPlaneProtocolAddingUnknownField(error))),
    ]
    for (name, envelopeRequestID, expected, payload) in treeUnknownCases {
        hostDataPlaneProtocolExpectMappingError(expected, name) {
            _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, envelopeRequestID, payload))
        }
    }
    var treeEnvelope = CPFileTreeEnvelope()
    treeEnvelope.requestID = requestID.description
    treeEnvelope.binding = binding
    treeEnvelope.childrenRequest = children
    hostDataPlaneProtocolExpectMappingError(.unknownFields("file_tree_envelope"), "file_tree_envelope") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(try hostDataPlaneProtocolAddingUnknownField(treeEnvelope).serializedData())
    }
}

@Test func hostDataPlaneProtocolRejectsAbsentOneOfUnknownEnumsAndMalformedPresence() throws {
    let values = hostDataPlaneProtocolFixture()
    let requestID = RequestID(uuid("30000000-0000-4000-8000-000000000001"))

    hostDataPlaneProtocolExpectMappingError(.invalidValue("host_data_plane_control_envelope"), "absent control payload") {
        _ = try HostDataPlaneMessages.decodeControlEnvelope(CPHostDataPlaneControlEnvelope().serializedData())
    }
    var document = CPDocumentEnvelope()
    document.requestID = requestID.description
    document.binding = try HostDataPlaneMessages.encode(values.binding)
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_envelope"), "absent document payload") {
        _ = try HostDataPlaneMessages.decodeDocumentEnvelope(document.serializedData())
    }
    var tree = CPFileTreeEnvelope()
    tree.requestID = requestID.description
    tree.binding = try HostDataPlaneMessages.encode(values.binding)
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_envelope"), "absent file-tree payload") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(tree.serializedData())
    }
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_mutation"), "absent mutation oneof") {
        _ = try HostDataPlaneMessages.decode(CPFileTreeMutationValue())
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("host_data_plane_control_envelope"), "unknown control oneof") {
        _ = try HostDataPlaneMessages.decodeControlEnvelope(Data([0x32, 0x00]))
    }
    let documentWithUnknownOneOf = document
    var documentUnknownBytes = try documentWithUnknownOneOf.serializedData()
    documentUnknownBytes.append(contentsOf: [0x92, 0x01, 0x00])
    hostDataPlaneProtocolExpectMappingError(.unknownFields("document_envelope"), "unknown document oneof") {
        _ = try HostDataPlaneMessages.decodeDocumentEnvelope(documentUnknownBytes)
    }
    let treeWithUnknownOneOf = tree
    var treeUnknownBytes = try treeWithUnknownOneOf.serializedData()
    treeUnknownBytes.append(contentsOf: [0x72, 0x00])
    hostDataPlaneProtocolExpectMappingError(.unknownFields("file_tree_envelope"), "unknown file-tree oneof") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(treeUnknownBytes)
    }
    hostDataPlaneProtocolExpectMappingError(.unknownFields("file_tree_mutation"), "unknown mutation oneof") {
        _ = try HostDataPlaneMessages.decode(CPFileTreeMutationValue(serializedBytes: [0x22, 0x00]))
    }

    var binding = try HostDataPlaneMessages.encode(values.binding)
    binding.clearWorkspaceContextID()
    hostDataPlaneProtocolExpectMappingError(.invalidValue("host_data_plane_binding"), "missing workspace context") {
        _ = try HostDataPlaneMessages.decode(binding)
    }
    var authenticate = CPHostDataPlaneAuthenticate(); authenticate.ticket = "ticket"
    hostDataPlaneProtocolExpectMappingError(.invalidValue("host_data_plane_authenticate"), "authenticate missing binding") {
        _ = try HostDataPlaneMessages.decodeControlEnvelope(hostDataPlaneProtocolControlBytes(.authenticate(authenticate)))
    }
    hostDataPlaneProtocolExpectMappingError(.invalidValue("host_data_plane_authenticated"), "authenticated missing binding") {
        _ = try HostDataPlaneMessages.decodeControlEnvelope(hostDataPlaneProtocolControlBytes(.authenticated(.init())))
    }

    var directory = CPWorkspaceDirectoryValue(); directory.kind = .root; directory.relativePath = "Sources"
    hostDataPlaneProtocolExpectMappingError(.invalidValue("workspace_directory"), "root with relative path") {
        _ = try HostDataPlaneMessages.decode(directory)
    }
    directory = .init(); directory.kind = .relative
    hostDataPlaneProtocolExpectMappingError(.invalidValue("workspace_directory"), "relative without path") {
        _ = try HostDataPlaneMessages.decode(directory)
    }
    for kind in [CPWorkspaceDirectoryKind.unspecified, .UNRECOGNIZED(99)] {
        directory = .init(); directory.kind = kind
        hostDataPlaneProtocolExpectMappingError(.invalidValue("workspace_directory"), "directory enum \(kind.rawValue)") {
            _ = try HostDataPlaneMessages.decode(directory)
        }
    }

    var entry = CPFileTreeEntryValue(); entry.identity = try HostDataPlaneMessages.encode(
        FileTreeEntryIdentity(validating: values.binding.environmentID, path: values.path)
    )
    for kind in [CPFileTreeEntryKindValue.unspecified, .UNRECOGNIZED(99)] {
        entry.kind = kind
        hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_entry"), "entry enum \(kind.rawValue)") {
            _ = try HostDataPlaneMessages.decode(entry)
        }
    }
    entry = .init(); entry.kind = .file
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_entry"), "entry missing identity") {
        _ = try HostDataPlaneMessages.decode(entry)
    }

    for dirty in [CPDocumentDirtyStateValue.unspecified, .UNRECOGNIZED(99)] {
        var snapshot = try HostDataPlaneMessages.encode(values.snapshot)
        snapshot.dirtyState = dirty
        hostDataPlaneProtocolExpectMappingError(.invalidValue("document_snapshot"), "dirty enum \(dirty.rawValue)") {
            _ = try HostDataPlaneMessages.decode(snapshot)
        }
    }
    for maintenance in [CPDocumentMaintenanceStateValue.unspecified, .UNRECOGNIZED(99)] {
        var snapshot = try HostDataPlaneMessages.encode(values.snapshot)
        snapshot.maintenance = [maintenance]
        hostDataPlaneProtocolExpectMappingError(.invalidValue("document_snapshot"), "maintenance enum \(maintenance.rawValue)") {
            _ = try HostDataPlaneMessages.decode(snapshot)
        }
    }

    var save = CPDocumentSaveRequest(); save.documentID = values.documentID.description
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_save_request"), "save missing fingerprint") {
        _ = try HostDataPlaneMessages.decodeDocumentEnvelope(hostDataPlaneProtocolDocumentBytes(values, requestID, .saveRequest(save)))
    }
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_children_request"), "children missing directory") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .childrenRequest(.init())))
    }
    var fileSnapshot = CPFileTreeSnapshotValue()
    fileSnapshot.environmentID = values.binding.environmentID.description
    fileSnapshot.generation = values.binding.activeContextGeneration
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_snapshot"), "snapshot missing directory") {
        _ = try HostDataPlaneMessages.decode(fileSnapshot)
    }
    var delta = CPFileTreeDeltaValue()
    delta.environmentID = values.binding.environmentID.description
    delta.revision = 1
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_delta"), "delta missing directory") {
        _ = try HostDataPlaneMessages.decode(delta)
    }
    let eventID = RequestID(uuid("30000000-0000-4000-8000-000000000002"))
    var event = CPFileTreeDeltaEvent()
    event.subscriptionID = requestID.description
    event.eventID = eventID.description
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_delta"), "event missing delta") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, eventID, .deltaEvent(event)))
    }
}

@Test func hostDataPlaneProtocolRejectsCarriageReturnNulUTF16OrderingAndNestedInconsistency() throws {
    let values = hostDataPlaneProtocolFixture()
    let requestID = RequestID(uuid("31000000-0000-4000-8000-000000000001"))

    for replacement in ["x\ry", "x\0y"] {
        var change = CPUTF16TextChange(); change.replacement = replacement
        hostDataPlaneProtocolExpectMappingError(.invalidValue("utf16_text_change"), "change control character") {
            _ = try HostDataPlaneMessages.decode(change)
        }
    }
    for text in ["x\ry", "x\0y"] {
        var snapshot = try HostDataPlaneMessages.encode(values.snapshot); snapshot.text = text
        hostDataPlaneProtocolExpectMappingError(.invalidValue("document_snapshot"), "snapshot control character") {
            _ = try HostDataPlaneMessages.decode(snapshot)
        }
    }

    let first = try HostDataPlaneMessages.encode(UTF16TextEdit(validatingOffset: 2, length: 2, replacement: "x"))
    let sameOffset = try HostDataPlaneMessages.encode(UTF16TextEdit(validatingOffset: 2, length: 0, replacement: "y"))
    let overlap = try HostDataPlaneMessages.encode(UTF16TextEdit(validatingOffset: 3, length: 0, replacement: "z"))
    var apply = CPDocumentApplyRequest()
    apply.documentID = values.documentID.description
    apply.editLeaseID = values.lease.id.description
    apply.clientSequence = 1
    apply.changes = [first, sameOffset]
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_apply_request"), "non-increasing UTF-16 offsets") {
        _ = try HostDataPlaneMessages.decode(apply)
    }
    apply.changes = [first, overlap]
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_apply_request"), "overlapping UTF-16 ranges") {
        _ = try HostDataPlaneMessages.decode(apply)
    }

    let otherDocumentID = DocumentID(uuid("31000000-0000-4000-8000-000000000002"))
    var snapshot = try HostDataPlaneMessages.encode(values.snapshot)
    snapshot.currentLease.documentID = otherDocumentID.description
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_snapshot"), "snapshot lease document mismatch") {
        _ = try HostDataPlaneMessages.decode(snapshot)
    }
    let otherEnvironmentID = EnvironmentID(uuid("31000000-0000-4000-8000-000000000003"))
    snapshot = try HostDataPlaneMessages.encode(values.snapshot)
    snapshot.environmentID = otherEnvironmentID.description
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_snapshot"), "snapshot binding environment mismatch") {
        _ = try HostDataPlaneMessages.decodeDocumentEnvelope(hostDataPlaneProtocolDocumentBytes(values, requestID, .snapshotResult(snapshot)))
    }

    var treeSnapshot = CPFileTreeSnapshotValue()
    treeSnapshot.environmentID = otherEnvironmentID.description
    treeSnapshot.directory = try HostDataPlaneMessages.encode(.root)
    treeSnapshot.generation = values.binding.activeContextGeneration
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_snapshot"), "tree snapshot binding environment mismatch") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .snapshotResult(treeSnapshot)))
    }
    treeSnapshot.environmentID = values.binding.environmentID.description
    treeSnapshot.generation += 1
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_snapshot"), "tree snapshot binding generation mismatch") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .snapshotResult(treeSnapshot)))
    }

    var wrongChild = CPFileTreeEntryValue()
    var wrongIdentity = CPFileTreeEntryIdentityValue()
    wrongIdentity.environmentID = otherEnvironmentID.description
    wrongIdentity.relativePath = "main.swift"
    wrongChild.identity = wrongIdentity; wrongChild.kind = .file
    treeSnapshot = .init()
    treeSnapshot.environmentID = values.binding.environmentID.description
    treeSnapshot.directory = try HostDataPlaneMessages.encode(.root)
    treeSnapshot.generation = values.binding.activeContextGeneration
    treeSnapshot.children = [wrongChild]
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_snapshot"), "tree child environment mismatch") {
        _ = try HostDataPlaneMessages.decode(treeSnapshot)
    }
    wrongIdentity.environmentID = values.binding.environmentID.description
    wrongIdentity.relativePath = "Sources/main.swift"
    wrongChild.identity = wrongIdentity
    treeSnapshot.children = [wrongChild]
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_snapshot"), "tree child not direct") {
        _ = try HostDataPlaneMessages.decode(treeSnapshot)
    }

    var otherIdentity = CPFileTreeEntryIdentityValue()
    otherIdentity.environmentID = otherEnvironmentID.description
    otherIdentity.relativePath = "main.swift"
    var remove = CPFileTreeMutationValue(); remove.remove = otherIdentity
    var delta = CPFileTreeDeltaValue()
    delta.environmentID = otherEnvironmentID.description
    delta.directory = try HostDataPlaneMessages.encode(.root)
    delta.revision = 1
    delta.mutations = [remove]
    let eventID = RequestID(uuid("31000000-0000-4000-8000-000000000004"))
    var event = CPFileTreeDeltaEvent()
    event.subscriptionID = requestID.description
    event.eventID = eventID.description
    event.delta = delta
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_delta"), "delta binding environment mismatch") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, eventID, .deltaEvent(event)))
    }

    var accepted = CPFileTreeSubscriptionAccepted()
    accepted.subscriptionID = RequestID().description
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_subscription_accepted"), "subscription request mismatch") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .subscriptionAccepted(accepted)))
    }
    var localIdentity = CPFileTreeEntryIdentityValue()
    localIdentity.environmentID = values.binding.environmentID.description
    localIdentity.relativePath = "main.swift"
    remove = .init(); remove.remove = localIdentity
    delta.environmentID = values.binding.environmentID.description
    delta.mutations = [remove]
    event = .init()
    event.subscriptionID = requestID.description
    event.eventID = RequestID().description
    event.delta = delta
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_delta"), "event request mismatch") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, eventID, .deltaEvent(event)))
    }
}

@Test func hostDataPlaneProtocolEnforcesEveryJavaScriptSafeCounterBoundary() throws {
    let values = hostDataPlaneProtocolFixture()
    let maximum = documentJavaScriptMaximum
    let unsafe = maximum + 1
    let requestID = RequestID(uuid("32000000-0000-4000-8000-000000000001"))

    var binding = try HostDataPlaneMessages.encode(values.binding)
    binding.activeContextGeneration = maximum
    #expect(try HostDataPlaneMessages.decode(binding).activeContextGeneration == maximum)
    binding.activeContextGeneration = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("host_data_plane_binding"), "binding generation") {
        _ = try HostDataPlaneMessages.decode(binding)
    }

    var change = CPUTF16TextChange(); change.offset = maximum
    #expect(try HostDataPlaneMessages.decode(change).offset == maximum)
    change.offset = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("utf16_text_change"), "UTF-16 offset") {
        _ = try HostDataPlaneMessages.decode(change)
    }
    change = .init(); change.length = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("utf16_text_change"), "UTF-16 length") {
        _ = try HostDataPlaneMessages.decode(change)
    }
    change.offset = maximum; change.length = 1
    hostDataPlaneProtocolExpectMappingError(.invalidValue("utf16_text_change"), "UTF-16 offset plus length") {
        _ = try HostDataPlaneMessages.decode(change)
    }

    var snapshot = try HostDataPlaneMessages.encode(values.snapshot)
    snapshot.documentVersion = maximum; snapshot.persistedVersion = maximum; snapshot.lastAcceptedClientSequence = maximum
    let maximumSnapshot = try HostDataPlaneMessages.decode(snapshot)
    #expect(maximumSnapshot.documentVersion == maximum)
    #expect(maximumSnapshot.persistedVersion == maximum)
    #expect(maximumSnapshot.lastAcceptedClientSequence == maximum)
    snapshot.documentVersion = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_snapshot"), "snapshot document version") {
        _ = try HostDataPlaneMessages.decode(snapshot)
    }
    snapshot = try HostDataPlaneMessages.encode(values.snapshot); snapshot.persistedVersion = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_snapshot"), "snapshot persisted version") {
        _ = try HostDataPlaneMessages.decode(snapshot)
    }
    snapshot = try HostDataPlaneMessages.encode(values.snapshot); snapshot.lastAcceptedClientSequence = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_snapshot"), "snapshot client sequence") {
        _ = try HostDataPlaneMessages.decode(snapshot)
    }

    var acknowledgement = try HostDataPlaneMessages.encode(values.acknowledgement)
    acknowledgement.clientSequence = maximum; acknowledgement.documentVersion = maximum
    #expect(try HostDataPlaneMessages.decode(acknowledgement).clientSequence == maximum)
    acknowledgement.clientSequence = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_acknowledgement"), "ack client sequence") {
        _ = try HostDataPlaneMessages.decode(acknowledgement)
    }
    acknowledgement = try HostDataPlaneMessages.encode(values.acknowledgement); acknowledgement.documentVersion = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_acknowledgement"), "ack document version") {
        _ = try HostDataPlaneMessages.decode(acknowledgement)
    }

    var apply = CPDocumentApplyRequest()
    apply.documentID = values.documentID.description
    apply.editLeaseID = values.lease.id.description
    apply.baseVersion = maximum
    apply.clientSequence = maximum
    apply.changes = [try HostDataPlaneMessages.encode(UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x"))]
    #expect(try HostDataPlaneMessages.decode(apply).baseVersion == maximum)
    apply.baseVersion = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_apply_request"), "apply base version") {
        _ = try HostDataPlaneMessages.decode(apply)
    }
    apply.baseVersion = 0; apply.clientSequence = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_apply_request"), "apply client sequence") {
        _ = try HostDataPlaneMessages.decode(apply)
    }
    apply.clientSequence = 0
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_apply_request"), "apply zero client sequence") {
        _ = try HostDataPlaneMessages.decode(apply)
    }
    apply.clientSequence = 1; apply.changes = []
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_apply_request"), "apply empty changes") {
        _ = try HostDataPlaneMessages.decode(apply)
    }

    var flush = CPDocumentFlushRequest(); flush.documentID = values.documentID.description; flush.throughClientSequence = maximum
    #expect(try HostDataPlaneMessages.decodeDocumentEnvelope(hostDataPlaneProtocolDocumentBytes(values, requestID, .flushRequest(flush))).flushRequest.throughClientSequence == maximum)
    flush.throughClientSequence = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_flush_request"), "flush sequence") {
        _ = try HostDataPlaneMessages.decodeDocumentEnvelope(hostDataPlaneProtocolDocumentBytes(values, requestID, .flushRequest(flush)))
    }
    var flushResult = CPDocumentFlushResult(); flushResult.documentVersion = maximum
    #expect(try HostDataPlaneMessages.decodeDocumentEnvelope(hostDataPlaneProtocolDocumentBytes(values, requestID, .flushResult(flushResult))).flushResult.documentVersion == maximum)
    flushResult.documentVersion = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_flush_result"), "flush result version") {
        _ = try HostDataPlaneMessages.decodeDocumentEnvelope(hostDataPlaneProtocolDocumentBytes(values, requestID, .flushResult(flushResult)))
    }

    var treeSnapshot = CPFileTreeSnapshotValue()
    treeSnapshot.environmentID = values.binding.environmentID.description
    treeSnapshot.directory = try HostDataPlaneMessages.encode(.root)
    treeSnapshot.generation = maximum
    treeSnapshot.revision = maximum
    #expect(try HostDataPlaneMessages.decode(treeSnapshot).generation == maximum)
    treeSnapshot.generation = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_snapshot"), "tree snapshot generation") {
        _ = try HostDataPlaneMessages.decode(treeSnapshot)
    }
    treeSnapshot.generation = maximum; treeSnapshot.revision = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_snapshot"), "tree snapshot revision") {
        _ = try HostDataPlaneMessages.decode(treeSnapshot)
    }
    treeSnapshot.generation = 0; treeSnapshot.revision = 0
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_snapshot"), "tree snapshot zero generation") {
        _ = try HostDataPlaneMessages.decode(treeSnapshot)
    }

    var delta = CPFileTreeDeltaValue()
    delta.environmentID = values.binding.environmentID.description
    delta.directory = try HostDataPlaneMessages.encode(.root)
    delta.revision = maximum
    var identity = CPFileTreeEntryIdentityValue(); identity.environmentID = values.binding.environmentID.description; identity.relativePath = "main.swift"
    var remove = CPFileTreeMutationValue(); remove.remove = identity
    delta.mutations = [remove]
    #expect(try HostDataPlaneMessages.decode(delta).revision == maximum)
    delta.revision = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_delta"), "tree delta revision") {
        _ = try HostDataPlaneMessages.decode(delta)
    }
    delta.revision = 0
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_delta"), "tree delta zero revision") {
        _ = try HostDataPlaneMessages.decode(delta)
    }

    var subscribe = CPFileTreeSubscribeRequest(); subscribe.afterRevision = maximum
    #expect(try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .subscribeRequest(subscribe))).subscribeRequest.afterRevision == maximum)
    subscribe.afterRevision = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_subscribe_request"), "subscribe revision") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .subscribeRequest(subscribe)))
    }

    var accepted = CPFileTreeSubscriptionAccepted(); accepted.subscriptionID = requestID.description; accepted.revision = maximum
    #expect(try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .subscriptionAccepted(accepted))).subscriptionAccepted.revision == maximum)
    accepted.revision = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_subscription_accepted"), "accepted revision") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .subscriptionAccepted(accepted)))
    }

    let subscriptionID = RequestID(uuid("32000000-0000-4000-8000-000000000002"))
    let eventID = RequestID(uuid("32000000-0000-4000-8000-000000000003"))
    var deltaAck = CPFileTreeDeltaAck(); deltaAck.subscriptionID = subscriptionID.description; deltaAck.eventID = eventID.description; deltaAck.revision = maximum
    #expect(try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .deltaAck(deltaAck))).deltaAck.revision == maximum)
    deltaAck.revision = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_delta_ack"), "delta ack revision") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .deltaAck(deltaAck)))
    }
    var ackAccepted = CPFileTreeAckAccepted(); ackAccepted.subscriptionID = subscriptionID.description; ackAccepted.eventID = eventID.description; ackAccepted.revision = maximum
    #expect(try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .ackAccepted(ackAccepted))).ackAccepted.revision == maximum)
    ackAccepted.revision = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("file_tree_ack_accepted"), "ack accepted revision") {
        _ = try HostDataPlaneMessages.decodeFileTreeEnvelope(hostDataPlaneProtocolFileTreeBytes(values, requestID, .ackAccepted(ackAccepted)))
    }
}

@Test func hostDataPlaneProtocolRejectsUnsafeFingerprintDirectlyAndWhenNested() throws {
    let values = hostDataPlaneProtocolFixture()
    let maximum = documentJavaScriptMaximum
    let unsafe = maximum + 1
    let maximumFingerprint = DiskFingerprint(
        deviceID: values.fingerprint.deviceID,
        inode: values.fingerprint.inode,
        byteCount: maximum,
        modificationTimeSeconds: values.fingerprint.modificationTimeSeconds,
        modificationTimeNanoseconds: values.fingerprint.modificationTimeNanoseconds,
        contentSHA256: values.fingerprint.contentSHA256
    )
    #expect(try HostDataPlaneMessages.encode(maximumFingerprint).byteCount == maximum)
    var wireFingerprint = try HostDataPlaneMessages.encode(maximumFingerprint)
    #expect(try HostDataPlaneMessages.decode(wireFingerprint).byteCount == maximum)

    let unsafeFingerprint = DiskFingerprint(
        deviceID: values.fingerprint.deviceID,
        inode: values.fingerprint.inode,
        byteCount: unsafe,
        modificationTimeSeconds: values.fingerprint.modificationTimeSeconds,
        modificationTimeNanoseconds: values.fingerprint.modificationTimeNanoseconds,
        contentSHA256: values.fingerprint.contentSHA256
    )
    hostDataPlaneProtocolExpectMappingError(.invalidValue("disk_fingerprint"), "fingerprint encode byte count") {
        _ = try HostDataPlaneMessages.encode(unsafeFingerprint)
    }
    wireFingerprint.byteCount = unsafe
    hostDataPlaneProtocolExpectMappingError(.invalidValue("disk_fingerprint"), "fingerprint decode byte count") {
        _ = try HostDataPlaneMessages.decode(wireFingerprint)
    }

    let requestID = RequestID(uuid("33000000-0000-4000-8000-000000000001"))
    var save = CPDocumentSaveRequest()
    save.documentID = values.documentID.description
    save.expectedFingerprint = wireFingerprint
    hostDataPlaneProtocolExpectMappingError(.invalidValue("disk_fingerprint"), "nested save fingerprint") {
        _ = try HostDataPlaneMessages.decodeDocumentEnvelope(hostDataPlaneProtocolDocumentBytes(values, requestID, .saveRequest(save)))
    }
    var snapshot = try HostDataPlaneMessages.encode(values.snapshot)
    snapshot.observedDiskFingerprint = wireFingerprint
    hostDataPlaneProtocolExpectMappingError(.invalidValue("disk_fingerprint"), "nested snapshot fingerprint") {
        _ = try HostDataPlaneMessages.decode(snapshot)
    }
}

@Test func hostDataPlaneProtocolRejectsUnknownFieldsUnsafeBoundsAndInvalidNestedValues() throws {
    let values = hostDataPlaneProtocolFixture()
    #expect(throws: ProtocolMappingError.invalidValue("host_data_plane_binding")) {
        _ = try HostDataPlaneBinding(
            validatingClientInstanceID: values.binding.clientInstanceID,
            windowID: values.binding.windowID,
            workspaceContextID: values.binding.workspaceContextID,
            environmentID: values.binding.environmentID,
            activeContextGeneration: documentJavaScriptMaximum + 1
        )
    }

    var binding = try HostDataPlaneMessages.encode(values.binding)
    binding.activeContextGeneration = 0
    #expect(throws: ProtocolMappingError.invalidValue("host_data_plane_binding")) {
        _ = try HostDataPlaneMessages.decode(binding)
    }
    let bindingWithUnknown = try CPDataPlaneBinding(
        serializedBytes: try HostDataPlaneMessages.encode(values.binding).serializedData() + Data([0x98, 0x06, 0x01])
    )
    #expect(throws: ProtocolMappingError.unknownFields("data_plane_binding")) {
        _ = try HostDataPlaneMessages.decode(bindingWithUnknown)
    }

    var fingerprint = try HostDataPlaneMessages.encode(values.fingerprint)
    fingerprint.contentSha256 = Data(repeating: 0, count: 31)
    #expect(throws: ProtocolMappingError.invalidValue("disk_fingerprint")) {
        _ = try HostDataPlaneMessages.decode(fingerprint)
    }
    fingerprint = try HostDataPlaneMessages.encode(values.fingerprint)
    fingerprint.modificationTimeNanoseconds = 1_000_000_000
    #expect(throws: ProtocolMappingError.invalidValue("disk_fingerprint")) {
        _ = try HostDataPlaneMessages.decode(fingerprint)
    }

    var snapshot = try HostDataPlaneMessages.encode(values.snapshot)
    snapshot.documentVersion = documentJavaScriptMaximum + 1
    #expect(throws: ProtocolMappingError.invalidValue("document_snapshot")) {
        _ = try HostDataPlaneMessages.decode(snapshot)
    }
    var delta = CPFileTreeDeltaValue()
    delta.environmentID = values.binding.environmentID.description
    delta.directory = try HostDataPlaneMessages.encode(.root)
    delta.revision = documentJavaScriptMaximum + 1
    #expect(throws: ProtocolMappingError.invalidValue("file_tree_delta")) {
        _ = try HostDataPlaneMessages.decode(delta)
    }

    let unsafeSnapshot = try FileTreeSnapshot(
        validating: values.binding.environmentID,
        directory: .root,
        generation: documentJavaScriptMaximum + 1,
        revision: 0,
        children: []
    )
    #expect(throws: ProtocolMappingError.invalidValue("file_tree_snapshot")) {
        _ = try HostDataPlaneMessages.encode(unsafeSnapshot)
    }
    let unsafeIdentity = try FileTreeEntryIdentity(
        validating: values.binding.environmentID,
        path: RelativePath("main.swift")
    )
    let unsafeDelta = try FileTreeDelta(
        validating: values.binding.environmentID,
        directory: .root,
        revision: documentJavaScriptMaximum + 1,
        mutations: [.remove(unsafeIdentity)]
    )
    #expect(throws: ProtocolMappingError.invalidValue("file_tree_delta")) {
        _ = try HostDataPlaneMessages.encode(unsafeDelta)
    }
}

@Test func hostDataPlaneProtocolValidatesBindingBeforePayload() throws {
    let values = hostDataPlaneProtocolFixture()
    var invalidBinding = try HostDataPlaneMessages.encode(values.binding)
    invalidBinding.activeContextGeneration = 0
    var invalidApply = CPDocumentApplyRequest()
    invalidApply.documentID = values.documentID.description
    invalidApply.editLeaseID = values.lease.id.description
    invalidApply.clientSequence = 0
    var envelope = CPDocumentEnvelope()
    envelope.requestID = RequestID().description
    envelope.binding = invalidBinding
    envelope.applyRequest = invalidApply

    #expect(throws: ProtocolMappingError.invalidValue("host_data_plane_binding")) {
        _ = try HostDataPlaneMessages.decodeDocumentEnvelope(envelope.serializedData())
    }

    envelope.binding = try HostDataPlaneMessages.encode(values.binding)
    #expect(throws: ProtocolMappingError.invalidValue("document_apply_request")) {
        _ = try HostDataPlaneMessages.decodeDocumentEnvelope(envelope.serializedData())
    }
}

@Test func hostDataPlaneProtocolControlErrorsNeverDecodeAsHandshakeResponses() throws {
    var wireError = CPDataPlaneError(); wireError.code = .invalidTicket
    var control = CPHostDataPlaneControlEnvelope(); control.error = wireError
    let bytes = try control.serializedData()
    #expect(throws: ProtocolMappingError.invalidValue("handshake_response")) {
        _ = try HostDataPlaneMessages.decodeHandshakeResponse(bytes)
    }

    var request = CPHandshakeRequest()
    request.protocolMajor = 1; request.protocolMinor = 1
    request.deviceID = DeviceID(uuid("cccccccc-0000-4000-8000-000000000001")).description
    request.requestedFeatures = [ProtocolFeature.hostDataPlane.rawValue]
    control = CPHostDataPlaneControlEnvelope(); control.handshakeRequest = request
    #expect(try HostDataPlaneMessages.decodeControlEnvelope(control.serializedData()).payload != nil)

    var response = CPHandshakeResponse()
    response.protocolMajor = 1; response.protocolMinor = 1
    response.connectionID = ConnectionID(uuid("cccccccc-0000-4000-8000-000000000002")).description
    response.acceptedFeatures = [ProtocolFeature.hostDataPlane.rawValue]
    response.serviceKind = "host-data-plane"
    control = CPHostDataPlaneControlEnvelope(); control.handshakeResponse = response
    #expect(try HostDataPlaneMessages.decodeHandshakeResponse(control.serializedData()) == response)
}

@Test func hostDataPlaneProtocolValidatesRemoteErrorPresenceRules() throws {
    #expect(try DataPlaneRemoteError(validatingCode: .invalidTicket, expected: nil, actual: nil).code == .invalidTicket)
    #expect(try DataPlaneRemoteError(validatingCode: .generationMismatch, expected: 4, actual: 3).expected == 4)
    #expect(try DataPlaneRemoteError(validatingCode: .treeRevisionUnavailable, expected: 7, actual: 5).actual == 5)
    #expect(throws: ProtocolMappingError.invalidValue("data_plane_error")) {
        _ = try DataPlaneRemoteError(validatingCode: .unspecified, expected: nil, actual: nil)
    }
    #expect(throws: ProtocolMappingError.invalidValue("data_plane_error")) {
        _ = try DataPlaneRemoteError(validatingCode: .invalidTicket, expected: 1, actual: 2)
    }
    #expect(throws: ProtocolMappingError.invalidValue("data_plane_error")) {
        _ = try DataPlaneRemoteError(validatingCode: .generationMismatch, expected: 1, actual: nil)
    }
    #expect(throws: ProtocolMappingError.invalidValue("data_plane_error")) {
        _ = try DataPlaneRemoteError(validatingCode: .documentInvalidLease, expected: nil, actual: nil)
    }
}

@Test func hostDataPlaneProtocolValidatesSharedRemoteErrorJavaScriptBoundaries() throws {
    let maximum = documentJavaScriptMaximum
    let expectedAtMaximum = try DataPlaneRemoteError(
        validatingCode: .generationMismatch,
        expected: maximum,
        actual: 1
    )
    #expect(expectedAtMaximum.expected == maximum)
    #expect(throws: ProtocolMappingError.invalidValue("data_plane_error")) {
        _ = try DataPlaneRemoteError(
            validatingCode: .generationMismatch,
            expected: maximum + 1,
            actual: 1
        )
    }

    let actualAtMaximum = try DataPlaneRemoteError(
        validatingCode: .treeRevisionUnavailable,
        expected: 1,
        actual: maximum
    )
    #expect(actualAtMaximum.actual == maximum)
    #expect(throws: ProtocolMappingError.invalidValue("data_plane_error")) {
        _ = try DataPlaneRemoteError(
            validatingCode: .treeRevisionUnavailable,
            expected: 1,
            actual: maximum + 1
        )
    }
}

@Test func hostDataPlaneProtocolExhaustivelyValidatesEveryErrorPresenceCombination() throws {
    let values = hostDataPlaneProtocolFixture()
    let codes: [CPDataPlaneErrorCode] = [
        .unspecified, .malformedMessage, .wrongChannel, .sequenceViolation, .ackViolation,
        .unauthorizedPeer, .invalidTicket, .ticketExpired, .ticketReplay, .contextMismatch,
        .environmentMismatch, .generationMismatch, .requestIDReuse, .documentNotOpen,
        .documentInvalidValue, .documentInvalidLease, .documentLeaseHeld,
        .documentBaseVersionMismatch, .documentSequenceGap, .documentDuplicateMismatch,
        .documentStaleSequence, .documentRecoveryRequired, .documentResynchronizing,
        .documentReadOnly, .documentFileMissing, .documentFingerprintMismatch,
        .treeZeroGeneration, .treeSymbolicLink, .treeRevisionUnavailable,
        .treeEventSourceUnavailable, .treeEnumerationFailed, .treeBackpressure,
        .requestCancelled, .internal, .UNRECOGNIZED(999),
    ]
    let paired: Set<CPDataPlaneErrorCode> = [
        .generationMismatch, .documentBaseVersionMismatch,
        .documentSequenceGap, .treeRevisionUnavailable,
    ]

    for code in codes {
        for hasExpected in [false, true] {
            for hasActual in [false, true] {
                for hasCommittedAcknowledgement in [false, true] {
                    var error = CPDataPlaneError()
                    error.code = code
                    if hasExpected { error.expected = 1 }
                    if hasActual { error.actual = 1 }
                    if hasCommittedAcknowledgement {
                        error.committedAcknowledgement = try HostDataPlaneMessages.encode(values.acknowledgement)
                    }
                    let isRecognized: Bool
                    if case .UNRECOGNIZED = code { isRecognized = false } else { isRecognized = code != .unspecified }
                    let isValid = isRecognized
                        && hasExpected == paired.contains(code)
                        && hasActual == paired.contains(code)
                        && hasCommittedAcknowledgement == (code == .documentRecoveryRequired)
                    let bytes = try hostDataPlaneProtocolControlBytes(.error(error))
                    let caseName = "error \(code.rawValue) expected=\(hasExpected) actual=\(hasActual) committed=\(hasCommittedAcknowledgement)"
                    if isValid {
                        let decoded = try HostDataPlaneMessages.decodeControlEnvelope(bytes)
                        #expect(decoded.error.code == code)
                    } else {
                        hostDataPlaneProtocolExpectMappingError(.invalidValue("data_plane_error"), caseName) {
                            _ = try HostDataPlaneMessages.decodeControlEnvelope(bytes)
                        }
                    }
                }
            }
        }
    }

    var error = CPDataPlaneError()
    error.code = .generationMismatch
    error.expected = documentJavaScriptMaximum
    error.actual = documentJavaScriptMaximum
    #expect(try HostDataPlaneMessages.decodeControlEnvelope(hostDataPlaneProtocolControlBytes(.error(error))).error.expected == documentJavaScriptMaximum)
    error.expected = documentJavaScriptMaximum + 1
    hostDataPlaneProtocolExpectMappingError(.invalidValue("data_plane_error"), "unsafe expected") {
        _ = try HostDataPlaneMessages.decodeControlEnvelope(hostDataPlaneProtocolControlBytes(.error(error)))
    }
    error.expected = documentJavaScriptMaximum
    error.actual = documentJavaScriptMaximum + 1
    hostDataPlaneProtocolExpectMappingError(.invalidValue("data_plane_error"), "unsafe actual") {
        _ = try HostDataPlaneMessages.decodeControlEnvelope(hostDataPlaneProtocolControlBytes(.error(error)))
    }

    error = .init()
    error.code = .documentRecoveryRequired
    error.committedAcknowledgement = try hostDataPlaneProtocolAddingUnknownField(
        HostDataPlaneMessages.encode(values.acknowledgement)
    )
    hostDataPlaneProtocolExpectMappingError(.unknownFields("document_acknowledgement"), "committed acknowledgement unknown fields") {
        _ = try HostDataPlaneMessages.decodeControlEnvelope(hostDataPlaneProtocolControlBytes(.error(error)))
    }
    error.committedAcknowledgement = try HostDataPlaneMessages.encode(values.acknowledgement)
    error.committedAcknowledgement.clientSequence = 0
    hostDataPlaneProtocolExpectMappingError(.invalidValue("document_acknowledgement"), "committed acknowledgement invalid counters") {
        _ = try HostDataPlaneMessages.decodeControlEnvelope(hostDataPlaneProtocolControlBytes(.error(error)))
    }
}

@Test func hostDataPlaneProtocolChoosesEnvelopeOnlyAfterFrameValidation() throws {
    let values = hostDataPlaneProtocolFixture()
    var document = CPDocumentEnvelope()
    document.requestID = RequestID().description
    document.binding = try HostDataPlaneMessages.encode(values.binding)
    var open = CPDocumentOpenRequest(); open.relativePath = values.path.string
    document.openRequest = open
    let payload = try document.serializedData()
    let header = FrameHeader(
        flags: 0,
        channel: .documentEdits,
        sequence: 1,
        acknowledgement: 0,
        payloadLength: UInt32(payload.count)
    )
    let decoded = try HostDataPlaneMessages.decodeEnvelope(Frame(header: header, payload: payload))
    guard case let .document(value) = decoded else {
        Issue.record("Expected document envelope")
        return
    }
    #expect(value.requestID == document.requestID)

    var malformedHeader = header.encoded()
    malformedHeader[0] = 0
    let validPayloadAfterBadHeader = malformedHeader + payload
    var decoder = FrameDecoder()
    #expect(throws: FrameCodecError.invalidMagic(0x004B5054)) {
        _ = try decoder.append(validPayloadAfterBadHeader)
    }

    let unknownChannel = FrameHeader(
        flags: 0,
        channel: ChannelID(rawValue: 99),
        sequence: 1,
        acknowledgement: 0,
        payloadLength: 1
    )
    #expect(throws: ProtocolMappingError.invalidValue("host_data_plane_channel")) {
        _ = try HostDataPlaneMessages.decodeEnvelope(Frame(header: unknownChannel, payload: Data([0xFF])))
    }
}

@Test func hostDataPlaneProtocolHasNoReverseHostCoreDependency() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
    let protocolTargetStart = try #require(manifest.range(of: ".target(\n            name: \"CockpitProtocol\""))
    let protocolTestsStart = try #require(
        manifest.range(of: ".testTarget(\n            name: \"CockpitProtocolTests\"", range: protocolTargetStart.upperBound..<manifest.endIndex)
    )
    let protocolTarget = manifest[protocolTargetStart.lowerBound..<protocolTestsStart.lowerBound]

    #expect(protocolTarget.contains("\"CockpitTypes\""))
    #expect(protocolTarget.contains(".product(name: \"SwiftProtobuf\", package: \"swift-protobuf\")"))
    #expect(!protocolTarget.contains("CockpitHostCore"))
}

private struct HostDataPlaneProtocolFixture {
    let binding: HostDataPlaneBinding
    let documentID: DocumentID
    let path: RelativePath
    let fingerprint: DiskFingerprint
    let lease: EditLease
    let acknowledgement: EditAcknowledgement
    let snapshot: DocumentSnapshot
}

private func hostDataPlaneProtocolFixture() -> HostDataPlaneProtocolFixture {
    let clientID = ClientInstanceID(uuid("10000000-0000-4000-8000-000000000001"))
    let environmentID = EnvironmentID(uuid("10000000-0000-4000-8000-000000000002"))
    let documentID = DocumentID(uuid("10000000-0000-4000-8000-000000000003"))
    let path = try! RelativePath("Sources/main.swift")
    let fingerprint = DiskFingerprint(
        deviceID: 1,
        inode: 2,
        byteCount: 3,
        modificationTimeSeconds: -4,
        modificationTimeNanoseconds: 5,
        contentSHA256: try! SHA256Digest(validating: Data(repeating: 0xAB, count: 32))
    )
    let lease = try! EditLease(
        validatingID: EditLeaseID(uuid("10000000-0000-4000-8000-000000000004")),
        documentID: documentID,
        clientInstanceID: clientID
    )
    let acknowledgement = try! EditAcknowledgement(
        validatingDocumentID: documentID,
        clientSequence: 1,
        documentVersion: 1
    )
    let binding = try! HostDataPlaneBinding(
        validatingClientInstanceID: clientID,
        windowID: WindowID(uuid("10000000-0000-4000-8000-000000000005")),
        workspaceContextID: .project(ProjectID(uuid("10000000-0000-4000-8000-000000000006"))),
        environmentID: environmentID,
        activeContextGeneration: 7
    )
    let snapshot = try! DocumentSnapshot(
        validatingDocumentID: documentID,
        environmentID: environmentID,
        relativePath: path,
        text: "abc\n",
        documentVersion: 1,
        persistedVersion: 0,
        lastAcceptedClientSequence: 1,
        dirtyState: .dirty,
        observedDiskFingerprint: fingerprint,
        currentLease: lease,
        maintenance: [.truncatedRecoveryTail, .compactionDeferred]
    )
    return HostDataPlaneProtocolFixture(
        binding: binding,
        documentID: documentID,
        path: path,
        fingerprint: fingerprint,
        lease: lease,
        acknowledgement: acknowledgement,
        snapshot: snapshot
    )
}

private func uuid(_ value: String) -> UUID { UUID(uuidString: value)! }

private func hostDataPlaneProtocolExpectBytes<Message: SwiftProtobuf.Message>(
    _ message: Message,
    _ expected: [UInt8]
) throws {
    #expect(Array(try message.serializedData()) == expected)
}

private func hostDataPlaneProtocolAddingUnknownField<Message: SwiftProtobuf.Message>(
    _ message: Message
) throws -> Message {
    var bytes = try message.serializedData()
    bytes.append(contentsOf: [0x98, 0x06, 0x01])
    return try Message(serializedBytes: bytes)
}

private func hostDataPlaneProtocolExpectMappingError(
    _ expected: ProtocolMappingError,
    _ name: String,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("\(name): accepted malformed wire")
    } catch let actual as ProtocolMappingError {
        if actual != expected {
            Issue.record("\(name): expected \(expected), received \(actual)")
        }
    } catch {
        Issue.record("\(name): expected \(expected), received \(error)")
    }
}

private func hostDataPlaneProtocolControlBytes(
    _ payload: CPHostDataPlaneControlEnvelope.OneOf_Payload
) throws -> Data {
    var envelope = CPHostDataPlaneControlEnvelope()
    envelope.payload = payload
    return try envelope.serializedData()
}

private func hostDataPlaneProtocolDocumentBytes(
    _ values: HostDataPlaneProtocolFixture,
    _ requestID: RequestID,
    _ payload: CPDocumentEnvelope.OneOf_Payload
) throws -> Data {
    var envelope = CPDocumentEnvelope()
    envelope.requestID = requestID.description
    envelope.binding = try HostDataPlaneMessages.encode(values.binding)
    envelope.payload = payload
    return try envelope.serializedData()
}

private func hostDataPlaneProtocolFileTreeBytes(
    _ values: HostDataPlaneProtocolFixture,
    _ requestID: RequestID,
    _ payload: CPFileTreeEnvelope.OneOf_Payload
) throws -> Data {
    var envelope = CPFileTreeEnvelope()
    envelope.requestID = requestID.description
    envelope.binding = try HostDataPlaneMessages.encode(values.binding)
    envelope.payload = payload
    return try envelope.serializedData()
}

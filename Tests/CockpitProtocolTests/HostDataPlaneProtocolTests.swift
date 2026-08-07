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

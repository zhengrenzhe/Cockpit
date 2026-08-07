import Foundation
import Testing
import CockpitTypes
@testable import CockpitProtocol

@Test func documentRecoveryRecordUsesFrozenHashAndDelimitedProtobufFraming() throws {
    let documentID = DocumentID(try protocolUUID(12))
    let record = try DocumentRecoveryRecord(
        documentID: documentID,
        documentVersion: 1,
        clientSequence: 1,
        utf8EditPayload: Data(#"{"edit":"x"}"#.utf8)
    )
    #expect(record.recordSHA256.bytes.map { String(format: "%02x", $0) }.joined() == "03396d54c8480d4b1302b80c8d9f37ce88b14244581b020c3ade292b4196a4c5")

    let framed = try DocumentMessages.encodeDelimited(record)
    let decoded = try DocumentMessages.decodeDelimitedRecord(framed)
    #expect(decoded.value == record)
    #expect(decoded.consumedBytes == framed.count)
}

@Test func documentRecoveryCheckpointUsesIndependentFrozenHashDomain() throws {
    let persistedBytes = Data("hello\n".utf8)
    let checkpoint = try DocumentRecoveryCheckpoint(
        documentID: DocumentID(try protocolUUID(12)),
        persistedDocumentVersion: 0,
        persistedClientSequence: 0,
        diskFingerprint: DiskFingerprint(
            deviceID: 9,
            inode: 10,
            byteCount: UInt64(persistedBytes.count),
            modificationTimeSeconds: -12,
            modificationTimeNanoseconds: 13,
            contentSHA256: try SHA256Digest(
                validating: protocolHexData("5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
            )
        ),
        persistedDocumentBytes: persistedBytes
    )
    #expect(checkpoint.checkpointSHA256.bytes.map { String(format: "%02x", $0) }.joined() == "4769bb5a48487c87d0a28001a5b12863716052c35a498606b125e339d864c7df")
    let message = try DocumentMessages.encode(checkpoint)
    #expect(message.formatVersion == 2)
    #expect(message.persistedDocumentBytes == persistedBytes)
    #expect(
        try DocumentMessages.decodeDelimitedCheckpoint(
            DocumentMessages.encodeDelimited(checkpoint)
        ).value == checkpoint
    )
}

@Test func documentRecoveryCheckpointRejectsMismatchedBytesAndSequenceAboveVersion() throws {
    let bytes = Data("disk".utf8)
    let fingerprint = DiskFingerprint(
        deviceID: 1,
        inode: 2,
        byteCount: UInt64(bytes.count),
        modificationTimeSeconds: 3,
        modificationTimeNanoseconds: 4,
        contentSHA256: try SHA256Digest(
            validating: protocolHexData("4b1e72365f7c481426ceb098c15adc429eb64e51e5d656409236fbdd1a99f4c2")
        )
    )
    #expect(throws: ProtocolMappingError.self) {
        _ = try DocumentRecoveryCheckpoint(
            documentID: DocumentID(try protocolUUID(14)),
            persistedDocumentVersion: 0,
            persistedClientSequence: 1,
            diskFingerprint: fingerprint,
            persistedDocumentBytes: bytes
        )
    }
    #expect(throws: ProtocolMappingError.self) {
        _ = try DocumentRecoveryCheckpoint(
            documentID: DocumentID(try protocolUUID(14)),
            persistedDocumentVersion: 0,
            persistedClientSequence: 0,
            diskFingerprint: fingerprint,
            persistedDocumentBytes: Data("other".utf8)
        )
    }
}

@Test func documentEditingCanonicalPayloadRoundTripsExactSchemaAndRejectsMutation() throws {
    let transaction = try EditTransaction(
        validatingDocumentID: DocumentID(try protocolUUID(21)),
        editLeaseID: EditLeaseID(try protocolUUID(22)),
        baseVersion: 7,
        clientSequence: 8,
        changes: [
            try UTF16TextEdit(validatingOffset: 1, length: 2, replacement: "x"),
            try UTF16TextEdit(validatingOffset: 5, length: 0, replacement: "y\n"),
        ]
    )
    let payload = try DocumentEditing.encodeRecoveryPayload(transaction)
    #expect(String(decoding: payload, as: UTF8.self) == #"{"baseVersion":7,"changes":[{"length":2,"offset":1,"replacement":"x"},{"length":0,"offset":5,"replacement":"y\n"}],"clientSequence":8,"documentID":"00000000-0000-0000-0000-000000000021","editLeaseID":"00000000-0000-0000-0000-000000000022"}"#)
    #expect(try DocumentEditing.decodeRecoveryPayload(payload) == transaction)

    let unknown = Data(String(decoding: payload.dropLast(), as: UTF8.self).appending(",\"unknown\":true}").utf8)
    #expect(throws: DocumentProtocolError.self) {
        _ = try DocumentEditing.decodeRecoveryPayload(unknown)
    }
    #expect(throws: DocumentProtocolError.self) {
        _ = try EditTransaction(
            validatingDocumentID: transaction.documentID,
            editLeaseID: transaction.editLeaseID,
            baseVersion: 7,
            clientSequence: 8,
            changes: [
                try UTF16TextEdit(validatingOffset: 2, length: 2, replacement: "a"),
                try UTF16TextEdit(validatingOffset: 3, length: 1, replacement: "b"),
            ]
        )
    }
}

@Test func documentRecoveryMapperRejectsFrozenMalformedFieldsAndUnknownFields() throws {
    let record = try DocumentRecoveryRecord(
        documentID: DocumentID(try #require(UUID(uuidString: "00000000-0000-0000-0000-abcdefabcdef"))),
        documentVersion: 1,
        clientSequence: 1,
        utf8EditPayload: Data("valid".utf8)
    )
    var message = try DocumentMessages.encode(record)
    let validHash = message.recordSha256
    let mutations: [(inout CPDocumentRecoveryRecord) -> Void] = [
        { $0.magic = Data("BAD!".utf8) },
        { $0.formatVersion = 2 },
        { $0.documentID = $0.documentID.uppercased() },
        { $0.documentVersion = 0 },
        { $0.clientSequence = 0 },
        { $0.recordSha256 = Data(repeating: 0, count: 31) },
        { $0.utf8EditPayload = Data() },
        { $0.utf8EditPayload = Data([0xC3, 0x28]) },
        { $0.utf8EditPayload = Data("bad\0payload".utf8) },
    ]
    for mutate in mutations {
        message = try DocumentMessages.encode(record)
        mutate(&message)
        #expect(throws: ProtocolMappingError.self) { _ = try DocumentMessages.decode(message) }
    }
    message = try CPDocumentRecoveryRecord(serializedBytes: try message.serializedData() + Data([0x98, 0x06, 0x01]))
    message.recordSha256 = validHash
    #expect(throws: ProtocolMappingError.unknownFields("document_recovery_record")) {
        _ = try DocumentMessages.decode(message)
    }
}

@Test func documentRecoveryDelimitedVarintRejectsNonCanonicalAndOverflowWithoutTrapping() {
    #expect(throws: DocumentDelimitedError.malformed) {
        _ = try DocumentMessages.decodeDelimitedRecord(Data([0x80, 0x00]))
    }
    #expect(throws: DocumentDelimitedError.malformed) {
        _ = try DocumentMessages.decodeDelimitedRecord(
            Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02])
        )
    }
    #expect(throws: DocumentDelimitedError.truncated) {
        _ = try DocumentMessages.decodeDelimitedRecord(
            Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        )
    }
}

@Test func documentRecoveryFingerprintCodableRejectsInvalidNanoseconds() {
    let json = Data(#"""
    {
      "deviceID": 1,
      "inode": 2,
      "byteCount": 3,
      "modificationTimeSeconds": 4,
      "modificationTimeNanoseconds": 1000000000,
      "contentSHA256": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    }
    """#.utf8)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(DiskFingerprint.self, from: json)
    }
}

private let protocol11 = ProtocolVersion(major: 1, minor: 1)

private func protocolUUID(_ suffix: Int) throws -> UUID {
    try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix)))
}

private func protocolHexData(_ hex: String) throws -> Data {
    guard hex.count.isMultiple(of: 2) else { throw CocoaError(.coderInvalidValue) }
    var result = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else {
            throw CocoaError(.coderInvalidValue)
        }
        result.append(byte)
        index = next
    }
    return result
}

private func requestContext(generation: UInt64 = 17) throws -> RequestContext {
    try RequestContext(
        validating: protocol11,
        clientInstanceID: ClientInstanceID(try protocolUUID(1)),
        windowID: WindowID(try protocolUUID(2)),
        workspaceContextID: .project(ProjectID(try protocolUUID(3))),
        environmentID: EnvironmentID(try protocolUUID(4)),
        activeContextGeneration: generation,
        requestID: RequestID(try protocolUUID(5))
    )
}

private func terminalInput(_ payload: TerminalInput.Payload, sequence: UInt64 = 1) throws -> TerminalInput {
    try TerminalInput(
        validatingContext: requestContext(),
        terminalSessionID: TerminalSessionID(try protocolUUID(6)),
        inputLeaseID: InputLeaseID(try protocolUUID(7)),
        inputSequence: sequence,
        payload: payload
    )
}

private func archiveMessageForMalformedTests() throws -> CPTerminalArchiveManifest {
    let digest = try SHA256Digest(validating: Data(repeating: 0x44, count: 32))
    let first = try TerminalArchiveChunk(
        validatingName: "00000000000000000001.ckgs",
        firstOutputSequence: 1,
        lastOutputSequence: 10,
        sha256: digest
    )
    let second = try TerminalArchiveChunk(
        validatingName: "00000000000000000021.ckgs",
        firstOutputSequence: 21,
        lastOutputSequence: 25,
        sha256: digest
    )
    let manifest = try TerminalArchiveManifest(
        validatingTerminalSessionID: TerminalSessionID(try protocolUUID(40)),
        workerInstanceID: WorkerInstanceID(try protocolUUID(41)),
        firstOutputSequence: 1,
        latestOutputSequence: 30,
        chunks: [first, second],
        finalSnapshotSHA256: digest,
        exitStatus: .exited(0),
        completedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    return try TerminalMessages.encode(manifest, negotiatedVersion: protocol11)
}

@Test func workspaceContextAndRequestContextRoundTripAllContextKindsAndGenerations() throws {
    let project = ProjectID(try protocolUUID(10))
    let conversation = ConversationID(try protocolUUID(11))
    #expect(try WorkspaceMessages.decode(WorkspaceMessages.encode(.project(project))) == .project(project))
    #expect(try WorkspaceMessages.decode(WorkspaceMessages.encode(.conversation(conversation))) == .conversation(conversation))

    for generation in [UInt64(17), 18, 19] {
        let original = try requestContext(generation: generation)
        let message = try WorkspaceMessages.encode(original, negotiatedVersion: protocol11)
        let decoded = try WorkspaceMessages.decode(message, negotiatedVersion: protocol11)
        #expect(decoded == original)
        #expect(decoded.activeContextGeneration == generation)
    }
}

@Test func documentIDMappingUsesCanonicalUUIDAndRejectsMalformedText() throws {
    let documentID = DocumentID(try protocolUUID(12))
    #expect(DocumentMessages.encode(documentID) == "00000000-0000-0000-0000-000000000012")
    #expect(try DocumentMessages.decode(documentID.description) == documentID)
    for value in ["", "not-a-uuid"] {
        #expect(throws: ProtocolMappingError.invalidIdentifier("document_id")) {
            _ = try DocumentMessages.decode(value)
        }
    }
}

@Test func terminalInputRoundTripsAllSixPayloadsAndFrozenValues() throws {
    let key = try TerminalKeyEvent(
        validatingLogicalKey: 0x1F642, physicalKey: 0x04, modifiers: 0x3FF, action: .repeat
    )
    let mouse = try TerminalMouseEvent(
        validatingCellX: -2, cellY: 4, buttons: 0x7FF, wheelX: -65_536,
        wheelY: 131_072, modifiers: 3, action: .scroll
    )
    let resize = try TerminalResize(validatingColumns: 120, rows: 40)
    let fixtures: [(TerminalInput.Payload, ChannelID)] = [
        (.text("hello"), .terminalInput),
        (.key(key), .terminalInput),
        (.paste("paste"), .terminalInput),
        (.mouse(mouse), .terminalInput),
        (.resize(resize), .terminalInput),
        (.signal(.interrupt), .control),
    ]
    for (index, fixture) in fixtures.enumerated() {
        let original = try terminalInput(fixture.0, sequence: UInt64(index + 1))
        let message = try TerminalMessages.encode(original, channelID: fixture.1, negotiatedVersion: protocol11)
        let wire = try message.serializedData()
        let decodedMessage = try CPTerminalInput(serializedBytes: wire)
        #expect(try TerminalMessages.decode(decodedMessage, channelID: fixture.1, negotiatedVersion: protocol11) == original)
    }
    #expect(key.action.rawValue == 2)
    #expect(mouse.action.rawValue == 4)
    #expect(mouse.wheelX == -65_536)
}

@Test func terminalInputEncoderAndDecoderEnforceFrozenChannels() throws {
    let signal = try terminalInput(.signal(.quit))
    #expect(throws: ProtocolMappingError.invalidValue("channel_id")) {
        _ = try TerminalMessages.encode(signal, channelID: .terminalInput, negotiatedVersion: protocol11)
    }
    let signalMessage = try TerminalMessages.encode(signal, channelID: .control, negotiatedVersion: protocol11)
    #expect(throws: ProtocolMappingError.invalidValue("channel_id")) {
        _ = try TerminalMessages.decode(signalMessage, channelID: .terminalInput, negotiatedVersion: protocol11)
    }

    let text = try terminalInput(.text("x"))
    #expect(throws: ProtocolMappingError.invalidValue("channel_id")) {
        _ = try TerminalMessages.encode(text, channelID: .control, negotiatedVersion: protocol11)
    }
    let textMessage = try TerminalMessages.encode(text, channelID: .terminalInput, negotiatedVersion: protocol11)
    #expect(throws: ProtocolMappingError.invalidValue("channel_id")) {
        _ = try TerminalMessages.decode(textMessage, channelID: .control, negotiatedVersion: protocol11)
    }
}

@Test func requestAndTerminalMappersRejectUnsupportedOrMismatchedVersionsFirst() throws {
    let context = try requestContext()
    #expect(throws: ProtocolMappingError.invalidValue("negotiated_version")) {
        _ = try WorkspaceMessages.encode(context, negotiatedVersion: .init(major: 1, minor: 0))
    }
    #expect(throws: ProtocolMappingError.invalidValue("protocol_version")) {
        _ = try WorkspaceMessages.encode(context, negotiatedVersion: .init(major: 1, minor: 2))
    }
    let message = try WorkspaceMessages.encode(context, negotiatedVersion: protocol11)
    #expect(throws: ProtocolMappingError.invalidValue("protocol_version")) {
        _ = try WorkspaceMessages.decode(message, negotiatedVersion: .init(major: 1, minor: 2))
    }
}

@Test func requestContextRejectsUnknownFieldsOneofAndMalformedScalars() throws {
    var noContext = CPRequestContext()
    noContext.protocolMajor = 1
    noContext.protocolMinor = 1
    noContext.clientInstanceID = ClientInstanceID(try protocolUUID(1)).description
    noContext.windowID = WindowID(try protocolUUID(2)).description
    noContext.environmentID = EnvironmentID(try protocolUUID(4)).description
    noContext.activeContextGeneration = 17
    noContext.requestID = RequestID(try protocolUUID(5)).description
    #expect(throws: ProtocolMappingError.missingRequiredField("workspace_context_id")) {
        _ = try WorkspaceMessages.decode(noContext, negotiatedVersion: protocol11)
    }

    var unknownOneof = CPWorkspaceContextID()
    #expect(throws: ProtocolMappingError.unknownOneOf("workspace_context_id.kind")) {
        _ = try WorkspaceMessages.decode(unknownOneof)
    }
    unknownOneof = try CPWorkspaceContextID(serializedBytes: [0x98, 0x06, 0x01])
    #expect(throws: ProtocolMappingError.unknownFields("workspace_context_id")) {
        _ = try WorkspaceMessages.decode(unknownOneof)
    }

    var malformed = try WorkspaceMessages.encode(try requestContext(), negotiatedVersion: protocol11)
    malformed.clientInstanceID = "bad"
    #expect(throws: ProtocolMappingError.invalidIdentifier("client_instance_id")) {
        _ = try WorkspaceMessages.decode(malformed, negotiatedVersion: protocol11)
    }
    malformed = try WorkspaceMessages.encode(try requestContext(), negotiatedVersion: protocol11)
    malformed.protocolMajor = 65_536
    #expect(throws: ProtocolMappingError.invalidValue("protocol_version")) {
        _ = try WorkspaceMessages.decode(malformed, negotiatedVersion: protocol11)
    }
    malformed = try WorkspaceMessages.encode(try requestContext(), negotiatedVersion: protocol11)
    malformed.activeContextGeneration = 0
    #expect(throws: ProtocolMappingError.invalidValue("request_context")) {
        _ = try WorkspaceMessages.decode(malformed, negotiatedVersion: protocol11)
    }
}

@Test func terminalInputDecoderRejectsNilUnknownEnumsAndInvalidScalars() throws {
    var message = try TerminalMessages.encode(try terminalInput(.text("x")), channelID: .terminalInput, negotiatedVersion: protocol11)
    message.payload = nil
    #expect(throws: ProtocolMappingError.unknownOneOf("terminal_input.payload")) {
        _ = try TerminalMessages.decode(message, channelID: .terminalInput, negotiatedVersion: protocol11)
    }

    let key = try TerminalKeyEvent(validatingLogicalKey: 65, physicalKey: 4, modifiers: 0, action: .press)
    message = try TerminalMessages.encode(try terminalInput(.key(key)), channelID: .terminalInput, negotiatedVersion: protocol11)
    message.key.action = .UNRECOGNIZED(99)
    #expect(throws: ProtocolMappingError.unknownEnum(field: "terminal_key.action", rawValue: 99)) {
        _ = try TerminalMessages.decode(message, channelID: .terminalInput, negotiatedVersion: protocol11)
    }

    message = try TerminalMessages.encode(try terminalInput(.resize(try TerminalResize(validatingColumns: 80, rows: 24))), channelID: .terminalInput, negotiatedVersion: protocol11)
    message.resize.columns = 65_536
    #expect(throws: ProtocolMappingError.invalidValue("terminal_resize")) {
        _ = try TerminalMessages.decode(message, channelID: .terminalInput, negotiatedVersion: protocol11)
    }
    message = try TerminalMessages.encode(try terminalInput(.text("x")), channelID: .terminalInput, negotiatedVersion: protocol11)
    message.inputSequence = 0
    #expect(throws: ProtocolMappingError.invalidValue("terminal_input")) {
        _ = try TerminalMessages.decode(message, channelID: .terminalInput, negotiatedVersion: protocol11)
    }
}

@Test func terminalInputDecoderRejectsEveryFrozenMalformedPayload() throws {
    var message = try TerminalMessages.encode(
        try terminalInput(.text("valid")), channelID: .terminalInput,
        negotiatedVersion: protocol11
    )
    message.text = ""
    #expect(throws: ProtocolMappingError.invalidValue("terminal_input")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }

    message = try TerminalMessages.encode(
        try terminalInput(.paste("valid")), channelID: .terminalInput,
        negotiatedVersion: protocol11
    )
    message.paste = ""
    #expect(throws: ProtocolMappingError.invalidValue("terminal_input")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }

    let key = try TerminalKeyEvent(
        validatingLogicalKey: 65, physicalKey: 4, modifiers: 0, action: .press
    )
    message = try TerminalMessages.encode(
        try terminalInput(.key(key)), channelID: .terminalInput,
        negotiatedVersion: protocol11
    )
    message.key.logicalKey = 0
    message.key.physicalKey = 0
    #expect(throws: ProtocolMappingError.invalidValue("terminal_key")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }
    message.key.logicalKey = 0xD800
    #expect(throws: ProtocolMappingError.invalidValue("terminal_key")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }
    message.key.logicalKey = 65
    message.key.modifiers = 1 << 10
    #expect(throws: ProtocolMappingError.invalidValue("terminal_key")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }

    let mouse = try TerminalMouseEvent(
        validatingCellX: 0, cellY: 0, buttons: 0, wheelX: 0,
        wheelY: 0, modifiers: 0, action: .motion
    )
    message = try TerminalMessages.encode(
        try terminalInput(.mouse(mouse)), channelID: .terminalInput,
        negotiatedVersion: protocol11
    )
    message.mouse.action = .UNRECOGNIZED(99)
    #expect(throws: ProtocolMappingError.unknownEnum(field: "terminal_mouse.action", rawValue: 99)) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }
    message.mouse.action = .motion
    message.mouse.buttons = 1 << 11
    #expect(throws: ProtocolMappingError.invalidValue("terminal_mouse")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }
    message.mouse.buttons = 0
    message.mouse.wheelX = 1
    #expect(throws: ProtocolMappingError.invalidValue("terminal_mouse")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }
    message.mouse.action = .scroll
    message.mouse.wheelX = 0
    #expect(throws: ProtocolMappingError.invalidValue("terminal_mouse")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }

    message = try TerminalMessages.encode(
        try terminalInput(.resize(try TerminalResize(validatingColumns: 80, rows: 24))),
        channelID: .terminalInput, negotiatedVersion: protocol11
    )
    message.resize.columns = 0
    #expect(throws: ProtocolMappingError.invalidValue("terminal_resize")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }

    message = try TerminalMessages.encode(
        try terminalInput(.signal(.interrupt)), channelID: .control,
        negotiatedVersion: protocol11
    )
    message.signal = .UNRECOGNIZED(99)
    #expect(throws: ProtocolMappingError.unknownEnum(field: "terminal_signal", rawValue: 99)) {
        _ = try TerminalMessages.decode(
            message, channelID: .control, negotiatedVersion: protocol11
        )
    }

    message = try TerminalMessages.encode(
        try terminalInput(.text("valid")), channelID: .terminalInput,
        negotiatedVersion: protocol11
    )
    message.terminalSessionID = "invalid-terminal-id"
    #expect(throws: ProtocolMappingError.invalidIdentifier("terminal_session_id")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }
}

@Test func terminalInputDecoderRejectsUnknownEnumBeforeMappingIdentifiers() throws {
    let key = try TerminalKeyEvent(
        validatingLogicalKey: 65, physicalKey: 4, modifiers: 0, action: .press
    )
    var message = try TerminalMessages.encode(
        try terminalInput(.key(key)), channelID: .terminalInput,
        negotiatedVersion: protocol11
    )
    message.context.clientInstanceID = "invalid-client-id"
    message.key.action = .UNRECOGNIZED(99)
    #expect(throws: ProtocolMappingError.unknownEnum(field: "terminal_key.action", rawValue: 99)) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }

    message = try TerminalMessages.encode(
        try terminalInput(.key(key)), channelID: .terminalInput,
        negotiatedVersion: protocol11
    )
    var contextBytes = Array(try message.context.serializedData())
    contextBytes.append(contentsOf: [0x98, 0x06, 0x01])
    message.context = try CPRequestContext(serializedBytes: contextBytes)
    message.key.action = .UNRECOGNIZED(99)
    #expect(throws: ProtocolMappingError.unknownFields("request_context")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }

    message = try TerminalMessages.encode(
        try terminalInput(.key(key)), channelID: .terminalInput,
        negotiatedVersion: protocol11
    )
    message.context.clientInstanceID = "invalid-client-id"
    message.key.logicalKey = 0
    message.key.physicalKey = 0
    #expect(throws: ProtocolMappingError.invalidIdentifier("client_instance_id")) {
        _ = try TerminalMessages.decode(
            message, channelID: .terminalInput, negotiatedVersion: protocol11
        )
    }
}

@Test func terminalInputFullProtobufFrameLimitRejectsEnvelopeOverflow() throws {
    let exactDomainLimit = String(repeating: "a", count: TerminalInput.maximumTextOrPasteUTF8Bytes)
    let value = try terminalInput(.text(exactDomainLimit))
    #expect(throws: ProtocolMappingError.invalidValue("terminal_input_frame_size")) {
        _ = try TerminalMessages.encode(value, channelID: .terminalInput, negotiatedVersion: protocol11)
    }
}

@Test func archiveRoundTripsExitFormsEmptyOutputChunksAndSequenceGaps() throws {
    let digest = try SHA256Digest(validating: Data(repeating: 0x11, count: 32))
    let completedAt = Date(timeIntervalSince1970: 1_700_000_000.25)
    let empty = try TerminalArchiveManifest(
        validatingTerminalSessionID: TerminalSessionID(try protocolUUID(20)),
        workerInstanceID: WorkerInstanceID(try protocolUUID(21)), firstOutputSequence: 0,
        latestOutputSequence: 0, chunks: [], finalSnapshotSHA256: digest,
        exitStatus: .exited(0), completedAt: completedAt
    )
    let emptyMessage = try TerminalMessages.encode(empty, negotiatedVersion: protocol11)
    #expect(try TerminalMessages.decode(emptyMessage, negotiatedVersion: protocol11) == empty)

    let first = try TerminalArchiveChunk(
        validatingName: "00000000000000000001.ckgs", firstOutputSequence: 1,
        lastOutputSequence: 10, sha256: digest
    )
    let second = try TerminalArchiveChunk(
        validatingName: "00000000000000000021.ckgs", firstOutputSequence: 21,
        lastOutputSequence: 25, sha256: digest
    )
    let chunked = try TerminalArchiveManifest(
        validatingTerminalSessionID: empty.terminalSessionID, workerInstanceID: empty.workerInstanceID,
        firstOutputSequence: 1, latestOutputSequence: 30, chunks: [first, second],
        finalSnapshotSHA256: digest, exitStatus: .signaled(9), completedAt: completedAt
    )
    let chunkedMessage = try TerminalMessages.encode(chunked, negotiatedVersion: protocol11)
    #expect(try TerminalMessages.decode(chunkedMessage, negotiatedVersion: protocol11) == chunked)
}

@Test func archiveDecoderRejectsMalformedHashPathTimestampExitAndSequence() throws {
    let digest = try SHA256Digest(validating: Data(repeating: 0x22, count: 32))
    let chunk = try TerminalArchiveChunk(validatingName: "00000000000000000001.ckgs", firstOutputSequence: 1, lastOutputSequence: 10, sha256: digest)
    let manifest = try TerminalArchiveManifest(
        validatingTerminalSessionID: TerminalSessionID(try protocolUUID(30)),
        workerInstanceID: WorkerInstanceID(try protocolUUID(31)), firstOutputSequence: 1,
        latestOutputSequence: 20, chunks: [chunk], finalSnapshotSHA256: digest,
        exitStatus: .exited(0), completedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    var message = try TerminalMessages.encode(manifest, negotiatedVersion: protocol11)
    message.finalSnapshotSha256 = Data(repeating: 0, count: 31)
    #expect(throws: ProtocolMappingError.invalidValue("final_snapshot_sha256")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }
    message = try TerminalMessages.encode(manifest, negotiatedVersion: protocol11)
    message.chunks[0].name = "/tmp/chunk.ckgs"
    #expect(throws: ProtocolMappingError.invalidValue("terminal_archive_chunk")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }
    message = try TerminalMessages.encode(manifest, negotiatedVersion: protocol11)
    message.exitStatus.result = nil
    #expect(throws: ProtocolMappingError.unknownOneOf("terminal_exit_status.result")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }
    message = try TerminalMessages.encode(manifest, negotiatedVersion: protocol11)
    message.exitStatus.exitCode = 256
    #expect(throws: ProtocolMappingError.invalidValue("terminal_exit_status")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }
    message = try TerminalMessages.encode(manifest, negotiatedVersion: protocol11)
    message.completedAt.seconds = 253_402_300_800
    #expect(throws: ProtocolMappingError.invalidValue("completed_at")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }
    message = try TerminalMessages.encode(manifest, negotiatedVersion: protocol11)
    message.chunks.append(message.chunks[0])
    #expect(throws: ProtocolMappingError.invalidValue("terminal_archive_manifest")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }

    message = try TerminalMessages.encode(manifest, negotiatedVersion: protocol11)
    var chunkBytes = Array(try message.chunks[0].serializedData())
    chunkBytes.append(contentsOf: [0x98, 0x06, 0x01])
    message.chunks[0] = try CPTerminalArchiveChunk(serializedBytes: chunkBytes)
    message.clearExitStatus()
    #expect(throws: ProtocolMappingError.unknownFields("terminal_archive_chunk")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }
}

@Test func archiveDecoderRejectsEveryFrozenMalformedField() throws {
    var message = try archiveMessageForMalformedTests()
    message.terminalSessionID = "invalid-terminal-id"
    #expect(throws: ProtocolMappingError.invalidIdentifier("terminal_session_id")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }

    message = try archiveMessageForMalformedTests()
    message.workerInstanceID = "invalid-worker-id"
    #expect(throws: ProtocolMappingError.invalidIdentifier("worker_instance_id")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }

    message = try archiveMessageForMalformedTests()
    message.chunks[0].sha256 = Data(repeating: 0, count: 31)
    #expect(throws: ProtocolMappingError.invalidValue("terminal_archive_chunk.sha256")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }

    message = try archiveMessageForMalformedTests()
    message.clearExitStatus()
    #expect(throws: ProtocolMappingError.missingRequiredField("exit_status")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }

    message = try archiveMessageForMalformedTests()
    message.clearCompletedAt()
    #expect(throws: ProtocolMappingError.missingRequiredField("completed_at")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }

    for signal in [Int32(0), 32] {
        message = try archiveMessageForMalformedTests()
        message.exitStatus.darwinSignal = signal
        #expect(throws: ProtocolMappingError.invalidValue("terminal_exit_status")) {
            _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
        }
    }

    for nanos in [Int32(-1), 1_000_000_000] {
        message = try archiveMessageForMalformedTests()
        message.completedAt.nanos = nanos
        #expect(throws: ProtocolMappingError.invalidValue("completed_at")) {
            _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
        }
    }
    message = try archiveMessageForMalformedTests()
    message.completedAt.seconds = -62_135_596_801
    #expect(throws: ProtocolMappingError.invalidValue("completed_at")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }

    message = try archiveMessageForMalformedTests()
    message.chunks.swapAt(0, 1)
    #expect(throws: ProtocolMappingError.invalidValue("terminal_archive_manifest")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }

    message = try archiveMessageForMalformedTests()
    message.chunks[1].name = "00000000000000000005.ckgs"
    message.chunks[1].firstOutputSequence = 5
    message.chunks[1].lastOutputSequence = 15
    #expect(throws: ProtocolMappingError.invalidValue("terminal_archive_manifest")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }

    message = try archiveMessageForMalformedTests()
    message.chunks[1].lastOutputSequence = 31
    #expect(throws: ProtocolMappingError.invalidValue("terminal_archive_manifest")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }

    #expect(throws: CockpitDomainValidationError.invalidTerminalExitStatus) {
        _ = try JSONEncoder().encode(TerminalExitStatus.signaled(0))
    }
}

@Test func archiveDecoderAppliesFrozenValidationOrderToCombinedFailures() throws {
    var message = try archiveMessageForMalformedTests()
    message.exitStatus.result = nil
    message.terminalSessionID = "invalid-terminal-id"
    message.workerInstanceID = "invalid-worker-id"
    message.completedAt.seconds = 253_402_300_800
    message.finalSnapshotSha256 = Data(repeating: 0, count: 31)
    message.chunks[0].name = "/absolute.ckgs"
    #expect(throws: ProtocolMappingError.unknownOneOf("terminal_exit_status.result")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }

    message = try archiveMessageForMalformedTests()
    message.terminalSessionID = "invalid-terminal-id"
    message.workerInstanceID = "invalid-worker-id"
    message.completedAt.seconds = 253_402_300_800
    message.finalSnapshotSha256 = Data(repeating: 0, count: 31)
    message.chunks[0].name = "/absolute.ckgs"
    #expect(throws: ProtocolMappingError.invalidIdentifier("terminal_session_id")) {
        _ = try TerminalMessages.decode(message, negotiatedVersion: protocol11)
    }
}

@Test func protocolMappingErrorsAlwaysRedactDetailsAndUseWireCodeThree() {
    let secret = "secret-text-/Users/example/file"
    let cases: [ProtocolMappingError] = [
        .missingRequiredField(secret), .invalidIdentifier(secret), .invalidValue(secret),
        .unknownOneOf(secret), .unknownEnum(field: secret, rawValue: 987_654),
        .unknownFields(secret),
    ]
    let expected = [
        "missing required field", "invalid identifier", "invalid value",
        "unknown oneof", "unknown enum", "unknown fields",
    ]
    for (error, expectedMessage) in zip(cases, expected) {
        let wire = error.asWireProtocolError()
        #expect(wire.code == .malformedMessage)
        #expect(wire.code.rawValue == 3)
        #expect(wire.message == expectedMessage)
        #expect(!wire.message.contains(secret))
        #expect(!wire.message.contains("987654"))
    }
}

import Foundation
import SwiftProtobuf
import CockpitTypes

public enum TerminalMessages {
    public static func encode(_ value: TerminalInput, channelID: ChannelID, negotiatedVersion: ProtocolVersion) throws -> CPTerminalInput {
        try validateNegotiatedVersion(negotiatedVersion)
        do {
            _ = try value.context.validated(negotiatedVersion: negotiatedVersion)
            _ = try value.validated()
        } catch CockpitDomainValidationError.protocolVersionMismatch {
            throw ProtocolMappingError.invalidValue("protocol_version")
        } catch {
            throw ProtocolMappingError.invalidValue("terminal_input")
        }
        try validateChannel(payload: value.payload, channelID: channelID)

        var message = CPTerminalInput()
        message.context = try WorkspaceMessages.encode(value.context, negotiatedVersion: negotiatedVersion)
        message.terminalSessionID = value.terminalSessionID.description
        message.inputLeaseID = value.inputLeaseID.description
        message.inputSequence = value.inputSequence
        switch value.payload {
        case let .text(text): message.text = text
        case let .key(key): message.key = encodeKey(key)
        case let .paste(paste): message.paste = paste
        case let .mouse(mouse): message.mouse = encodeMouse(mouse)
        case let .resize(resize): message.resize = encodeResize(resize)
        case let .signal(signal): message.signal = encodeSignal(signal)
        }
        let encodedSize: Int
        do { encodedSize = try message.serializedData().count }
        catch { throw ProtocolMappingError.invalidValue("terminal_input_frame_size") }
        guard encodedSize <= Int(FrameHeader.maximumPayloadLength) else {
            throw ProtocolMappingError.invalidValue("terminal_input_frame_size")
        }
        return message
    }

    public static func decode(_ message: CPTerminalInput, channelID: ChannelID, negotiatedVersion: ProtocolVersion) throws -> TerminalInput {
        try validateNegotiatedVersion(negotiatedVersion)
        try rejectTerminalInputUnknownFields(message)
        guard message.hasContext else { throw ProtocolMappingError.missingRequiredField("context") }
        guard message.context.hasWorkspaceContextID else {
            throw ProtocolMappingError.missingRequiredField("workspace_context_id")
        }
        guard message.context.workspaceContextID.kind != nil else {
            throw ProtocolMappingError.unknownOneOf("workspace_context_id.kind")
        }
        guard let payload = message.payload else { throw ProtocolMappingError.unknownOneOf("terminal_input.payload") }
        try validatePayloadEnum(payload)
        let context = try WorkspaceMessages.decode(message.context, negotiatedVersion: negotiatedVersion)
        let terminalSessionID: TerminalSessionID = try decodeID(
            message.terminalSessionID, field: "terminal_session_id"
        )
        let inputLeaseID: InputLeaseID = try decodeID(
            message.inputLeaseID, field: "input_lease_id"
        )
        let mappedPayload: TerminalInput.Payload
        switch payload {
        case let .text(value): mappedPayload = .text(value)
        case let .key(value): mappedPayload = .key(try decodeKey(value))
        case let .paste(value): mappedPayload = .paste(value)
        case let .mouse(value): mappedPayload = .mouse(try decodeMouse(value))
        case let .resize(value): mappedPayload = .resize(try decodeResize(value))
        case let .signal(value): mappedPayload = .signal(try decodeSignal(value))
        }
        let value: TerminalInput
        do {
            value = try TerminalInput(
                validatingContext: context,
                terminalSessionID: terminalSessionID,
                inputLeaseID: inputLeaseID,
                inputSequence: message.inputSequence,
                payload: mappedPayload
            )
        } catch let error as ProtocolMappingError {
            throw error
        } catch {
            throw ProtocolMappingError.invalidValue("terminal_input")
        }
        try validateChannel(payload: value.payload, channelID: channelID)
        return value
    }

    public static func encode(_ value: TerminalArchiveManifest, negotiatedVersion: ProtocolVersion) throws -> CPTerminalArchiveManifest {
        try validateNegotiatedVersion(negotiatedVersion)
        let valid: TerminalArchiveManifest
        do { valid = try value.validated() }
        catch { throw ProtocolMappingError.invalidValue("terminal_archive_manifest") }
        var message = CPTerminalArchiveManifest()
        message.terminalSessionID = valid.terminalSessionID.description
        message.workerInstanceID = valid.workerInstanceID.description
        message.firstOutputSequence = valid.firstOutputSequence
        message.latestOutputSequence = valid.latestOutputSequence
        message.chunks = valid.chunks.map(encodeChunk)
        message.finalSnapshotSha256 = valid.finalSnapshotSHA256.bytes
        message.exitStatus = encodeExitStatus(valid.exitStatus)
        let timestamp = Google_Protobuf_Timestamp(date: valid.completedAt)
        guard isValid(timestamp) else { throw ProtocolMappingError.invalidValue("completed_at") }
        message.completedAt = timestamp
        return message
    }

    public static func decode(_ message: CPTerminalArchiveManifest, negotiatedVersion: ProtocolVersion) throws -> TerminalArchiveManifest {
        try validateNegotiatedVersion(negotiatedVersion)
        try rejectUnknownFields(message.unknownFields.data, field: "terminal_archive_manifest")
        if message.hasExitStatus {
            try rejectUnknownFields(message.exitStatus.unknownFields.data, field: "terminal_exit_status")
        }
        if message.hasCompletedAt {
            try rejectUnknownFields(message.completedAt.unknownFields.data, field: "completed_at")
        }
        for chunk in message.chunks {
            try rejectUnknownFields(chunk.unknownFields.data, field: "terminal_archive_chunk")
        }
        guard message.hasExitStatus else { throw ProtocolMappingError.missingRequiredField("exit_status") }
        guard message.hasCompletedAt else { throw ProtocolMappingError.missingRequiredField("completed_at") }
        guard isValid(message.completedAt) else { throw ProtocolMappingError.invalidValue("completed_at") }
        let chunks = try message.chunks.map(decodeChunk)
        let digest: SHA256Digest
        do { digest = try SHA256Digest(validating: message.finalSnapshotSha256) }
        catch { throw ProtocolMappingError.invalidValue("final_snapshot_sha256") }
        let exitStatus = try decodeExitStatus(message.exitStatus)
        do {
            return try TerminalArchiveManifest(
                validatingTerminalSessionID: decodeID(message.terminalSessionID, field: "terminal_session_id"),
                workerInstanceID: decodeID(message.workerInstanceID, field: "worker_instance_id"),
                firstOutputSequence: message.firstOutputSequence,
                latestOutputSequence: message.latestOutputSequence,
                chunks: chunks,
                finalSnapshotSHA256: digest,
                exitStatus: exitStatus,
                completedAt: message.completedAt.date
            )
        } catch let error as ProtocolMappingError {
            throw error
        } catch {
            throw ProtocolMappingError.invalidValue("terminal_archive_manifest")
        }
    }
}

private func rejectTerminalInputUnknownFields(_ message: CPTerminalInput) throws {
    try rejectUnknownFields(message.unknownFields.data, field: "terminal_input")
    if message.hasContext {
        try rejectUnknownFields(message.context.unknownFields.data, field: "request_context")
        if message.context.hasWorkspaceContextID {
            try rejectUnknownFields(
                message.context.workspaceContextID.unknownFields.data,
                field: "workspace_context_id"
            )
        }
    }
    switch message.payload {
    case let .key(value):
        try rejectUnknownFields(value.unknownFields.data, field: "terminal_key")
    case let .mouse(value):
        try rejectUnknownFields(value.unknownFields.data, field: "terminal_mouse")
    case let .resize(value):
        try rejectUnknownFields(value.unknownFields.data, field: "terminal_resize")
    case .text, .paste, .signal, nil:
        break
    }
}

private func validatePayloadEnum(_ payload: CPTerminalInput.OneOf_Payload) throws {
    switch payload {
    case let .key(value):
        switch value.action {
        case .press, .repeat, .release: break
        case .unspecified: throw ProtocolMappingError.invalidValue("terminal_key.action")
        case let .UNRECOGNIZED(raw):
            throw ProtocolMappingError.unknownEnum(field: "terminal_key.action", rawValue: raw)
        }
    case let .mouse(value):
        switch value.action {
        case .press, .release, .motion, .scroll: break
        case .unspecified: throw ProtocolMappingError.invalidValue("terminal_mouse.action")
        case let .UNRECOGNIZED(raw):
            throw ProtocolMappingError.unknownEnum(field: "terminal_mouse.action", rawValue: raw)
        }
    case let .signal(value):
        switch value {
        case .interrupt, .quit, .suspend, .continue: break
        case .unspecified: throw ProtocolMappingError.invalidValue("terminal_signal")
        case let .UNRECOGNIZED(raw):
            throw ProtocolMappingError.unknownEnum(field: "terminal_signal", rawValue: raw)
        }
    case .text, .paste, .resize:
        break
    }
}

private func validateChannel(payload: TerminalInput.Payload, channelID: ChannelID) throws {
    let valid: Bool
    switch payload {
    case .signal: valid = channelID == .control
    case .text, .key, .paste, .mouse, .resize: valid = channelID == .terminalInput
    }
    guard valid else { throw ProtocolMappingError.invalidValue("channel_id") }
}

private func encodeKey(_ value: TerminalKeyEvent) -> CPTerminalKeyEvent {
    var message = CPTerminalKeyEvent()
    message.logicalKey = value.logicalKey; message.physicalKey = value.physicalKey; message.modifiers = value.modifiers
    switch value.action {
    case .press: message.action = .press
    case .repeat: message.action = .repeat
    case .release: message.action = .release
    }
    return message
}

private func decodeKey(_ message: CPTerminalKeyEvent) throws -> TerminalKeyEvent {
    try rejectUnknownFields(message.unknownFields.data, field: "terminal_key")
    let action: TerminalKeyAction
    switch message.action {
    case .press: action = .press
    case .repeat: action = .repeat
    case .release: action = .release
    case .unspecified: throw ProtocolMappingError.invalidValue("terminal_key.action")
    case let .UNRECOGNIZED(raw): throw ProtocolMappingError.unknownEnum(field: "terminal_key.action", rawValue: raw)
    }
    do { return try TerminalKeyEvent(validatingLogicalKey: message.logicalKey, physicalKey: message.physicalKey, modifiers: message.modifiers, action: action) }
    catch { throw ProtocolMappingError.invalidValue("terminal_key") }
}

private func encodeMouse(_ value: TerminalMouseEvent) -> CPTerminalMouseEvent {
    var message = CPTerminalMouseEvent()
    message.cellX = value.cellX; message.cellY = value.cellY; message.buttons = value.buttons
    message.wheelX = value.wheelX; message.wheelY = value.wheelY; message.modifiers = value.modifiers
    switch value.action {
    case .press: message.action = .press
    case .release: message.action = .release
    case .motion: message.action = .motion
    case .scroll: message.action = .scroll
    }
    return message
}

private func decodeMouse(_ message: CPTerminalMouseEvent) throws -> TerminalMouseEvent {
    try rejectUnknownFields(message.unknownFields.data, field: "terminal_mouse")
    let action: TerminalMouseAction
    switch message.action {
    case .press: action = .press
    case .release: action = .release
    case .motion: action = .motion
    case .scroll: action = .scroll
    case .unspecified: throw ProtocolMappingError.invalidValue("terminal_mouse.action")
    case let .UNRECOGNIZED(raw): throw ProtocolMappingError.unknownEnum(field: "terminal_mouse.action", rawValue: raw)
    }
    do { return try TerminalMouseEvent(validatingCellX: message.cellX, cellY: message.cellY, buttons: message.buttons, wheelX: message.wheelX, wheelY: message.wheelY, modifiers: message.modifiers, action: action) }
    catch { throw ProtocolMappingError.invalidValue("terminal_mouse") }
}

private func encodeResize(_ value: TerminalResize) -> CPTerminalResize {
    var message = CPTerminalResize(); message.columns = UInt32(value.columns); message.rows = UInt32(value.rows); return message
}

private func decodeResize(_ message: CPTerminalResize) throws -> TerminalResize {
    try rejectUnknownFields(message.unknownFields.data, field: "terminal_resize")
    do { return try TerminalResize(validatingColumns: message.columns, rows: message.rows) }
    catch { throw ProtocolMappingError.invalidValue("terminal_resize") }
}

private func encodeSignal(_ value: TerminalSignal) -> CPTerminalSignal {
    switch value {
    case .interrupt: return .interrupt
    case .quit: return .quit
    case .suspend: return .suspend
    case .continue: return .continue
    }
}

private func decodeSignal(_ value: CPTerminalSignal) throws -> TerminalSignal {
    switch value {
    case .interrupt: return .interrupt
    case .quit: return .quit
    case .suspend: return .suspend
    case .continue: return .continue
    case .unspecified: throw ProtocolMappingError.invalidValue("terminal_signal")
    case let .UNRECOGNIZED(raw): throw ProtocolMappingError.unknownEnum(field: "terminal_signal", rawValue: raw)
    }
}

private func encodeChunk(_ value: TerminalArchiveChunk) -> CPTerminalArchiveChunk {
    var message = CPTerminalArchiveChunk()
    message.name = value.name; message.firstOutputSequence = value.firstOutputSequence; message.lastOutputSequence = value.lastOutputSequence; message.sha256 = value.sha256.bytes
    return message
}

private func decodeChunk(_ message: CPTerminalArchiveChunk) throws -> TerminalArchiveChunk {
    let digest: SHA256Digest
    do { digest = try SHA256Digest(validating: message.sha256) }
    catch { throw ProtocolMappingError.invalidValue("terminal_archive_chunk.sha256") }
    do { return try TerminalArchiveChunk(validatingName: message.name, firstOutputSequence: message.firstOutputSequence, lastOutputSequence: message.lastOutputSequence, sha256: digest) }
    catch { throw ProtocolMappingError.invalidValue("terminal_archive_chunk") }
}

private func encodeExitStatus(_ value: TerminalExitStatus) -> CPTerminalExitStatus {
    var message = CPTerminalExitStatus()
    switch value {
    case let .exited(code): message.exitCode = UInt32(code)
    case let .signaled(signal): message.darwinSignal = signal
    }
    return message
}

private func decodeExitStatus(_ message: CPTerminalExitStatus) throws -> TerminalExitStatus {
    switch message.result {
    case let .exitCode(code):
        guard let value = UInt8(exactly: code) else { throw ProtocolMappingError.invalidValue("terminal_exit_status") }
        return .exited(value)
    case let .darwinSignal(signal):
        do { return try TerminalExitStatus.signaled(signal).validated() }
        catch { throw ProtocolMappingError.invalidValue("terminal_exit_status") }
    case nil: throw ProtocolMappingError.unknownOneOf("terminal_exit_status.result")
    }
}

private func isValid(_ timestamp: Google_Protobuf_Timestamp) -> Bool {
    (-62_135_596_800...253_402_300_799).contains(timestamp.seconds)
        && (0...999_999_999).contains(timestamp.nanos)
}

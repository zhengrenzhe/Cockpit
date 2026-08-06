import Foundation

public enum TerminalKeyAction: UInt8, Hashable, Codable, Sendable {
    case press = 1
    case `repeat` = 2
    case release = 3
}

public struct TerminalKeyEvent: Hashable, Codable, Sendable {
    public let logicalKey: UInt32
    public let physicalKey: UInt32
    public let modifiers: UInt32
    public let action: TerminalKeyAction

    public init(validatingLogicalKey logicalKey: UInt32, physicalKey: UInt32, modifiers: UInt32, action: TerminalKeyAction) throws {
        guard logicalKey != 0 || physicalKey != 0 else { throw CockpitDomainValidationError.invalidTerminalKeyIdentity }
        guard logicalKey == 0 || (logicalKey <= 0x10FFFF && !(0xD800...0xDFFF).contains(logicalKey)) else {
            throw CockpitDomainValidationError.invalidTerminalLogicalKey
        }
        guard modifiers & ~UInt32(0x3FF) == 0 else { throw CockpitDomainValidationError.invalidTerminalModifiers }
        self.logicalKey = logicalKey
        self.physicalKey = physicalKey
        self.modifiers = modifiers
        self.action = action
    }

    private enum CodingKeys: String, CodingKey { case logicalKey, physicalKey, modifiers, action }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validatingLogicalKey: c.decode(UInt32.self, forKey: .logicalKey), physicalKey: c.decode(UInt32.self, forKey: .physicalKey), modifiers: c.decode(UInt32.self, forKey: .modifiers), action: c.decode(TerminalKeyAction.self, forKey: .action))
    }
    public func encode(to encoder: Encoder) throws {
        let v = try Self(validatingLogicalKey: logicalKey, physicalKey: physicalKey, modifiers: modifiers, action: action)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v.logicalKey, forKey: .logicalKey); try c.encode(v.physicalKey, forKey: .physicalKey)
        try c.encode(v.modifiers, forKey: .modifiers); try c.encode(v.action, forKey: .action)
    }
}

public enum TerminalMouseAction: UInt8, Hashable, Codable, Sendable {
    case press = 1
    case release = 2
    case motion = 3
    case scroll = 4
}

public struct TerminalMouseEvent: Hashable, Codable, Sendable {
    public let cellX: Int32
    public let cellY: Int32
    public let buttons: UInt32
    public let wheelX: Int32
    public let wheelY: Int32
    public let modifiers: UInt32
    public let action: TerminalMouseAction

    public init(validatingCellX cellX: Int32, cellY: Int32, buttons: UInt32, wheelX: Int32, wheelY: Int32, modifiers: UInt32, action: TerminalMouseAction) throws {
        guard buttons & ~UInt32(0x7FF) == 0 else { throw CockpitDomainValidationError.invalidTerminalMouseButtons }
        guard modifiers & ~UInt32(0x3FF) == 0 else { throw CockpitDomainValidationError.invalidTerminalModifiers }
        switch action {
        case .scroll:
            guard wheelX != 0 || wheelY != 0 else { throw CockpitDomainValidationError.invalidTerminalMouseWheel }
        case .press, .release, .motion:
            guard wheelX == 0, wheelY == 0 else { throw CockpitDomainValidationError.invalidTerminalMouseWheel }
        }
        self.cellX = cellX; self.cellY = cellY; self.buttons = buttons
        self.wheelX = wheelX; self.wheelY = wheelY; self.modifiers = modifiers; self.action = action
    }

    private enum CodingKeys: String, CodingKey { case cellX, cellY, buttons, wheelX, wheelY, modifiers, action }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validatingCellX: c.decode(Int32.self, forKey: .cellX), cellY: c.decode(Int32.self, forKey: .cellY), buttons: c.decode(UInt32.self, forKey: .buttons), wheelX: c.decode(Int32.self, forKey: .wheelX), wheelY: c.decode(Int32.self, forKey: .wheelY), modifiers: c.decode(UInt32.self, forKey: .modifiers), action: c.decode(TerminalMouseAction.self, forKey: .action))
    }
    public func encode(to encoder: Encoder) throws {
        let v = try Self(validatingCellX: cellX, cellY: cellY, buttons: buttons, wheelX: wheelX, wheelY: wheelY, modifiers: modifiers, action: action)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v.cellX, forKey: .cellX); try c.encode(v.cellY, forKey: .cellY); try c.encode(v.buttons, forKey: .buttons)
        try c.encode(v.wheelX, forKey: .wheelX); try c.encode(v.wheelY, forKey: .wheelY); try c.encode(v.modifiers, forKey: .modifiers); try c.encode(v.action, forKey: .action)
    }
}

public struct TerminalResize: Hashable, Codable, Sendable {
    public let columns: UInt16
    public let rows: UInt16

    public init(validatingColumns columns: UInt32, rows: UInt32) throws {
        guard (1...65_535).contains(columns), (1...65_535).contains(rows) else { throw CockpitDomainValidationError.invalidTerminalResize }
        self.columns = UInt16(columns); self.rows = UInt16(rows)
    }

    private enum CodingKeys: String, CodingKey { case columns, rows }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validatingColumns: c.decode(UInt32.self, forKey: .columns), rows: c.decode(UInt32.self, forKey: .rows))
    }
    public func encode(to encoder: Encoder) throws {
        let v = try Self(validatingColumns: UInt32(columns), rows: UInt32(rows))
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v.columns, forKey: .columns); try c.encode(v.rows, forKey: .rows)
    }
}

public enum TerminalSignal: UInt8, Hashable, Codable, Sendable {
    case interrupt = 1
    case quit = 2
    case suspend = 3
    case `continue` = 4
}

public struct TerminalInput: Hashable, Sendable {
    public let context: RequestContext
    public let terminalSessionID: TerminalSessionID
    public let inputLeaseID: InputLeaseID
    public let inputSequence: UInt64
    public let payload: Payload

    public enum Payload: Hashable, Sendable {
        case text(String)
        case key(TerminalKeyEvent)
        case paste(String)
        case mouse(TerminalMouseEvent)
        case resize(TerminalResize)
        case signal(TerminalSignal)
    }

    public static let maximumTextOrPasteUTF8Bytes = 16 * 1_024 * 1_024

    public init(validatingContext context: RequestContext, terminalSessionID: TerminalSessionID, inputLeaseID: InputLeaseID, inputSequence: UInt64, payload: Payload) throws {
        guard inputSequence > 0 else { throw CockpitDomainValidationError.zeroInputSequence }
        _ = try RequestContext(validating: context.protocolVersion, clientInstanceID: context.clientInstanceID, windowID: context.windowID, workspaceContextID: context.workspaceContextID, environmentID: context.environmentID, activeContextGeneration: context.activeContextGeneration, requestID: context.requestID)
        switch payload {
        case let .text(value):
            guard !value.isEmpty else { throw CockpitDomainValidationError.emptyTerminalText }
            guard value.utf8.count <= Self.maximumTextOrPasteUTF8Bytes else { throw CockpitDomainValidationError.terminalTextOrPasteTooLarge }
        case let .paste(value):
            guard !value.isEmpty else { throw CockpitDomainValidationError.emptyTerminalPaste }
            guard value.utf8.count <= Self.maximumTextOrPasteUTF8Bytes else { throw CockpitDomainValidationError.terminalTextOrPasteTooLarge }
        case let .key(value):
            _ = try TerminalKeyEvent(validatingLogicalKey: value.logicalKey, physicalKey: value.physicalKey, modifiers: value.modifiers, action: value.action)
        case let .mouse(value):
            _ = try TerminalMouseEvent(validatingCellX: value.cellX, cellY: value.cellY, buttons: value.buttons, wheelX: value.wheelX, wheelY: value.wheelY, modifiers: value.modifiers, action: value.action)
        case let .resize(value):
            _ = try TerminalResize(validatingColumns: UInt32(value.columns), rows: UInt32(value.rows))
        case .signal: break
        }
        self.context = context; self.terminalSessionID = terminalSessionID; self.inputLeaseID = inputLeaseID
        self.inputSequence = inputSequence; self.payload = payload
    }

    public func validated() throws -> Self {
        try Self(validatingContext: context, terminalSessionID: terminalSessionID, inputLeaseID: inputLeaseID, inputSequence: inputSequence, payload: payload)
    }
}

public typealias TerminalInputFrame = TerminalInput

public struct SHA256Digest: Hashable, Codable, Sendable {
    public let bytes: Data

    public init(validating bytes: Data) throws {
        guard bytes.count == 32 else { throw CockpitDomainValidationError.invalidSHA256DigestLength }
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(Data.self))
    }
    public func encode(to encoder: Encoder) throws {
        let valid = try Self(validating: bytes)
        var container = encoder.singleValueContainer(); try container.encode(valid.bytes)
    }
}

public struct TerminalArchiveChunk: Hashable, Codable, Sendable {
    public let name: String
    public let firstOutputSequence: UInt64
    public let lastOutputSequence: UInt64
    public let sha256: SHA256Digest

    public init(validatingName name: String, firstOutputSequence: UInt64, lastOutputSequence: UInt64, sha256: SHA256Digest) throws {
        let expectedName = String(format: "%020llu.ckgs", firstOutputSequence)
        guard name == expectedName, !name.contains("/"), !name.contains("\\"), !name.contains("\0"), name != ".", name != ".." else {
            throw CockpitDomainValidationError.invalidTerminalArchiveChunkName
        }
        guard firstOutputSequence > 0, firstOutputSequence <= lastOutputSequence else { throw CockpitDomainValidationError.invalidTerminalArchiveChunkRange }
        self.name = name; self.firstOutputSequence = firstOutputSequence; self.lastOutputSequence = lastOutputSequence
        self.sha256 = try SHA256Digest(validating: sha256.bytes)
    }

    private enum CodingKeys: String, CodingKey { case name, firstOutputSequence, lastOutputSequence, sha256 }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validatingName: c.decode(String.self, forKey: .name), firstOutputSequence: c.decode(UInt64.self, forKey: .firstOutputSequence), lastOutputSequence: c.decode(UInt64.self, forKey: .lastOutputSequence), sha256: c.decode(SHA256Digest.self, forKey: .sha256))
    }
    public func encode(to encoder: Encoder) throws {
        let v = try Self(validatingName: name, firstOutputSequence: firstOutputSequence, lastOutputSequence: lastOutputSequence, sha256: sha256)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v.name, forKey: .name); try c.encode(v.firstOutputSequence, forKey: .firstOutputSequence)
        try c.encode(v.lastOutputSequence, forKey: .lastOutputSequence); try c.encode(v.sha256, forKey: .sha256)
    }
}

public enum TerminalExitStatus: Hashable, Codable, Sendable {
    case exited(UInt8)
    case signaled(Int32)

    public func validated() throws -> Self {
        switch self {
        case .exited: return self
        case let .signaled(value):
            guard (1...31).contains(value) else { throw CockpitDomainValidationError.invalidTerminalExitStatus }
            return self
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case exited, signaled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .exited: self = .exited(try c.decode(UInt8.self, forKey: .value))
        case .signaled: self = .signaled(try c.decode(Int32.self, forKey: .value))
        }
        self = try validated()
    }
    public func encode(to encoder: Encoder) throws {
        let v = try validated(); var c = encoder.container(keyedBy: CodingKeys.self)
        switch v {
        case let .exited(value): try c.encode(Kind.exited, forKey: .kind); try c.encode(value, forKey: .value)
        case let .signaled(value): try c.encode(Kind.signaled, forKey: .kind); try c.encode(value, forKey: .value)
        }
    }
}

public struct TerminalArchiveManifest: Hashable, Codable, Sendable {
    public let terminalSessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID
    public let firstOutputSequence: UInt64
    public let latestOutputSequence: UInt64
    public let chunks: [TerminalArchiveChunk]
    public let finalSnapshotSHA256: SHA256Digest
    public let exitStatus: TerminalExitStatus
    public let completedAt: Date

    public init(validatingTerminalSessionID terminalSessionID: TerminalSessionID, workerInstanceID: WorkerInstanceID, firstOutputSequence: UInt64, latestOutputSequence: UInt64, chunks: [TerminalArchiveChunk], finalSnapshotSHA256: SHA256Digest, exitStatus: TerminalExitStatus, completedAt: Date) throws {
        let completedAtSeconds = completedAt.timeIntervalSince1970
        guard completedAtSeconds.isFinite,
              completedAtSeconds >= -62_135_596_800,
              completedAtSeconds < 253_402_300_800
        else { throw CockpitDomainValidationError.invalidTerminalArchiveCompletionDate }
        _ = try exitStatus.validated(); _ = try SHA256Digest(validating: finalSnapshotSHA256.bytes)
        if firstOutputSequence == 0, latestOutputSequence == 0 {
            guard chunks.isEmpty else { throw CockpitDomainValidationError.invalidTerminalArchiveChunks }
        } else {
            guard firstOutputSequence >= 1, firstOutputSequence <= latestOutputSequence else { throw CockpitDomainValidationError.invalidTerminalArchiveRange }
        }
        var names = Set<String>(); var previousLast: UInt64?
        for chunk in chunks {
            let valid = try TerminalArchiveChunk(validatingName: chunk.name, firstOutputSequence: chunk.firstOutputSequence, lastOutputSequence: chunk.lastOutputSequence, sha256: chunk.sha256)
            guard valid.firstOutputSequence >= firstOutputSequence, valid.lastOutputSequence <= latestOutputSequence else { throw CockpitDomainValidationError.invalidTerminalArchiveChunks }
            guard names.insert(valid.name).inserted else { throw CockpitDomainValidationError.invalidTerminalArchiveChunks }
            if let previousLast { guard valid.firstOutputSequence > previousLast else { throw CockpitDomainValidationError.invalidTerminalArchiveChunks } }
            previousLast = valid.lastOutputSequence
        }
        self.terminalSessionID = terminalSessionID; self.workerInstanceID = workerInstanceID
        self.firstOutputSequence = firstOutputSequence; self.latestOutputSequence = latestOutputSequence; self.chunks = chunks
        self.finalSnapshotSHA256 = finalSnapshotSHA256; self.exitStatus = exitStatus; self.completedAt = completedAt
    }

    public func validated() throws -> Self {
        try Self(validatingTerminalSessionID: terminalSessionID, workerInstanceID: workerInstanceID, firstOutputSequence: firstOutputSequence, latestOutputSequence: latestOutputSequence, chunks: chunks, finalSnapshotSHA256: finalSnapshotSHA256, exitStatus: exitStatus, completedAt: completedAt)
    }

    private enum CodingKeys: String, CodingKey { case terminalSessionID, workerInstanceID, firstOutputSequence, latestOutputSequence, chunks, finalSnapshotSHA256, exitStatus, completedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validatingTerminalSessionID: c.decode(TerminalSessionID.self, forKey: .terminalSessionID), workerInstanceID: c.decode(WorkerInstanceID.self, forKey: .workerInstanceID), firstOutputSequence: c.decode(UInt64.self, forKey: .firstOutputSequence), latestOutputSequence: c.decode(UInt64.self, forKey: .latestOutputSequence), chunks: c.decode([TerminalArchiveChunk].self, forKey: .chunks), finalSnapshotSHA256: c.decode(SHA256Digest.self, forKey: .finalSnapshotSHA256), exitStatus: c.decode(TerminalExitStatus.self, forKey: .exitStatus), completedAt: c.decode(Date.self, forKey: .completedAt))
    }
    public func encode(to encoder: Encoder) throws {
        let v = try validated(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v.terminalSessionID, forKey: .terminalSessionID); try c.encode(v.workerInstanceID, forKey: .workerInstanceID)
        try c.encode(v.firstOutputSequence, forKey: .firstOutputSequence); try c.encode(v.latestOutputSequence, forKey: .latestOutputSequence)
        try c.encode(v.chunks, forKey: .chunks); try c.encode(v.finalSnapshotSHA256, forKey: .finalSnapshotSHA256)
        try c.encode(v.exitStatus, forKey: .exitStatus); try c.encode(v.completedAt, forKey: .completedAt)
    }
}

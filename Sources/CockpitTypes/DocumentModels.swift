import Foundation

public struct TextPosition: Hashable, Codable, Sendable {
    public let line: UInt64
    public let column: UInt64

    public init(validatingLine line: UInt64, column: UInt64) throws {
        guard line > 0, column > 0 else { throw CockpitDomainValidationError.zeroTextPosition }
        self.line = line
        self.column = column
    }

    private enum CodingKeys: String, CodingKey { case line, column }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validatingLine: container.decode(UInt64.self, forKey: .line), column: container.decode(UInt64.self, forKey: .column))
    }

    public func encode(to encoder: Encoder) throws {
        let valid = try Self(validatingLine: line, column: column)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.line, forKey: .line)
        try container.encode(valid.column, forKey: .column)
    }
}

public struct TextRange: Hashable, Codable, Sendable {
    public let anchor: TextPosition
    public let active: TextPosition

    public init(validatingAnchor anchor: TextPosition, active: TextPosition) throws {
        self.anchor = try TextPosition(validatingLine: anchor.line, column: anchor.column)
        self.active = try TextPosition(validatingLine: active.line, column: active.column)
    }

    private enum CodingKeys: String, CodingKey { case anchor, active }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validatingAnchor: container.decode(TextPosition.self, forKey: .anchor), active: container.decode(TextPosition.self, forKey: .active))
    }

    public func encode(to encoder: Encoder) throws {
        let valid = try Self(validatingAnchor: anchor, active: active)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.anchor, forKey: .anchor)
        try container.encode(valid.active, forKey: .active)
    }
}

public struct DocumentViewState: Hashable, Codable, Sendable {
    public var cursor: TextPosition
    public var selections: [TextRange]
    public var firstVisibleLine: UInt64
    public var horizontalScrollOffset: Double

    public init(
        validatingCursor cursor: TextPosition,
        selections: [TextRange],
        firstVisibleLine: UInt64,
        horizontalScrollOffset: Double
    ) throws {
        guard firstVisibleLine > 0 else { throw CockpitDomainValidationError.zeroTextPosition }
        guard horizontalScrollOffset.isFinite, horizontalScrollOffset >= 0 else {
            throw CockpitDomainValidationError.invalidHorizontalScrollOffset
        }
        self.cursor = try TextPosition(validatingLine: cursor.line, column: cursor.column)
        self.selections = try selections.map { try TextRange(validatingAnchor: $0.anchor, active: $0.active) }
        self.firstVisibleLine = firstVisibleLine
        self.horizontalScrollOffset = horizontalScrollOffset
    }

    public static func initial() -> Self {
        try! Self(
            validatingCursor: TextPosition(validatingLine: 1, column: 1),
            selections: [], firstVisibleLine: 1, horizontalScrollOffset: 0
        )
    }

    public func validated() throws -> Self {
        try Self(validatingCursor: cursor, selections: selections, firstVisibleLine: firstVisibleLine, horizontalScrollOffset: horizontalScrollOffset)
    }

    private enum CodingKeys: String, CodingKey { case cursor, selections, firstVisibleLine, horizontalScrollOffset }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validatingCursor: container.decode(TextPosition.self, forKey: .cursor),
            selections: container.decode([TextRange].self, forKey: .selections),
            firstVisibleLine: container.decode(UInt64.self, forKey: .firstVisibleLine),
            horizontalScrollOffset: container.decode(Double.self, forKey: .horizontalScrollOffset)
        )
    }

    public func encode(to encoder: Encoder) throws {
        let valid = try validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.cursor, forKey: .cursor)
        try container.encode(valid.selections, forKey: .selections)
        try container.encode(valid.firstVisibleLine, forKey: .firstVisibleLine)
        try container.encode(valid.horizontalScrollOffset, forKey: .horizontalScrollOffset)
    }
}

public struct TabRecord: Hashable, Codable, Sendable {
    public enum Resource: Hashable, Codable, Sendable {
        case file(DocumentID)
        case terminal(TerminalSessionID)
        case newTabPicker

        private enum CodingKeys: String, CodingKey { case kind, documentID, terminalSessionID }
        private enum Kind: String, Codable { case file, terminal, newTabPicker = "new-tab-picker" }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(Kind.self, forKey: .kind)
            let hasDocument = container.contains(.documentID)
            let hasTerminal = container.contains(.terminalSessionID)
            guard !(hasDocument && hasTerminal) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Only one resource identifier is permitted"))
            }
            switch kind {
            case .file:
                guard hasDocument, !hasTerminal else { throw Self.invalidResource(decoder) }
                let value = try container.decode(String.self, forKey: .documentID)
                guard let uuid = UUID(uuidString: value), !value.isEmpty else { throw Self.invalidResource(decoder) }
                self = .file(DocumentID(uuid))
            case .terminal:
                guard hasTerminal, !hasDocument else { throw Self.invalidResource(decoder) }
                let value = try container.decode(String.self, forKey: .terminalSessionID)
                guard let uuid = UUID(uuidString: value), !value.isEmpty else { throw Self.invalidResource(decoder) }
                self = .terminal(TerminalSessionID(uuid))
            case .newTabPicker:
                guard !hasDocument, !hasTerminal else { throw Self.invalidResource(decoder) }
                self = .newTabPicker
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .file(documentID):
                try container.encode(Kind.file, forKey: .kind)
                try container.encode(documentID.description, forKey: .documentID)
            case let .terminal(terminalSessionID):
                try container.encode(Kind.terminal, forKey: .kind)
                try container.encode(terminalSessionID.description, forKey: .terminalSessionID)
            case .newTabPicker:
                try container.encode(Kind.newTabPicker, forKey: .kind)
            }
        }

        private static func invalidResource(_ decoder: Decoder) -> DecodingError {
            .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tagged tab resource"))
        }
    }

    public let id: TabID
    public var resource: Resource
    public var fileViewState: DocumentViewState?

    public init(validatingID id: TabID, resource: Resource, fileViewState: DocumentViewState?) throws {
        switch (resource, fileViewState) {
        case (.file, .some): break
        case (.terminal, .none), (.newTabPicker, .none): break
        default: throw CockpitDomainValidationError.invalidTabViewState
        }
        self.id = id
        self.resource = resource
        self.fileViewState = try fileViewState?.validated()
    }

    public func validated() throws -> Self {
        try Self(validatingID: id, resource: resource, fileViewState: fileViewState)
    }

    private enum CodingKeys: String, CodingKey { case id, resource, fileViewState }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let idText = try container.decode(String.self, forKey: .id)
        guard let uuid = UUID(uuidString: idText), !idText.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tab identifier"))
        }
        try self.init(
            validatingID: TabID(uuid),
            resource: container.decode(Resource.self, forKey: .resource),
            fileViewState: container.decodeIfPresent(DocumentViewState.self, forKey: .fileViewState)
        )
    }

    public func encode(to encoder: Encoder) throws {
        let valid = try validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.id.description, forKey: .id)
        try container.encode(valid.resource, forKey: .resource)
        try container.encodeIfPresent(valid.fileViewState, forKey: .fileViewState)
    }
}

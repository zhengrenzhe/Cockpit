import CoreFoundation
import Foundation
import CockpitProtocol
import CockpitTypes

public enum MonacoBridgeError: Error, Hashable, Sendable {
    case invalidSchema
    case staleGeneration
    case staleDocumentState
    case unknownDocument
    case readOnly
    case resynchronizing
    case fileMissing
    case transportFailure

    public var wireCode: String {
        switch self {
        case .invalidSchema: "invalid-schema"
        case .staleGeneration: "stale-generation"
        case .staleDocumentState: "stale-document-state"
        case .unknownDocument: "unknown-document"
        case .readOnly: "read-only"
        case .resynchronizing: "resynchronizing"
        case .fileMissing: "file-missing"
        case .transportFailure: "transport-failure"
        }
    }
}

public struct MonacoDocumentReference: Hashable, Sendable {
    public let workspaceContextID: WorkspaceContextID
    public let tabID: TabID
    public let documentID: DocumentID

    public init(
        workspaceContextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) {
        self.workspaceContextID = workspaceContextID
        self.tabID = tabID
        self.documentID = documentID
    }
}

public struct MonacoDocumentAccess: Hashable, Sendable {
    public let reference: MonacoDocumentReference
    public let uri: String
    public let lastAcceptedClientSequence: UInt64
    public let editLeaseID: EditLeaseID?
    public let writable: Bool

    public init(
        reference: MonacoDocumentReference,
        uri: String,
        lastAcceptedClientSequence: UInt64,
        editLeaseID: EditLeaseID?,
        writable: Bool
    ) {
        self.reference = reference
        self.uri = uri
        self.lastAcceptedClientSequence = lastAcceptedClientSequence
        self.editLeaseID = editLeaseID
        self.writable = writable
    }
}

public enum MonacoToNativeMessage: Hashable, Sendable {
    case ready(webContentGeneration: UInt64)
    case edit(
        webContentGeneration: UInt64,
        access: MonacoDocumentAccess,
        baseVersion: UInt64,
        changes: [UTF16TextEdit]
    )
    case save(webContentGeneration: UInt64, access: MonacoDocumentAccess)
    case viewState(
        webContentGeneration: UInt64,
        access: MonacoDocumentAccess,
        value: DocumentViewState
    )
}

public enum MonacoNativeMessage: Hashable, Sendable {
    case open(
        webContentGeneration: UInt64,
        access: MonacoDocumentAccess,
        language: String,
        snapshot: DocumentSnapshot,
        viewState: DocumentViewState?
    )
    case acknowledgement(
        webContentGeneration: UInt64,
        access: MonacoDocumentAccess,
        acknowledgement: EditAcknowledgement
    )
    case replace(
        webContentGeneration: UInt64,
        access: MonacoDocumentAccess,
        snapshot: DocumentSnapshot,
        viewState: DocumentViewState?
    )
    case setWritable(webContentGeneration: UInt64, access: MonacoDocumentAccess)
    case renameModel(
        webContentGeneration: UInt64,
        access: MonacoDocumentAccess,
        oldURI: String,
        language: String,
        snapshot: DocumentSnapshot,
        viewState: DocumentViewState?
    )
    case disposeModel(webContentGeneration: UInt64, access: MonacoDocumentAccess)
    case selectModel(
        webContentGeneration: UInt64,
        access: MonacoDocumentAccess,
        viewState: DocumentViewState?
    )
}

public enum MonacoNativeReply: Hashable, Sendable {
    case success(MonacoNativeMessage?)
    case failure(MonacoBridgeError)

    public var error: MonacoBridgeError? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}

@MainActor
public enum MonacoMessageCodec {
    private static let maximumInteger = documentJavaScriptMaximum

    public static func decode(_ body: Any) throws -> MonacoToNativeMessage {
        let object = try dictionary(body)
        guard let type = object["type"] as? String else { throw MonacoBridgeError.invalidSchema }
        if type == "ready" {
            try requireKeys(object, ["type", "webContentGeneration"])
            return .ready(webContentGeneration: try positiveInteger(object["webContentGeneration"]))
        }

        let expected: Set<String>
        switch type {
        case "edit":
            expected = commonDocumentKeys.union(["baseVersion", "changes"])
        case "save":
            expected = commonDocumentKeys
        case "viewState":
            expected = commonDocumentKeys.union(["value"])
        default:
            throw MonacoBridgeError.invalidSchema
        }
        try requireKeys(object, expected)
        let generation = try positiveInteger(object["webContentGeneration"])
        let access = try decodeAccess(object)

        switch type {
        case "edit":
            let baseVersion = try nonnegativeInteger(object["baseVersion"])
            guard let rawChanges = object["changes"] as? [Any], !rawChanges.isEmpty else {
                throw MonacoBridgeError.invalidSchema
            }
            var changes: [UTF16TextEdit] = []
            var priorOffset: UInt64?
            var priorEnd: UInt64?
            for rawChange in rawChanges {
                let value = try dictionary(rawChange)
                try requireKeys(value, ["offset", "length", "replacement"])
                let offset = try nonnegativeInteger(value["offset"])
                let length = try nonnegativeInteger(value["length"])
                guard let replacement = value["replacement"] as? String else {
                    throw MonacoBridgeError.invalidSchema
                }
                let edit: UTF16TextEdit
                do {
                    edit = try UTF16TextEdit(
                        validatingOffset: offset,
                        length: length,
                        replacement: replacement
                    )
                } catch {
                    throw MonacoBridgeError.invalidSchema
                }
                if let priorOffset, offset <= priorOffset { throw MonacoBridgeError.invalidSchema }
                if let priorEnd, offset < priorEnd { throw MonacoBridgeError.invalidSchema }
                priorOffset = offset
                priorEnd = offset + length
                changes.append(edit)
            }
            guard access.writable, access.editLeaseID != nil else {
                throw MonacoBridgeError.invalidSchema
            }
            return .edit(
                webContentGeneration: generation,
                access: access,
                baseVersion: baseVersion,
                changes: changes
            )
        case "save":
            return .save(webContentGeneration: generation, access: access)
        case "viewState":
            return .viewState(
                webContentGeneration: generation,
                access: access,
                value: try decodeViewState(object["value"])
            )
        default:
            throw MonacoBridgeError.invalidSchema
        }
    }

    public static func javaScriptObject(for message: MonacoNativeMessage) throws -> [String: Any] {
        try validate(message)
        switch message {
        case let .open(generation, access, language, snapshot, viewState):
            var value = documentObject(type: "open", generation: generation, access: access)
            value.merge([
                "language": language,
                "text": snapshot.text,
                "documentVersion": snapshot.documentVersion,
                "viewState": viewState.map(viewStateObject) ?? NSNull(),
            ]) { _, new in new }
            return value
        case let .acknowledgement(generation, access, acknowledgement):
            var value = documentObject(type: "ack", generation: generation, access: access)
            value.merge([
                "clientSequence": acknowledgement.clientSequence,
                "documentVersion": acknowledgement.documentVersion,
            ]) { _, new in new }
            return value
        case let .replace(generation, access, snapshot, viewState):
            var value = documentObject(type: "replace", generation: generation, access: access)
            value.merge([
                "text": snapshot.text,
                "documentVersion": snapshot.documentVersion,
                "viewState": viewState.map(viewStateObject) ?? NSNull(),
            ]) { _, new in new }
            return value
        case let .setWritable(generation, access):
            return documentObject(type: "setWritable", generation: generation, access: access)
        case let .renameModel(generation, access, oldURI, language, snapshot, viewState):
            var value = documentObject(type: "renameModel", generation: generation, access: access)
            value["oldURI"] = oldURI
            value["newURI"] = value.removeValue(forKey: "uri")
            value.merge([
                "language": language,
                "text": snapshot.text,
                "documentVersion": snapshot.documentVersion,
                "viewState": viewState.map(viewStateObject) ?? NSNull(),
            ]) { _, new in new }
            return value
        case let .disposeModel(generation, access):
            return documentObject(type: "disposeModel", generation: generation, access: access)
        case let .selectModel(generation, access, viewState):
            var value = documentObject(type: "selectModel", generation: generation, access: access)
            value["viewState"] = viewState.map(viewStateObject) ?? NSNull()
            return value
        }
    }

    public static func javaScriptObject(for reply: MonacoNativeReply) -> [String: Any] {
        switch reply {
        case let .failure(error):
            return ["ok": false, "error": ["code": error.wireCode]]
        case let .success(message):
            do {
                return [
                    "ok": true,
                    "message": try message.map(javaScriptObject(for:)) ?? NSNull(),
                ]
            } catch {
                return ["ok": false, "error": ["code": MonacoBridgeError.invalidSchema.wireCode]]
            }
        }
    }

    private static let commonDocumentKeys: Set<String> = [
        "type", "webContentGeneration", "workspaceContextID", "tabID", "documentID",
        "uri", "lastAcceptedClientSequence", "editLeaseID", "writable",
    ]

    private static func decodeAccess(_ object: [String: Any]) throws -> MonacoDocumentAccess {
        let contextID = try decodeContext(object["workspaceContextID"])
        let tabID = try identifier(object["tabID"], TabID.init)
        let documentID = try identifier(object["documentID"], DocumentID.init)
        guard let uri = object["uri"] as? String, MonacoFileURI.isCanonical(uri),
              let writable = strictBool(object["writable"])
        else { throw MonacoBridgeError.invalidSchema }
        let lastSequence = try nonnegativeInteger(object["lastAcceptedClientSequence"])
        let leaseID: EditLeaseID?
        if isNull(object["editLeaseID"]) {
            leaseID = nil
        } else {
            leaseID = try identifier(object["editLeaseID"], EditLeaseID.init)
        }
        guard writable == (leaseID != nil) else { throw MonacoBridgeError.invalidSchema }
        return MonacoDocumentAccess(
            reference: MonacoDocumentReference(
                workspaceContextID: contextID,
                tabID: tabID,
                documentID: documentID
            ),
            uri: uri,
            lastAcceptedClientSequence: lastSequence,
            editLeaseID: leaseID,
            writable: writable
        )
    }

    private static func decodeContext(_ raw: Any?) throws -> WorkspaceContextID {
        let object = try dictionary(raw as Any)
        guard let kind = object["kind"] as? String else { throw MonacoBridgeError.invalidSchema }
        switch kind {
        case "project":
            try requireKeys(object, ["kind", "projectID"])
            return .project(try identifier(object["projectID"], ProjectID.init))
        case "conversation":
            try requireKeys(object, ["kind", "conversationID"])
            return .conversation(try identifier(object["conversationID"], ConversationID.init))
        default:
            throw MonacoBridgeError.invalidSchema
        }
    }

    private static func decodeViewState(_ raw: Any?) throws -> DocumentViewState {
        let object = try dictionary(raw as Any)
        try requireKeys(object, ["cursor", "selections", "firstVisibleLine", "horizontalScrollOffset"])
        let cursor = try decodePosition(object["cursor"])
        guard let rawSelections = object["selections"] as? [Any] else {
            throw MonacoBridgeError.invalidSchema
        }
        let selections = try rawSelections.map { raw -> CockpitTypes.TextRange in
            let range = try dictionary(raw)
            try requireKeys(range, ["anchor", "active"])
            return try CockpitTypes.TextRange(
                validatingAnchor: decodePosition(range["anchor"]),
                active: decodePosition(range["active"])
            )
        }
        return try DocumentViewState(
            validatingCursor: cursor,
            selections: selections,
            firstVisibleLine: positiveInteger(object["firstVisibleLine"]),
            horizontalScrollOffset: nonnegativeFiniteNumber(object["horizontalScrollOffset"])
        )
    }

    private static func decodePosition(_ raw: Any?) throws -> TextPosition {
        let object = try dictionary(raw as Any)
        try requireKeys(object, ["line", "column"])
        return try TextPosition(
            validatingLine: positiveInteger(object["line"]),
            column: positiveInteger(object["column"])
        )
    }

    private static func documentObject(
        type: String,
        generation: UInt64,
        access: MonacoDocumentAccess
    ) -> [String: Any] {
        [
            "type": type,
            "webContentGeneration": generation,
            "workspaceContextID": contextObject(access.reference.workspaceContextID),
            "tabID": access.reference.tabID.description,
            "documentID": access.reference.documentID.description,
            "uri": access.uri,
            "lastAcceptedClientSequence": access.lastAcceptedClientSequence,
            "editLeaseID": access.editLeaseID?.description ?? NSNull(),
            "writable": access.writable,
        ]
    }

    private static func contextObject(_ value: WorkspaceContextID) -> [String: Any] {
        switch value {
        case let .project(projectID):
            ["kind": "project", "projectID": projectID.description]
        case let .conversation(conversationID):
            ["kind": "conversation", "conversationID": conversationID.description]
        }
    }

    private static func viewStateObject(_ value: DocumentViewState) -> [String: Any] {
        [
            "cursor": positionObject(value.cursor),
            "selections": value.selections.map {
                ["anchor": positionObject($0.anchor), "active": positionObject($0.active)]
            },
            "firstVisibleLine": value.firstVisibleLine,
            "horizontalScrollOffset": value.horizontalScrollOffset,
        ]
    }

    private static func positionObject(_ value: TextPosition) -> [String: Any] {
        ["line": value.line, "column": value.column]
    }

    private static func validate(_ message: MonacoNativeMessage) throws {
        let generation: UInt64
        let access: MonacoDocumentAccess
        let viewState: DocumentViewState?
        switch message {
        case let .open(value, tuple, language, snapshot, state):
            generation = value
            access = tuple
            viewState = state
            guard !language.isEmpty,
                  snapshot.documentID == tuple.reference.documentID,
                  snapshot.documentVersion <= maximumInteger
            else { throw MonacoBridgeError.invalidSchema }
        case let .acknowledgement(value, tuple, acknowledgement):
            generation = value
            access = tuple
            viewState = nil
            guard acknowledgement.documentID == tuple.reference.documentID,
                  acknowledgement.clientSequence <= maximumInteger,
                  acknowledgement.documentVersion <= maximumInteger
            else { throw MonacoBridgeError.invalidSchema }
        case let .replace(value, tuple, snapshot, state):
            generation = value
            access = tuple
            viewState = state
            guard snapshot.documentID == tuple.reference.documentID,
                  snapshot.documentVersion <= maximumInteger
            else { throw MonacoBridgeError.invalidSchema }
        case let .setWritable(value, tuple), let .disposeModel(value, tuple):
            generation = value
            access = tuple
            viewState = nil
        case let .renameModel(value, tuple, oldURI, language, snapshot, state):
            generation = value
            access = tuple
            viewState = state
            guard MonacoFileURI.isCanonical(oldURI), !language.isEmpty,
                  snapshot.documentID == tuple.reference.documentID,
                  snapshot.documentVersion <= maximumInteger
            else { throw MonacoBridgeError.invalidSchema }
        case let .selectModel(value, tuple, state):
            generation = value
            access = tuple
            viewState = state
        }
        guard generation > 0, generation <= maximumInteger,
              access.lastAcceptedClientSequence <= maximumInteger,
              MonacoFileURI.isCanonical(access.uri),
              access.writable == (access.editLeaseID != nil)
        else { throw MonacoBridgeError.invalidSchema }
        if let viewState { try validate(viewState) }
    }

    private static func validate(_ viewState: DocumentViewState) throws {
        guard viewState.cursor.line <= maximumInteger,
              viewState.cursor.column <= maximumInteger,
              viewState.firstVisibleLine > 0,
              viewState.firstVisibleLine <= maximumInteger,
              viewState.horizontalScrollOffset.isFinite,
              viewState.horizontalScrollOffset >= 0,
              viewState.selections.allSatisfy({ range in
                  range.anchor.line <= maximumInteger
                      && range.anchor.column <= maximumInteger
                      && range.active.line <= maximumInteger
                      && range.active.column <= maximumInteger
              })
        else { throw MonacoBridgeError.invalidSchema }
    }

    private static func dictionary(_ value: Any) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw MonacoBridgeError.invalidSchema }
        return value
    }

    private static func requireKeys(_ value: [String: Any], _ keys: Set<String>) throws {
        guard Set(value.keys) == keys else { throw MonacoBridgeError.invalidSchema }
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func number(_ value: Any?) throws -> Double {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { throw MonacoBridgeError.invalidSchema }
        return number.doubleValue
    }

    private static func nonnegativeInteger(_ value: Any?) throws -> UInt64 {
        let value = try number(value)
        guard value.isFinite, value.rounded(.towardZero) == value,
              value >= 0, value <= Double(maximumInteger)
        else { throw MonacoBridgeError.invalidSchema }
        return UInt64(value)
    }

    private static func positiveInteger(_ value: Any?) throws -> UInt64 {
        let value = try nonnegativeInteger(value)
        guard value > 0 else { throw MonacoBridgeError.invalidSchema }
        return value
    }

    private static func nonnegativeFiniteNumber(_ value: Any?) throws -> Double {
        let value = try number(value)
        guard value.isFinite, value >= 0 else { throw MonacoBridgeError.invalidSchema }
        return value
    }

    private static func identifier<Scope>(
        _ value: Any?,
        _ make: (UUID) -> CockpitID<Scope>
    ) throws -> CockpitID<Scope> {
        guard let text = value as? String,
              let uuid = UUID(uuidString: text),
              make(uuid).description == text
        else { throw MonacoBridgeError.invalidSchema }
        return make(uuid)
    }

    private static func isNull(_ value: Any?) -> Bool {
        guard let value else { return true }
        if value is NSNull { return true }
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }
}

public enum MonacoFileURI {
    public static func make(environmentID: EnvironmentID, path: RelativePath) throws -> String {
        let encoded = path.string.split(separator: "/").map { component in
            component.utf8.map { byte -> String in
                switch byte {
                case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                    String(UnicodeScalar(byte))
                default:
                    String(format: "%%%02X", byte)
                }
            }.joined()
        }.joined(separator: "/")
        return "cockpit-file://\(environmentID.description)/\(encoded)"
    }

    static func isCanonical(_ value: String) -> Bool {
        let prefix = "cockpit-file://"
        guard value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        let pieces = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count > 1,
              let uuid = UUID(uuidString: String(pieces[0])),
              EnvironmentID(uuid).description == pieces[0]
        else { return false }
        let decoded = pieces.dropFirst().map { String($0).removingPercentEncoding }
        guard decoded.allSatisfy({ $0 != nil }),
              let path = try? RelativePath(decoded.compactMap { $0 }.joined(separator: "/")),
              let canonical = try? make(environmentID: EnvironmentID(uuid), path: path)
        else { return false }
        return canonical == value
    }
}

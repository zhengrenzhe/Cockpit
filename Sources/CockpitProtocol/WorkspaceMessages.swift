import Foundation
import CockpitTypes

public enum ProtocolMappingError: Error, Equatable, Sendable {
    case missingRequiredField(String)
    case invalidIdentifier(String)
    case invalidValue(String)
    case unknownOneOf(String)
    case unknownEnum(field: String, rawValue: Int)
    case unknownFields(String)
}

public enum WorkspaceMessages {
    public static func encode(_ value: WorkspaceContextID) throws -> CPWorkspaceContextID {
        var message = CPWorkspaceContextID()
        switch value {
        case let .project(id): message.projectID = id.description
        case let .conversation(id): message.conversationID = id.description
        }
        return message
    }

    public static func decode(_ message: CPWorkspaceContextID) throws -> WorkspaceContextID {
        try rejectUnknownFields(message.unknownFields.data, field: "workspace_context_id")
        switch message.kind {
        case let .projectID(value): return .project(try decodeID(value, field: "project_id"))
        case let .conversationID(value): return .conversation(try decodeID(value, field: "conversation_id"))
        case nil: throw ProtocolMappingError.unknownOneOf("workspace_context_id.kind")
        }
    }

    public static func encode(_ value: RequestContext, negotiatedVersion: ProtocolVersion) throws -> CPRequestContext {
        try validateNegotiatedVersion(negotiatedVersion)
        do { _ = try value.validated(negotiatedVersion: negotiatedVersion) }
        catch CockpitDomainValidationError.protocolVersionMismatch { throw ProtocolMappingError.invalidValue("protocol_version") }
        catch { throw ProtocolMappingError.invalidValue("request_context") }
        var message = CPRequestContext()
        message.protocolMajor = UInt32(value.protocolVersion.major)
        message.protocolMinor = UInt32(value.protocolVersion.minor)
        message.clientInstanceID = value.clientInstanceID.description
        message.windowID = value.windowID.description
        message.workspaceContextID = try encode(value.workspaceContextID)
        message.environmentID = value.environmentID.description
        message.activeContextGeneration = value.activeContextGeneration
        message.requestID = value.requestID.description
        return message
    }

    public static func decode(_ message: CPRequestContext, negotiatedVersion: ProtocolVersion) throws -> RequestContext {
        try validateNegotiatedVersion(negotiatedVersion)
        try rejectUnknownFields(message.unknownFields.data, field: "request_context")
        guard message.hasWorkspaceContextID else { throw ProtocolMappingError.missingRequiredField("workspace_context_id") }
        let workspaceContextID = try decode(message.workspaceContextID)
        guard let major = UInt16(exactly: message.protocolMajor), let minor = UInt16(exactly: message.protocolMinor) else {
            throw ProtocolMappingError.invalidValue("protocol_version")
        }
        let version = ProtocolVersion(major: major, minor: minor)
        let value: RequestContext
        do {
            value = try RequestContext(
                validating: version,
                clientInstanceID: decodeID(message.clientInstanceID, field: "client_instance_id"),
                windowID: decodeID(message.windowID, field: "window_id"),
                workspaceContextID: workspaceContextID,
                environmentID: decodeID(message.environmentID, field: "environment_id"),
                activeContextGeneration: message.activeContextGeneration,
                requestID: decodeID(message.requestID, field: "request_id")
            )
            return try value.validated(negotiatedVersion: negotiatedVersion)
        } catch let error as ProtocolMappingError {
            throw error
        } catch CockpitDomainValidationError.protocolVersionMismatch {
            throw ProtocolMappingError.invalidValue("protocol_version")
        } catch {
            throw ProtocolMappingError.invalidValue("request_context")
        }
    }
}

extension ProtocolMappingError {
    public func asWireProtocolError() -> CPProtocolError {
        var value = CPProtocolError()
        value.code = .malformedMessage
        switch self {
        case .missingRequiredField: value.message = "missing required field"
        case .invalidIdentifier: value.message = "invalid identifier"
        case .invalidValue: value.message = "invalid value"
        case .unknownOneOf: value.message = "unknown oneof"
        case .unknownEnum: value.message = "unknown enum"
        case .unknownFields: value.message = "unknown fields"
        }
        return value
    }
}

internal func validateNegotiatedVersion(_ version: ProtocolVersion) throws {
    guard version.major == 1, version.minor >= 1 else { throw ProtocolMappingError.invalidValue("negotiated_version") }
}

internal func rejectUnknownFields(_ data: Data, field: String) throws {
    guard data.isEmpty else { throw ProtocolMappingError.unknownFields(field) }
}

internal func decodeID<Scope>(_ value: String, field: String) throws -> CockpitID<Scope> {
    guard !value.isEmpty, let uuid = UUID(uuidString: value) else { throw ProtocolMappingError.invalidIdentifier(field) }
    return CockpitID<Scope>(uuid)
}

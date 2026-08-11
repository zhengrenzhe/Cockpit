import Foundation
import CockpitTypes

public enum WorkspaceCommandRequest: Hashable, Sendable, Codable {
    case addProject(bookmark: Data, displayName: String)
    case listWorkspace
    case createDirectConversation(projectID: ProjectID)
    case renameConversation(id: ConversationID, title: String)
    case resolveContext(WorkspaceContextID)
    case performFileOperation(context: RequestContext, operation: FileOperation)
    case loadClientState(ClientWorkspaceStateKey)
    case saveClientState(ClientWorkspaceState)

    private enum Command: String, Codable {
        case addProject
        case listWorkspace
        case createDirectConversation
        case renameConversation
        case resolveContext
        case performFileOperation
        case loadClientState
        case saveClientState
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case bookmark
        case displayName
        case projectID
        case conversationID
        case title
        case contextID
        case context
        case fileOperation
        case clientStateKey
        case clientState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let command = try container.decode(Command.self, forKey: .command)
        switch command {
        case .addProject:
            try requireExactKeys(
                decoder,
                required: ["command", "bookmark", "displayName"]
            )
            try Self.reject([.projectID, .conversationID, .title, .contextID], in: container)
            self = .addProject(
                bookmark: try container.decode(Data.self, forKey: .bookmark),
                displayName: try container.decode(String.self, forKey: .displayName)
            )
        case .listWorkspace:
            try requireExactKeys(decoder, required: ["command"])
            try Self.reject(
                [.bookmark, .displayName, .projectID, .conversationID, .title, .contextID],
                in: container
            )
            self = .listWorkspace
        case .createDirectConversation:
            try requireExactKeys(decoder, required: ["command", "projectID"])
            try Self.reject([.bookmark, .displayName, .conversationID, .title, .contextID], in: container)
            self = .createDirectConversation(
                projectID: try container.decode(ProjectID.self, forKey: .projectID)
            )
        case .renameConversation:
            try requireExactKeys(
                decoder,
                required: ["command", "conversationID", "title"]
            )
            try Self.reject([.bookmark, .displayName, .projectID, .contextID], in: container)
            self = .renameConversation(
                id: try container.decode(ConversationID.self, forKey: .conversationID),
                title: try container.decode(String.self, forKey: .title)
            )
        case .resolveContext:
            try requireExactKeys(decoder, required: ["command", "contextID"])
            try Self.reject([.bookmark, .displayName, .projectID, .conversationID, .title], in: container)
            self = .resolveContext(
                try container.decode(WireWorkspaceContextID.self, forKey: .contextID).value
            )
        case .performFileOperation:
            try requireExactKeys(
                decoder,
                required: ["command", "context", "fileOperation"]
            )
            self = .performFileOperation(
                context: try container.decode(WireRequestContext.self, forKey: .context).value,
                operation: try container.decode(WireFileOperation.self, forKey: .fileOperation).value
            )
        case .loadClientState:
            try requireExactKeys(decoder, required: ["command", "clientStateKey"])
            self = .loadClientState(
                try container.decode(ClientWorkspaceStateKey.self, forKey: .clientStateKey)
            )
        case .saveClientState:
            try requireExactKeys(decoder, required: ["command", "clientState"])
            self = .saveClientState(
                try container.decode(ClientWorkspaceState.self, forKey: .clientState).validated()
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .addProject(bookmark, displayName):
            try container.encode(Command.addProject, forKey: .command)
            try container.encode(bookmark, forKey: .bookmark)
            try container.encode(displayName, forKey: .displayName)
        case .listWorkspace:
            try container.encode(Command.listWorkspace, forKey: .command)
        case let .createDirectConversation(projectID):
            try container.encode(Command.createDirectConversation, forKey: .command)
            try container.encode(projectID, forKey: .projectID)
        case let .renameConversation(id, title):
            try container.encode(Command.renameConversation, forKey: .command)
            try container.encode(id, forKey: .conversationID)
            try container.encode(title, forKey: .title)
        case let .resolveContext(contextID):
            try container.encode(Command.resolveContext, forKey: .command)
            try container.encode(WireWorkspaceContextID(contextID), forKey: .contextID)
        case let .performFileOperation(context, operation):
            try container.encode(Command.performFileOperation, forKey: .command)
            try container.encode(WireRequestContext(context), forKey: .context)
            try container.encode(WireFileOperation(operation), forKey: .fileOperation)
        case let .loadClientState(key):
            try container.encode(Command.loadClientState, forKey: .command)
            try container.encode(key, forKey: .clientStateKey)
        case let .saveClientState(state):
            try container.encode(Command.saveClientState, forKey: .command)
            try container.encode(try state.validated(), forKey: .clientState)
        }
    }

    private static func reject(
        _ keys: [CodingKeys],
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        if let key = keys.first(where: container.contains) {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Field \(key.stringValue) is forbidden for this workspace command"
            )
        }
    }
}

public enum WorkspaceCommandResponse: Hashable, Sendable, Codable {
    case projectSnapshot(ProjectSnapshot)
    case workspaceSnapshot(WorkspaceSnapshot)
    case conversation(Conversation)
    case empty
    case resolvedContext(ResolvedWorkspaceContext)
    case fileOperationResult(FileOperationResult)
    case clientWorkspaceState(ClientWorkspaceState?)

    private enum Result: String, Codable {
        case projectSnapshot
        case workspaceSnapshot
        case conversation
        case empty
        case resolvedContext
        case fileOperationResult
        case clientWorkspaceState
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case projectSnapshot
        case workspaceSnapshot
        case conversation
        case resolvedContext
        case fileOperationResult
        case clientWorkspaceState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Result.self, forKey: .result) {
        case .projectSnapshot:
            try requireExactKeys(decoder, required: ["result", "projectSnapshot"])
            try Self.reject([.workspaceSnapshot, .conversation, .resolvedContext], in: container)
            self = .projectSnapshot(
                try container.decode(WireProjectSnapshot.self, forKey: .projectSnapshot).value
            )
        case .workspaceSnapshot:
            try requireExactKeys(decoder, required: ["result", "workspaceSnapshot"])
            try Self.reject([.projectSnapshot, .conversation, .resolvedContext], in: container)
            self = .workspaceSnapshot(
                try container.decode([WireProjectSnapshot].self, forKey: .workspaceSnapshot).map {
                    try $0.value
                }
            )
        case .conversation:
            try requireExactKeys(decoder, required: ["result", "conversation"])
            try Self.reject([.projectSnapshot, .workspaceSnapshot, .resolvedContext], in: container)
            self = .conversation(
                try container.decode(WireConversation.self, forKey: .conversation).value
            )
        case .empty:
            try requireExactKeys(decoder, required: ["result"])
            try Self.reject([.projectSnapshot, .workspaceSnapshot, .conversation, .resolvedContext], in: container)
            self = .empty
        case .resolvedContext:
            try requireExactKeys(decoder, required: ["result", "resolvedContext"])
            try Self.reject([.projectSnapshot, .workspaceSnapshot, .conversation], in: container)
            self = .resolvedContext(
                try container.decode(WireResolvedWorkspaceContext.self, forKey: .resolvedContext).value
            )
        case .fileOperationResult:
            try requireExactKeys(decoder, required: ["result", "fileOperationResult"])
            self = .fileOperationResult(
                try container.decode(WireFileOperationResult.self, forKey: .fileOperationResult).value
            )
        case .clientWorkspaceState:
            try requireExactKeys(decoder, required: ["result", "clientWorkspaceState"])
            self = .clientWorkspaceState(
                try container.decodeIfPresent(
                    ClientWorkspaceState.self,
                    forKey: .clientWorkspaceState
                )?.validated()
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .projectSnapshot(snapshot):
            try container.encode(Result.projectSnapshot, forKey: .result)
            try container.encode(WireProjectSnapshot(snapshot), forKey: .projectSnapshot)
        case let .workspaceSnapshot(snapshot):
            try container.encode(Result.workspaceSnapshot, forKey: .result)
            try container.encode(snapshot.map(WireProjectSnapshot.init), forKey: .workspaceSnapshot)
        case let .conversation(conversation):
            try container.encode(Result.conversation, forKey: .result)
            try container.encode(WireConversation(conversation), forKey: .conversation)
        case .empty:
            try container.encode(Result.empty, forKey: .result)
        case let .resolvedContext(context):
            try container.encode(Result.resolvedContext, forKey: .result)
            try container.encode(WireResolvedWorkspaceContext(context), forKey: .resolvedContext)
        case let .fileOperationResult(result):
            try container.encode(Result.fileOperationResult, forKey: .result)
            try container.encode(WireFileOperationResult(result), forKey: .fileOperationResult)
        case let .clientWorkspaceState(state):
            try container.encode(Result.clientWorkspaceState, forKey: .result)
            if let state {
                try container.encode(try state.validated(), forKey: .clientWorkspaceState)
            } else {
                try container.encodeNil(forKey: .clientWorkspaceState)
            }
        }
    }

    private static func reject(
        _ keys: [CodingKeys],
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        if let key = keys.first(where: container.contains) {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Field \(key.stringValue) is forbidden for this workspace response"
            )
        }
    }
}

public struct WorkspaceCommandRouter: Sendable {
    private let service: any WorkspaceServing
    private let clientStateService: (any ClientWorkspaceStateServing)?

    public init(
        service: any WorkspaceServing,
        clientStateService: (any ClientWorkspaceStateServing)? = nil
    ) {
        self.service = service
        self.clientStateService = clientStateService
            ?? (service as? any ClientWorkspaceStateServing)
    }

    public func route(_ data: Data) async throws -> Data {
        let request = try JSONDecoder().decode(WorkspaceCommandRequest.self, from: data)
        let response: WorkspaceCommandResponse
        switch request {
        case let .addProject(bookmark, displayName):
            response = .projectSnapshot(
                try await service.addProject(bookmark: bookmark, displayName: displayName)
            )
        case .listWorkspace:
            response = .workspaceSnapshot(try await service.listWorkspace())
        case let .createDirectConversation(projectID):
            response = .conversation(
                try await service.createDirectConversation(projectID: projectID)
            )
        case let .renameConversation(id, title):
            try await service.renameConversation(id: id, title: title)
            response = .empty
        case let .resolveContext(contextID):
            response = .resolvedContext(try await service.resolveContext(contextID))
        case let .performFileOperation(context, operation):
            response = .fileOperationResult(
                try await service.performFileOperation(context: context, operation: operation)
            )
        case let .loadClientState(key):
            guard let clientStateService else { throw CocoaError(.coderInvalidValue) }
            response = .clientWorkspaceState(
                try await clientStateService.loadClientState(key)
            )
        case let .saveClientState(state):
            guard let clientStateService else { throw CocoaError(.coderInvalidValue) }
            try await clientStateService.saveClientState(state)
            response = .empty
        }
        return try JSONEncoder().encode(response)
    }
}

private struct WireRequestContext: Codable {
    let value: RequestContext

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case clientInstanceID
        case windowID
        case workspaceContextID
        case environmentID
        case activeContextGeneration
        case requestID
    }

    init(_ value: RequestContext) { self.value = value }

    init(from decoder: Decoder) throws {
        try requireExactKeys(
            decoder,
            required: [
                "protocolVersion", "clientInstanceID", "windowID", "workspaceContextID",
                "environmentID", "activeContextGeneration", "requestID",
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try RequestContext(
            validating: container.decode(WireProtocolVersion.self, forKey: .protocolVersion).value,
            clientInstanceID: container.decode(WireCockpitID<ClientInstanceScope>.self, forKey: .clientInstanceID).value,
            windowID: container.decode(WireCockpitID<WindowScope>.self, forKey: .windowID).value,
            workspaceContextID: container.decode(WireWorkspaceContextID.self, forKey: .workspaceContextID).value,
            environmentID: container.decode(WireCockpitID<EnvironmentScope>.self, forKey: .environmentID).value,
            activeContextGeneration: container.decode(UInt64.self, forKey: .activeContextGeneration),
            requestID: container.decode(WireCockpitID<RequestScope>.self, forKey: .requestID).value
        )
    }

    func encode(to encoder: Encoder) throws {
        let valid = try RequestContext(
            validating: value.protocolVersion,
            clientInstanceID: value.clientInstanceID,
            windowID: value.windowID,
            workspaceContextID: value.workspaceContextID,
            environmentID: value.environmentID,
            activeContextGeneration: value.activeContextGeneration,
            requestID: value.requestID
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WireProtocolVersion(valid.protocolVersion), forKey: .protocolVersion)
        try container.encode(WireCockpitID(valid.clientInstanceID), forKey: .clientInstanceID)
        try container.encode(WireCockpitID(valid.windowID), forKey: .windowID)
        try container.encode(WireWorkspaceContextID(valid.workspaceContextID), forKey: .workspaceContextID)
        try container.encode(WireCockpitID(valid.environmentID), forKey: .environmentID)
        try container.encode(valid.activeContextGeneration, forKey: .activeContextGeneration)
        try container.encode(WireCockpitID(valid.requestID), forKey: .requestID)
    }
}

private struct WireProtocolVersion: Codable {
    let value: ProtocolVersion
    private enum CodingKeys: String, CodingKey { case major, minor }
    init(_ value: ProtocolVersion) { self.value = value }
    init(from decoder: Decoder) throws {
        try requireExactKeys(decoder, required: ["major", "minor"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = ProtocolVersion(
            major: try container.decode(UInt16.self, forKey: .major),
            minor: try container.decode(UInt16.self, forKey: .minor)
        )
        guard value.major > 0 else { throw CocoaError(.coderInvalidValue) }
        self.value = value
    }
    func encode(to encoder: Encoder) throws {
        guard value.major > 0 else { throw CocoaError(.coderInvalidValue) }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.major, forKey: .major)
        try container.encode(value.minor, forKey: .minor)
    }
}

private struct WireCockpitID<Scope>: Codable {
    let value: CockpitID<Scope>
    private enum CodingKeys: String, CodingKey { case rawValue }

    init(_ value: CockpitID<Scope>) { self.value = value }

    init(from decoder: Decoder) throws {
        try requireExactKeys(decoder, required: ["rawValue"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = CockpitID(try container.decode(UUID.self, forKey: .rawValue))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.rawValue, forKey: .rawValue)
    }
}

private struct WireWorkspaceDirectory: Codable {
    let value: WorkspaceDirectory
    private enum CodingKeys: String, CodingKey { case root, relative }
    init(_ value: WorkspaceDirectory) { self.value = value }
    init(from decoder: Decoder) throws {
        let keys = try decodedKeySet(decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch keys {
        case ["root"]:
            guard try container.decode(Bool.self, forKey: .root) else {
                throw CocoaError(.coderInvalidValue)
            }
            value = .root
        case ["relative"]:
            value = .relative(try RelativePath(container.decode(String.self, forKey: .relative)))
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }
    func encode(to encoder: Encoder) throws {
        let valid = try value.validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch valid {
        case .root: try container.encode(true, forKey: .root)
        case let .relative(path): try container.encode(path.string, forKey: .relative)
        }
    }
}

private struct WireFileOperation: Codable {
    let value: FileOperation
    private enum Kind: String, Codable { case createFile, createDirectory, rename, move, trash }
    private enum CodingKeys: String, CodingKey {
        case kind, parent, name, source, newName, destinationDirectory, path
    }
    init(_ value: FileOperation) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .createFile:
            try requireExactKeys(decoder, required: ["kind", "parent", "name"])
            value = .createFile(
                parent: try container.decode(WireWorkspaceDirectory.self, forKey: .parent).value,
                name: try validatedWireName(container.decode(String.self, forKey: .name))
            )
        case .createDirectory:
            try requireExactKeys(decoder, required: ["kind", "parent", "name"])
            value = .createDirectory(
                parent: try container.decode(WireWorkspaceDirectory.self, forKey: .parent).value,
                name: try validatedWireName(container.decode(String.self, forKey: .name))
            )
        case .rename:
            try requireExactKeys(decoder, required: ["kind", "source", "newName"])
            value = .rename(
                source: try RelativePath(container.decode(String.self, forKey: .source)),
                newName: try validatedWireName(container.decode(String.self, forKey: .newName))
            )
        case .move:
            try requireExactKeys(decoder, required: ["kind", "source", "destinationDirectory"])
            value = .move(
                source: try RelativePath(container.decode(String.self, forKey: .source)),
                destinationDirectory: try container.decode(WireWorkspaceDirectory.self, forKey: .destinationDirectory).value
            )
        case .trash:
            try requireExactKeys(decoder, required: ["kind", "path"])
            value = .trash(path: try RelativePath(container.decode(String.self, forKey: .path)))
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case let .createFile(parent, name):
            try container.encode(Kind.createFile, forKey: .kind)
            try container.encode(WireWorkspaceDirectory(parent), forKey: .parent)
            try container.encode(validatedWireName(name), forKey: .name)
        case let .createDirectory(parent, name):
            try container.encode(Kind.createDirectory, forKey: .kind)
            try container.encode(WireWorkspaceDirectory(parent), forKey: .parent)
            try container.encode(validatedWireName(name), forKey: .name)
        case let .rename(source, newName):
            try container.encode(Kind.rename, forKey: .kind)
            try container.encode(RelativePath(source.string).string, forKey: .source)
            try container.encode(validatedWireName(newName), forKey: .newName)
        case let .move(source, destinationDirectory):
            try container.encode(Kind.move, forKey: .kind)
            try container.encode(RelativePath(source.string).string, forKey: .source)
            try container.encode(WireWorkspaceDirectory(destinationDirectory), forKey: .destinationDirectory)
        case let .trash(path):
            try container.encode(Kind.trash, forKey: .kind)
            try container.encode(RelativePath(path.string).string, forKey: .path)
        }
    }
}

private struct WireFileOperationResult: Codable {
    let value: FileOperationResult
    private enum Kind: String, Codable { case created, relocated, trashed }
    private enum EntryKind: String, Codable { case file, directory, symbolicLink }
    private enum CodingKeys: String, CodingKey { case kind, path, entryKind, from, to }
    init(_ value: FileOperationResult) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .created:
            try requireExactKeys(decoder, required: ["kind", "path", "entryKind"])
            let entryKind: FileTreeEntryKind
            switch try container.decode(EntryKind.self, forKey: .entryKind) {
            case .file: entryKind = .file
            case .directory: entryKind = .directory
            case .symbolicLink: entryKind = .symbolicLink
            }
            value = .created(
                path: try RelativePath(container.decode(String.self, forKey: .path)),
                kind: entryKind
            )
        case .relocated:
            try requireExactKeys(decoder, required: ["kind", "from", "to"])
            value = .relocated(
                from: try RelativePath(container.decode(String.self, forKey: .from)),
                to: try RelativePath(container.decode(String.self, forKey: .to))
            )
        case .trashed:
            try requireExactKeys(decoder, required: ["kind", "path"])
            value = .trashed(path: try RelativePath(container.decode(String.self, forKey: .path)))
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case let .created(path, kind):
            try container.encode(Kind.created, forKey: .kind)
            try container.encode(RelativePath(path.string).string, forKey: .path)
            let entryKind: EntryKind = switch kind {
            case .file: .file
            case .directory: .directory
            case .symbolicLink: .symbolicLink
            }
            try container.encode(entryKind, forKey: .entryKind)
        case let .relocated(from, to):
            try container.encode(Kind.relocated, forKey: .kind)
            try container.encode(RelativePath(from.string).string, forKey: .from)
            try container.encode(RelativePath(to.string).string, forKey: .to)
        case let .trashed(path):
            try container.encode(Kind.trashed, forKey: .kind)
            try container.encode(RelativePath(path.string).string, forKey: .path)
        }
    }
}

private func validatedWireName(_ name: String) throws -> String {
    guard !name.isEmpty,
          name != ".",
          name != "..",
          !name.contains("/"),
          !name.contains("\0")
    else {
        throw FileOperationError.invalidName
    }
    return name
}

private struct WireProjectSnapshot: Codable {
    let projectID: ProjectID
    let displayName: String
    let resolvedContext: ResolvedWorkspaceContext
    let conversations: [WireConversation]

    private enum CodingKeys: String, CodingKey {
        case projectID
        case displayName
        case resolvedContext
        case conversations
    }

    init(_ value: ProjectSnapshot) {
        projectID = value.projectID
        displayName = value.displayName
        resolvedContext = value.resolvedContext
        conversations = value.conversations.map(WireConversation.init)
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(
            decoder,
            required: ["projectID", "displayName", "resolvedContext", "conversations"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        displayName = try container.decode(String.self, forKey: .displayName)
        resolvedContext = try container.decode(
            WireResolvedWorkspaceContext.self,
            forKey: .resolvedContext
        ).value
        conversations = try container.decode([WireConversation].self, forKey: .conversations)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(WireResolvedWorkspaceContext(resolvedContext), forKey: .resolvedContext)
        try container.encode(conversations, forKey: .conversations)
    }

    var value: ProjectSnapshot {
        get throws {
            ProjectSnapshot(
                projectID: projectID,
                displayName: displayName,
                resolvedContext: resolvedContext,
                conversations: try conversations.map { try $0.value }
            )
        }
    }
}

private struct WireConversation: Codable {
    let id: ConversationID
    let projectID: ProjectID
    let environmentID: EnvironmentID
    let title: String
    let lifecycle: String
    let deletionPhase: String?
    let deletionOperationID: DeletionOperationID?
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case environmentID
        case title
        case lifecycle
        case deletionPhase
        case deletionOperationID
        case createdAt
    }

    init(_ value: Conversation) {
        id = value.id
        projectID = value.projectID
        environmentID = value.environmentID
        title = value.title
        switch value.lifecycleState {
        case .active:
            lifecycle = "active"
            deletionPhase = nil
        case let .deleting(phase):
            lifecycle = "deleting"
            deletionPhase = phase
        }
        deletionOperationID = value.deletionOperationID
        createdAt = value.createdAt
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(
            decoder,
            required: ["id", "projectID", "environmentID", "title", "lifecycle", "createdAt"],
            optional: ["deletionPhase", "deletionOperationID"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ConversationID.self, forKey: .id)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        environmentID = try container.decode(EnvironmentID.self, forKey: .environmentID)
        title = try container.decode(String.self, forKey: .title)
        lifecycle = try container.decode(String.self, forKey: .lifecycle)
        deletionPhase = try container.decodeIfPresent(String.self, forKey: .deletionPhase)
        deletionOperationID = try container.decodeIfPresent(
            DeletionOperationID.self,
            forKey: .deletionOperationID
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(environmentID, forKey: .environmentID)
        try container.encode(title, forKey: .title)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encodeIfPresent(deletionPhase, forKey: .deletionPhase)
        try container.encodeIfPresent(deletionOperationID, forKey: .deletionOperationID)
        try container.encode(createdAt, forKey: .createdAt)
    }

    var value: Conversation {
        get throws {
            let state: ConversationLifecycleState
            switch lifecycle {
            case "active":
                guard deletionPhase == nil, deletionOperationID == nil else {
                    throw CocoaError(.coderInvalidValue)
                }
                state = .active
            case "deleting":
                guard let deletionPhase, deletionOperationID != nil else {
                    throw CocoaError(.coderInvalidValue)
                }
                state = .deleting(phase: deletionPhase)
            default:
                throw CocoaError(.coderInvalidValue)
            }
            return Conversation(
                id: id,
                projectID: projectID,
                environmentID: environmentID,
                title: title,
                lifecycleState: state,
                deletionOperationID: deletionOperationID,
                createdAt: createdAt
            )
        }
    }
}

private struct WireResolvedWorkspaceContext: Codable {
    let value: ResolvedWorkspaceContext

    private enum CodingKeys: String, CodingKey {
        case contextID
        case projectID
        case conversationID
        case environmentID
        case workspaceRootIdentity
    }

    init(_ value: ResolvedWorkspaceContext) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(
            decoder,
            required: ["contextID", "projectID", "environmentID", "workspaceRootIdentity"],
            optional: ["conversationID"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try ResolvedWorkspaceContext(
            validating: container.decode(WireWorkspaceContextID.self, forKey: .contextID).value,
            projectID: container.decode(ProjectID.self, forKey: .projectID),
            conversationID: container.decodeIfPresent(ConversationID.self, forKey: .conversationID),
            environmentID: container.decode(EnvironmentID.self, forKey: .environmentID),
            workspaceRootIdentity: container.decode(String.self, forKey: .workspaceRootIdentity)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(WireWorkspaceContextID(value.contextID), forKey: .contextID)
        try container.encode(value.projectID, forKey: .projectID)
        try container.encodeIfPresent(value.conversationID, forKey: .conversationID)
        try container.encode(value.environmentID, forKey: .environmentID)
        try container.encode(value.workspaceRootIdentity, forKey: .workspaceRootIdentity)
    }
}

private struct WireWorkspaceContextID: Codable {
    let value: WorkspaceContextID

    private enum CodingKeys: String, CodingKey {
        case project
        case conversation
    }

    init(_ value: WorkspaceContextID) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let keys = try decodedKeySet(decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch keys {
        case ["project"]:
            value = .project(
                try container.decode(WireCockpitID<ProjectScope>.self, forKey: .project).value
            )
        case ["conversation"]:
            value = .conversation(
                try container.decode(WireCockpitID<ConversationScope>.self, forKey: .conversation).value
            )
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Workspace context ID requires exactly one approved key"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case let .project(projectID):
            try container.encode(WireCockpitID(projectID), forKey: .project)
        case let .conversation(conversationID):
            try container.encode(WireCockpitID(conversationID), forKey: .conversation)
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func decodedKeySet(_ decoder: Decoder) throws -> Set<String> {
    Set(
        try decoder.container(keyedBy: DynamicCodingKey.self)
            .allKeys
            .map(\.stringValue)
    )
}

private func requireExactKeys(
    _ decoder: Decoder,
    required: Set<String>,
    optional: Set<String> = []
) throws {
    let actual = try decodedKeySet(decoder)
    guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Wire keys do not match the approved schema"
            )
        )
    }
}

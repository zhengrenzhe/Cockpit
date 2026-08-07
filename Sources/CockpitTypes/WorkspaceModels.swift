import Foundation

public enum WorkspaceDirectory: Hashable, Codable, Sendable {
    case root
    case relative(RelativePath)

    public func validated() throws -> Self {
        switch self {
        case .root: return .root
        case let .relative(path): return .relative(try RelativePath(path.string))
        }
    }

    private enum CodingKeys: String, CodingKey { case root, relative }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let root = try container.decodeIfPresent(Bool.self, forKey: .root)
        let relative = try container.decodeIfPresent(RelativePath.self, forKey: .relative)
        switch (root, relative) {
        case (true?, nil): self = .root
        case (nil, let path?): self = .relative(try RelativePath(path.string))
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Exactly one workspace directory kind is required"))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .root: try container.encode(true, forKey: .root)
        case let .relative(path): try container.encode(try RelativePath(path.string), forKey: .relative)
        }
    }
}

public struct FileTreeEntryIdentity: Hashable, Codable, Sendable {
    public let environmentID: EnvironmentID
    public let path: RelativePath

    public init(validating environmentID: EnvironmentID, path: RelativePath) throws {
        self.environmentID = environmentID
        self.path = try RelativePath(path.string)
    }

    private enum CodingKeys: String, CodingKey { case environmentID, path }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validating: container.decode(EnvironmentID.self, forKey: .environmentID), path: container.decode(RelativePath.self, forKey: .path))
    }
    public func encode(to encoder: Encoder) throws {
        let valid = try Self(validating: environmentID, path: path)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.environmentID, forKey: .environmentID)
        try container.encode(valid.path, forKey: .path)
    }
}

public enum FileTreeEntryKind: Hashable, Codable, Sendable {
    case directory
    case file
    case symbolicLink
}

public struct FileTreeEntry: Hashable, Codable, Sendable {
    public let identity: FileTreeEntryIdentity
    public let kind: FileTreeEntryKind

    public init(validating identity: FileTreeEntryIdentity, kind: FileTreeEntryKind) throws {
        self.identity = try FileTreeEntryIdentity(validating: identity.environmentID, path: identity.path)
        self.kind = kind
    }
    private enum CodingKeys: String, CodingKey { case identity, kind }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validating: container.decode(FileTreeEntryIdentity.self, forKey: .identity), kind: container.decode(FileTreeEntryKind.self, forKey: .kind))
    }
    public func encode(to encoder: Encoder) throws {
        let valid = try Self(validating: identity, kind: kind)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.identity, forKey: .identity)
        try container.encode(valid.kind, forKey: .kind)
    }
}

public struct FileTreeSnapshot: Hashable, Codable, Sendable {
    public let environmentID: EnvironmentID
    public let directory: WorkspaceDirectory
    public let generation: UInt64
    public let revision: UInt64
    public let children: [FileTreeEntry]

    public init(
        validating environmentID: EnvironmentID,
        directory: WorkspaceDirectory,
        generation: UInt64,
        revision: UInt64,
        children: [FileTreeEntry]
    ) throws {
        let directory = try directory.validated()
        guard generation > 0 else { throw CockpitDomainValidationError.invalidFileTreeGeneration }
        guard Set(children.map(\.identity)).count == children.count,
              children.allSatisfy({ $0.identity.environmentID == environmentID && directory.containsDirectChild($0.identity.path) })
        else { throw CockpitDomainValidationError.invalidFileTreeEnvelope }
        self.environmentID = environmentID
        self.directory = directory
        self.generation = generation
        self.revision = revision
        self.children = children
    }
    private enum CodingKeys: String, CodingKey { case environmentID, directory, generation, revision, children }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validating: c.decode(EnvironmentID.self, forKey: .environmentID), directory: c.decode(WorkspaceDirectory.self, forKey: .directory), generation: c.decode(UInt64.self, forKey: .generation), revision: c.decode(UInt64.self, forKey: .revision), children: c.decode([FileTreeEntry].self, forKey: .children))
    }
    public func encode(to encoder: Encoder) throws {
        let v = try Self(validating: environmentID, directory: directory, generation: generation, revision: revision, children: children)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v.environmentID, forKey: .environmentID); try c.encode(v.directory, forKey: .directory); try c.encode(v.generation, forKey: .generation); try c.encode(v.revision, forKey: .revision); try c.encode(v.children, forKey: .children)
    }
}

public enum FileTreeMutation: Hashable, Codable, Sendable {
    case insert(FileTreeEntry)
    case remove(FileTreeEntryIdentity)
    case update(FileTreeEntry)
}

public struct FileTreeDelta: Hashable, Codable, Sendable {
    public let environmentID: EnvironmentID
    public let directory: WorkspaceDirectory
    public let revision: UInt64
    public let mutations: [FileTreeMutation]

    public init(
        validating environmentID: EnvironmentID,
        directory: WorkspaceDirectory,
        revision: UInt64,
        mutations: [FileTreeMutation]
    ) throws {
        let directory = try directory.validated()
        guard revision > 0, !mutations.isEmpty else { throw CockpitDomainValidationError.invalidFileTreeDelta }
        let identities = mutations.map(\.identity)
        guard Set(identities).count == identities.count,
              identities.allSatisfy({ $0.environmentID == environmentID && directory.containsDirectChild($0.path) })
        else { throw CockpitDomainValidationError.invalidFileTreeEnvelope }
        self.environmentID = environmentID
        self.directory = directory
        self.revision = revision
        self.mutations = mutations
    }
    private enum CodingKeys: String, CodingKey { case environmentID, directory, revision, mutations }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validating: c.decode(EnvironmentID.self, forKey: .environmentID), directory: c.decode(WorkspaceDirectory.self, forKey: .directory), revision: c.decode(UInt64.self, forKey: .revision), mutations: c.decode([FileTreeMutation].self, forKey: .mutations))
    }
    public func encode(to encoder: Encoder) throws {
        let v = try Self(validating: environmentID, directory: directory, revision: revision, mutations: mutations)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v.environmentID, forKey: .environmentID); try c.encode(v.directory, forKey: .directory); try c.encode(v.revision, forKey: .revision); try c.encode(v.mutations, forKey: .mutations)
    }
}

private extension WorkspaceDirectory {
    func containsDirectChild(_ path: RelativePath) -> Bool {
        let components = path.string.split(separator: "/")
        switch self {
        case .root: return components.count == 1
        case let .relative(parent):
            let parentComponents = parent.string.split(separator: "/")
            return components.count == parentComponents.count + 1 && components.dropLast().elementsEqual(parentComponents)
        }
    }
}

private extension FileTreeMutation {
    var identity: FileTreeEntryIdentity {
        switch self {
        case let .insert(entry), let .update(entry): return entry.identity
        case let .remove(identity): return identity
        }
    }
}

public enum CockpitDomainValidationError: Error, Equatable, Sendable {
    case invalidFileTreeGeneration
    case invalidFileTreeEnvelope
    case invalidFileTreeDelta
    case inconsistentWorkspaceContext
    case emptyWorkspaceRootIdentity
    case zeroActiveContextGeneration
    case invalidProtocolVersion
    case protocolVersionMismatch
    case zeroTextPosition
    case invalidHorizontalScrollOffset
    case invalidTabViewState
    case duplicateTabID
    case selectedTabNotFound
    case invalidSplitViewWidth
    case zeroInputSequence
    case emptyTerminalText
    case emptyTerminalPaste
    case terminalTextOrPasteTooLarge
    case invalidTerminalKeyIdentity
    case invalidTerminalLogicalKey
    case invalidTerminalModifiers
    case invalidTerminalMouseButtons
    case invalidTerminalMouseWheel
    case invalidTerminalResize
    case invalidSHA256DigestLength
    case invalidTerminalArchiveChunkName
    case invalidTerminalArchiveChunkRange
    case invalidTerminalExitStatus
    case invalidTerminalArchiveRange
    case invalidTerminalArchiveChunks
    case invalidTerminalArchiveCompletionDate
}

public enum WorkspaceContextID: Hashable, Codable, Sendable {
    case project(ProjectID)
    case conversation(ConversationID)

    private enum CodingKeys: String, CodingKey { case project, conversation }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let project = try container.decodeIfPresent(ProjectID.self, forKey: .project)
        let conversation = try container.decodeIfPresent(ConversationID.self, forKey: .conversation)
        switch (project, conversation) {
        case let (.some(value), .none): self = .project(value)
        case let (.none, .some(value)): self = .conversation(value)
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Exactly one workspace context kind is required")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .project(value): try container.encode(value, forKey: .project)
        case let .conversation(value): try container.encode(value, forKey: .conversation)
        }
    }
}

public struct ResolvedWorkspaceContext: Hashable, Codable, Sendable {
    public let contextID: WorkspaceContextID
    public let projectID: ProjectID
    public let conversationID: ConversationID?
    public let environmentID: EnvironmentID
    public let workspaceRootIdentity: String

    public init(
        validating contextID: WorkspaceContextID,
        projectID: ProjectID,
        conversationID: ConversationID?,
        environmentID: EnvironmentID,
        workspaceRootIdentity: String
    ) throws {
        try Self.validate(contextID: contextID, projectID: projectID, conversationID: conversationID, workspaceRootIdentity: workspaceRootIdentity)
        self.contextID = contextID
        self.projectID = projectID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.workspaceRootIdentity = workspaceRootIdentity
    }

    private static func validate(contextID: WorkspaceContextID, projectID: ProjectID, conversationID: ConversationID?, workspaceRootIdentity: String) throws {
        guard !workspaceRootIdentity.isEmpty else { throw CockpitDomainValidationError.emptyWorkspaceRootIdentity }
        switch contextID {
        case let .project(contextProject):
            guard contextProject == projectID, conversationID == nil else { throw CockpitDomainValidationError.inconsistentWorkspaceContext }
        case let .conversation(contextConversation):
            guard conversationID == contextConversation else { throw CockpitDomainValidationError.inconsistentWorkspaceContext }
        }
    }

    private enum CodingKeys: String, CodingKey { case contextID, projectID, conversationID, environmentID, workspaceRootIdentity }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validating: container.decode(WorkspaceContextID.self, forKey: .contextID),
            projectID: container.decode(ProjectID.self, forKey: .projectID),
            conversationID: container.decodeIfPresent(ConversationID.self, forKey: .conversationID),
            environmentID: container.decode(EnvironmentID.self, forKey: .environmentID),
            workspaceRootIdentity: container.decode(String.self, forKey: .workspaceRootIdentity)
        )
    }

    public func encode(to encoder: Encoder) throws {
        let valid = try Self(validating: contextID, projectID: projectID, conversationID: conversationID, environmentID: environmentID, workspaceRootIdentity: workspaceRootIdentity)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.contextID, forKey: .contextID)
        try container.encode(valid.projectID, forKey: .projectID)
        try container.encodeIfPresent(valid.conversationID, forKey: .conversationID)
        try container.encode(valid.environmentID, forKey: .environmentID)
        try container.encode(valid.workspaceRootIdentity, forKey: .workspaceRootIdentity)
    }
}

public struct ActiveContext: Hashable, Codable, Sendable {
    public let contextID: WorkspaceContextID
    public let projectID: ProjectID
    public let conversationID: ConversationID?
    public let environmentID: EnvironmentID
    public let workspaceRootIdentity: String
    public let generation: UInt64

    public init(
        validating contextID: WorkspaceContextID,
        projectID: ProjectID,
        conversationID: ConversationID?,
        environmentID: EnvironmentID,
        workspaceRootIdentity: String,
        generation: UInt64
    ) throws {
        _ = try ResolvedWorkspaceContext(validating: contextID, projectID: projectID, conversationID: conversationID, environmentID: environmentID, workspaceRootIdentity: workspaceRootIdentity)
        guard generation > 0 else { throw CockpitDomainValidationError.zeroActiveContextGeneration }
        self.contextID = contextID
        self.projectID = projectID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.workspaceRootIdentity = workspaceRootIdentity
        self.generation = generation
    }

    private enum CodingKeys: String, CodingKey { case contextID, projectID, conversationID, environmentID, workspaceRootIdentity, generation }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validating: container.decode(WorkspaceContextID.self, forKey: .contextID),
            projectID: container.decode(ProjectID.self, forKey: .projectID),
            conversationID: container.decodeIfPresent(ConversationID.self, forKey: .conversationID),
            environmentID: container.decode(EnvironmentID.self, forKey: .environmentID),
            workspaceRootIdentity: container.decode(String.self, forKey: .workspaceRootIdentity),
            generation: container.decode(UInt64.self, forKey: .generation)
        )
    }

    public func encode(to encoder: Encoder) throws {
        let valid = try Self(validating: contextID, projectID: projectID, conversationID: conversationID, environmentID: environmentID, workspaceRootIdentity: workspaceRootIdentity, generation: generation)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.contextID, forKey: .contextID)
        try container.encode(valid.projectID, forKey: .projectID)
        try container.encodeIfPresent(valid.conversationID, forKey: .conversationID)
        try container.encode(valid.environmentID, forKey: .environmentID)
        try container.encode(valid.workspaceRootIdentity, forKey: .workspaceRootIdentity)
        try container.encode(valid.generation, forKey: .generation)
    }
}

public struct RequestContext: Hashable, Codable, Sendable {
    public let protocolVersion: ProtocolVersion
    public let clientInstanceID: ClientInstanceID
    public let windowID: WindowID
    public let workspaceContextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let activeContextGeneration: UInt64
    public let requestID: RequestID

    public init(
        validating protocolVersion: ProtocolVersion,
        clientInstanceID: ClientInstanceID,
        windowID: WindowID,
        workspaceContextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        activeContextGeneration: UInt64,
        requestID: RequestID
    ) throws {
        guard protocolVersion.major > 0 else { throw CockpitDomainValidationError.invalidProtocolVersion }
        guard activeContextGeneration > 0 else { throw CockpitDomainValidationError.zeroActiveContextGeneration }
        self.protocolVersion = protocolVersion
        self.clientInstanceID = clientInstanceID
        self.windowID = windowID
        self.workspaceContextID = workspaceContextID
        self.environmentID = environmentID
        self.activeContextGeneration = activeContextGeneration
        self.requestID = requestID
    }

    public func validated(negotiatedVersion: ProtocolVersion) throws -> Self {
        guard protocolVersion == negotiatedVersion else { throw CockpitDomainValidationError.protocolVersionMismatch }
        return try Self(validating: protocolVersion, clientInstanceID: clientInstanceID, windowID: windowID, workspaceContextID: workspaceContextID, environmentID: environmentID, activeContextGeneration: activeContextGeneration, requestID: requestID)
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, clientInstanceID, windowID, workspaceContextID, environmentID, activeContextGeneration, requestID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validating: container.decode(ProtocolVersion.self, forKey: .protocolVersion),
            clientInstanceID: container.decode(ClientInstanceID.self, forKey: .clientInstanceID),
            windowID: container.decode(WindowID.self, forKey: .windowID),
            workspaceContextID: container.decode(WorkspaceContextID.self, forKey: .workspaceContextID),
            environmentID: container.decode(EnvironmentID.self, forKey: .environmentID),
            activeContextGeneration: container.decode(UInt64.self, forKey: .activeContextGeneration),
            requestID: container.decode(RequestID.self, forKey: .requestID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        let valid = try Self(validating: protocolVersion, clientInstanceID: clientInstanceID, windowID: windowID, workspaceContextID: workspaceContextID, environmentID: environmentID, activeContextGeneration: activeContextGeneration, requestID: requestID)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.protocolVersion, forKey: .protocolVersion)
        try container.encode(valid.clientInstanceID, forKey: .clientInstanceID)
        try container.encode(valid.windowID, forKey: .windowID)
        try container.encode(valid.workspaceContextID, forKey: .workspaceContextID)
        try container.encode(valid.environmentID, forKey: .environmentID)
        try container.encode(valid.activeContextGeneration, forKey: .activeContextGeneration)
        try container.encode(valid.requestID, forKey: .requestID)
    }
}

public struct ClientWorkspaceStateKey: Hashable, Codable, Sendable {
    public let deviceID: DeviceID
    public let windowID: WindowID
    public let workspaceContextID: WorkspaceContextID

    public init(
        deviceID: DeviceID,
        windowID: WindowID,
        workspaceContextID: WorkspaceContextID
    ) {
        self.deviceID = deviceID
        self.windowID = windowID
        self.workspaceContextID = workspaceContextID
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID, windowID, workspaceContextID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            deviceID: try container.decode(DeviceID.self, forKey: .deviceID),
            windowID: try container.decode(WindowID.self, forKey: .windowID),
            workspaceContextID: try container.decode(WorkspaceContextID.self, forKey: .workspaceContextID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        let valid = Self(
            deviceID: deviceID,
            windowID: windowID,
            workspaceContextID: workspaceContextID
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.deviceID, forKey: .deviceID)
        try container.encode(valid.windowID, forKey: .windowID)
        try container.encode(valid.workspaceContextID, forKey: .workspaceContextID)
    }
}

public struct SidebarState: Hashable, Codable, Sendable {
    public var isCollapsed: Bool

    public init(isCollapsed: Bool) {
        self.isCollapsed = isCollapsed
    }

    private enum CodingKeys: String, CodingKey { case isCollapsed }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(isCollapsed: try container.decode(Bool.self, forKey: .isCollapsed))
    }

    public func encode(to encoder: Encoder) throws {
        let valid = Self(isCollapsed: isCollapsed)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.isCollapsed, forKey: .isCollapsed)
    }
}

public struct SplitViewState: Hashable, Codable, Sendable {
    public var leadingPaneWidth: Double
    public var trailingPaneWidth: Double

    public init(
        validatingLeadingPaneWidth leadingPaneWidth: Double,
        trailingPaneWidth: Double
    ) throws {
        guard leadingPaneWidth.isFinite,
              leadingPaneWidth >= 0,
              trailingPaneWidth.isFinite,
              trailingPaneWidth >= 0
        else {
            throw CockpitDomainValidationError.invalidSplitViewWidth
        }
        self.leadingPaneWidth = leadingPaneWidth
        self.trailingPaneWidth = trailingPaneWidth
    }

    public func validated() throws -> Self {
        try Self(
            validatingLeadingPaneWidth: leadingPaneWidth,
            trailingPaneWidth: trailingPaneWidth
        )
    }

    private enum CodingKeys: String, CodingKey {
        case leadingPaneWidth, trailingPaneWidth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validatingLeadingPaneWidth: container.decode(Double.self, forKey: .leadingPaneWidth),
            trailingPaneWidth: container.decode(Double.self, forKey: .trailingPaneWidth)
        )
    }

    public func encode(to encoder: Encoder) throws {
        let valid = try validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.leadingPaneWidth, forKey: .leadingPaneWidth)
        try container.encode(valid.trailingPaneWidth, forKey: .trailingPaneWidth)
    }
}

public struct ClientWorkspaceState: Hashable, Codable, Sendable {
    public let key: ClientWorkspaceStateKey
    public var tabs: [TabRecord]
    public var selectedTabID: TabID?
    public var sidebar: SidebarState
    public var splitView: SplitViewState

    public init(
        validatingKey key: ClientWorkspaceStateKey,
        tabs: [TabRecord],
        selectedTabID: TabID?,
        sidebar: SidebarState,
        splitView: SplitViewState
    ) throws {
        let validTabs = try tabs.map { try $0.validated() }
        let tabIDs = Set(validTabs.map(\.id))
        guard tabIDs.count == validTabs.count else {
            throw CockpitDomainValidationError.duplicateTabID
        }
        if let selectedTabID, !tabIDs.contains(selectedTabID) {
            throw CockpitDomainValidationError.selectedTabNotFound
        }
        self.key = key
        self.tabs = validTabs
        self.selectedTabID = selectedTabID
        self.sidebar = SidebarState(isCollapsed: sidebar.isCollapsed)
        self.splitView = try splitView.validated()
    }

    public func validated() throws -> Self {
        try Self(
            validatingKey: key,
            tabs: tabs,
            selectedTabID: selectedTabID,
            sidebar: sidebar,
            splitView: splitView
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key, tabs, selectedTabID, sidebar, splitView
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validatingKey: container.decode(ClientWorkspaceStateKey.self, forKey: .key),
            tabs: container.decode([TabRecord].self, forKey: .tabs),
            selectedTabID: container.decodeIfPresent(TabID.self, forKey: .selectedTabID),
            sidebar: container.decode(SidebarState.self, forKey: .sidebar),
            splitView: container.decode(SplitViewState.self, forKey: .splitView)
        )
    }

    public func encode(to encoder: Encoder) throws {
        let valid = try validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valid.key, forKey: .key)
        try container.encode(valid.tabs, forKey: .tabs)
        try container.encodeIfPresent(valid.selectedTabID, forKey: .selectedTabID)
        try container.encode(valid.sidebar, forKey: .sidebar)
        try container.encode(valid.splitView, forKey: .splitView)
    }
}

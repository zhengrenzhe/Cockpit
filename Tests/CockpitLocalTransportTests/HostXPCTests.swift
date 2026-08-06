import Foundation
import Testing
import CockpitTypes
import CockpitProtocol
import CockpitHostCore
@testable import CockpitLocalTransport

@Test func workspaceCommandUsesExplicitTagAndRejectsForbiddenFields() throws {
    let encoded = try JSONEncoder().encode(WorkspaceCommandRequest.listWorkspace)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object.keys.sorted() == ["command"])
    #expect(object["command"] as? String == "listWorkspace")

    let invalid = Data(
        #"{"command":"listWorkspace","projectID":"00000000-0000-0000-0000-000000000001"}"#.utf8
    )
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(WorkspaceCommandRequest.self, from: invalid)
    }
}

@Test func workspaceRequestRejectsUnknownField() {
    let invalid = Data(#"{"command":"listWorkspace","unknown":1}"#.utf8)

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(WorkspaceCommandRequest.self, from: invalid)
    }
}

@Test func workspaceResponseRejectsUnknownTopLevelField() throws {
    let encoded = try JSONEncoder().encode(WorkspaceCommandResponse.empty)
    let invalid = try mutatingJSONObject(encoded) { object in
        object["unknown"] = 1
    }

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(WorkspaceCommandResponse.self, from: invalid)
    }
}

@Test func workspaceResponseRejectsUnknownNestedWireFields() throws {
    let fixture = try WorkspaceFixture()
    let projectData = try JSONEncoder().encode(
        WorkspaceCommandResponse.projectSnapshot(fixture.snapshot)
    )
    let projectUnknown = try mutatingJSONObject(projectData) { object in
        var project = object["projectSnapshot"] as! [String: Any]
        project["unknown"] = 1
        object["projectSnapshot"] = project
    }
    let conversationUnknown = try mutatingJSONObject(projectData) { object in
        var project = object["projectSnapshot"] as! [String: Any]
        var conversations = project["conversations"] as! [[String: Any]]
        conversations[0]["unknown"] = 1
        project["conversations"] = conversations
        object["projectSnapshot"] = project
    }
    let contextUnknown = try mutatingJSONObject(projectData) { object in
        var project = object["projectSnapshot"] as! [String: Any]
        var context = project["resolvedContext"] as! [String: Any]
        context["unknown"] = 1
        project["resolvedContext"] = context
        object["projectSnapshot"] = project
    }
    let contextIDUnknown = try mutatingJSONObject(projectData) { object in
        var project = object["projectSnapshot"] as! [String: Any]
        var context = project["resolvedContext"] as! [String: Any]
        var contextID = context["contextID"] as! [String: Any]
        contextID["unknown"] = 1
        context["contextID"] = contextID
        project["resolvedContext"] = context
        object["projectSnapshot"] = project
    }

    for invalid in [projectUnknown, conversationUnknown, contextUnknown, contextIDUnknown] {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WorkspaceCommandResponse.self, from: invalid)
        }
    }
}

@Test func routerRoundTripsWorkspaceCommandsWithoutAbsolutePathOnTheWire() async throws {
    let fixture = try WorkspaceFixture()
    let service = RecordingWorkspaceService(fixture: fixture)
    let router = WorkspaceCommandRouter(service: service)

    let listResponse = try await route(.listWorkspace, through: router)
    #expect(listResponse == .workspaceSnapshot([fixture.snapshot]))
    let listData = try JSONEncoder().encode(listResponse)
    #expect(!String(decoding: listData, as: UTF8.self).contains("/private/tmp/Cockpit"))

    #expect(
        try await route(
            .addProject(bookmark: Data([0x01]), displayName: "Cockpit"),
            through: router
        ) == .projectSnapshot(fixture.snapshot)
    )
    #expect(
        try await route(
            .createDirectConversation(projectID: fixture.projectID),
            through: router
        ) == .conversation(fixture.conversation)
    )
    #expect(
        try await route(
            .renameConversation(id: fixture.conversation.id, title: "Renamed"),
            through: router
        ) == .empty
    )
    #expect(
        try await route(
            .resolveContext(.conversation(fixture.conversation.id)),
            through: router
        ) == .resolvedContext(fixture.conversationContext)
    )
    #expect(await service.recordedCommands == ["list", "add", "create", "rename:Renamed", "resolve"])
}

@Test func hostExportRoutesAsynchronouslyRepliesOnceAndPreservesNSError() async throws {
    let expected = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
    let service = ThrowingWorkspaceService(error: expected)
    let exported = HostXPCExport(
        handshakeHandler: { try HostHandshakeHandler().handle($0) },
        workspaceRouter: WorkspaceCommandRouter(service: service)
    )
    let request = try JSONEncoder().encode(WorkspaceCommandRequest.listWorkspace)
    let replies = ReplyCounter()

    await withCheckedContinuation { continuation in
        exported.workspaceCommand(request) { data, error in
            replies.record(data: data, error: error)
            continuation.resume()
        }
    }
    for _ in 0..<10 { await Task.yield() }

    #expect(replies.count == 1)
    #expect(replies.data == nil)
    #expect(replies.error?.domain == NSCocoaErrorDomain)
    #expect(replies.error?.code == NSFileReadNoSuchFileError)
}

@Test func hostProtocolListenerRejectsWrongUIDBeforeConfigurationExportOrResume() {
    let exported = NSObject()
    let delegate = MachServiceListenerDelegate(
        exportedObject: exported,
        exportedInterface: NSXPCInterface(with: HostXPCProtocol.self),
        peerValidator: XPCPeerValidator(expectedEffectiveUserIdentifier: 501)
    )
    let connection = FakeHostIncomingConnection(effectiveUserIdentifier: 502)

    #expect(!delegate.shouldAccept(connection))
    #expect(connection.exportedInterface == nil)
    #expect(connection.exportedObject == nil)
    #expect(connection.resumeCount == 0)
}

@Test func hostClientProvidesTypedWorkspaceServingRoundTrip() async throws {
    let fixture = try WorkspaceFixture()
    let service = RecordingWorkspaceService(fixture: fixture)
    let exported = HostXPCExport(
        handshakeHandler: { try HostHandshakeHandler().handle($0) },
        workspaceRouter: WorkspaceCommandRouter(service: service)
    )
    let connection = FakeHostClientConnection(proxy: exported)
    let client = HostXPCClient(connectionFactory: { _ in connection })

    #expect(try await client.listWorkspace() == [fixture.snapshot])
    #expect(connection.resumeCount == 1)
    await client.disconnect()
}

@Test func cockpitHostParksWithoutCheckedContinuationMisuse() async throws {
    let diagnostics = Pipe()
    let process = Process()
    process.executableURL = try cockpitHostExecutableURL()
    process.standardOutput = diagnostics
    process.standardError = diagnostics
    try process.run()

    try await Task.sleep(for: .milliseconds(250))
    let stayedRunning = process.isRunning
    if stayedRunning {
        process.terminate()
    }
    process.waitUntilExit()
    let output = String(
        decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )

    if !stayedRunning {
        Issue.record(
            "CockpitHost exited before parking: executable=\(process.executableURL?.path ?? "nil"), reason=\(String(describing: process.terminationReason)), status=\(process.terminationStatus), output=\(output)"
        )
    }
    #expect(!output.contains("SWIFT TASK CONTINUATION MISUSE"))
}

private func route(
    _ request: WorkspaceCommandRequest,
    through router: WorkspaceCommandRouter
) async throws -> WorkspaceCommandResponse {
    let response = try await router.route(JSONEncoder().encode(request))
    return try JSONDecoder().decode(WorkspaceCommandResponse.self, from: response)
}

private func mutatingJSONObject(
    _ data: Data,
    mutation: (inout [String: Any]) -> Void
) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    mutation(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func cockpitHostExecutableURL() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let build = repository.appendingPathComponent(".build", isDirectory: true)
    let enumerator = FileManager.default.enumerator(
        at: build,
        includingPropertiesForKeys: [.isExecutableKey],
        options: [.skipsHiddenFiles]
    )
    while let candidate = enumerator?.nextObject() as? URL {
        if candidate.lastPathComponent == "CockpitHost",
           candidate.path.contains("/debug/"),
           FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    throw CocoaError(.fileNoSuchFile)
}

private struct WorkspaceFixture: Sendable {
    let projectID: ProjectID
    let conversation: Conversation
    let projectContext: ResolvedWorkspaceContext
    let conversationContext: ResolvedWorkspaceContext
    let snapshot: ProjectSnapshot

    init() throws {
        projectID = ProjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        let environmentID = EnvironmentID(UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)
        let conversationID = ConversationID(UUID(uuidString: "00000000-0000-0000-0000-000000000103")!)
        conversation = Conversation(
            id: conversationID,
            projectID: projectID,
            environmentID: environmentID,
            title: "新任务",
            lifecycleState: .active,
            deletionOperationID: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        projectContext = try ResolvedWorkspaceContext(
            validating: .project(projectID),
            projectID: projectID,
            conversationID: nil,
            environmentID: environmentID,
            workspaceRootIdentity: "volume:test/file:cockpit"
        )
        conversationContext = try ResolvedWorkspaceContext(
            validating: .conversation(conversationID),
            projectID: projectID,
            conversationID: conversationID,
            environmentID: environmentID,
            workspaceRootIdentity: "volume:test/file:cockpit"
        )
        snapshot = ProjectSnapshot(
            projectID: projectID,
            displayName: "Cockpit",
            resolvedContext: projectContext,
            conversations: [conversation]
        )
    }
}

private actor RecordingWorkspaceService: WorkspaceServing {
    let fixture: WorkspaceFixture
    private(set) var recordedCommands: [String] = []

    init(fixture: WorkspaceFixture) { self.fixture = fixture }

    func addProject(bookmark: Data, displayName: String) -> ProjectSnapshot {
        recordedCommands.append("add")
        return fixture.snapshot
    }

    func listWorkspace() -> WorkspaceSnapshot {
        recordedCommands.append("list")
        return [fixture.snapshot]
    }

    func createDirectConversation(projectID: ProjectID) -> Conversation {
        recordedCommands.append("create")
        return fixture.conversation
    }

    func renameConversation(id: ConversationID, title: String) {
        recordedCommands.append("rename:\(title)")
    }

    func resolveContext(_ id: WorkspaceContextID) -> ResolvedWorkspaceContext {
        recordedCommands.append("resolve")
        return fixture.conversationContext
    }
}

private actor ThrowingWorkspaceService: WorkspaceServing {
    let error: NSError

    init(error: NSError) { self.error = error }

    func addProject(bookmark: Data, displayName: String) throws -> ProjectSnapshot { throw error }
    func listWorkspace() throws -> WorkspaceSnapshot { throw error }
    func createDirectConversation(projectID: ProjectID) throws -> Conversation { throw error }
    func renameConversation(id: ConversationID, title: String) throws { throw error }
    func resolveContext(_ id: WorkspaceContextID) throws -> ResolvedWorkspaceContext { throw error }
}

private final class ReplyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Data?, NSError?)] = []

    func record(data: Data?, error: NSError?) {
        lock.withLock { replies.append((data, error)) }
    }

    var count: Int { lock.withLock { replies.count } }
    var data: Data? { lock.withLock { replies.first?.0 } }
    var error: NSError? { lock.withLock { replies.first?.1 } }
}

private final class FakeHostIncomingConnection: IncomingXPCConnectionBoundary {
    let effectiveUserIdentifier: uid_t
    var exportedInterface: NSXPCInterface?
    var exportedObject: Any?
    private(set) var resumeCount = 0

    init(effectiveUserIdentifier: uid_t) {
        self.effectiveUserIdentifier = effectiveUserIdentifier
    }

    func resume() { resumeCount += 1 }
}

private final class FakeHostClientConnection: XPCConnectionBoundary, @unchecked Sendable {
    let proxy: Any
    private(set) var resumeCount = 0

    init(proxy: Any) { self.proxy = proxy }

    func configureRemoteObjectInterface(_ interface: NSXPCInterface) {}
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {}
    func resume() { resumeCount += 1 }
    func invalidate() {}
    func remoteObjectProxy(errorHandler: @escaping @Sendable (any Error) -> Void) -> Any { proxy }
}

import Darwin
import Foundation
import Testing
import CockpitTypes
import CockpitProtocol
import CockpitHostCore
import CockpitTerminalCore
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

@Test func fileOperationWireTagsRoundTripCompleteContextAndRejectUnknownForbiddenAndInvalidPaths() throws {
    let fixture = try WorkspaceFixture()
    let context = try fixture.requestContext()
    let request = try WorkspaceCommandRequest.performFileOperation(
        context: context,
        operation: .createFile(parent: .relative(RelativePath("nested")), name: "file.txt")
    )
    let encoded = try JSONEncoder().encode(request)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(object.keys.sorted() == ["command", "context", "fileOperation"])
    #expect(object["command"] as? String == "performFileOperation")
    #expect(try JSONDecoder().decode(WorkspaceCommandRequest.self, from: encoded) == request)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("/private/tmp"))

    let unknownOperation = try mutatingJSONObject(encoded) { object in
        var operation = object["fileOperation"] as! [String: Any]
        operation["unknown"] = true
        object["fileOperation"] = operation
    }
    let forbiddenOperation = try mutatingJSONObject(encoded) { object in
        var operation = object["fileOperation"] as! [String: Any]
        operation["source"] = "forbidden"
        object["fileOperation"] = operation
    }
    let unknownDirectory = try mutatingJSONObject(encoded) { object in
        var operation = object["fileOperation"] as! [String: Any]
        var parent = operation["parent"] as! [String: Any]
        parent["unknown"] = true
        operation["parent"] = parent
        object["fileOperation"] = operation
    }
    let unknownContext = try mutatingJSONObject(encoded) { object in
        var context = object["context"] as! [String: Any]
        context["unknown"] = true
        object["context"] = context
    }
    var unknownNestedIDs: [Data] = []
    for key in ["clientInstanceID", "windowID", "environmentID", "requestID"] {
        unknownNestedIDs.append(try mutatingJSONObject(encoded) { object in
            var context = object["context"] as! [String: Any]
            var identifier = context[key] as! [String: Any]
            identifier["unknown"] = true
            context[key] = identifier
            object["context"] = context
        })
    }
    let unknownProjectID = try mutatingJSONObject(encoded) { object in
        var context = object["context"] as! [String: Any]
        var contextID = context["workspaceContextID"] as! [String: Any]
        var projectID = contextID["project"] as! [String: Any]
        projectID["unknown"] = true
        contextID["project"] = projectID
        context["workspaceContextID"] = contextID
        object["context"] = context
    }
    let conversationContext = try RequestContext(
        validating: context.protocolVersion,
        clientInstanceID: context.clientInstanceID,
        windowID: context.windowID,
        workspaceContextID: .conversation(fixture.conversation.id),
        environmentID: context.environmentID,
        activeContextGeneration: context.activeContextGeneration,
        requestID: context.requestID
    )
    let conversationRequest = try JSONEncoder().encode(
        WorkspaceCommandRequest.performFileOperation(
            context: conversationContext,
            operation: .createFile(parent: .root, name: "file.txt")
        )
    )
    let unknownConversationID = try mutatingJSONObject(conversationRequest) { object in
        var context = object["context"] as! [String: Any]
        var contextID = context["workspaceContextID"] as! [String: Any]
        var conversationID = contextID["conversation"] as! [String: Any]
        conversationID["unknown"] = true
        contextID["conversation"] = conversationID
        context["workspaceContextID"] = contextID
        object["context"] = context
    }
    let traversal = try JSONEncoder().encode(
        WorkspaceCommandRequest.performFileOperation(
            context: context,
            operation: .rename(source: RelativePath("safe"), newName: "new")
        )
    )
    let invalidTraversal = try mutatingJSONObject(traversal) { object in
        var operation = object["fileOperation"] as! [String: Any]
        operation["source"] = "../escape"
        object["fileOperation"] = operation
    }
    for invalid in [
        unknownOperation, forbiddenOperation, unknownDirectory, unknownContext,
        unknownProjectID, unknownConversationID, invalidTraversal,
    ] + unknownNestedIDs {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(WorkspaceCommandRequest.self, from: invalid)
        }
    }

    let result = try WorkspaceCommandResponse.fileOperationResult(
        .relocated(from: RelativePath("nested/file.txt"), to: RelativePath("moved/file.txt"))
    )
    let resultData = try JSONEncoder().encode(result)
    #expect(try JSONDecoder().decode(WorkspaceCommandResponse.self, from: resultData) == result)
    #expect(!String(decoding: resultData, as: UTF8.self).contains("/private/tmp"))
    let unknownResult = try mutatingJSONObject(resultData) { object in
        var value = object["fileOperationResult"] as! [String: Any]
        value["unknown"] = true
        object["fileOperationResult"] = value
    }
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(WorkspaceCommandResponse.self, from: unknownResult)
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
    #expect(
        try await route(
            .performFileOperation(
                context: fixture.requestContext(),
                operation: .createFile(parent: .root, name: "created.txt")
            ),
            through: router
        ) == .fileOperationResult(.created(path: RelativePath("created.txt"), kind: .file))
    )
    #expect(await service.recordedCommands == ["list", "add", "create", "rename:Renamed", "resolve", "file"])
}

@Test func hostExportRoutesAsynchronouslyRepliesOnceAndSanitizesNSError() async throws {
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
    #expect(replies.error?.domain == "dev.cockpit.host-workspace")
    #expect(replies.error?.code == 1)
    #expect(replies.error?.userInfo.isEmpty == true)
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
    #expect(
        try await client.performFileOperation(
            context: fixture.requestContext(),
            operation: .createDirectory(parent: .root, name: "created")
        ) == .created(path: RelativePath("created"), kind: .directory)
    )
    #expect(connection.resumeCount == 1)
    await client.disconnect()
}

@Test func hostClientRoundTripsConversationDeletionThroughWorkspaceRouter() async throws {
    let fixture = try WorkspaceFixture()
    let operationID = DeletionOperationID()
    let activeSessionID = TerminalSessionID()
    let dirtyDocument = try DocumentSnapshot(
        validatingDocumentID: DocumentID(),
        environmentID: fixture.environmentID,
        relativePath: RelativePath("dirty.txt"),
        text: "dirty",
        documentVersion: 2,
        persistedVersion: 1,
        lastAcceptedClientSequence: 1,
        dirtyState: .dirty,
        observedDiskFingerprint: nil,
        currentLease: nil,
        maintenance: []
    )
    let preparationID = UUID(uuidString: "74000000-0000-4000-8000-000000000099")!
    let expectedImpact = ConversationDeletionImpact(
        conversationID: fixture.conversation.id,
        projectID: fixture.projectID,
        environmentID: fixture.environmentID,
        dirtyDocuments: [dirtyDocument],
        preparationID: preparationID
    )
    let deletion = RecordingConversationDeletionService(
        impact: expectedImpact,
        progress: [
            .forceConfirmationRequired(
                operationID: operationID,
                activeSessionIDs: [activeSessionID]
            ),
            .deleted(projectContextID: .project(fixture.projectID)),
        ]
    )
    let exported = HostXPCExport(
        handshakeHandler: { try HostHandshakeHandler().handle($0) },
        workspaceRouter: WorkspaceCommandRouter(
            service: RecordingWorkspaceService(fixture: fixture),
            deletionService: deletion
        )
    )
    let connection = FakeHostClientConnection(proxy: exported)
    let client = HostXPCClient(connectionFactory: { _ in connection })

    #expect(try await client.deletionImpact(
        conversationID: fixture.conversation.id
    ) == expectedImpact)
    #expect(
        try await client.beginConversationDeletion(
            conversationID: fixture.conversation.id,
            operationID: operationID,
            preparationID: preparationID
        ) == .forceConfirmationRequired(
            operationID: operationID,
            activeSessionIDs: [activeSessionID]
        )
    )
    #expect(
        try await client.resumeConversationDeletion(
            operationID: operationID,
            force: true
        ) == .deleted(projectContextID: .project(fixture.projectID))
    )
    #expect(await deletion.calls == [
        .impact(fixture.conversation.id),
        .begin(fixture.conversation.id, operationID),
        .resume(operationID, true),
    ])
    await client.disconnect()
}

@Test func hostClientRoundTripsDurableClientWorkspaceStateThroughWorkspaceCommand() async throws {
    let fixture = try WorkspaceFixture()
    let workspace = RecordingWorkspaceService(fixture: fixture)
    let clientStates = RecordingClientWorkspaceStateService()
    let exported = HostXPCExport(
        handshakeHandler: { try HostHandshakeHandler().handle($0) },
        workspaceRouter: WorkspaceCommandRouter(
            service: workspace,
            clientStateService: clientStates
        )
    )
    let connection = FakeHostClientConnection(proxy: exported)
    let client = HostXPCClient(connectionFactory: { _ in connection })
    let key = ClientWorkspaceStateKey(
        deviceID: DeviceID(UUID(uuidString: "00000000-0000-0000-0000-000000000911")!),
        windowID: WindowID(UUID(uuidString: "00000000-0000-0000-0000-000000000912")!),
        workspaceContextID: .project(fixture.projectID)
    )
    let tab = try TabRecord(
        validatingID: TabID(UUID(uuidString: "00000000-0000-0000-0000-000000000913")!),
        resource: .terminal(TerminalSessionID(UUID(uuidString: "00000000-0000-0000-0000-000000000914")!)),
        terminalKind: .codex,
        fileViewState: nil
    )
    let state = try ClientWorkspaceState(
        validatingKey: key,
        tabs: [tab],
        selectedTabID: tab.id,
        sidebar: SidebarState(isCollapsed: false),
        splitView: SplitViewState(
            validatingLeadingPaneWidth: 240,
            trailingPaneWidth: 300
        )
    )

    #expect(try await client.loadClientState(key) == nil)
    try await client.saveClientState(state)
    #expect(try await client.loadClientState(key) == state)
    await client.disconnect()
}

@Test func hostWorkspaceXPCSanitizesPOSIXAndCocoaPaths() async throws {
    let fixture = try WorkspaceFixture()
    let errors = [
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EEXIST),
            userInfo: [NSFilePathErrorKey: "/private/tmp/root/existing"]
        ),
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSURLErrorKey: URL(fileURLWithPath: "/private/tmp/root/denied")]
        ),
    ]

    for injected in errors {
        let service = ThrowingWorkspaceService(error: injected)
        let exported = HostXPCExport(
            handshakeHandler: { try HostHandshakeHandler().handle($0) },
            workspaceRouter: WorkspaceCommandRouter(service: service)
        )
        let connection = FakeHostClientConnection(proxy: exported)
        let client = HostXPCClient(connectionFactory: { _ in connection })
        do {
            _ = try await client.performFileOperation(
                context: fixture.requestContext(),
                operation: .createFile(parent: .root, name: "failure")
            )
            Issue.record("Expected file operation to fail")
        } catch {
            let actual = error as NSError
            #expect(actual.domain == "dev.cockpit.host-workspace")
            #expect(actual.code == 1)
            #expect(actual.userInfo.isEmpty)
            #expect(!actual.description.contains("/private/tmp/root"))
        }
    }
}

@Test func cockpitHostParksWithoutCheckedContinuationMisuse() async throws {
    let executableURL = try cockpitHostExecutableURL()
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    let diagnostics = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
        close(descriptors[0])
        close(descriptors[1])
        throw CocoaError(.executableRuntimeMismatch)
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO) == 0,
          posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
          posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0 else {
        close(descriptors[1])
        throw CocoaError(.executableRuntimeMismatch)
    }
    var processID: pid_t = 0
    let spawnStatus = executableURL.path.withCString { executable in
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
        defer { free(arguments[0]) }
        return arguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &processID,
                executable,
                &actions,
                nil,
                buffer.baseAddress,
                environ
            )
        }
    }
    close(descriptors[1])
    guard spawnStatus == 0 else {
        throw POSIXError(.init(rawValue: spawnStatus) ?? .EIO)
    }
    var reaped = false
    defer {
        if !reaped {
            if kill(processID, 0) == 0 || errno == EPERM {
                _ = kill(processID, SIGKILL)
            }
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0, errno == EINTR {}
        }
    }

    try await Task.sleep(for: .milliseconds(250))
    let stayedRunning = kill(processID, 0) == 0 || errno == EPERM
    if stayedRunning {
        #expect(kill(processID, SIGTERM) == 0)
    }
    let waitStatus = try await waitForOwnedHostProcessExit(processID, timeout: 5)
    reaped = true
    let output = String(
        decoding: diagnostics.readDataToEndOfFile(),
        as: UTF8.self
    )

    if !stayedRunning {
        Issue.record(
            "CockpitHost exited before parking: executable=\(executableURL.path), waitStatus=\(waitStatus), output=\(output)"
        )
    }
    #expect(waitStatus & 0x7f == 0)
    #expect((waitStatus >> 8) & 0xff == 0)
    #expect(!output.contains("SWIFT TASK CONTINUATION MISUSE"))
}

private func waitForOwnedHostProcessExit(
    _ processID: pid_t,
    timeout: TimeInterval
) async throws -> Int32 {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG)
        if result == processID { return status }
        if result < 0, errno == EINTR { continue }
        if result < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.executableRuntimeMismatch)
}

@Test func hostTerminalCreatePayloadOmitsWorkspaceRootAndHostAddsResolvedRoot() async throws {
    let projectID = ProjectID()
    let contextID = WorkspaceContextID.project(projectID)
    let environmentID = EnvironmentID()
    let intent = TerminalCreateRequest(
        contextID: contextID,
        environmentID: environmentID,
        kind: .shell,
        arguments: [],
        terminalSize: try TerminalResize(validatingColumns: 100, rows: 30),
        environmentOverrides: ["TERM": "xterm-256color"],
        idempotencyKey: RequestID()
    )
    let wire = try JSONEncoder().encode(HostTerminalCommandRequest.create(intent))
    let wireText = String(decoding: wire, as: UTF8.self)
    #expect(!wireText.contains("workspaceRoot"))
    #expect(!wireText.contains("/private/tmp/Cockpit"))

    let supervisor = RecordingTerminalSupervisorControl()
    let service = WorkspaceTerminalService(
        resolveContext: { requested in
            #expect(requested == contextID)
            return try ResolvedWorkspaceContext(
                validating: contextID,
                projectID: projectID,
                conversationID: nil,
                environmentID: environmentID,
                workspaceRootIdentity: "root-id"
            )
        },
        resolveWorkspaceRoot: { _ in "/private/tmp/Cockpit" },
        supervisor: supervisor
    )

    _ = try await service.perform(.create(intent))
    #expect(await supervisor.created?.workspaceRoot == "/private/tmp/Cockpit")
}

@Test func hostTerminalAgentSelectionUsesBookmarkOnClientBoundaryAndResolvedPathInternally() async throws {
    let projectID = ProjectID()
    let contextID = WorkspaceContextID.project(projectID)
    let environmentID = EnvironmentID()
    let bookmark = Data("agent-bookmark-fixture".utf8)
    let resolvedExecutable = "/private/tmp/Cockpit-Fixtures/codex"
    let intent = TerminalCreateRequest(
        contextID: contextID,
        environmentID: environmentID,
        kind: .agent(.codex),
        arguments: ["--resume", "task-17"],
        terminalSize: try TerminalResize(validatingColumns: 100, rows: 30),
        environmentOverrides: [:],
        idempotencyKey: RequestID(),
        selectedExecutableBookmark: bookmark
    )
    let wire = try JSONEncoder().encode(HostTerminalCommandRequest.create(intent))
    let wireText = String(decoding: wire, as: UTF8.self)
    #expect(wireText.contains(bookmark.base64EncodedString()))
    #expect(!wireText.contains(resolvedExecutable))

    let supervisor = RecordingTerminalSupervisorControl()
    let service = WorkspaceTerminalService(
        resolveContext: { requested in
            #expect(requested == contextID)
            return try ResolvedWorkspaceContext(
                validating: contextID,
                projectID: projectID,
                conversationID: nil,
                environmentID: environmentID,
                workspaceRootIdentity: "root-id"
            )
        },
        resolveWorkspaceRoot: { _ in "/private/tmp/Cockpit" },
        resolveAgentExecutableBookmark: { value in
            #expect(value == bookmark)
            return resolvedExecutable
        },
        supervisor: supervisor
    )

    _ = try await service.perform(.create(intent))
    #expect(await supervisor.created?.selectedExecutablePath == resolvedExecutable)
}

@Test func hostTerminalAgentSelectionRequiredReturnsTypedResponseWithoutPathErrorMetadata() async throws {
    let fixture = try WorkspaceFixture()
    let supervisor = RecordingTerminalSupervisorControl()
    await supervisor.setCreateError(
        TerminalSupervisorCreateError.agentExecutableSelectionRequired(.claude)
    )
    let service = WorkspaceTerminalService(
        resolveContext: { _ in fixture.projectContext },
        resolveWorkspaceRoot: { _ in "/private/tmp/Cockpit" },
        resolveAgentExecutableBookmark: { _ in
            Issue.record("bookmark resolver must not run without a selected bookmark")
            return "/private/tmp/unexpected"
        },
        supervisor: supervisor
    )
    let request = TerminalCreateRequest(
        contextID: fixture.projectContext.contextID,
        environmentID: fixture.environmentID,
        kind: .agent(.claude),
        arguments: [],
        terminalSize: try TerminalResize(validatingColumns: 90, rows: 28),
        environmentOverrides: [:],
        idempotencyKey: RequestID()
    )

    #expect(
        try await service.perform(.create(request))
            == .agentExecutableSelectionRequired(.claude)
    )
}

@Test func hostTerminalResponsesRedactLaunchStateEndpointPathAndArchiveBytes() async throws {
    let fixture = try WorkspaceFixture()
    let contextID = fixture.projectContext.contextID
    let environmentID = fixture.environmentID
    let sessionID = TerminalSessionID()
    let workerID = WorkerInstanceID()
    let clientID = ClientInstanceID()
    let viewerID = ViewerID(clientID.rawValue)
    let secretRoot = "/private/tmp/Cockpit-Secret-Workspace"
    let secretEndpoint = "/private/tmp/cockpit.501/terminal/secret-viewer.sock"
    let launchSpec = try LaunchSpec(
        kind: .shell,
        loginShellPath: "/bin/zsh",
        executablePath: "/bin/zsh",
        arguments: [],
        workspaceRoot: secretRoot,
        terminalSize: try TerminalResize(validatingColumns: 100, rows: 30),
        environmentOverrides: [:]
    )
    let record = try TerminalSessionRecord(
        validatingSessionID: sessionID,
        contextID: contextID,
        environmentID: environmentID,
        protocolVersion: .current,
        launchSpecData: try JSONEncoder().encode(launchSpec),
        lifecycleState: .running,
        startNonce: Data(repeating: 0xA7, count: 16),
        workerID: workerID,
        processIdentity: try CLIProcessIdentity(validatingProcessID: 771, processGroupID: 771),
        latestSequence: 9,
        archiveManifest: try RelativeArchivePath(validating: "session/final.ckgf")
    )
    let authorization = TerminalAttachAuthorization(
        endpoint: try KeeperEndpoint(
            path: secretEndpoint,
            sessionID: sessionID,
            workerID: workerID
        ),
        wireTicket: String(repeating: "A", count: 43),
        binding: TerminalAttachBinding(
            sessionID: sessionID,
            workerID: workerID,
            clientInstanceID: clientID
        ),
        viewerID: viewerID,
        capabilities: [.view]
    )
    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cockpit-host-archive-\(UUID().uuidString)")
    let archiveBytes = Data([0x43, 0x4B, 0x47, 0x46, 0x10, 0x20])
    try archiveBytes.write(to: archiveURL)
    defer { try? FileManager.default.removeItem(at: archiveURL) }

    let supervisor = RecordingTerminalSupervisorControl()
    await supervisor.setRecords([record])
    await supervisor.setAuthorization(authorization)
    await supervisor.setArchiveURL(archiveURL)
    let terminalService = WorkspaceTerminalService(
        resolveContext: { requested in
            #expect(requested == contextID)
            return fixture.projectContext
        },
        resolveWorkspaceRoot: { _ in secretRoot },
        supervisor: supervisor
    )
    let workspace = RecordingWorkspaceService(fixture: fixture)
    let exported = HostXPCExport(
        handshakeHandler: { try HostHandshakeHandler().handle($0) },
        workspaceRouter: WorkspaceCommandRouter(service: workspace),
        workspaceTerminalService: terminalService
    )
    let create = TerminalCreateRequest(
        contextID: contextID,
        environmentID: environmentID,
        kind: .shell,
        arguments: [],
        terminalSize: try TerminalResize(validatingColumns: 100, rows: 30),
        environmentOverrides: [:],
        idempotencyKey: RequestID()
    )
    let attach = TerminalAttachTicketRequest(
        sessionID: sessionID,
        clientInstanceID: clientID,
        viewerID: viewerID,
        capabilities: [.view]
    )
    let responseData = try await [
        HostTerminalCommandRequest.create(create),
        .list(contextID: contextID),
        .issueAttachTicket(
            contextID: contextID,
            environmentID: environmentID,
            request: attach
        ),
    ].asyncMap { try await terminalWireResponse($0, through: exported) }

    for data in responseData {
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("launchSpecData"))
        #expect(!text.contains("startNonce"))
        #expect(!text.contains(secretRoot))
        #expect(!text.contains(secretEndpoint))
        #expect(!text.contains("\"endpoint\""))
    }

    let archiveHandle: FileHandle = try await withCheckedThrowingContinuation { continuation in
        exported.openTerminalArchive(
            try! JSONEncoder().encode(
                HostTerminalArchiveRequest(
                    contextID: contextID,
                    environmentID: environmentID,
                    sessionID: sessionID
                )
            )
        ) { handle, error in
            if let error { continuation.resume(throwing: error) }
            else if let handle { continuation.resume(returning: handle) }
            else { continuation.resume(throwing: CocoaError(.coderInvalidValue)) }
        }
    }
    #expect(try archiveHandle.readToEnd() == archiveBytes)
    try archiveHandle.close()
}

@Test func hostTerminalServiceRejectsContextEnvironmentAndSessionMismatch() async throws {
    let projectID = ProjectID()
    let contextID = WorkspaceContextID.project(projectID)
    let environmentID = EnvironmentID()
    let otherEnvironment = EnvironmentID()
    let supervisor = RecordingTerminalSupervisorControl()
    let existing = try TerminalSessionRecord(
        validatingSessionID: TerminalSessionID(),
        contextID: contextID,
        environmentID: environmentID,
        protocolVersion: .current,
        launchSpecData: Data([1]),
        lifecycleState: .running,
        startNonce: Data(repeating: 2, count: 16),
        workerID: WorkerInstanceID(),
        processIdentity: try CLIProcessIdentity(validatingProcessID: 777, processGroupID: 777)
    )
    await supervisor.setRecords([existing])
    let service = WorkspaceTerminalService(
        resolveContext: { _ in
            try ResolvedWorkspaceContext(
                validating: contextID,
                projectID: projectID,
                conversationID: nil,
                environmentID: environmentID,
                workspaceRootIdentity: "root-id"
            )
        },
        resolveWorkspaceRoot: { _ in "/private/tmp/Cockpit" },
        supervisor: supervisor
    )

    let mismatchedCreate = TerminalCreateRequest(
        contextID: contextID,
        environmentID: otherEnvironment,
        kind: .shell,
        arguments: [],
        terminalSize: try TerminalResize(validatingColumns: 80, rows: 24),
        environmentOverrides: [:],
        idempotencyKey: RequestID()
    )
    await #expect(throws: WorkspaceTerminalServiceError.contextEnvironmentMismatch) {
        _ = try await service.perform(.create(mismatchedCreate))
    }

    let mismatchedReturnedSession = try TerminalSessionRecord(
        validatingSessionID: TerminalSessionID(),
        contextID: contextID,
        environmentID: otherEnvironment,
        protocolVersion: .current,
        launchSpecData: Data([1]),
        lifecycleState: .running,
        startNonce: Data(repeating: 4, count: 16),
        workerID: WorkerInstanceID(),
        processIdentity: try CLIProcessIdentity(validatingProcessID: 778, processGroupID: 778)
    )
    await supervisor.setRecords([mismatchedReturnedSession])
    await #expect(throws: WorkspaceTerminalServiceError.sessionBindingMismatch) {
        _ = try await service.perform(.list(contextID: contextID))
    }
    let validCreate = TerminalCreateRequest(
        contextID: contextID,
        environmentID: environmentID,
        kind: .shell,
        arguments: [],
        terminalSize: try TerminalResize(validatingColumns: 80, rows: 24),
        environmentOverrides: [:],
        idempotencyKey: RequestID()
    )
    await #expect(throws: WorkspaceTerminalServiceError.sessionBindingMismatch) {
        _ = try await service.perform(.create(validCreate))
    }

    await supervisor.setRecords([existing])
    let attach = TerminalAttachTicketRequest(
        sessionID: TerminalSessionID(),
        clientInstanceID: ClientInstanceID(),
        viewerID: ViewerID(),
        capabilities: [.view]
    )
    await #expect(throws: WorkspaceTerminalServiceError.sessionBindingMismatch) {
        _ = try await service.perform(
            .issueAttachTicket(
                contextID: contextID,
                environmentID: environmentID,
                request: attach
            )
        )
    }
}

@Test func hostTerminalServiceExactBindsResolverTicketAndLeaseResponses() async throws {
    let projectID = ProjectID()
    let contextID = WorkspaceContextID.project(projectID)
    let environmentID = EnvironmentID()
    let sessionID = TerminalSessionID()
    let workerID = WorkerInstanceID()
    let clientID = ClientInstanceID()
    let viewerID = ViewerID(clientID.rawValue)
    let record = try TerminalSessionRecord(
        validatingSessionID: sessionID,
        contextID: contextID,
        environmentID: environmentID,
        protocolVersion: .current,
        launchSpecData: Data([1]),
        lifecycleState: .running,
        startNonce: Data(repeating: 7, count: 16),
        workerID: workerID,
        processIdentity: try CLIProcessIdentity(validatingProcessID: 881, processGroupID: 881)
    )
    let supervisor = RecordingTerminalSupervisorControl()
    await supervisor.setRecords([record])
    let service = WorkspaceTerminalService(
        resolveContext: { _ in
            try ResolvedWorkspaceContext(
                validating: contextID,
                projectID: projectID,
                conversationID: nil,
                environmentID: environmentID,
                workspaceRootIdentity: "root-id"
            )
        },
        resolveWorkspaceRoot: { _ in "/private/tmp/Cockpit" },
        supervisor: supervisor
    )

    let unrelatedProject = ProjectID()
    let mismatchedResolver = WorkspaceTerminalService(
        resolveContext: { _ in
            try ResolvedWorkspaceContext(
                validating: .project(unrelatedProject),
                projectID: unrelatedProject,
                conversationID: nil,
                environmentID: environmentID,
                workspaceRootIdentity: "wrong-root"
            )
        },
        resolveWorkspaceRoot: { _ in "/private/tmp/Cockpit" },
        supervisor: supervisor
    )
    await #expect(throws: WorkspaceTerminalServiceError.contextEnvironmentMismatch) {
        _ = try await mismatchedResolver.perform(.list(contextID: contextID))
    }

    let independentViewer = ViewerID()
    await supervisor.setAuthorization(
        TerminalAttachAuthorization(
            endpoint: try KeeperEndpoint(
                path: "/private/tmp/cockpit-test/keeper.sock",
                sessionID: sessionID,
                workerID: workerID
            ),
            wireTicket: String(repeating: "A", count: 43),
            binding: TerminalAttachBinding(
                sessionID: sessionID,
                workerID: workerID,
                clientInstanceID: clientID
            ),
            viewerID: independentViewer,
            capabilities: [.view]
        )
    )
    await #expect(throws: WorkspaceTerminalServiceError.invalidResponse) {
        _ = try await service.perform(
            .issueAttachTicket(
                contextID: contextID,
                environmentID: environmentID,
                request: TerminalAttachTicketRequest(
                    sessionID: sessionID,
                    clientInstanceID: clientID,
                    viewerID: independentViewer,
                    capabilities: [.view]
                )
            )
        )
    }

    let unrelatedWorker = WorkerInstanceID()
    await supervisor.setAuthorization(
        TerminalAttachAuthorization(
            endpoint: try KeeperEndpoint(
                path: "/private/tmp/cockpit-test/keeper.sock",
                sessionID: sessionID,
                workerID: unrelatedWorker
            ),
            wireTicket: String(repeating: "C", count: 43),
            binding: TerminalAttachBinding(
                sessionID: sessionID,
                workerID: unrelatedWorker,
                clientInstanceID: clientID
            ),
            viewerID: viewerID,
            capabilities: [.view]
        )
    )
    await #expect(throws: WorkspaceTerminalServiceError.invalidResponse) {
        _ = try await service.perform(
            .issueAttachTicket(
                contextID: contextID,
                environmentID: environmentID,
                request: TerminalAttachTicketRequest(
                    sessionID: sessionID,
                    clientInstanceID: clientID,
                    viewerID: viewerID,
                    capabilities: [.view]
                )
            )
        )
    }

    await supervisor.setAuthorization(
        TerminalAttachAuthorization(
            endpoint: try KeeperEndpoint(
                path: "/private/tmp/cockpit-test/keeper.sock",
                sessionID: sessionID,
                workerID: workerID
            ),
            wireTicket: String(repeating: "B", count: 43),
            binding: TerminalAttachBinding(
                sessionID: sessionID,
                workerID: workerID,
                clientInstanceID: ClientInstanceID()
            ),
            viewerID: viewerID,
            capabilities: [.view, .input]
        )
    )
    await #expect(throws: WorkspaceTerminalServiceError.invalidResponse) {
        _ = try await service.perform(
            .issueAttachTicket(
                contextID: contextID,
                environmentID: environmentID,
                request: TerminalAttachTicketRequest(
                    sessionID: sessionID,
                    clientInstanceID: clientID,
                    viewerID: viewerID,
                    capabilities: [.view]
                )
            )
        )
    }

    await supervisor.setInputLease(
        try InputLeaseGrant(
            validatingLeaseID: InputLeaseID(),
            holderViewerID: ViewerID(),
            sequenceBase: 9,
            capabilities: [.input, .resize]
        )
    )
    await #expect(throws: WorkspaceTerminalServiceError.invalidResponse) {
        _ = try await service.perform(
            .acquireInputLease(
                contextID: contextID,
                environmentID: environmentID,
                request: TerminalInputLeaseRequest(
                    sessionID: sessionID,
                    viewerID: viewerID,
                    capabilities: [.input]
                )
            )
        )
    }

    let oldLeaseID = InputLeaseID()
    let transferredLease = try InputLeaseGrant(
        validatingLeaseID: InputLeaseID(),
        holderViewerID: viewerID,
        sequenceBase: 10,
        capabilities: [.input]
    )
    await supervisor.setInputLease(transferredLease)
    let transfer = try await service.perform(
        .transferInputLease(
            contextID: contextID,
            environmentID: environmentID,
            request: TerminalInputLeaseTransferRequest(
                sessionID: sessionID,
                leaseID: oldLeaseID,
                toViewerID: viewerID,
                capabilities: [.input]
            )
        )
    )
    #expect(transfer == .inputLease(transferredLease))
}

@Test func hostTerminalXPCSanitizesCommandAndArchiveErrors() async throws {
    let fixture = try WorkspaceFixture()
    let secretPath = "/private/tmp/Cockpit-Secret-Workspace/private.ckgf"
    let injected = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileReadNoSuchFileError,
        userInfo: [NSFilePathErrorKey: secretPath, NSURLErrorKey: URL(fileURLWithPath: secretPath)]
    )
    let terminalService = WorkspaceTerminalService(
        resolveContext: { _ in throw injected },
        resolveWorkspaceRoot: { _ in throw injected },
        supervisor: RecordingTerminalSupervisorControl()
    )
    let export = HostXPCExport(
        handshakeHandler: { try HostHandshakeHandler().handle($0) },
        workspaceRouter: WorkspaceCommandRouter(service: RecordingWorkspaceService(fixture: fixture)),
        workspaceTerminalService: terminalService
    )

    let commandError: NSError = await withCheckedContinuation { continuation in
        export.terminalCommand(
            try! JSONEncoder().encode(
                HostTerminalCommandRequest.list(contextID: fixture.projectContext.contextID)
            )
        ) { _, error in continuation.resume(returning: error!) }
    }
    let archiveError: NSError = await withCheckedContinuation { continuation in
        export.openTerminalArchive(
            try! JSONEncoder().encode(
                HostTerminalArchiveRequest(
                    contextID: fixture.projectContext.contextID,
                    environmentID: fixture.environmentID,
                    sessionID: TerminalSessionID()
                )
            )
        ) { _, error in continuation.resume(returning: error!) }
    }

    for error in [commandError, archiveError] {
        #expect(error.domain == "dev.cockpit.host-terminal")
        #expect(error.userInfo.isEmpty)
        #expect(!error.description.contains(secretPath))
    }
}

private actor RecordingTerminalSupervisorControl: TerminalSupervisorControlling {
    private(set) var created: ResolvedTerminalCreateRequest?
    private var records: [TerminalSessionRecord] = []
    private var authorization: TerminalAttachAuthorization?
    private var inputLease: InputLeaseGrant?
    private var archiveURL: URL?
    private var createError: (any Error)?

    func setRecords(_ records: [TerminalSessionRecord]) { self.records = records }
    func setAuthorization(_ authorization: TerminalAttachAuthorization) {
        self.authorization = authorization
    }
    func setInputLease(_ inputLease: InputLeaseGrant) { self.inputLease = inputLease }
    func setArchiveURL(_ archiveURL: URL) { self.archiveURL = archiveURL }
    func setCreateError(_ error: any Error) { createError = error }
    func createResolved(_ request: ResolvedTerminalCreateRequest) async throws -> TerminalSessionRecord {
        created = request
        if let createError { throw createError }
        if let first = records.first { return first }
        let executablePath: String
        switch request.kind {
        case .shell:
            executablePath = "/bin/zsh"
        case .agent:
            executablePath = request.selectedExecutablePath ?? "/usr/bin/true"
        }
        let launchSpec = try LaunchSpec(
            kind: request.kind,
            loginShellPath: "/bin/zsh",
            executablePath: executablePath,
            arguments: request.arguments,
            workspaceRoot: request.workspaceRoot,
            terminalSize: request.terminalSize,
            environmentOverrides: request.environmentOverrides
        )
        return try TerminalSessionRecord(
            validatingSessionID: TerminalSessionID(),
            contextID: request.contextID,
            environmentID: request.environmentID,
            protocolVersion: .current,
            launchSpecData: JSONEncoder().encode(launchSpec),
            lifecycleState: .preparing,
            startNonce: Data(repeating: 3, count: 16)
        )
    }
    func list(contextID: WorkspaceContextID) async throws -> [TerminalSessionRecord] { records }
    func issueAttachTicket(_ request: TerminalAttachTicketRequest) async throws -> TerminalAttachAuthorization {
        guard let authorization else { throw CocoaError(.featureUnsupported) }
        return authorization
    }
    func acquireInputLease(_ request: TerminalInputLeaseRequest) async throws -> InputLeaseGrant {
        guard let inputLease else { throw CocoaError(.featureUnsupported) }
        return inputLease
    }
    func transferInputLease(_ request: TerminalInputLeaseTransferRequest) async throws -> InputLeaseGrant {
        guard let inputLease else { throw CocoaError(.featureUnsupported) }
        return inputLease
    }
    func releaseInputLease(sessionID: TerminalSessionID, leaseID: InputLeaseID) async throws {}
    func signal(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        signal: TerminalSignal
    ) async throws -> Int32 { 0 }
    func terminate(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        force: Bool
    ) async throws {}
    func purgeFinishedRecords() async throws -> Int { 0 }
    func reconcile() async throws {}
    func openArchive(sessionID: TerminalSessionID) async throws -> FileHandle {
        guard let archiveURL else {
            return try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        }
        return try FileHandle(forReadingFrom: archiveURL)
    }
}

private func terminalWireResponse(
    _ request: HostTerminalCommandRequest,
    through export: HostXPCExport
) async throws -> Data {
    let encoded = try JSONEncoder().encode(request)
    return try await withCheckedThrowingContinuation { continuation in
        export.terminalCommand(encoded) { data, error in
            if let error { continuation.resume(throwing: error) }
            else if let data { continuation.resume(returning: data) }
            else { continuation.resume(throwing: CocoaError(.coderInvalidValue)) }
        }
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(underestimatedCount)
        for element in self { result.append(try await transform(element)) }
        return result
    }
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
    let environmentID: EnvironmentID
    let conversation: Conversation
    let projectContext: ResolvedWorkspaceContext
    let conversationContext: ResolvedWorkspaceContext
    let snapshot: ProjectSnapshot

    init() throws {
        projectID = ProjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        environmentID = EnvironmentID(UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)
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

    func requestContext() throws -> RequestContext {
        try RequestContext(
            validating: .current,
            clientInstanceID: ClientInstanceID(UUID(uuidString: "00000000-0000-0000-0000-000000000104")!),
            windowID: WindowID(UUID(uuidString: "00000000-0000-0000-0000-000000000105")!),
            workspaceContextID: .project(projectID),
            environmentID: environmentID,
            activeContextGeneration: 7,
            requestID: RequestID(UUID(uuidString: "00000000-0000-0000-0000-000000000106")!)
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

    func performFileOperation(context: RequestContext, operation: FileOperation) throws -> FileOperationResult {
        recordedCommands.append("file")
        switch operation {
        case let .createFile(_, name): return .created(path: try RelativePath(name), kind: .file)
        case let .createDirectory(_, name): return .created(path: try RelativePath(name), kind: .directory)
        default: throw FileOperationError.invalidPath
        }
    }
}

private actor RecordingClientWorkspaceStateService: ClientWorkspaceStateServing {
    private var values: [ClientWorkspaceStateKey: ClientWorkspaceState] = [:]

    func loadClientState(
        _ key: ClientWorkspaceStateKey
    ) -> ClientWorkspaceState? {
        values[key]
    }

    func saveClientState(_ state: ClientWorkspaceState) throws {
        let valid = try state.validated()
        values[valid.key] = valid
    }
}

private actor RecordingConversationDeletionService: ConversationDeletionServing {
    enum Call: Hashable {
        case impact(ConversationID)
        case begin(ConversationID, DeletionOperationID)
        case resume(DeletionOperationID, Bool)
    }

    let impact: ConversationDeletionImpact
    private var progress: [ConversationDeletionProgress]
    private(set) var calls: [Call] = []

    init(
        impact: ConversationDeletionImpact,
        progress: [ConversationDeletionProgress]
    ) {
        self.impact = impact
        self.progress = progress
    }

    func deletionImpact(
        conversationID: ConversationID
    ) -> ConversationDeletionImpact {
        calls.append(.impact(conversationID))
        return impact
    }

    func beginConversationDeletion(
        conversationID: ConversationID,
        operationID: DeletionOperationID,
        preparationID: UUID
    ) -> ConversationDeletionProgress {
        calls.append(.begin(conversationID, operationID))
        return progress.removeFirst()
    }

    func resumeConversationDeletion(
        operationID: DeletionOperationID,
        force: Bool
    ) -> ConversationDeletionProgress {
        calls.append(.resume(operationID, force))
        return progress.removeFirst()
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
    func performFileOperation(context: RequestContext, operation: FileOperation) throws -> FileOperationResult { throw error }
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

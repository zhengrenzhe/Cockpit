import Darwin
import Foundation
import Testing
import CockpitClientCore
import CockpitHostCore
import CockpitProtocol
import CockpitTypes
@testable import CockpitLocalTransport

@Test func hostDataPlaneTicketUsesCanonicalRawHashExpiryAndAtomicReplay() async throws {
    let fixture = try HostDataPlaneFixture()
    let clock = AdvancingHostDataPlaneClock()
    let random = FixedHostDataPlaneRandomBytes(Array(0..<32))
    let store = HostDataPlaneTicketStore(clock: clock, randomBytes: random)

    let first = try await store.issue(binding: fixture.binding, expectedPeerUID: 501)
    #expect(first.wireValue == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    #expect(first.wireValue.count == 43)
    #expect(first.validForMilliseconds == 30_000)

    let wrongBinding = try HostDataPlaneBinding(
        validatingClientInstanceID: fixture.binding.clientInstanceID,
        windowID: fixture.binding.windowID,
        workspaceContextID: fixture.binding.workspaceContextID,
        environmentID: fixture.binding.environmentID,
        activeContextGeneration: fixture.binding.activeContextGeneration + 1
    )
    await #expect(throws: HostDataPlaneTicketError.bindingMismatch) {
        _ = try await store.consume(
            wireValue: first.wireValue,
            binding: wrongBinding,
            peerUID: 501
        )
    }
    #expect(
        try await store.consume(
            wireValue: first.wireValue,
            binding: fixture.binding,
            peerUID: 501
        ) == fixture.binding
    )
    await #expect(throws: HostDataPlaneTicketError.replay) {
        _ = try await store.consume(
            wireValue: first.wireValue,
            binding: fixture.binding,
            peerUID: 501
        )
    }

    let second = try await store.issue(binding: fixture.binding, expectedPeerUID: 501)
    clock.advance(by: .seconds(30))
    await #expect(throws: HostDataPlaneTicketError.expired) {
        _ = try await store.consume(
            wireValue: second.wireValue,
            binding: fixture.binding,
            peerUID: 501
        )
    }
}

@Test func hostDataPlaneTicketRejectsNoncanonicalUnknownWrongPeerAndRandomFailure() async throws {
    let fixture = try HostDataPlaneFixture()
    let store = HostDataPlaneTicketStore(
        clock: AdvancingHostDataPlaneClock(),
        randomBytes: FixedHostDataPlaneRandomBytes(Array(repeating: 7, count: 32))
    )
    let issued = try await store.issue(binding: fixture.binding, expectedPeerUID: 501)
    for invalid in [
        issued.wireValue + "=",
        issued.wireValue.lowercased(),
        String(repeating: "A", count: 42),
        String(repeating: "!", count: 43),
    ] {
        await #expect(throws: HostDataPlaneTicketError.invalidCanonicalTicket) {
            _ = try await store.consume(
                wireValue: invalid,
                binding: fixture.binding,
                peerUID: 501
            )
        }
    }
    await #expect(throws: HostDataPlaneTicketError.bindingMismatch) {
        _ = try await store.consume(
            wireValue: issued.wireValue,
            binding: fixture.binding,
            peerUID: 502
        )
    }
    #expect(
        try await store.consume(
            wireValue: issued.wireValue,
            binding: fixture.binding,
            peerUID: 501
        ) == fixture.binding
    )

    let failing = HostDataPlaneTicketStore(
        clock: AdvancingHostDataPlaneClock(),
        randomBytes: ThrowingHostDataPlaneRandomBytes()
    )
    await #expect(throws: HostDataPlaneTicketError.randomGenerationFailed) {
        _ = try await failing.issue(binding: fixture.binding, expectedPeerUID: 501)
    }
}

@Test func hostDataPlaneAddressUsesExactTupleCapacitySunLengthAndNamespace() async throws {
    let path = "/private/tmp/cockpit.501/host/test/host.sock"
    let address = try UnixDomainSocketAddress(path: path)
    #expect(MemoryLayout.size(ofValue: address.value.sun_path) == 104)
    #expect(address.value.sun_family == sa_family_t(AF_UNIX))
    #expect(
        address.length
            == socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + path.utf8.count + 1)
    )
    #expect(address.value.sun_len == UInt8(address.length))
    #expect(hostDataPlanePath(from: address) == path)

    let exactCapacity = String(repeating: "a", count: 103)
    _ = try UnixDomainSocketAddress(path: exactCapacity)
    #expect(throws: UnixDomainSocketError.pathTooLong) {
        _ = try UnixDomainSocketAddress(path: String(repeating: "a", count: 104))
    }

    let fixture = try HostDataPlaneFixture()
    for invalid in ["", "Upper", "-leading", String(repeating: "a", count: 33), "bad/path"] {
        let server = HostDataPlaneServer(
            namespace: invalid,
            service: fixture.service,
            ticketStore: fixture.ticketStore,
            systemCalls: ScriptedUnixDomainSocketSystemCalls(uid: 501),
            peerCredentials: FixedPeerCredentialReader(uid: 501)
        )
        await #expect(throws: UnixDomainSocketError.invalidNamespace) {
            try await server.start()
        }
    }
}

@Test func hostDataPlaneServerEnforcesDirectorySocketIdentityPermissionsAndDescriptorFlags() async throws {
    let fixture = try HostDataPlaneFixture()
    let calls = ScriptedUnixDomainSocketSystemCalls(uid: 501)
    calls.acceptedDescriptors = [44]
    let server = HostDataPlaneServer(
        namespace: "flags",
        service: fixture.service,
        ticketStore: fixture.ticketStore,
        systemCalls: calls,
        peerCredentials: FixedPeerCredentialReader(uid: 502)
    )
    try await server.start()
    try await eventually {
        calls.closedDescriptors.contains(44)
    }

    #expect(calls.createdDirectories == [
        "/private/tmp/cockpit.501",
        "/private/tmp/cockpit.501/host",
        "/private/tmp/cockpit.501/host/flags",
    ])
    #expect(calls.directoryPermissions.values.allSatisfy { $0 == 0o700 })
    #expect(calls.permissionChanges["/private/tmp/cockpit.501/host/flags/host.sock"] == 0o600)
    #expect(calls.closeOnExecDescriptors.contains(41))
    #expect(calls.noSigPipeDescriptors.contains(41))
    #expect(calls.closeOnExecDescriptors.contains(44))
    #expect(calls.noSigPipeDescriptors.contains(44))
    #expect(calls.pathStatusCalls.contains("/private/tmp/cockpit.501/host/flags/host.sock"))

    await server.shutdown()
    #expect(calls.closedDescriptors.contains(41))
    #expect(calls.unlinkedPaths == ["/private/tmp/cockpit.501/host/flags/host.sock"])
}

@Test func hostDataPlaneServerFailsClosedForUnsafeLiveStaleAndRacedPaths() async throws {
    let fixture = try HostDataPlaneFixture()
    let root = "/private/tmp/cockpit.501"
    let socket = root + "/host/race/host.sock"

    let unsafeDirectory = ScriptedUnixDomainSocketSystemCalls(uid: 501)
    unsafeDirectory.statuses[root] = [.init(
        kind: .symbolicLink, owner: 501, permissions: 0o700, device: 1, inode: 1
    )]
    await #expect(throws: UnixDomainSocketError.unsafeDirectory) {
        try await HostDataPlaneServer(
            namespace: "race", service: fixture.service, ticketStore: fixture.ticketStore,
            systemCalls: unsafeDirectory, peerCredentials: FixedPeerCredentialReader(uid: 501)
        ).start()
    }

    for status in [
        UnixSocketPathStatus(kind: .symbolicLink, owner: 501, permissions: 0o600, device: 2, inode: 2),
        UnixSocketPathStatus(kind: .other, owner: 501, permissions: 0o600, device: 2, inode: 2),
        UnixSocketPathStatus(kind: .socket, owner: 502, permissions: 0o600, device: 2, inode: 2),
    ] {
        let calls = ScriptedUnixDomainSocketSystemCalls(uid: 501)
        calls.seedSafeDirectories(namespace: "race")
        calls.statuses[socket] = [status]
        await #expect(throws: UnixDomainSocketError.unsafeSocket) {
            try await HostDataPlaneServer(
                namespace: "race", service: fixture.service, ticketStore: fixture.ticketStore,
                systemCalls: calls, peerCredentials: FixedPeerCredentialReader(uid: 501)
            ).start()
        }
    }

    let live = ScriptedUnixDomainSocketSystemCalls(uid: 501)
    live.seedSafeDirectories(namespace: "race")
    live.statuses[socket] = [.init(kind: .socket, owner: 501, permissions: 0o600, device: 3, inode: 3)]
    live.connectError = nil
    await #expect(throws: UnixDomainSocketError.serverAlreadyRunning) {
        try await HostDataPlaneServer(
            namespace: "race", service: fixture.service, ticketStore: fixture.ticketStore,
            systemCalls: live, peerCredentials: FixedPeerCredentialReader(uid: 501)
        ).start()
    }
    #expect(live.unlinkedPaths.isEmpty)

    let raced = ScriptedUnixDomainSocketSystemCalls(uid: 501)
    raced.seedSafeDirectories(namespace: "race")
    raced.statuses[socket] = [
        .init(kind: .socket, owner: 501, permissions: 0o600, device: 4, inode: 4),
        .init(kind: .socket, owner: 501, permissions: 0o600, device: 4, inode: 5),
    ]
    raced.connectError = .systemCall(function: "connect", errno: ECONNREFUSED)
    await #expect(throws: UnixDomainSocketError.staleSocketRace) {
        try await HostDataPlaneServer(
            namespace: "race", service: fixture.service, ticketStore: fixture.ticketStore,
            systemCalls: raced, peerCredentials: FixedPeerCredentialReader(uid: 501)
        ).start()
    }
    #expect(raced.unlinkedPaths.isEmpty)
}

@Test func hostDataPlaneShutdownUsesBoundPathInodeGuard() async throws {
    let fixture = try HostDataPlaneFixture()
    let calls = ScriptedUnixDomainSocketSystemCalls(uid: 501)
    let socket = "/private/tmp/cockpit.501/host/guard/host.sock"
    calls.postBindSocketIdentity = .init(
        kind: .socket, owner: 501, permissions: 0o600, device: 9, inode: 10
    )
    let server = HostDataPlaneServer(
        namespace: "guard", service: fixture.service, ticketStore: fixture.ticketStore,
        systemCalls: calls, peerCredentials: FixedPeerCredentialReader(uid: 501)
    )
    try await server.start()
    calls.statuses[socket] = [.init(
        kind: .socket, owner: 501, permissions: 0o600, device: 9, inode: 11
    )]
    await server.shutdown()
    #expect(!calls.unlinkedPaths.contains(socket))
}

@Test func hostDataPlaneXPCDerivesBindingWaitsForReadyAndReturnsTypedErrors() async throws {
    let fixture = try HostDataPlaneFixture()
    let namespace = uniqueHostDataPlaneNamespace("xpc")
    let server = HostDataPlaneServer(
        namespace: namespace,
        service: fixture.service,
        ticketStore: fixture.ticketStore
    )
    let issuer = HostDataPlaneTicketIssuer(
        server: server,
        store: fixture.ticketStore,
        effectiveUserID: geteuid()
    )
    let export = HostXPCExport(
        handshakeHandler: { try HostHandshakeHandler().handle($0) },
        workspaceRouter: WorkspaceCommandRouter(service: ThrowingWorkspaceService()),
        hostDataPlaneTicketIssuer: issuer
    )
    let xpcClient = HostXPCClient(connectionFactory: { _ in HostDataPlaneXPCConnection(proxy: export) })

    do {
        _ = try await xpcClient.issueHostDataPlaneTicket(context: fixture.requestContext)
        Issue.record("ticket issued before server readiness")
    } catch {
        let error = error as NSError
        #expect(error.domain == "dev.cockpit.host-data-plane-ticket")
        #expect(error.code == 1)
        #expect(error.userInfo[NSLocalizedDescriptionKey] == nil)
    }

    try await server.start()
    let response = try await xpcClient.issueHostDataPlaneTicket(context: fixture.requestContext)
    #expect(response.validForMilliseconds == 30_000)
    #expect(response.socketPath.hasSuffix("/host/\(namespace)/host.sock"))
    #expect(
        try await fixture.ticketStore.consume(
            wireValue: response.ticket,
            binding: fixture.binding,
            peerUID: geteuid()
        ) == fixture.binding
    )

    var malformed = CPHostDataPlaneTicketRequest()
    malformed.context = try WorkspaceMessages.encode(fixture.requestContext, negotiatedVersion: .current)
    malformed.context.activeContextGeneration = 0
    let reply = await invokeTicketExport(export, data: try malformed.serializedData())
    #expect(reply.data == nil)
    #expect(reply.error?.domain == "dev.cockpit.host-data-plane-ticket")
    #expect(reply.error?.code == 2)
    await issuer.stopIssuingTickets()
    await server.shutdown()
}

@Test func hostDataPlaneIssuanceShutdownGateOrdersDeliverStopAndRejectsNewIssues() async throws {
    let fixture = try HostDataPlaneFixture()
    let server = HostDataPlaneServer(
        namespace: uniqueHostDataPlaneNamespace("gate"),
        service: fixture.service,
        ticketStore: fixture.ticketStore
    )
    try await server.start()
    let issuer = HostDataPlaneTicketIssuer(
        server: server,
        store: fixture.ticketStore,
        effectiveUserID: geteuid()
    )
    let order = LockedHostDataPlaneBox<[String]>([])
    let deliveryEntered = DispatchSemaphore(value: 0)
    let releaseDelivery = DispatchSemaphore(value: 0)
    let issue = Task {
        try await issuer.issue(for: fixture.requestContext) { _ in
            order.withValue { $0.append("deliver") }
            deliveryEntered.signal()
            releaseDelivery.wait()
        }
    }
    let entered = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: deliveryEntered.wait(timeout: .now() + 2))
        }
    }
    #expect(entered == .success)
    let stop = Task {
        await issuer.stopIssuingTickets()
        order.withValue { $0.append("stop") }
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(order.value == ["deliver"])
    releaseDelivery.signal()
    try await issue.value
    await stop.value
    await server.shutdown()
    order.withValue { $0.append("shutdown") }
    #expect(order.value == ["deliver", "stop", "shutdown"])

    let lateDeliveries = LockedHostDataPlaneBox(0)
    do {
        try await issuer.issue(for: fixture.requestContext) { _ in
            lateDeliveries.withValue { $0 += 1 }
        }
        Issue.record("post-stop issue succeeded")
    } catch {}
    #expect(lateDeliveries.value == 0)
}

@Test func hostDataPlaneUsesExistingHeaderControlEnvelopeAndRejectsWrongChannelBeforePayload() throws {
    let fixture = Data([
        0x43, 0x4B, 0x50, 0x54, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x05,
    ])
    #expect(try FrameHeader(decoding: fixture).encoded() == fixture)

    var error = CPDataPlaneError()
    error.code = .invalidTicket
    var control = CPHostDataPlaneControlEnvelope()
    control.error = error
    let bytes = try control.serializedData()
    #expect(throws: ProtocolMappingError.invalidValue("handshake_response")) {
        _ = try HostDataPlaneMessages.decodeHandshakeResponse(bytes)
    }

    let unknown = try Frame(
        header: FrameHeader(
            flags: 0,
            channel: ChannelID(rawValue: 99),
            sequence: 1,
            acknowledgement: 0,
            payloadLength: 1
        ),
        payload: Data([0xFF])
    )
    #expect(throws: ProtocolMappingError.invalidValue("host_data_plane_channel")) {
        _ = try HostDataPlaneMessages.decodeEnvelope(unknown)
    }
}

@Test func hostDataPlaneClientAuthenticatesAndRoutesAllDocumentOperationsWithCorrelation() async throws {
    let stack = try await HostDataPlaneTestStack.make(prefix: "docs")
    defer { Task { await stack.shutdown() } }
    try await stack.client.connect()

    #expect(
        try await stack.client.openDocument(
            in: stack.fixture.binding.environmentID,
            at: RelativePath("file.txt")
        ) == stack.fixture.snapshot
    )
    #expect(try await stack.client.snapshot(documentID: stack.fixture.documentID) == stack.fixture.snapshot)
    #expect(
        try await stack.client.acquireEditLease(
            documentID: stack.fixture.documentID,
            client: stack.fixture.binding.clientInstanceID
        ) == stack.fixture.lease
    )
    #expect(
        try await stack.client.transferEditLease(
            documentID: stack.fixture.documentID,
            from: stack.fixture.lease.id,
            to: stack.fixture.binding.clientInstanceID
        ) == stack.fixture.lease
    )
    #expect(try await stack.client.apply(stack.fixture.transaction) == stack.fixture.acknowledgement)
    #expect(
        try await stack.client.flush(
            documentID: stack.fixture.documentID,
            through: stack.fixture.transaction.clientSequence
        ) == stack.fixture.acknowledgement.documentVersion
    )
    #expect(
        try await stack.client.save(
            documentID: stack.fixture.documentID,
            expectedFingerprint: stack.fixture.fingerprint
        ) == stack.fixture.snapshot
    )
    #expect(try await stack.client.discard(documentID: stack.fixture.documentID) == stack.fixture.snapshot)
    #expect(stack.fixture.service.callNames == [
        "open", "snapshot", "acquire", "transfer", "apply", "flush", "save", "discard",
    ])
}

@Test func hostDataPlaneClientRejectsAcquireIdentityAndWireBindingMismatchWithoutHostCall() async throws {
    let stack = try await HostDataPlaneTestStack.make(prefix: "bind")
    defer { Task { await stack.shutdown() } }
    try await stack.client.connect()
    await #expect(throws: DocumentProtocolError.invalidLease) {
        _ = try await stack.client.acquireEditLease(
            documentID: stack.fixture.documentID,
            client: ClientInstanceID()
        )
    }
    #expect(stack.fixture.service.callNames.isEmpty)

    let issued = try await stack.fixture.ticketStore.issue(
        binding: stack.fixture.binding,
        expectedPeerUID: geteuid()
    )
    let wrong = try HostDataPlaneBinding(
        validatingClientInstanceID: stack.fixture.binding.clientInstanceID,
        windowID: stack.fixture.binding.windowID,
        workspaceContextID: stack.fixture.binding.workspaceContextID,
        environmentID: stack.fixture.binding.environmentID,
        activeContextGeneration: stack.fixture.binding.activeContextGeneration + 1
    )
    let peer = try RawHostDataPlanePeer(path: stack.serverSocketPath)
    try peer.handshake()
    let error = try peer.authenticate(ticket: issued.wireValue, binding: wrong)
    #expect(error.code == .generationMismatch)
    #expect(stack.fixture.service.callNames.isEmpty)
}

@Test func hostDataPlaneMapsEveryDocumentErrorAndPreservesOnlyApprovedDiagnostics() async throws {
    let stack = try await HostDataPlaneTestStack.make(prefix: "errors")
    defer { Task { await stack.shutdown() } }
    try await stack.client.connect()
    var diagnostics = stack.client.documentDiagnostics().makeAsyncIterator()
    let acknowledgement = stack.fixture.acknowledgement
    let pairs: [(any Error, DocumentProtocolError)] = [
        (HostDataPlaneServiceError.documentNotOpen, .invalidValue),
        (DocumentProtocolError.invalidValue, .invalidValue),
        (DocumentProtocolError.invalidLease, .invalidLease),
        (DocumentProtocolError.leaseHeld, .leaseHeld),
        (DocumentProtocolError.baseVersionMismatch(expected: 3, actual: 2), .baseVersionMismatch(expected: 3, actual: 2)),
        (DocumentProtocolError.sequenceGap(expected: 4, actual: 2), .sequenceGap(expected: 4, actual: 2)),
        (DocumentProtocolError.duplicateMismatch, .duplicateMismatch),
        (DocumentProtocolError.staleSequence, .staleSequence),
        (DocumentProtocolError.resynchronizing, .resynchronizing),
        (DocumentProtocolError.readOnly, .readOnly),
        (DocumentProtocolError.fileMissing, .fileMissing),
    ]
    for (wireError, expected) in pairs {
        stack.fixture.service.nextError = wireError
        await #expect(throws: expected) {
            _ = try await stack.client.snapshot(documentID: stack.fixture.documentID)
        }
    }

    stack.fixture.service.nextError = HostDataPlaneDocumentError.committedRecoveryRequired(acknowledgement)
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await stack.client.snapshot(documentID: stack.fixture.documentID)
    }
    #expect(await diagnostics.next() == .committedRecoveryRequired(acknowledgement))

    stack.fixture.service.nextError = DocumentStorageError.fingerprintMismatch(
        expected: stack.fixture.fingerprint,
        actual: stack.fixture.otherFingerprint
    )
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await stack.client.snapshot(documentID: stack.fixture.documentID)
    }
    #expect(await diagnostics.next() == .fingerprintMismatch)
}

@Test func hostDataPlaneAuthoritativeApplyErrorsSendOnceAndImmediatelyResynchronizeController() async throws {
    let fixture = try HostDataPlaneFixture()
    let errors: [DocumentProtocolError] = [
        .invalidLease, .leaseHeld, .baseVersionMismatch(expected: 2, actual: 1),
        .sequenceGap(expected: 2, actual: 1), .duplicateMismatch, .staleSequence,
        .recoveryRequired,
    ]
    for error in errors {
        let transport = AuthoritativeHostDataPlaneTransport(fixture: fixture, applyError: error)
        let controller = DocumentClientController(
            clientInstanceID: fixture.binding.clientInstanceID,
            transport: transport
        )
        _ = try await controller.open(
            in: fixture.binding.environmentID,
            at: RelativePath("file.txt"),
            requestWriteAccess: true
        )
        await #expect(throws: error) {
            _ = try await controller.submit([
                try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x"),
            ])
        }
        #expect(transport.applyCount == 1)
        #expect(await controller.state == .resynchronizing)
    }
}

@Test func hostDataPlaneFileTreeEnforcesBackpressureCancelAndRevisionReconnect() async throws {
    let stack = try await HostDataPlaneTestStack.make(prefix: "tree")
    defer { Task { await stack.shutdown() } }
    try await stack.client.connect()
    #expect(try await stack.client.children(at: .root) == stack.fixture.treeSnapshot)

    var iterator = stack.client.changes(
        after: stack.fixture.treeSnapshot.revision,
        expandedDirectories: [.root, .root]
    ).makeAsyncIterator()
    try await eventually { stack.fixture.service.activeTreeSubscriptions == 1 }
    stack.fixture.service.yieldTreeDelta(stack.fixture.treeDelta)
    #expect(try await iterator.next() == stack.fixture.treeDelta)
    #expect(stack.fixture.service.treePullCount == 1)
    stack.fixture.service.yieldTreeDelta(stack.fixture.nextTreeDelta)
    _ = try await iterator.next()
    #expect(stack.fixture.service.treePullCount == 2)

    let cancellation = Task {
        var stream = stack.client.changes(
            after: stack.fixture.nextTreeDelta.revision,
            expandedDirectories: [.root]
        ).makeAsyncIterator()
        return try await stream.next()
    }
    try await eventually { stack.fixture.service.activeTreeSubscriptions == 2 }
    cancellation.cancel()
    _ = try? await cancellation.value
    try await eventually { stack.fixture.service.cancelledTreeSubscriptions > 0 }

    stack.fixture.service.nextError = FileTreeProviderError.revisionUnavailable(
        requested: 1,
        current: stack.fixture.treeSnapshot.revision
    )
    var recovered = stack.client.changes(
        after: 1,
        expandedDirectories: [.root]
    ).makeAsyncIterator()
    try await eventually {
        stack.fixture.service.childrenDirectories == [.root, .root]
            && stack.fixture.service.activeTreeSubscriptions >= 2
    }
    stack.fixture.service.yieldTreeDelta(stack.fixture.nextTreeDelta)
    #expect(try await recovered.next() == stack.fixture.nextTreeDelta)
    #expect(stack.fixture.service.childrenDirectories == [.root, .root])
}

@Test func hostDataPlaneMalformedSequenceAckRequestReuseAndPeerUIDFailClosed() async throws {
    let fixture = try HostDataPlaneFixture()
    let namespace = uniqueHostDataPlaneNamespace("wire")
    let wrongPeer = FixedPeerCredentialReader(uid: geteuid() + 1)
    let server = HostDataPlaneServer(
        namespace: namespace,
        service: fixture.service,
        ticketStore: fixture.ticketStore,
        systemCalls: DarwinUnixDomainSocketSystemCalls(),
        peerCredentials: wrongPeer
    )
    try await server.start()
    let peer = try RawHostDataPlanePeer(path: hostDataPlaneSocketPath(namespace: namespace, uid: geteuid()))
    try peer.sendRaw(Data(repeating: 0xFF, count: 32))
    #expect(try peer.readUntilEOF().isEmpty)
    #expect(fixture.service.callNames.isEmpty)
    await server.shutdown()

    let goodStack = try await HostDataPlaneTestStack.make(prefix: "seq")
    defer { Task { await goodStack.shutdown() } }
    let issued = try await goodStack.fixture.ticketStore.issue(
        binding: goodStack.fixture.binding,
        expectedPeerUID: geteuid()
    )
    let raw = try RawHostDataPlanePeer(path: goodStack.serverSocketPath)
    try raw.handshake()
    #expect(try raw.authenticate(ticket: issued.wireValue, binding: goodStack.fixture.binding).code == .unspecified)
    let request = try raw.documentSnapshotRequest(
        binding: goodStack.fixture.binding,
        documentID: goodStack.fixture.documentID,
        requestID: RequestID(),
        sequence: 2,
        acknowledgement: 0
    )
    try raw.sendRaw(request)
    let response = try raw.readFrame()
    #expect(response.header.channel == .documentEdits)
    #expect(response.header.sequence == 1)
    #expect(response.header.acknowledgement == 0)
    #expect(try raw.dataPlaneError(from: response).code == .sequenceViolation)
    #expect(goodStack.fixture.service.callNames.isEmpty)

    let malformedTicket = try await goodStack.fixture.ticketStore.issue(
        binding: goodStack.fixture.binding,
        expectedPeerUID: geteuid()
    )
    let malformed = try RawHostDataPlanePeer(path: goodStack.serverSocketPath)
    try malformed.handshake()
    #expect(
        try malformed.authenticate(
            ticket: malformedTicket.wireValue,
            binding: goodStack.fixture.binding
        ).code == .unspecified
    )
    let malformedFrame = try Frame(
        header: FrameHeader(
            flags: 1,
            channel: .documentEdits,
            sequence: 1,
            acknowledgement: 0,
            payloadLength: 1
        ),
        payload: Data([0xFF])
    )
    try malformed.sendRaw(malformedFrame.encoded())
    let malformedResponse = try malformed.readFrame()
    #expect(malformedResponse.header.channel == .documentEdits)
    #expect(malformedResponse.header.sequence == 1)
    #expect(malformedResponse.header.acknowledgement == 0)
    #expect(try malformed.dataPlaneError(from: malformedResponse).code == .malformedMessage)
    #expect(goodStack.fixture.service.callNames.isEmpty)

    let oversizedTicket = try await goodStack.fixture.ticketStore.issue(
        binding: goodStack.fixture.binding,
        expectedPeerUID: geteuid()
    )
    let oversized = try RawHostDataPlanePeer(path: goodStack.serverSocketPath)
    try oversized.handshake()
    #expect(
        try oversized.authenticate(
            ticket: oversizedTicket.wireValue,
            binding: goodStack.fixture.binding
        ).code == .unspecified
    )
    try oversized.sendRaw(
        FrameHeader(
            flags: 0,
            channel: .fileTreeEvents,
            sequence: 1,
            acknowledgement: 0,
            payloadLength: FrameHeader.maximumPayloadLength + 1
        ).encoded()
    )
    let oversizedResponse = try oversized.readFrame()
    #expect(oversizedResponse.header.channel == .fileTreeEvents)
    #expect(oversizedResponse.header.sequence == 1)
    #expect(oversizedResponse.header.acknowledgement == 0)
    #expect(try oversized.dataPlaneError(from: oversizedResponse).code == .malformedMessage)
    #expect(goodStack.fixture.service.callNames.isEmpty)
}

@Test func hostDataPlaneRealSameUIDChildExercisesGetpeereidHandshakeAndChannelsThreeFour() async throws {
    let stack = try await HostDataPlaneTestStack.make(prefix: "child")
    defer { Task { await stack.shutdown() } }
    let issued = try await stack.fixture.ticketStore.issue(
        binding: stack.fixture.binding,
        expectedPeerUID: geteuid()
    )
    let frames = try childProcessFrames(fixture: stack.fixture, ticket: issued.wireValue)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "-c", hostDataPlanePythonChild,
        stack.serverSocketPath,
    ] + frames.map { $0.base64EncodedString() }
    let diagnostics = Pipe()
    process.standardOutput = diagnostics
    process.standardError = diagnostics
    try process.run()
    process.waitUntilExit()
    let output = String(
        decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    #expect(process.terminationReason == .exit)
    #expect(process.terminationStatus == 0, Comment(rawValue: output))
    #expect(stack.fixture.service.callNames == ["snapshot", "treeChildren"])
}

@Test func hostDataPlanePeerCloseIsDisconnectedWithoutSIGPIPETermination() async throws {
    let stack = try await HostDataPlaneTestStack.make(prefix: "epipe")
    try await stack.client.connect()
    await stack.server.shutdown()
    await #expect(throws: HostDataPlaneClientError.disconnected) {
        _ = try await stack.client.snapshot(documentID: stack.fixture.documentID)
    }
    #expect(getpid() > 1)
}

@Test func hostDataPlaneCockpitHostSIGTERMStopsTicketsUnlinksSocketAndExits() async throws {
    let path = hostDataPlaneSocketPath(namespace: "default", uid: geteuid())
    let previousInode = hostDataPlaneInode(path)
    let process = Process()
    process.executableURL = try cockpitHostDataPlaneExecutableURL()
    let diagnostics = Pipe()
    process.standardOutput = diagnostics
    process.standardError = diagnostics
    try process.run()
    defer {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
    try await eventually(timeout: .seconds(4)) {
        guard let inode = hostDataPlaneInode(path) else { return false }
        return previousInode == nil || inode != previousInode
    }
    #expect(kill(process.processIdentifier, SIGTERM) == 0)
    process.waitUntilExit()
    let output = String(
        decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    #expect(process.terminationReason == .exit, Comment(rawValue: output))
    #expect(process.terminationStatus == 0, Comment(rawValue: output))
    #expect(!FileManager.default.fileExists(atPath: path))
}

private struct HostDataPlaneFixture: Sendable {
    let binding: HostDataPlaneBinding
    let requestContext: RequestContext
    let documentID: DocumentID
    let lease: EditLease
    let fingerprint: DiskFingerprint
    let otherFingerprint: DiskFingerprint
    let snapshot: DocumentSnapshot
    let acknowledgement: EditAcknowledgement
    let transaction: EditTransaction
    let treeSnapshot: FileTreeSnapshot
    let treeDelta: FileTreeDelta
    let nextTreeDelta: FileTreeDelta
    let service: RecordingHostDataPlaneService
    let ticketStore: HostDataPlaneTicketStore

    init() throws {
        let client = ClientInstanceID(uuid(1))
        let window = WindowID(uuid(2))
        let project = ProjectID(uuid(3))
        let environment = EnvironmentID(uuid(4))
        documentID = DocumentID(uuid(5))
        binding = try HostDataPlaneBinding(
            validatingClientInstanceID: client,
            windowID: window,
            workspaceContextID: .project(project),
            environmentID: environment,
            activeContextGeneration: 7
        )
        requestContext = try RequestContext(
            validating: .current,
            clientInstanceID: client,
            windowID: window,
            workspaceContextID: .project(project),
            environmentID: environment,
            activeContextGeneration: 7,
            requestID: RequestID(uuid(6))
        )
        lease = try EditLease(
            validatingID: EditLeaseID(uuid(7)),
            documentID: documentID,
            clientInstanceID: client
        )
        fingerprint = DiskFingerprint(
            deviceID: 1,
            inode: 2,
            byteCount: 3,
            modificationTimeSeconds: 4,
            modificationTimeNanoseconds: 5,
            contentSHA256: try SHA256Digest(validating: Data(repeating: 0x11, count: 32))
        )
        otherFingerprint = DiskFingerprint(
            deviceID: 1,
            inode: 2,
            byteCount: 4,
            modificationTimeSeconds: 5,
            modificationTimeNanoseconds: 6,
            contentSHA256: try SHA256Digest(validating: Data(repeating: 0x22, count: 32))
        )
        snapshot = try DocumentSnapshot(
            validatingDocumentID: documentID,
            environmentID: environment,
            relativePath: RelativePath("file.txt"),
            text: "hello",
            documentVersion: 2,
            persistedVersion: 2,
            lastAcceptedClientSequence: 1,
            dirtyState: .clean,
            observedDiskFingerprint: fingerprint,
            currentLease: lease,
            maintenance: []
        )
        acknowledgement = try EditAcknowledgement(
            validatingDocumentID: documentID,
            clientSequence: 2,
            documentVersion: 3
        )
        transaction = try EditTransaction(
            validatingDocumentID: documentID,
            editLeaseID: lease.id,
            baseVersion: 2,
            clientSequence: 2,
            changes: [try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x")]
        )
        let entry = try FileTreeEntry(
            validating: FileTreeEntryIdentity(
                validating: environment,
                path: RelativePath("file.txt")
            ),
            kind: .file
        )
        treeSnapshot = try FileTreeSnapshot(
            validating: environment,
            directory: .root,
            generation: 7,
            revision: 10,
            children: [entry]
        )
        treeDelta = try FileTreeDelta(
            validating: environment,
            directory: .root,
            revision: 11,
            mutations: [.update(entry)]
        )
        nextTreeDelta = try FileTreeDelta(
            validating: environment,
            directory: .root,
            revision: 12,
            mutations: [.update(entry)]
        )
        service = RecordingHostDataPlaneService(
            snapshot: snapshot,
            lease: lease,
            acknowledgement: acknowledgement,
            treeSnapshot: treeSnapshot
        )
        ticketStore = HostDataPlaneTicketStore()
    }
}

private final class RecordingHostDataPlaneService: HostDataPlaneServing, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshotValue: DocumentSnapshot
    private let leaseValue: EditLease
    private let acknowledgementValue: EditAcknowledgement
    private let treeSnapshotValue: FileTreeSnapshot
    private var calls: [String] = []
    private var pendingError: (any Error)?
    private var treeContinuations: [UUID: AsyncThrowingStream<FileTreeDelta, Error>.Continuation] = [:]
    private var pulls = 0
    private var cancelledSubscriptions = 0
    private var directories: [WorkspaceDirectory] = []

    init(
        snapshot: DocumentSnapshot,
        lease: EditLease,
        acknowledgement: EditAcknowledgement,
        treeSnapshot: FileTreeSnapshot
    ) {
        snapshotValue = snapshot
        leaseValue = lease
        acknowledgementValue = acknowledgement
        treeSnapshotValue = treeSnapshot
    }

    var callNames: [String] { lock.withLock { calls } }
    var treePullCount: Int { lock.withLock { pulls } }
    var cancelledTreeSubscriptions: Int { lock.withLock { cancelledSubscriptions } }
    var activeTreeSubscriptions: Int { lock.withLock { treeContinuations.count } }
    var childrenDirectories: [WorkspaceDirectory] { lock.withLock { directories } }
    var nextError: (any Error)? {
        get { lock.withLock { pendingError } }
        set { lock.withLock { pendingError = newValue } }
    }

    func openDocument(binding: HostDataPlaneBinding, at path: RelativePath) async throws -> DocumentSnapshot {
        try take("open"); return snapshotValue
    }
    func snapshot(binding: HostDataPlaneBinding, documentID: DocumentID) async throws -> DocumentSnapshot {
        try take("snapshot"); return snapshotValue
    }
    func acquireEditLease(binding: HostDataPlaneBinding, documentID: DocumentID) async throws -> EditLease {
        try take("acquire"); return leaseValue
    }
    func transferEditLease(binding: HostDataPlaneBinding, documentID: DocumentID, from leaseID: EditLeaseID, to client: ClientInstanceID) async throws -> EditLease {
        try take("transfer"); return leaseValue
    }
    func apply(binding: HostDataPlaneBinding, transaction: EditTransaction) async throws -> EditAcknowledgement {
        try take("apply"); return acknowledgementValue
    }
    func flush(binding: HostDataPlaneBinding, documentID: DocumentID, through clientSequence: UInt64) async throws -> UInt64 {
        try take("flush"); return acknowledgementValue.documentVersion
    }
    func save(binding: HostDataPlaneBinding, documentID: DocumentID, expectedFingerprint: DiskFingerprint) async throws -> DocumentSnapshot {
        try take("save"); return snapshotValue
    }
    func discard(binding: HostDataPlaneBinding, documentID: DocumentID) async throws -> DocumentSnapshot {
        try take("discard"); return snapshotValue
    }
    func fileTreeChildren(binding: HostDataPlaneBinding, at directory: WorkspaceDirectory) async throws -> FileTreeSnapshot {
        lock.withLock { directories.append(directory) }
        try take("treeChildren")
        return treeSnapshotValue
    }
    func fileTreeChanges(binding: HostDataPlaneBinding, after revision: UInt64) -> AsyncThrowingStream<FileTreeDelta, Error> {
        let id = UUID()
        let error = lock.withLock { () -> (any Error)? in
            defer { pendingError = nil }
            return pendingError
        }
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            lock.withLock { treeContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    self?.treeContinuations.removeValue(forKey: id)
                    self?.cancelledSubscriptions += 1
                }
            }
        }
    }
    func yieldTreeDelta(_ delta: FileTreeDelta) {
        let continuations = lock.withLock { Array(treeContinuations.values) }
        for continuation in continuations {
            if case .enqueued = continuation.yield(delta) {
                lock.withLock { pulls += 1 }
            }
        }
    }

    private func take(_ name: String) throws {
        let error = lock.withLock { () -> (any Error)? in
            calls.append(name)
            defer { pendingError = nil }
            return pendingError
        }
        if let error { throw error }
    }
}

private final class AdvancingHostDataPlaneClock: HostDataPlaneClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(by duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

private struct FixedHostDataPlaneRandomBytes: HostDataPlaneRandomBytes {
    let value: [UInt8]
    init(_ value: [UInt8]) { self.value = value }
    func bytes(count: Int) throws -> [UInt8] { value }
}

private struct ThrowingHostDataPlaneRandomBytes: HostDataPlaneRandomBytes {
    func bytes(count: Int) throws -> [UInt8] { throw CocoaError(.coderInvalidValue) }
}

private struct FixedPeerCredentialReader: PeerCredentialReading {
    let uid: uid_t
    func peerCredentials(for descriptor: Int32) throws -> (uid: uid_t, gid: gid_t) { (uid, 20) }
}

private final class ScriptedUnixDomainSocketSystemCalls: UnixDomainSocketSystemCalls, @unchecked Sendable {
    private let lock = NSLock()
    let uid: uid_t
    var statuses: [String: [UnixSocketPathStatus?]] = [:]
    var connectError: UnixDomainSocketError? = .systemCall(function: "connect", errno: ENOENT)
    var acceptedDescriptors: [Int32] = []
    var postBindSocketIdentity = UnixSocketPathStatus(
        kind: .socket, owner: 501, permissions: 0o600, device: 8, inode: 9
    )
    private(set) var createdDirectories: [String] = []
    private(set) var directoryPermissions: [String: mode_t] = [:]
    private(set) var permissionChanges: [String: mode_t] = [:]
    private(set) var closeOnExecDescriptors: [Int32] = []
    private(set) var noSigPipeDescriptors: [Int32] = []
    private(set) var closedDescriptors: [Int32] = []
    private(set) var unlinkedPaths: [String] = []
    private(set) var pathStatusCalls: [String] = []
    private var boundPath: String?
    private var nextDescriptor: Int32 = 41

    init(uid: uid_t) {
        self.uid = uid
        postBindSocketIdentity = .init(
            kind: .socket, owner: uid, permissions: 0o600, device: 8, inode: 9
        )
    }

    func seedSafeDirectories(namespace: String) {
        for path in [
            "/private/tmp/cockpit.\(uid)",
            "/private/tmp/cockpit.\(uid)/host",
            "/private/tmp/cockpit.\(uid)/host/\(namespace)",
        ] {
            statuses[path] = [.init(
                kind: .directory, owner: uid, permissions: 0o700, device: 1, inode: ino_t(path.count)
            )]
        }
    }

    func effectiveUserID() -> uid_t { uid }
    func createStreamSocket() throws -> Int32 {
        lock.withLock { defer { nextDescriptor += 1 }; return nextDescriptor }
    }
    func setCloseOnExec(_ descriptor: Int32) throws { lock.withLock { closeOnExecDescriptors.append(descriptor) } }
    func setNoSigPipe(_ descriptor: Int32) throws { lock.withLock { noSigPipeDescriptors.append(descriptor) } }
    func bind(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {
        lock.withLock { boundPath = hostDataPlanePath(from: address) }
    }
    func listen(_ descriptor: Int32, backlog: Int32) throws {}
    func accept(_ descriptor: Int32) throws -> Int32 {
        try lock.withLock {
            guard !acceptedDescriptors.isEmpty else {
                throw UnixDomainSocketError.systemCall(function: "accept", errno: ECANCELED)
            }
            return acceptedDescriptors.removeFirst()
        }
    }
    func connect(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {
        if let connectError { throw connectError }
    }
    func pathStatus(_ path: String) throws -> UnixSocketPathStatus? {
        lock.withLock {
            pathStatusCalls.append(path)
            if var sequence = statuses[path], !sequence.isEmpty {
                let value = sequence.removeFirst()
                statuses[path] = sequence
                return value
            }
            if path == boundPath { return postBindSocketIdentity }
            return directoryPermissions[path].map {
                UnixSocketPathStatus(
                    kind: .directory, owner: uid, permissions: $0,
                    device: 1, inode: ino_t(path.count)
                )
            }
        }
    }
    func makeDirectory(_ path: String, permissions: mode_t) throws {
        lock.withLock {
            createdDirectories.append(path)
            directoryPermissions[path] = permissions
        }
    }
    func setPermissions(_ path: String, permissions: mode_t) throws {
        lock.withLock { permissionChanges[path] = permissions }
    }
    func unlink(_ path: String) throws { lock.withLock { unlinkedPaths.append(path) } }
    func close(_ descriptor: Int32) { lock.withLock { closedDescriptors.append(descriptor) } }
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int { 0 }
    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int { buffer.count }
}

private final class HostDataPlaneXPCConnection: XPCConnectionBoundary, @unchecked Sendable {
    private let proxy: Any
    init(proxy: Any) { self.proxy = proxy }
    func configureRemoteObjectInterface(_ interface: NSXPCInterface) {}
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {}
    func resume() {}
    func invalidate() {}
    func remoteObjectProxy(errorHandler: @escaping @Sendable (any Error) -> Void) -> Any { proxy }
}

private actor ThrowingWorkspaceService: WorkspaceServing {
    func addProject(bookmark: Data, displayName: String) throws -> ProjectSnapshot { throw CocoaError(.coderInvalidValue) }
    func listWorkspace() throws -> WorkspaceSnapshot { throw CocoaError(.coderInvalidValue) }
    func createDirectConversation(projectID: ProjectID) throws -> Conversation { throw CocoaError(.coderInvalidValue) }
    func renameConversation(id: ConversationID, title: String) throws { throw CocoaError(.coderInvalidValue) }
    func resolveContext(_ id: WorkspaceContextID) throws -> ResolvedWorkspaceContext { throw CocoaError(.coderInvalidValue) }
    func performFileOperation(context: RequestContext, operation: FileOperation) throws -> FileOperationResult { throw CocoaError(.coderInvalidValue) }
}

private struct TicketExportReply: @unchecked Sendable {
    let data: Data?
    let error: NSError?
}

private func invokeTicketExport(_ export: HostXPCExport, data: Data) async -> TicketExportReply {
    await withCheckedContinuation { continuation in
        export.issueHostDataPlaneTicket(data) { value, error in
            continuation.resume(returning: TicketExportReply(data: value, error: error))
        }
    }
}

private struct HostDataPlaneTestStack: Sendable {
    let fixture: HostDataPlaneFixture
    let server: HostDataPlaneServer
    let issuer: HostDataPlaneTicketIssuer
    let client: HostDataPlaneClient
    let serverSocketPath: String

    static func make(prefix: String) async throws -> Self {
        let fixture = try HostDataPlaneFixture()
        let namespace = uniqueHostDataPlaneNamespace(prefix)
        let server = HostDataPlaneServer(
            namespace: namespace,
            service: fixture.service,
            ticketStore: fixture.ticketStore
        )
        try await server.start()
        let issuer = HostDataPlaneTicketIssuer(
            server: server,
            store: fixture.ticketStore,
            effectiveUserID: geteuid()
        )
        let export = HostXPCExport(
            handshakeHandler: { try HostHandshakeHandler().handle($0) },
            workspaceRouter: WorkspaceCommandRouter(service: ThrowingWorkspaceService()),
            hostDataPlaneTicketIssuer: issuer
        )
        let xpc = HostXPCClient(
            connectionFactory: { _ in HostDataPlaneXPCConnection(proxy: export) }
        )
        return Self(
            fixture: fixture,
            server: server,
            issuer: issuer,
            client: HostDataPlaneClient(binding: fixture.binding, xpcClient: xpc),
            serverSocketPath: hostDataPlaneSocketPath(namespace: namespace, uid: geteuid())
        )
    }

    func shutdown() async {
        await issuer.stopIssuingTickets()
        await client.disconnect()
        await server.shutdown()
    }
}

private final class AuthoritativeHostDataPlaneTransport: DocumentDataTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let fixture: HostDataPlaneFixture
    private let applyError: DocumentProtocolError
    private var count = 0
    var applyCount: Int { lock.withLock { count } }

    init(fixture: HostDataPlaneFixture, applyError: DocumentProtocolError) {
        self.fixture = fixture
        self.applyError = applyError
    }
    func openDocument(in environmentID: EnvironmentID, at path: RelativePath) async throws -> DocumentSnapshot { fixture.snapshot }
    func snapshot(documentID: DocumentID) async throws -> DocumentSnapshot { fixture.snapshot }
    func acquireEditLease(documentID: DocumentID, client: ClientInstanceID) async throws -> EditLease { fixture.lease }
    func transferEditLease(documentID: DocumentID, from leaseID: EditLeaseID, to client: ClientInstanceID) async throws -> EditLease { fixture.lease }
    func apply(_ transaction: EditTransaction) async throws -> EditAcknowledgement {
        lock.withLock { count += 1 }
        throw applyError
    }
    func flush(documentID: DocumentID, through clientSequence: UInt64) async throws -> UInt64 { fixture.snapshot.documentVersion }
    func save(documentID: DocumentID, expectedFingerprint: DiskFingerprint) async throws -> DocumentSnapshot { fixture.snapshot }
    func discard(documentID: DocumentID) async throws -> DocumentSnapshot { fixture.snapshot }
}

private final class RawHostDataPlanePeer {
    private let descriptor: Int32

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        var address = try UnixDomainSocketAddress(path: path).value
        let length = try UnixDomainSocketAddress(path: path).length
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno)!) }
    }
    deinit { Darwin.close(descriptor) }

    func handshake() throws {
        var request = CPHostDataPlaneControlEnvelope()
        request.handshakeRequest = .cockpit(
            deviceID: DeviceID(uuid(20)),
            features: [.hostDataPlane]
        )
        try writeFrame(channel: .control, sequence: 1, acknowledgement: 0, payload: request.serializedData())
        let response = try readFrame()
        #expect(response.header.sequence == 1)
        #expect(response.header.acknowledgement == 1)
        _ = try HostDataPlaneMessages.decodeHandshakeResponse(response.payload)
    }

    func authenticate(ticket: String, binding: HostDataPlaneBinding) throws -> CPDataPlaneError {
        var authenticate = CPHostDataPlaneAuthenticate()
        authenticate.ticket = ticket
        authenticate.binding = try HostDataPlaneMessages.encode(binding)
        var control = CPHostDataPlaneControlEnvelope()
        control.authenticate = authenticate
        try writeFrame(channel: .control, sequence: 2, acknowledgement: 1, payload: control.serializedData())
        let response = try readFrame()
        let decoded = try HostDataPlaneMessages.decodeControlEnvelope(response.payload)
        switch decoded.payload {
        case .authenticated?: return CPDataPlaneError()
        case let .error(error)?: return error
        default: throw ProtocolMappingError.invalidValue("host_data_plane_authenticate")
        }
    }

    func documentSnapshotRequest(
        binding: HostDataPlaneBinding,
        documentID: DocumentID,
        requestID: RequestID,
        sequence: UInt64,
        acknowledgement: UInt64
    ) throws -> Data {
        var request = CPDocumentSnapshotRequest()
        request.documentID = documentID.description
        var envelope = CPDocumentEnvelope()
        envelope.requestID = requestID.description
        envelope.binding = try HostDataPlaneMessages.encode(binding)
        envelope.snapshotRequest = request
        return try Frame(
            header: FrameHeader(
                flags: 0,
                channel: .documentEdits,
                sequence: sequence,
                acknowledgement: acknowledgement,
                payloadLength: UInt32(envelope.serializedData().count)
            ),
            payload: envelope.serializedData()
        ).encoded()
    }

    func dataPlaneError(from frame: Frame) throws -> CPDataPlaneError {
        switch try HostDataPlaneMessages.decodeEnvelope(frame) {
        case let .document(value):
            guard case let .error(error)? = value.payload else {
                throw ProtocolMappingError.invalidValue("data_plane_error")
            }
            return error
        case let .fileTree(value):
            guard case let .error(error)? = value.payload else {
                throw ProtocolMappingError.invalidValue("data_plane_error")
            }
            return error
        case let .control(value):
            guard case let .error(error)? = value.payload else {
                throw ProtocolMappingError.invalidValue("data_plane_error")
            }
            return error
        }
    }

    func writeFrame(channel: ChannelID, sequence: UInt64, acknowledgement: UInt64, payload: Data) throws {
        let frame = try Frame(
            header: FrameHeader(
                flags: 0,
                channel: channel,
                sequence: sequence,
                acknowledgement: acknowledgement,
                payloadLength: UInt32(payload.count)
            ),
            payload: payload
        )
        try sendRaw(frame.encoded())
    }
    func sendRaw(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw POSIXError(.init(rawValue: errno)!) }
                offset += written
            }
        }
    }
    func readFrame() throws -> Frame {
        let headerData = try readExactly(FrameHeader.encodedLength)
        let header = try FrameHeader(decoding: headerData)
        return try Frame(header: header, payload: readExactly(Int(header.payloadLength)))
    }
    func readUntilEOF() throws -> Data {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count == 0 { return result }
            guard count > 0 else { throw POSIXError(.init(rawValue: errno)!) }
            result.append(contentsOf: bytes[0..<count])
        }
    }
    private func readExactly(_ count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let received = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                guard received > 0 else { throw HostDataPlaneClientError.disconnected }
                offset += received
            }
        }
        return result
    }
}

private func childProcessFrames(
    fixture: HostDataPlaneFixture,
    ticket: String
) throws -> [Data] {
    var handshake = CPHostDataPlaneControlEnvelope()
    handshake.handshakeRequest = .cockpit(deviceID: DeviceID(uuid(30)), features: [.hostDataPlane])
    var authenticate = CPHostDataPlaneAuthenticate()
    authenticate.ticket = ticket
    authenticate.binding = try HostDataPlaneMessages.encode(fixture.binding)
    var authentication = CPHostDataPlaneControlEnvelope()
    authentication.authenticate = authenticate
    var documentRequest = CPDocumentSnapshotRequest()
    documentRequest.documentID = fixture.documentID.description
    var document = CPDocumentEnvelope()
    document.requestID = RequestID(uuid(31)).description
    document.binding = try HostDataPlaneMessages.encode(fixture.binding)
    document.snapshotRequest = documentRequest
    var childrenRequest = CPFileTreeChildrenRequest()
    childrenRequest.directory = try HostDataPlaneMessages.encode(WorkspaceDirectory.root)
    var tree = CPFileTreeEnvelope()
    tree.requestID = RequestID(uuid(32)).description
    tree.binding = try HostDataPlaneMessages.encode(fixture.binding)
    tree.childrenRequest = childrenRequest
    return try [
        framed(.control, 1, 0, handshake.serializedData()),
        framed(.control, 2, 1, authentication.serializedData()),
        framed(.documentEdits, 1, 0, document.serializedData()),
        framed(.fileTreeEvents, 1, 0, tree.serializedData()),
    ]
}

private func framed(_ channel: ChannelID, _ sequence: UInt64, _ acknowledgement: UInt64, _ payload: Data) throws -> Data {
    try Frame(
        header: FrameHeader(
            flags: 0, channel: channel, sequence: sequence,
            acknowledgement: acknowledgement, payloadLength: UInt32(payload.count)
        ),
        payload: payload
    ).encoded()
}

private let hostDataPlanePythonChild = #"""
import base64,socket,struct,sys
path=sys.argv[1]
frames=[base64.b64decode(x) for x in sys.argv[2:]]
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
s.connect(path)
expected=[(0,1,1),(0,2,2),(3,1,1),(4,1,1)]
for frame,want in zip(frames,expected):
    s.sendall(frame)
    header=b''
    while len(header)<32:
        chunk=s.recv(32-len(header))
        if not chunk: raise SystemExit('early eof')
        header+=chunk
    magic,version,flags,channel,seq,ack,length=struct.unpack('>IHHIQQI',header)
    payload=b''
    while len(payload)<length:
        payload+=s.recv(length-len(payload))
    if magic!=0x434B5054 or version!=1 or flags!=0 or (channel,seq,ack)!=want:
        raise SystemExit(f'bad header {(magic,version,flags,channel,seq,ack,length)} want={want}')
s.close()
"""#

private final class LockedHostDataPlaneBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&storage) }
    }
}

private func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw CocoaError(.coderReadCorrupt) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func hostDataPlaneSocketPath(namespace: String, uid: uid_t) -> String {
    "/private/tmp/cockpit.\(uid)/host/\(namespace)/host.sock"
}

private func hostDataPlaneInode(_ path: String) -> ino_t? {
    var value = stat()
    return path.withCString { lstat($0, &value) == 0 ? value.st_ino : nil }
}

private func uniqueHostDataPlaneNamespace(_ prefix: String) -> String {
    "\(prefix)-\(UUID().uuidString.lowercased().prefix(12))"
}

private func hostDataPlanePath(from address: UnixDomainSocketAddress) -> String {
    var value = address.value
    let capacity = MemoryLayout.size(ofValue: value.sun_path)
    return withUnsafePointer(to: &value.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
            String(cString: $0)
        }
    }
}

private func cockpitHostDataPlaneExecutableURL() throws -> URL {
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

private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

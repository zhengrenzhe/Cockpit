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
    let random = SequencedHostDataPlaneRandomBytes([
        (0..<32).map(UInt8.init),
        (32..<64).map(UInt8.init),
    ])
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

@Test func hostDataPlaneTicketCollisionPreservesLiveAndConsumedEntriesUntilExpiry() async throws {
    let fixture = try HostDataPlaneFixture()
    let clock = AdvancingHostDataPlaneClock()
    let firstBytes = Array(repeating: UInt8(0x41), count: 32)
    let secondBytes = Array(repeating: UInt8(0x42), count: 32)
    let random = SequencedHostDataPlaneRandomBytes(
        [firstBytes, firstBytes, secondBytes] + Array(repeating: firstBytes, count: 9)
    )
    let store = HostDataPlaneTicketStore(clock: clock, randomBytes: random)

    let first = try await store.issue(binding: fixture.binding, expectedPeerUID: 501)
    let second = try await store.issue(binding: fixture.binding, expectedPeerUID: 501)
    #expect(first.wireValue != second.wireValue)
    #expect(
        try await store.consume(
            wireValue: first.wireValue,
            binding: fixture.binding,
            peerUID: 501
        ) == fixture.binding
    )

    await #expect(throws: HostDataPlaneTicketError.randomGenerationFailed) {
        _ = try await store.issue(binding: fixture.binding, expectedPeerUID: 501)
    }
    await #expect(throws: HostDataPlaneTicketError.replay) {
        _ = try await store.consume(
            wireValue: first.wireValue,
            binding: fixture.binding,
            peerUID: 501
        )
    }

    clock.advance(by: .seconds(30))
    let reused = try await store.issue(binding: fixture.binding, expectedPeerUID: 501)
    #expect(reused.wireValue == first.wireValue)
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

@Test func hostDataPlaneServerShutdownClosesClientOnceListenerLastAndJoinsWorker() async throws {
    let fixture = try HostDataPlaneFixture()
    let calls = ScriptedUnixDomainSocketSystemCalls(uid: 501)
    calls.seedSafeDirectories(namespace: "lifecycle")
    calls.acceptedDescriptors = [44]
    calls.blockReads = true
    let server = HostDataPlaneServer(
        namespace: "lifecycle",
        service: fixture.service,
        ticketStore: fixture.ticketStore,
        systemCalls: calls,
        peerCredentials: FixedPeerCredentialReader(uid: 501)
    )
    try await server.start()
    try await eventually { calls.readEntered }

    let returned = LockedHostDataPlaneBox(false)
    let shutdown = Task {
        await server.shutdown()
        returned.withValue { $0 = true }
    }
    try await eventually(timeout: .milliseconds(250)) {
        returned.value && calls.interruptedDescriptors == [44]
    }
    await shutdown.value

    #expect(returned.value)
    #expect(calls.interruptedDescriptors == [44])
    #expect(calls.closedDescriptors.filter { $0 == 44 }.count == 1)
    let clientClose = try #require(calls.closedDescriptors.firstIndex(of: 44))
    let listenerClose = try #require(calls.closedDescriptors.firstIndex(of: 41))
    #expect(clientClose < listenerClose)
}

@Test func hostDataPlaneServerShutdownCancelsSubscriptionBeforeListenerClose() async throws {
    let order = LockedHostDataPlaneBox<[String]>([])
    let fixture = try HostDataPlaneFixture {
        order.withValue { $0.append("subscription-cancel") }
    }
    let calls = RecordingDarwinUnixDomainSocketSystemCalls { event in
        order.withValue { $0.append(event) }
    }
    let namespace = uniqueHostDataPlaneNamespace("shutdown-order")
    let server = HostDataPlaneServer(
        namespace: namespace,
        service: fixture.service,
        ticketStore: fixture.ticketStore,
        systemCalls: calls,
        peerCredentials: DarwinPeerCredentialReader()
    )
    try await server.start()
    let issued = try await fixture.ticketStore.issue(
        binding: fixture.binding,
        expectedPeerUID: geteuid()
    )
    let peer = try RawHostDataPlanePeer(
        path: hostDataPlaneSocketPath(namespace: namespace, uid: geteuid())
    )
    try peer.handshake()
    #expect(try peer.authenticate(ticket: issued.wireValue, binding: fixture.binding).code == .unspecified)
    let subscriptionID = RequestID().description
    try peer.writeFrame(
        channel: .fileTreeEvents,
        sequence: 1,
        acknowledgement: 0,
        payload: try fileTreeSubscribeEnvelope(
            requestID: subscriptionID,
            binding: fixture.binding,
            after: fixture.treeSnapshot.revision
        ).serializedData()
    )
    _ = try peer.readFrame()
    try await eventually { fixture.service.activeTreeSubscriptions == 1 }

    await server.shutdown()

    let events = order.value
    let clientClose = try #require(events.firstIndex(of: "client-close"))
    let subscriptionCancel = try #require(events.firstIndex(of: "subscription-cancel"))
    let listenerClose = try #require(events.firstIndex(of: "listener-close"))
    #expect(clientClose < subscriptionCancel)
    #expect(subscriptionCancel < listenerClose)
}

@Test func hostDataPlaneServerShutdownRejectsSubscriptionRegistrationAfterStopBegins() async throws {
    let fixture = try HostDataPlaneFixture()
    let calls = RecordingDarwinUnixDomainSocketSystemCalls(
        blockSubscriptionAccepted: true
    ) { _ in }
    let namespace = uniqueHostDataPlaneNamespace("subreg-race")
    let server = HostDataPlaneServer(
        namespace: namespace,
        service: fixture.service,
        ticketStore: fixture.ticketStore,
        systemCalls: calls,
        peerCredentials: DarwinPeerCredentialReader()
    )
    try await server.start()
    let issued = try await fixture.ticketStore.issue(
        binding: fixture.binding,
        expectedPeerUID: geteuid()
    )
    let peer = try RawHostDataPlanePeer(
        path: hostDataPlaneSocketPath(namespace: namespace, uid: geteuid())
    )
    try peer.handshake()
    #expect(
        try peer.authenticate(
            ticket: issued.wireValue,
            binding: fixture.binding
        ).code == .unspecified
    )
    let subscriptionID = RequestID().description
    try peer.writeFrame(
        channel: .fileTreeEvents,
        sequence: 1,
        acknowledgement: 0,
        payload: try fileTreeSubscribeEnvelope(
            requestID: subscriptionID,
            binding: fixture.binding,
            after: fixture.treeSnapshot.revision
        ).serializedData()
    )
    _ = try peer.readFrame()
    try await eventually { calls.subscriptionAcceptedWriteBlocked }

    let shutdown = Task { await server.shutdown() }
    try await Task.sleep(for: .milliseconds(20))
    calls.releaseSubscriptionAcceptedWrite()
    await shutdown.value
    try await Task.sleep(for: .milliseconds(20))

    #expect(fixture.service.treeAfterRevisions.isEmpty)
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

@Test func hostDataPlaneXPCRejectsEveryNoncanonicalContextIDAndUnsafeGenerationAsInvalidContext() async throws {
    let fixture = try HostDataPlaneFixture()
    let random = CountingHostDataPlaneRandomBytes(Array(repeating: 0x33, count: 32))
    let store = HostDataPlaneTicketStore(clock: AdvancingHostDataPlaneClock(), randomBytes: random)
    let server = HostDataPlaneServer(
        namespace: uniqueHostDataPlaneNamespace("exactctx"),
        service: fixture.service,
        ticketStore: store
    )
    try await server.start()
    let issuer = HostDataPlaneTicketIssuer(server: server, store: store, effectiveUserID: geteuid())
    let export = HostXPCExport(
        handshakeHandler: { try HostHandshakeHandler().handle($0) },
        workspaceRouter: WorkspaceCommandRouter(service: ThrowingWorkspaceService()),
        hostDataPlaneTicketIssuer: issuer
    )
    defer { Task { await issuer.stopIssuingTickets(); await server.shutdown() } }

    let canonical = try WorkspaceMessages.encode(fixture.requestContext, negotiatedVersion: .current)
    let uppercase = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".uppercased()
    let mutations: [(inout CPRequestContext) -> Void] = [
        { $0.clientInstanceID = uppercase },
        { $0.windowID = uppercase },
        { $0.workspaceContextID.projectID = uppercase },
        { $0.environmentID = uppercase },
        { $0.requestID = uppercase },
    ]
    for mutate in mutations {
        var context = canonical
        mutate(&context)
        var request = CPHostDataPlaneTicketRequest(); request.context = context
        let reply = await invokeTicketExport(export, data: try request.serializedData())
        #expect(reply.data == nil)
        #expect(reply.error?.domain == "dev.cockpit.host-data-plane-ticket")
        #expect(reply.error?.code == 2)
    }

    var unsafe = canonical
    unsafe.activeContextGeneration = documentJavaScriptMaximum + 1
    var unsafeRequest = CPHostDataPlaneTicketRequest(); unsafeRequest.context = unsafe
    let unsafeReply = await invokeTicketExport(export, data: try unsafeRequest.serializedData())
    #expect(unsafeReply.data == nil)
    #expect(unsafeReply.error?.code == 2)
    #expect(random.callCount == 0)

    var maximum = canonical
    maximum.activeContextGeneration = documentJavaScriptMaximum
    var maximumRequest = CPHostDataPlaneTicketRequest(); maximumRequest.context = maximum
    let maximumReply = await invokeTicketExport(export, data: try maximumRequest.serializedData())
    #expect(maximumReply.error == nil)
    #expect(maximumReply.data != nil)
    #expect(random.callCount == 1)
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

@Test func hostDataPlaneIssuanceUsesOnePermitForTwoAdmittedIssuesThroughStop() async throws {
    let fixture = try HostDataPlaneFixture()
    let random = BlockingFirstHostDataPlaneRandomBytes()
    let store = HostDataPlaneTicketStore(clock: AdvancingHostDataPlaneClock(), randomBytes: random)
    let server = HostDataPlaneServer(
        namespace: uniqueHostDataPlaneNamespace("permit"),
        service: fixture.service,
        ticketStore: store
    )
    try await server.start()
    let issuer = HostDataPlaneTicketIssuer(server: server, store: store, effectiveUserID: geteuid())
    let order = LockedHostDataPlaneBox<[String]>([])
    let first = Task {
        try await issuer.issue(for: fixture.requestContext) { _ in
            order.withValue { $0.append("first") }
        }
    }
    try await eventually { random.firstCallEntered }
    let second = Task {
        try await issuer.issue(for: fixture.requestContext) { _ in
            order.withValue { $0.append("second") }
        }
    }
    let stopReturned = LockedHostDataPlaneBox(false)
    let stop = Task {
        await issuer.stopIssuingTickets()
        order.withValue { $0.append("stop") }
        stopReturned.withValue { $0 = true }
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(random.callCount == 1)
    #expect(order.value.isEmpty)
    #expect(!stopReturned.value)
    random.releaseFirstCall()
    try await first.value
    try await second.value
    await stop.value
    #expect(order.value == ["first", "second", "stop"])
    await server.shutdown()
}

@Test func hostDataPlaneHostShutdownCoordinatorOrdersAdmittedReplyServerAndListener() async throws {
    let fixture = try HostDataPlaneFixture()
    let order = LockedHostDataPlaneBox<[String]>([])
    let calls = ScriptedUnixDomainSocketSystemCalls(uid: 501)
    calls.closeObserver = { descriptor in
        if descriptor == 41 { order.withValue { $0.append("server") } }
    }
    let server = HostDataPlaneServer(
        namespace: "coordinator",
        service: fixture.service,
        ticketStore: fixture.ticketStore,
        systemCalls: calls,
        peerCredentials: FixedPeerCredentialReader(uid: 501)
    )
    try await server.start()
    let issuer = HostDataPlaneTicketIssuer(
        server: server,
        store: fixture.ticketStore,
        effectiveUserID: 501
    )
    let deliveryEntered = DispatchSemaphore(value: 0)
    let releaseDelivery = DispatchSemaphore(value: 0)
    let issue = Task {
        try await issuer.issue(for: fixture.requestContext) { _ in
            order.withValue { $0.append("reply") }
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

    let coordinator = HostShutdownCoordinator(
        ticketIssuer: issuer,
        dataPlaneServer: server,
        invalidateListener: { order.withValue { $0.append("listener") } },
        stopProcess: { order.withValue { $0.append("run-loop") } }
    )
    let shutdown = Task { await coordinator.shutdown() }
    try await Task.sleep(for: .milliseconds(50))
    #expect(order.value == ["reply"])
    releaseDelivery.signal()
    try await issue.value
    await shutdown.value
    #expect(order.value == ["reply", "server", "listener", "run-loop"])

    let lateDeliveries = LockedHostDataPlaneBox(0)
    await #expect(throws: (any Error).self) {
        try await issuer.issue(for: fixture.requestContext) { _ in
            lateDeliveries.withValue { $0 += 1 }
        }
    }
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

@Test func hostDataPlaneClientSingleReadPumpDispatchesReorderedConcurrentUnaryReplies() async throws {
    let fixture = try HostDataPlaneFixture()
    let harness = try await ScriptedHostDataPlaneClientHarness.make(fixture: fixture)
    defer { Task { await harness.client.disconnect() } }

    let first = Task { try await harness.client.snapshot(documentID: fixture.documentID) }
    try await harness.calls.waitForWrittenFrames(3)
    let tree = Task { try await harness.client.children(at: .root) }
    try await harness.calls.waitForWrittenFrames(4)
    let second = Task { try await harness.client.snapshot(documentID: fixture.documentID) }
    try await harness.calls.waitForWrittenFrames(5)
    let firstRequest = try documentEnvelope(harness.calls.writtenFrames[2])
    let treeRequest = try fileTreeEnvelope(harness.calls.writtenFrames[3])
    let secondRequest = try documentEnvelope(harness.calls.writtenFrames[4])

    harness.calls.enqueue(try documentSnapshotFrame(
        requestID: secondRequest.requestID,
        binding: fixture.binding,
        snapshot: fixture.snapshot,
        sequence: 1,
        acknowledgement: 2
    ))
    harness.calls.enqueue(try fileTreeSnapshotFrame(
        requestID: treeRequest.requestID,
        binding: fixture.binding,
        snapshot: fixture.treeSnapshot,
        sequence: 1,
        acknowledgement: 1
    ))
    harness.calls.enqueue(try documentSnapshotFrame(
        requestID: firstRequest.requestID,
        binding: fixture.binding,
        snapshot: fixture.snapshot,
        sequence: 2,
        acknowledgement: 2
    ))

    #expect(try await first.value == fixture.snapshot)
    #expect(try await tree.value == fixture.treeSnapshot)
    #expect(try await second.value == fixture.snapshot)
    #expect(harness.calls.maximumConcurrentReaders == 1)
}

@Test func hostDataPlaneClientCancellationCompletesBeforeLateReplyAndDiscardKeepsConnectionUsable() async throws {
    let fixture = try HostDataPlaneFixture()
    let harness = try await ScriptedHostDataPlaneClientHarness.make(fixture: fixture)
    defer { Task { await harness.client.disconnect() } }
    let completion = LockedHostDataPlaneBox<Result<DocumentSnapshot, any Error>?>(nil)
    let cancelled = Task {
        do {
            let value = try await harness.client.snapshot(documentID: fixture.documentID)
            completion.withValue { $0 = .success(value) }
        } catch {
            completion.withValue { $0 = .failure(error) }
        }
    }
    try await harness.calls.waitForWrittenFrames(3)
    let cancelledRequest = try documentEnvelope(harness.calls.writtenFrames[2])
    cancelled.cancel()
    try await eventually(timeout: .milliseconds(250)) { completion.value != nil }
    if case let .failure(error)? = completion.value {
        #expect(error as? HostDataPlaneClientError == .requestCancelled)
    } else {
        Issue.record("cancelled unary did not complete with requestCancelled")
    }

    harness.calls.enqueue(try documentSnapshotFrame(
        requestID: cancelledRequest.requestID,
        binding: fixture.binding,
        snapshot: fixture.snapshot,
        sequence: 1,
        acknowledgement: 1
    ))
    await cancelled.value

    let next = Task { try await harness.client.snapshot(documentID: fixture.documentID) }
    try await harness.calls.waitForWrittenFrames(4)
    let nextRequest = try documentEnvelope(harness.calls.writtenFrames[3])
    harness.calls.enqueue(try documentSnapshotFrame(
        requestID: nextRequest.requestID,
        binding: fixture.binding,
        snapshot: fixture.snapshot,
        sequence: 2,
        acknowledgement: 2
    ))
    #expect(try await next.value == fixture.snapshot)
}

@Test func hostDataPlaneClientColdFirstUseIsSingleFlight() async throws {
    let fixture = try HostDataPlaneFixture()
    let calls = ScriptedHostDataPlaneClientSocketCalls()
    let proxy = BlockingHostDataPlaneTicketProxy()
    let xpc = HostXPCClient(connectionFactory: { _ in HostDataPlaneXPCConnection(proxy: proxy) })
    let client = HostDataPlaneClient(
        binding: fixture.binding,
        xpcClient: xpc,
        systemCalls: calls
    )

    let first = Task { try await client.snapshot(documentID: fixture.documentID) }
    let second = Task { try await client.children(at: .root) }
    try await proxy.waitForIssueAttempt()
    _ = try? await eventually(timeout: .milliseconds(250)) { proxy.issueCount == 2 }
    #expect(proxy.issueCount == 1)
    if proxy.issueCount != 1 {
        first.cancel()
        second.cancel()
        proxy.releaseTickets()
        _ = try? await first.value
        _ = try? await second.value
        return
    }
    var handshake = CPHandshakeResponse()
    handshake.protocolMajor = 1
    handshake.protocolMinor = 1
    handshake.connectionID = ConnectionID(uuid(24)).description
    handshake.acceptedFeatures = [ProtocolFeature.hostDataPlane.rawValue]
    handshake.serviceKind = "host-data-plane"
    var handshakeEnvelope = CPHostDataPlaneControlEnvelope()
    handshakeEnvelope.handshakeResponse = handshake
    calls.enqueue(try hostDataPlaneTestFrame(
        .control,
        1,
        1,
        handshakeEnvelope.serializedData()
    ))
    var authenticated = CPHostDataPlaneAuthenticated()
    authenticated.binding = try HostDataPlaneMessages.encode(fixture.binding)
    var authenticatedEnvelope = CPHostDataPlaneControlEnvelope()
    authenticatedEnvelope.authenticated = authenticated
    calls.enqueue(try hostDataPlaneTestFrame(
        .control,
        2,
        2,
        authenticatedEnvelope.serializedData()
    ))
    proxy.releaseTicket()
    let bothRequestsWritten = (try? await eventually {
        calls.writtenFrames.count == 4
    }) != nil
    #expect(calls.createSocketCount == 1)
    #expect(bothRequestsWritten)
    guard bothRequestsWritten else {
        first.cancel()
        second.cancel()
        calls.close(71)
        _ = try? await first.value
        _ = try? await second.value
        return
    }
    for frame in calls.writtenFrames.dropFirst(2) {
        switch try HostDataPlaneMessages.decodeEnvelope(frame) {
        case let .document(envelope):
            calls.enqueue(try documentSnapshotFrame(
                requestID: envelope.requestID,
                binding: fixture.binding,
                snapshot: fixture.snapshot
            ))
        case let .fileTree(envelope):
            calls.enqueue(try fileTreeSnapshotFrame(
                requestID: envelope.requestID,
                binding: fixture.binding,
                snapshot: fixture.treeSnapshot
            ))
        case .control:
            Issue.record("single-flight emitted an unexpected control frame")
        }
    }
    #expect(try await first.value == fixture.snapshot)
    #expect(try await second.value == fixture.treeSnapshot)
    await client.disconnect()
    #expect(calls.closeCount == 1)
}

@Test func hostDataPlaneClientDisconnectInterruptsAndJoinsBlockedHandshakeOnce() async throws {
    let fixture = try HostDataPlaneFixture()
    let calls = ScriptedHostDataPlaneClientSocketCalls()
    let proxy = FixedHostDataPlaneTicketProxy()
    let xpc = HostXPCClient(connectionFactory: { _ in HostDataPlaneXPCConnection(proxy: proxy) })
    let client = HostDataPlaneClient(
        binding: fixture.binding,
        xpcClient: xpc,
        systemCalls: calls
    )
    let operation = Task { try await client.snapshot(documentID: fixture.documentID) }
    try await calls.waitForWrittenFrames(1)

    let disconnected = LockedHostDataPlaneBox(false)
    let disconnect = Task {
        await client.disconnect()
        disconnected.withValue { $0 = true }
    }
    _ = try? await eventually(timeout: .milliseconds(250)) {
        disconnected.value && calls.closeCount == 1
    }
    #expect(disconnected.value)
    #expect(calls.closeCount == 1)
    if calls.closeCount == 0 { calls.close(71) }
    await #expect(throws: HostDataPlaneClientError.disconnected) { _ = try await operation.value }
    await disconnect.value
    #expect(calls.closeCount == 1)
}

@Test func hostDataPlaneTreeCancelInterruptsAndJoinsBlockedHandshakeOnce() async throws {
    let fixture = try HostDataPlaneFixture()
    let calls = ScriptedHostDataPlaneClientSocketCalls()
    let proxy = FixedHostDataPlaneTicketProxy()
    let xpc = HostXPCClient(connectionFactory: { _ in HostDataPlaneXPCConnection(proxy: proxy) })
    let client = HostDataPlaneClient(
        binding: fixture.binding,
        xpcClient: xpc,
        systemCalls: calls
    )
    let completion = LockedHostDataPlaneBox<Result<FileTreeDelta?, any Error>?>(nil)
    var operation: Task<Void, Never>? = Task {
        do {
            var iterator = client.changes(
                after: fixture.treeSnapshot.revision,
                expandedDirectories: [.root]
            ).makeAsyncIterator()
            let value = try await iterator.next()
            completion.withValue { $0 = .success(value) }
        } catch {
            completion.withValue { $0 = .failure(error) }
        }
    }
    try await calls.waitForWrittenFrames(1)
    #expect(calls.createSocketCount == 1)
    operation?.cancel()
    _ = try? await eventually(timeout: .milliseconds(250)) {
        completion.value != nil && calls.closeCount == 1
    }
    #expect(completion.value != nil)
    #expect(calls.closeCount == 1)
    if calls.closeCount == 0 { calls.close(71) }
    if case let .failure(error)? = completion.value {
        #expect(error as? HostDataPlaneClientError == .requestCancelled)
    } else if case .success(nil)? = completion.value {
        // A cancelled AsyncThrowingStream iterator may complete its pending next() with nil.
    } else {
        Issue.record("tree handshake cancellation produced a value")
    }
    await operation?.value
    operation = nil
    #expect(proxy.issueCount == 1)
    #expect(calls.closeCount == 1)
}

@Test func hostDataPlaneClientDisconnectAndInflightReadCloseDescriptorExactlyOnce() async throws {
    let fixture = try HostDataPlaneFixture()
    let harness = try await ScriptedHostDataPlaneClientHarness.make(fixture: fixture)
    harness.calls.holdClosedRead = true
    let operation = Task { try await harness.client.snapshot(documentID: fixture.documentID) }
    try await harness.calls.waitForWrittenFrames(3)
    try await eventually { harness.calls.activeReaderCount == 1 }
    await harness.client.disconnect()
    harness.calls.markDescriptorReused()
    harness.calls.releaseClosedRead()
    await #expect(throws: HostDataPlaneClientError.disconnected) { _ = try await operation.value }
    #expect(harness.calls.closeCount == 1)
    #expect(harness.calls.replacementCloseCount == 0)
}

@Test func hostDataPlaneDescriptorLeaseDefersFinalCloseUntilPausedReadExits() async throws {
    let fixture = try HostDataPlaneFixture()
    let harness = try await ScriptedHostDataPlaneClientHarness.make(fixture: fixture)
    harness.calls.holdInterruptedRead = true
    harness.calls.reuseDescriptorOnClose = true
    try await eventually { harness.calls.activeReaderCount == 1 }

    let disconnected = LockedHostDataPlaneBox(false)
    let disconnect = Task {
        await harness.client.disconnect()
        disconnected.withValue { $0 = true }
    }
    try await eventually { harness.calls.interruptCount == 1 }
    #expect(!disconnected.value)
    #expect(harness.calls.closeCount == 0)
    #expect(harness.calls.replacementReadCount == 0)

    harness.calls.releaseInterruptedRead()
    await disconnect.value
    #expect(disconnected.value)
    #expect(harness.calls.closeCount == 1)
    #expect(harness.calls.replacementReadCount == 0)
    #expect(harness.calls.replacementCloseCount == 0)
}

@Test func hostDataPlaneServerSubscriptionLivenessRejectsWaiterAfterAtomicCancel() {
    var state = HostDataPlaneSubscriptionLivenessState()
    let registered = state.register("subscription")
    #expect(registered)
    #expect(state.admitsWaiter(for: "subscription", taskIsCancelled: false))
    state.cancel("subscription")
    #expect(!state.admitsWaiter(for: "subscription", taskIsCancelled: false))
    #expect(!state.admitsWaiter(for: "subscription", taskIsCancelled: true))
    state.stop()
    let registeredAfterStop = state.register("replacement")
    #expect(!registeredAfterStop)
}

@Test func hostDataPlaneUnaryCancellationStateConsumesPreRegistrationExactlyOnce() {
    var state = HostDataPlaneUnaryCancellationState<String>()
    let recorded = state.recordBeforeRegistration("request", requestIDWasUsed: false)
    let consumed = state.consumeBeforeRegistration("request")
    let consumedAgain = state.consumeBeforeRegistration("request")
    #expect(recorded)
    #expect(consumed)
    #expect(!consumedAgain)

    let recordedUsedRequest = state.recordBeforeRegistration("used-request", requestIDWasUsed: true)
    let consumedUsedRequest = state.consumeBeforeRegistration("used-request")
    #expect(!recordedUsedRequest)
    #expect(!consumedUsedRequest)
}

@Test func hostDataPlaneEstablishedOverflowClosesAndCompletesEveryPendingRequest() async throws {
    let fixture = try HostDataPlaneFixture()
    let calls = ScriptedHostDataPlaneClientSocketCalls()
    let owner = HostDataPlaneDescriptorOwner(71, calls: calls)
    let connection = HostDataPlaneClientConnection(
        descriptorOwner: owner,
        systemCalls: calls,
        binding: fixture.binding,
        sequences: HostDataPlaneClientSequenceState(
            lastOutgoing: [ChannelID.documentEdits.rawValue: UInt64.max]
        )
    )
    connection.start()
    let pending = LockedHostDataPlaneBox<Result<Frame, any Error>?>(nil)
    let overflow = LockedHostDataPlaneBox<Result<Frame, any Error>?>(nil)
    let first = Task {
        do {
            let frame = try await connection.roundTrip(
                channel: .fileTreeEvents,
                requestID: RequestID().description,
                payload: Data()
            )
            pending.withValue { $0 = .success(frame) }
        } catch {
            pending.withValue { $0 = .failure(error) }
        }
    }
    try await calls.waitForWrittenFrames(1)
    let second = Task {
        do {
            let frame = try await connection.roundTrip(
                channel: .documentEdits,
                requestID: RequestID().description,
                payload: Data()
            )
            overflow.withValue { $0 = .success(frame) }
        } catch {
            overflow.withValue { $0 = .failure(error) }
        }
    }
    let completed = (try? await eventually { pending.value != nil && overflow.value != nil }) != nil
    if !completed {
        await connection.shutdown()
    }
    #expect(completed)
    if case let .failure(error)? = pending.value {
        #expect(error as? HostDataPlaneClientError == .disconnected)
    } else {
        Issue.record("overflow left the previously pending request incomplete")
    }
    if case let .failure(error)? = overflow.value {
        #expect(error as? HostDataPlaneClientError == .disconnected)
    } else {
        Issue.record("overflow request did not fail as disconnected")
    }
    #expect(calls.closeCount == 1)
    await first.value
    await second.value
    await connection.shutdown()
}

@Test func hostDataPlaneClientRejectsMismatchedDocumentBindingAndPayloadAndCloses() async throws {
    let fixture = try HostDataPlaneFixture()
    let wrongBinding = try HostDataPlaneBinding(
        validatingClientInstanceID: ClientInstanceID(uuid(21)),
        windowID: fixture.binding.windowID,
        workspaceContextID: fixture.binding.workspaceContextID,
        environmentID: fixture.binding.environmentID,
        activeContextGeneration: fixture.binding.activeContextGeneration
    )
    let mismatchedSnapshot = try DocumentSnapshot(
        validatingDocumentID: DocumentID(uuid(22)),
        environmentID: fixture.snapshot.environmentID,
        relativePath: fixture.snapshot.relativePath,
        text: fixture.snapshot.text,
        documentVersion: fixture.snapshot.documentVersion,
        persistedVersion: fixture.snapshot.persistedVersion,
        lastAcceptedClientSequence: fixture.snapshot.lastAcceptedClientSequence,
        dirtyState: fixture.snapshot.dirtyState,
        observedDiskFingerprint: fixture.snapshot.observedDiskFingerprint,
        currentLease: nil,
        maintenance: fixture.snapshot.maintenance
    )

    for (binding, snapshot) in [
        (wrongBinding, fixture.snapshot),
        (fixture.binding, mismatchedSnapshot),
    ] {
        let harness = try await ScriptedHostDataPlaneClientHarness.make(fixture: fixture)
        let operation = Task { try await harness.client.snapshot(documentID: fixture.documentID) }
        try await harness.calls.waitForWrittenFrames(3)
        let request = try documentEnvelope(harness.calls.writtenFrames[2])
        harness.calls.enqueue(try documentSnapshotFrame(
            requestID: request.requestID,
            binding: binding,
            snapshot: snapshot,
            sequence: 1,
            acknowledgement: 1
        ))
        await #expect(throws: HostDataPlaneClientError.disconnected) { _ = try await operation.value }
        #expect(harness.calls.closeCount == 1)
    }
}

@Test func hostDataPlaneClientRejectsMismatchedLeaseAckAndTreeSnapshotCorrelation() async throws {
    let fixture = try HostDataPlaneFixture()

    for wrongLease in [
        try EditLease(
            validatingID: fixture.lease.id,
            documentID: fixture.documentID,
            clientInstanceID: ClientInstanceID(uuid(23))
        ),
        try EditLease(
            validatingID: fixture.lease.id,
            documentID: DocumentID(uuid(23)),
            clientInstanceID: fixture.binding.clientInstanceID
        ),
    ] {
        let harness = try await ScriptedHostDataPlaneClientHarness.make(fixture: fixture)
        let operation = Task {
            try await harness.client.acquireEditLease(
                documentID: fixture.documentID,
                client: fixture.binding.clientInstanceID
            )
        }
        try await harness.calls.waitForWrittenFrames(3)
        let request = try documentEnvelope(harness.calls.writtenFrames[2])
        harness.calls.enqueue(try documentLeaseFrame(
            requestID: request.requestID,
            binding: fixture.binding,
            lease: wrongLease
        ))
        await #expect(throws: HostDataPlaneClientError.disconnected) { _ = try await operation.value }
    }

    for wrongAck in [
        try EditAcknowledgement(
            validatingDocumentID: fixture.documentID,
            clientSequence: 1,
            documentVersion: 3
        ),
        try EditAcknowledgement(
            validatingDocumentID: DocumentID(uuid(23)),
            clientSequence: fixture.transaction.clientSequence,
            documentVersion: 3
        ),
    ] {
        let harness = try await ScriptedHostDataPlaneClientHarness.make(fixture: fixture)
        let operation = Task { try await harness.client.apply(fixture.transaction) }
        try await harness.calls.waitForWrittenFrames(3)
        let request = try documentEnvelope(harness.calls.writtenFrames[2])
        harness.calls.enqueue(try documentAcknowledgementFrame(
            requestID: request.requestID,
            binding: fixture.binding,
            acknowledgementValue: wrongAck
        ))
        await #expect(throws: HostDataPlaneClientError.disconnected) { _ = try await operation.value }
    }

    for wrongSnapshot in [
        try FileTreeSnapshot(
            validating: fixture.binding.environmentID,
            directory: .relative(RelativePath("nested")),
            generation: fixture.binding.activeContextGeneration,
            revision: fixture.treeSnapshot.revision,
            children: []
        ),
        try FileTreeSnapshot(
            validating: fixture.binding.environmentID,
            directory: .root,
            generation: fixture.binding.activeContextGeneration + 1,
            revision: fixture.treeSnapshot.revision,
            children: []
        ),
    ] {
        let harness = try await ScriptedHostDataPlaneClientHarness.make(fixture: fixture)
        let operation = Task { try await harness.client.children(at: .root) }
        try await harness.calls.waitForWrittenFrames(3)
        let request = try fileTreeEnvelope(harness.calls.writtenFrames[2])
        harness.calls.enqueue(try fileTreeSnapshotFrame(
            requestID: request.requestID,
            binding: fixture.binding,
            snapshot: wrongSnapshot
        ))
        await #expect(throws: HostDataPlaneClientError.disconnected) { _ = try await operation.value }
    }
}

@Test func hostDataPlaneTreeClientRejectsEveryMismatchedAckReplyField() async throws {
    enum Mismatch: CaseIterable { case request, subscription, event, revision }

    let fixture = try HostDataPlaneFixture()
    for mismatch in Mismatch.allCases {
        let harness = try ScriptedHostDataPlaneTreeHarness(fixture: fixture)
        var iterator = harness.client.changes(
            after: fixture.treeSnapshot.revision,
            expandedDirectories: [.root]
        ).makeAsyncIterator()
        try await harness.calls.waitForWrittenFrames(3)
        let subscribe = try fileTreeEnvelope(harness.calls.writtenFrames[2])
        harness.calls.enqueue(try fileTreeSubscriptionAcceptedFrame(
            requestID: subscribe.requestID,
            binding: fixture.binding,
            revision: fixture.treeSnapshot.revision
        ))
        let eventID = RequestID().description
        harness.calls.enqueue(try fileTreeDeltaFrame(
            requestID: eventID,
            subscriptionID: subscribe.requestID,
            binding: fixture.binding,
            delta: fixture.treeDelta,
            sequence: 2,
            acknowledgement: 1
        ))
        #expect(try await iterator.next() == fixture.treeDelta)

        let next = Task { try await iterator.next() }
        try await harness.calls.waitForWrittenFrames(4)
        let acknowledgementRequest = try fileTreeEnvelope(harness.calls.writtenFrames[3])
        let requested = acknowledgementRequest.deltaAck
        harness.calls.enqueue(try fileTreeAckAcceptedFrame(
            requestID: mismatch == .request ? RequestID().description : acknowledgementRequest.requestID,
            subscriptionID: mismatch == .subscription ? RequestID().description : requested.subscriptionID,
            eventID: mismatch == .event ? RequestID().description : requested.eventID,
            revision: mismatch == .revision ? requested.revision + 1 : requested.revision,
            binding: fixture.binding,
            sequence: 3,
            acknowledgement: 2
        ))
        await #expect(throws: HostDataPlaneClientError.disconnected) {
            _ = try await next.value
        }
        #expect(harness.calls.closeCount == 1)
    }
}

@Test func hostDataPlaneTreeClientRejectsMismatchedDeltaIdentityAndNonadvancingRevision() async throws {
    enum Mismatch: CaseIterable { case eventIdentity, revision }

    let fixture = try HostDataPlaneFixture()
    let nonadvancing = try FileTreeDelta(
        validating: fixture.binding.environmentID,
        directory: fixture.treeDelta.directory,
        revision: fixture.treeSnapshot.revision,
        mutations: fixture.treeDelta.mutations
    )
    for mismatch in Mismatch.allCases {
        let harness = try ScriptedHostDataPlaneTreeHarness(fixture: fixture)
        var iterator = harness.client.changes(
            after: fixture.treeSnapshot.revision,
            expandedDirectories: [.root]
        ).makeAsyncIterator()
        try await harness.calls.waitForWrittenFrames(3)
        let subscribe = try fileTreeEnvelope(harness.calls.writtenFrames[2])
        harness.calls.enqueue(try fileTreeSubscriptionAcceptedFrame(
            requestID: subscribe.requestID,
            binding: fixture.binding,
            revision: fixture.treeSnapshot.revision
        ))
        let envelopeRequestID = RequestID().description
        harness.calls.enqueue(try fileTreeDeltaFrame(
            requestID: envelopeRequestID,
            eventID: mismatch == .eventIdentity ? RequestID().description : envelopeRequestID,
            subscriptionID: subscribe.requestID,
            binding: fixture.binding,
            delta: mismatch == .revision ? nonadvancing : fixture.treeDelta,
            sequence: 2,
            acknowledgement: 1
        ))

        await #expect(throws: HostDataPlaneClientError.disconnected) {
            _ = try await iterator.next()
        }
        #expect(harness.calls.closeCount == 1)
    }
}

@Test func hostDataPlaneTreeClientWaitsForAndConsumesCorrelatedCancelReply() async throws {
    let fixture = try HostDataPlaneFixture()
    let harness = try ScriptedHostDataPlaneTreeHarness(fixture: fixture)
    let firstDelta = LockedHostDataPlaneBox<FileTreeDelta?>(nil)
    var waiting: Task<FileTreeDelta?, any Error>? = Task {
        var iterator = harness.client.changes(
            after: fixture.treeSnapshot.revision,
            expandedDirectories: [.root]
        ).makeAsyncIterator()
        let received = try await iterator.next()
        firstDelta.withValue { $0 = received }
        return try await iterator.next()
    }
    try await harness.calls.waitForWrittenFrames(3)
    let subscribe = try fileTreeEnvelope(harness.calls.writtenFrames[2])
    harness.calls.enqueue(try fileTreeSubscriptionAcceptedFrame(
        requestID: subscribe.requestID,
        binding: fixture.binding,
        revision: fixture.treeSnapshot.revision
    ))
    let eventID = RequestID().description
    harness.calls.enqueue(try fileTreeDeltaFrame(
        requestID: eventID,
        subscriptionID: subscribe.requestID,
        binding: fixture.binding,
        delta: fixture.treeDelta,
        sequence: 2,
        acknowledgement: 1
    ))
    try await eventually { firstDelta.value == fixture.treeDelta }
    try await harness.calls.waitForWrittenFrames(4)
    let acknowledgementRequest = try fileTreeEnvelope(harness.calls.writtenFrames[3])

    waiting?.cancel()
    _ = try? await waiting?.value
    waiting = nil
    do {
        try await harness.calls.waitForWrittenFrames(5)
    } catch {
        Issue.record("tree cancellation did not write cancel request")
        return
    }
    #expect(harness.calls.closeCount == 0)
    let cancel = try fileTreeEnvelope(harness.calls.writtenFrames[4])
    let requestedAcknowledgement = acknowledgementRequest.deltaAck
    harness.calls.enqueue(try fileTreeAckAcceptedFrame(
        requestID: acknowledgementRequest.requestID,
        subscriptionID: requestedAcknowledgement.subscriptionID,
        eventID: requestedAcknowledgement.eventID,
        revision: requestedAcknowledgement.revision,
        binding: fixture.binding,
        sequence: 3,
        acknowledgement: 2
    ))
    harness.calls.enqueue(try fileTreeCancelledFrame(
        requestID: cancel.requestID,
        subscriptionID: RequestID().description,
        binding: fixture.binding,
        sequence: 4,
        acknowledgement: 3
    ))
    do {
        try await eventually { harness.calls.closeCount == 1 }
    } catch {
        Issue.record("tree cancellation did not close after cancel response")
        return
    }
    #expect(harness.calls.unreadByteCount == 0)
}

@Test func hostDataPlaneTreeCancelUsesOneReaderThroughAckDeltaAndExactCancelled() async throws {
    let fixture = try HostDataPlaneFixture()
    let harness = try ScriptedHostDataPlaneTreeHarness(fixture: fixture)
    let firstDelta = LockedHostDataPlaneBox<FileTreeDelta?>(nil)
    var waiting: Task<FileTreeDelta?, any Error>? = Task {
        var iterator = harness.client.changes(
            after: fixture.treeSnapshot.revision,
            expandedDirectories: [.root]
        ).makeAsyncIterator()
        let received = try await iterator.next()
        firstDelta.withValue { $0 = received }
        return try await iterator.next()
    }
    try await harness.calls.waitForWrittenFrames(3)
    let subscribe = try fileTreeEnvelope(harness.calls.writtenFrames[2])
    harness.calls.enqueue(try fileTreeSubscriptionAcceptedFrame(
        requestID: subscribe.requestID,
        binding: fixture.binding,
        revision: fixture.treeSnapshot.revision
    ))
    let firstEventID = RequestID().description
    harness.calls.enqueue(try fileTreeDeltaFrame(
        requestID: firstEventID,
        subscriptionID: subscribe.requestID,
        binding: fixture.binding,
        delta: fixture.treeDelta,
        sequence: 2,
        acknowledgement: 1
    ))
    try await eventually { firstDelta.value == fixture.treeDelta }
    try await harness.calls.waitForWrittenFrames(4)
    let acknowledgement = try fileTreeEnvelope(harness.calls.writtenFrames[3])

    waiting?.cancel()
    _ = try? await waiting?.value
    waiting = nil
    try await harness.calls.waitForWrittenFrames(5)
    let cancel = try fileTreeEnvelope(harness.calls.writtenFrames[4])
    let requested = acknowledgement.deltaAck
    harness.calls.enqueue(try fileTreeAckAcceptedFrame(
        requestID: acknowledgement.requestID,
        subscriptionID: requested.subscriptionID,
        eventID: requested.eventID,
        revision: requested.revision,
        binding: fixture.binding,
        sequence: 3,
        acknowledgement: 2
    ))
    harness.calls.enqueue(try fileTreeDeltaFrame(
        requestID: RequestID().description,
        subscriptionID: subscribe.requestID,
        binding: fixture.binding,
        delta: fixture.nextTreeDelta,
        sequence: 4,
        acknowledgement: 2
    ))
    harness.calls.enqueue(try fileTreeCancelledFrame(
        requestID: cancel.requestID,
        subscriptionID: subscribe.requestID,
        binding: fixture.binding,
        sequence: 5,
        acknowledgement: 3
    ))
    try await eventually { harness.calls.closeCount == 1 }
    #expect(harness.calls.maximumConcurrentReaders == 1)
    #expect(harness.calls.unreadByteCount == 0)
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
        _ = try await stack.client.apply(stack.fixture.transaction)
    }
    #expect(await diagnostics.next() == .committedRecoveryRequired(acknowledgement))

    stack.fixture.service.nextError = DocumentStorageError.fingerprintMismatch(
        expected: stack.fixture.fingerprint,
        actual: stack.fixture.otherFingerprint
    )
    await #expect(throws: DocumentProtocolError.recoveryRequired) {
        _ = try await stack.client.save(
            documentID: stack.fixture.documentID,
            expectedFingerprint: stack.fixture.fingerprint
        )
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

@Test func hostDataPlaneLocalTransportNumericApplyErrorsSendOnceAndResynchronizeController() async throws {
    let errors: [DocumentProtocolError] = [
        .invalidLease,
        .leaseHeld,
        .baseVersionMismatch(expected: 2, actual: 1),
        .sequenceGap(expected: 2, actual: 1),
        .duplicateMismatch,
        .staleSequence,
        .recoveryRequired,
    ]
    for expected in errors {
        let stack = try await HostDataPlaneTestStack.make(prefix: "controller")
        let controller = DocumentClientController(
            clientInstanceID: stack.fixture.binding.clientInstanceID,
            transport: stack.client
        )
        _ = try await controller.open(
            in: stack.fixture.binding.environmentID,
            at: RelativePath("file.txt"),
            requestWriteAccess: true
        )
        stack.fixture.service.nextError = expected == .recoveryRequired
            ? HostDataPlaneDocumentError.committedRecoveryRequired(
                stack.fixture.acknowledgement
            )
            : expected
        await #expect(throws: expected) {
            _ = try await controller.submit([
                try UTF16TextEdit(validatingOffset: 0, length: 0, replacement: "x"),
            ])
        }
        #expect(stack.fixture.service.callNames.filter { $0 == "apply" }.count == 1)
        #expect(await controller.state == .resynchronizing)
        await stack.shutdown()
    }
}

@Test func hostDataPlaneCommittedDiagnosticMustMatchApplyDocumentAndSequence() async throws {
    let fixture = try HostDataPlaneFixture()
    for wrong in [
        try EditAcknowledgement(
            validatingDocumentID: DocumentID(uuid(25)),
            clientSequence: fixture.transaction.clientSequence,
            documentVersion: fixture.acknowledgement.documentVersion
        ),
        try EditAcknowledgement(
            validatingDocumentID: fixture.transaction.documentID,
            clientSequence: fixture.transaction.clientSequence + 1,
            documentVersion: fixture.acknowledgement.documentVersion
        ),
    ] {
        let harness = try await ScriptedHostDataPlaneClientHarness.make(fixture: fixture)
        let receivedDiagnostic = LockedHostDataPlaneBox<DocumentDataPlaneDiagnostic?>(nil)
        let diagnostic = Task {
            var iterator = harness.client.documentDiagnostics().makeAsyncIterator()
            if let value = await iterator.next() {
                receivedDiagnostic.withValue { $0 = value }
            }
        }
        let operation = Task { try await harness.client.apply(fixture.transaction) }
        try await harness.calls.waitForWrittenFrames(3)
        let request = try documentEnvelope(harness.calls.writtenFrames[2])
        var remote = CPDataPlaneError()
        remote.code = .documentRecoveryRequired
        remote.committedAcknowledgement = try HostDataPlaneMessages.encode(wrong)
        harness.calls.enqueue(try documentErrorFrame(
            requestID: request.requestID,
            binding: fixture.binding,
            error: remote
        ))
        await #expect(throws: HostDataPlaneClientError.disconnected) {
            _ = try await operation.value
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(receivedDiagnostic.value == nil)
        diagnostic.cancel()
        await diagnostic.value
        #expect(harness.calls.closeCount == 1)
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

@Test func hostDataPlaneFileTreeDisconnectGetsNewTicketAndResubscribesFromLastAppliedRevision() async throws {
    let fixture = try HostDataPlaneFixture()
    let namespace = uniqueHostDataPlaneNamespace("reconnect")
    let firstServer = HostDataPlaneServer(
        namespace: namespace,
        service: fixture.service,
        ticketStore: fixture.ticketStore
    )
    try await firstServer.start()
    let firstIssuer = HostDataPlaneTicketIssuer(
        server: firstServer,
        store: fixture.ticketStore,
        effectiveUserID: geteuid()
    )
    let firstExport = HostXPCExport(
        handshakeHandler: { try HostHandshakeHandler().handle($0) },
        workspaceRouter: WorkspaceCommandRouter(service: ThrowingWorkspaceService()),
        hostDataPlaneTicketIssuer: firstIssuer
    )
    let proxy = SwitchingHostDataPlaneTicketProxy(export: firstExport)
    let xpc = HostXPCClient(connectionFactory: { _ in HostDataPlaneXPCConnection(proxy: proxy) })
    let client = HostDataPlaneClient(binding: fixture.binding, xpcClient: xpc)

    var iterator = client.changes(
        after: fixture.treeSnapshot.revision,
        expandedDirectories: [.root, .root]
    ).makeAsyncIterator()
    try await eventually { fixture.service.activeTreeSubscriptions == 1 }
    fixture.service.yieldTreeDelta(fixture.treeDelta)
    #expect(try await iterator.next() == fixture.treeDelta)

    await firstIssuer.stopIssuingTickets()
    await firstServer.shutdown()
    let secondServer = HostDataPlaneServer(
        namespace: namespace,
        service: fixture.service,
        ticketStore: fixture.ticketStore
    )
    try await secondServer.start()
    let secondIssuer = HostDataPlaneTicketIssuer(
        server: secondServer,
        store: fixture.ticketStore,
        effectiveUserID: geteuid()
    )
    let secondExport = HostXPCExport(
        handshakeHandler: { try HostHandshakeHandler().handle($0) },
        workspaceRouter: WorkspaceCommandRouter(service: ThrowingWorkspaceService()),
        hostDataPlaneTicketIssuer: secondIssuer
    )
    proxy.replaceExport(secondExport)
    fixture.service.nextError = FileTreeProviderError.revisionUnavailable(
        requested: fixture.treeDelta.revision,
        current: fixture.treeDelta.revision
    )

    let resumed = Task { try await iterator.next() }
    do {
        try await eventually {
            proxy.successfulIssueCount == 2
                && fixture.service.childrenDirectories == [.root]
                && fixture.service.activeTreeSubscriptions == 1
        }
    } catch {
        Issue.record("tree stream did not reconnect with a new ticket and captured directory refresh")
    }
    fixture.service.yieldTreeDelta(fixture.nextTreeDelta)
    do {
        #expect(try await resumed.value == fixture.nextTreeDelta)
    } catch {
        Issue.record("reconnected tree stream did not resume: \(error)")
    }
    #expect(fixture.service.treeAfterRevisions.prefix(3) == [
        fixture.treeSnapshot.revision,
        fixture.treeDelta.revision,
        fixture.treeDelta.revision,
    ])
    #expect(fixture.service.callNames.filter { $0 == "apply" }.isEmpty)

    await client.disconnect()
    await secondIssuer.stopIssuingTickets()
    await secondServer.shutdown()
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

@Test func hostDataPlaneRawWireRejectsAckViolationAndRequestIDReuse() async throws {
    let stack = try await HostDataPlaneTestStack.make(prefix: "ackreuse")
    defer { Task { await stack.shutdown() } }

    do {
        let issued = try await stack.fixture.ticketStore.issue(
            binding: stack.fixture.binding,
            expectedPeerUID: geteuid()
        )
        let peer = try RawHostDataPlanePeer(path: stack.serverSocketPath)
        try peer.handshake()
        #expect(try peer.authenticate(ticket: issued.wireValue, binding: stack.fixture.binding).code == .unspecified)
        try peer.sendRaw(try peer.documentSnapshotRequest(
            binding: stack.fixture.binding,
            documentID: stack.fixture.documentID,
            requestID: RequestID(),
            sequence: 1,
            acknowledgement: 1
        ))
        #expect(try peer.dataPlaneError(from: peer.readFrame()).code == .ackViolation)
    }

    do {
        let issued = try await stack.fixture.ticketStore.issue(
            binding: stack.fixture.binding,
            expectedPeerUID: geteuid()
        )
        let peer = try RawHostDataPlanePeer(path: stack.serverSocketPath)
        try peer.handshake()
        #expect(try peer.authenticate(ticket: issued.wireValue, binding: stack.fixture.binding).code == .unspecified)
        let requestID = RequestID()
        try peer.sendRaw(try peer.documentSnapshotRequest(
            binding: stack.fixture.binding,
            documentID: stack.fixture.documentID,
            requestID: requestID,
            sequence: 1,
            acknowledgement: 0
        ))
        _ = try peer.readFrame()
        try peer.sendRaw(try peer.documentSnapshotRequest(
            binding: stack.fixture.binding,
            documentID: stack.fixture.documentID,
            requestID: requestID,
            sequence: 2,
            acknowledgement: 1
        ))
        #expect(try peer.dataPlaneError(from: peer.readFrame()).code == .requestIDReuse)
    }
}

@Test func hostDataPlaneWrongTreeEventOrRevisionAckCancelsOnlyThatSubscription() async throws {
    for wrongRevision in [false, true] {
        let stack = try await HostDataPlaneTestStack.make(prefix: wrongRevision ? "ackrev" : "ackevent")
        defer { Task { await stack.shutdown() } }
        let issued = try await stack.fixture.ticketStore.issue(
            binding: stack.fixture.binding,
            expectedPeerUID: geteuid()
        )
        let peer = try RawHostDataPlanePeer(path: stack.serverSocketPath)
        try peer.handshake()
        #expect(try peer.authenticate(ticket: issued.wireValue, binding: stack.fixture.binding).code == .unspecified)

        let subscriptionIDs = [RequestID().description, RequestID().description]
        var outgoing: UInt64 = 0
        var lastIncoming: UInt64 = 0
        for subscriptionID in subscriptionIDs {
            outgoing += 1
            try peer.writeFrame(
                channel: .fileTreeEvents,
                sequence: outgoing,
                acknowledgement: lastIncoming,
                payload: try fileTreeSubscribeEnvelope(
                    requestID: subscriptionID,
                    binding: stack.fixture.binding,
                    after: stack.fixture.treeSnapshot.revision
                ).serializedData()
            )
            let acceptedFrame = try peer.readFrame()
            lastIncoming = acceptedFrame.header.sequence
            let acceptedEnvelope = try fileTreeEnvelope(acceptedFrame)
            #expect(acceptedEnvelope.requestID == subscriptionID)
            #expect(acceptedEnvelope.subscriptionAccepted.subscriptionID == subscriptionID)
        }
        try await eventually { stack.fixture.service.activeTreeSubscriptions == 2 }
        stack.fixture.service.yieldTreeDelta(stack.fixture.treeDelta)
        var events: [String: CPFileTreeDeltaEvent] = [:]
        for _ in subscriptionIDs {
            let eventFrame = try peer.readFrame()
            lastIncoming = eventFrame.header.sequence
            let eventEnvelope = try fileTreeEnvelope(eventFrame)
            guard case let .deltaEvent(event)? = eventEnvelope.payload else {
                Issue.record("missing tree delta event")
                continue
            }
            events[event.subscriptionID] = event
        }
        let cancelledEvent = try #require(events[subscriptionIDs[0]])
        let survivingEvent = try #require(events[subscriptionIDs[1]])

        var ack = CPFileTreeDeltaAck()
        ack.subscriptionID = subscriptionIDs[0]
        ack.eventID = wrongRevision ? cancelledEvent.eventID : survivingEvent.eventID
        ack.revision = wrongRevision ? cancelledEvent.delta.revision + 1 : cancelledEvent.delta.revision
        var ackEnvelope = CPFileTreeEnvelope()
        ackEnvelope.requestID = RequestID().description
        ackEnvelope.binding = try HostDataPlaneMessages.encode(stack.fixture.binding)
        ackEnvelope.deltaAck = ack
        outgoing += 1
        try peer.writeFrame(
            channel: .fileTreeEvents,
            sequence: outgoing,
            acknowledgement: lastIncoming,
            payload: ackEnvelope.serializedData()
        )
        let errorFrame = try peer.readFrame()
        lastIncoming = errorFrame.header.sequence
        #expect(try peer.dataPlaneError(from: errorFrame).code == .treeBackpressure)
        do {
            try await eventually {
                stack.fixture.service.cancelledTreeSubscriptions == 1
                    && stack.fixture.service.activeTreeSubscriptions == 1
            }
        } catch {
            Issue.record("wrong tree ACK did not cancel only its subscription")
        }

        var survivingAck = CPFileTreeDeltaAck()
        survivingAck.subscriptionID = subscriptionIDs[1]
        survivingAck.eventID = survivingEvent.eventID
        survivingAck.revision = survivingEvent.delta.revision
        var survivingAckEnvelope = CPFileTreeEnvelope()
        survivingAckEnvelope.requestID = RequestID().description
        survivingAckEnvelope.binding = try HostDataPlaneMessages.encode(stack.fixture.binding)
        survivingAckEnvelope.deltaAck = survivingAck
        outgoing += 1
        try peer.writeFrame(
            channel: .fileTreeEvents,
            sequence: outgoing,
            acknowledgement: lastIncoming,
            payload: survivingAckEnvelope.serializedData()
        )
        let acceptedAckFrame = try peer.readFrame()
        lastIncoming = acceptedAckFrame.header.sequence
        let acceptedAck = try fileTreeEnvelope(acceptedAckFrame)
        guard case .ackAccepted? = acceptedAck.payload else {
            Issue.record("wrong tree ACK cancelled the unrelated subscription")
            continue
        }
        #expect(acceptedAck.ackAccepted.subscriptionID == subscriptionIDs[1])
        #expect(acceptedAck.ackAccepted.eventID == survivingEvent.eventID)
        #expect(acceptedAck.ackAccepted.revision == survivingEvent.delta.revision)

        let pulls = stack.fixture.service.treePullCount
        stack.fixture.service.yieldTreeDelta(stack.fixture.nextTreeDelta)
        try await eventually { stack.fixture.service.treePullCount == pulls + 1 }
        let nextFrame = try peer.readFrame()
        let nextEnvelope = try fileTreeEnvelope(nextFrame)
        #expect(nextEnvelope.deltaEvent.subscriptionID == subscriptionIDs[1])
    }
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
    let fixture = try HostDataPlaneFixture()
    let path = hostDataPlaneSocketPath(namespace: "default", uid: geteuid())
    let previousInode = hostDataPlaneInode(path)
    #expect(previousInode == nil)
    guard previousInode == nil else { return }

    let uid = geteuid()
    let domain = "gui/\(uid)"
    let label = "dev.cockpit.host.tests.\(UUID().uuidString.lowercased())"
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(label, isDirectory: true)
    let plist = temporary.appendingPathComponent("launchd.plist")
    let diagnostics = temporary.appendingPathComponent("host.log")
    let hostExecutable = temporary.appendingPathComponent("CockpitHost")
    let socketCalls = DarwinUnixDomainSocketSystemCalls()
    var ownedSocketIdentity: UnixSocketPathStatus?
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    try FileManager.default.copyItem(
        at: cockpitHostDataPlaneExecutableURL(),
        to: hostExecutable
    )
    let configuration: [String: Any] = [
        "Label": label,
        "ProgramArguments": [hostExecutable.path],
        "MachServices": ["dev.cockpit.host": true],
        "StandardOutPath": diagnostics.path,
        "StandardErrorPath": diagnostics.path,
    ]
    try PropertyListSerialization.data(
        fromPropertyList: configuration,
        format: .xml,
        options: 0
    ).write(to: plist, options: .atomic)
    defer {
        _ = try? runHostDataPlaneLaunchctl(["bootout", "\(domain)/\(label)"])
        if let ownedSocketIdentity,
           let current = try? socketCalls.pathStatus(path),
           current == ownedSocketIdentity {
            _ = Darwin.unlink(path)
        }
        try? FileManager.default.removeItem(at: temporary)
    }

    let productionJob = try runHostDataPlaneLaunchctl([
        "print", "\(domain)/dev.cockpit.host",
    ])
    #expect(productionJob.status != 0)
    guard productionJob.status != 0 else { return }
    let bootstrap = try runHostDataPlaneLaunchctl(["bootstrap", domain, plist.path])
    #expect(bootstrap.status == 0, Comment(rawValue: bootstrap.output))
    guard bootstrap.status == 0 else { return }
    let loadedJob = try runHostDataPlaneLaunchctl(["print", "\(domain)/\(label)"])
    #expect(loadedJob.status == 0, Comment(rawValue: loadedJob.output))
    guard loadedJob.status == 0 else { return }

    let xpc = HostXPCClient()
    let ticket = try await hostDataPlaneTicket(
        from: xpc,
        context: fixture.requestContext,
        timeout: .seconds(2)
    )
    #expect(ticket.socketPath == path)
    guard let socketIdentity = try socketCalls.pathStatus(path) else {
        Issue.record("ticket returned without a bound socket")
        return
    }
    ownedSocketIdentity = socketIdentity
    #expect(socketIdentity.kind == .socket)
    #expect(socketIdentity.owner == uid)
    let activePeer = try RawHostDataPlanePeer(path: path)
    try activePeer.handshake()
    #expect(
        try activePeer.authenticate(
            ticket: ticket.ticket,
            binding: fixture.binding
        ).code == .unspecified
    )
    try activePeer.setReceiveBuffer(byteCount: 1_024)
    let fullyWrittenRequests = try activePeer.fillDocumentRequestsUntilWouldBlock(
        binding: fixture.binding,
        documentID: fixture.documentID
    )
    #expect(fullyWrittenRequests > 0)
    let runningJob = try runHostDataPlaneLaunchctl(["print", "\(domain)/\(label)"])
    let processIdentifier = try hostDataPlaneLaunchctlPID(runningJob.output)
    await xpc.disconnect()
    #expect(kill(processIdentifier, SIGTERM) == 0)
    try await eventually(timeout: .seconds(2)) {
        kill(processIdentifier, 0) == -1
            && errno == ESRCH
            && !FileManager.default.fileExists(atPath: path)
    }
    let stoppedJob = try runHostDataPlaneLaunchctl(["print", "\(domain)/\(label)"])
    let output = (try? String(contentsOf: diagnostics, encoding: .utf8)) ?? ""
    #expect(stoppedJob.output.contains("state = not running"), Comment(rawValue: output))
    #expect(stoppedJob.output.contains("last exit code = 0"), Comment(rawValue: output))
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

    init(treeCancellationObserver: (@Sendable () -> Void)? = nil) throws {
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
            treeSnapshot: treeSnapshot,
            treeCancellationObserver: treeCancellationObserver
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
    private let treeCancellationObserver: (@Sendable () -> Void)?
    private var calls: [String] = []
    private var pendingError: (any Error)?
    private var treeContinuations: [UUID: AsyncThrowingStream<FileTreeDelta, Error>.Continuation] = [:]
    private var pulls = 0
    private var cancelledSubscriptions = 0
    private var directories: [WorkspaceDirectory] = []
    private var afterRevisions: [UInt64] = []

    init(
        snapshot: DocumentSnapshot,
        lease: EditLease,
        acknowledgement: EditAcknowledgement,
        treeSnapshot: FileTreeSnapshot,
        treeCancellationObserver: (@Sendable () -> Void)? = nil
    ) {
        snapshotValue = snapshot
        leaseValue = lease
        acknowledgementValue = acknowledgement
        treeSnapshotValue = treeSnapshot
        self.treeCancellationObserver = treeCancellationObserver
    }

    var callNames: [String] { lock.withLock { calls } }
    var treePullCount: Int { lock.withLock { pulls } }
    var cancelledTreeSubscriptions: Int { lock.withLock { cancelledSubscriptions } }
    var activeTreeSubscriptions: Int { lock.withLock { treeContinuations.count } }
    var childrenDirectories: [WorkspaceDirectory] { lock.withLock { directories } }
    var treeAfterRevisions: [UInt64] { lock.withLock { afterRevisions } }
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
            afterRevisions.append(revision)
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
                self?.treeCancellationObserver?()
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

private final class SequencedHostDataPlaneRandomBytes: HostDataPlaneRandomBytes, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[UInt8]]
    init(_ values: [[UInt8]]) { self.values = values }
    func bytes(count: Int) throws -> [UInt8] {
        try lock.withLock {
            guard !values.isEmpty else { throw HostDataPlaneTicketError.randomGenerationFailed }
            return values.removeFirst()
        }
    }
}

private final class CountingHostDataPlaneRandomBytes: HostDataPlaneRandomBytes, @unchecked Sendable {
    private let lock = NSLock()
    private let value: [UInt8]
    private var calls = 0
    init(_ value: [UInt8]) { self.value = value }
    var callCount: Int { lock.withLock { calls } }
    func bytes(count: Int) throws -> [UInt8] {
        lock.withLock { calls += 1 }
        return value
    }
}

private final class BlockingFirstHostDataPlaneRandomBytes: HostDataPlaneRandomBytes, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var calls = 0
    private var entered = false
    var callCount: Int { lock.withLock { calls } }
    var firstCallEntered: Bool { lock.withLock { entered } }
    func bytes(count: Int) throws -> [UInt8] {
        let call = lock.withLock { () -> Int in
            calls += 1
            if calls == 1 { entered = true }
            return calls
        }
        if call == 1 { release.wait() }
        return Array(repeating: UInt8(call), count: count)
    }
    func releaseFirstCall() { release.signal() }
}

private struct FixedPeerCredentialReader: PeerCredentialReading {
    let uid: uid_t
    func peerCredentials(for descriptor: Int32) throws -> (uid: uid_t, gid: gid_t) { (uid, 20) }
}

private final class ScriptedUnixDomainSocketSystemCalls: UnixDomainSocketSystemCalls, HostDataPlaneDescriptorInterrupting, @unchecked Sendable {
    private let lock = NSLock()
    private let readRelease = DispatchSemaphore(value: 0)
    let uid: uid_t
    var statuses: [String: [UnixSocketPathStatus?]] = [:]
    var connectError: UnixDomainSocketError? = .systemCall(function: "connect", errno: ENOENT)
    var acceptedDescriptors: [Int32] = []
    var blockReads = false
    var closeObserver: (@Sendable (Int32) -> Void)?
    var postBindSocketIdentity = UnixSocketPathStatus(
        kind: .socket, owner: 501, permissions: 0o600, device: 8, inode: 9
    )
    private(set) var createdDirectories: [String] = []
    private(set) var directoryPermissions: [String: mode_t] = [:]
    private(set) var permissionChanges: [String: mode_t] = [:]
    private(set) var closeOnExecDescriptors: [Int32] = []
    private(set) var noSigPipeDescriptors: [Int32] = []
    private(set) var closedDescriptors: [Int32] = []
    private(set) var interruptedDescriptors: [Int32] = []
    private(set) var unlinkedPaths: [String] = []
    private(set) var pathStatusCalls: [String] = []
    private var boundPath: String?
    private var nextDescriptor: Int32 = 41
    private var enteredRead = false

    var readEntered: Bool { lock.withLock { enteredRead } }

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
    func close(_ descriptor: Int32) {
        lock.withLock { closedDescriptors.append(descriptor) }
        closeObserver?(descriptor)
    }
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if lock.withLock({ blockReads }) {
            lock.withLock { enteredRead = true }
            readRelease.wait()
        }
        return 0
    }
    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int { buffer.count }
    func interruptHostDataPlaneDescriptor(_ descriptor: Int32) {
        lock.withLock { interruptedDescriptors.append(descriptor) }
        readRelease.signal()
    }
}

private final class RecordingDarwinUnixDomainSocketSystemCalls: UnixDomainSocketSystemCalls, HostDataPlaneDescriptorInterrupting, @unchecked Sendable {
    private let base = DarwinUnixDomainSocketSystemCalls()
    private let lock = NSLock()
    private let observe: @Sendable (String) -> Void
    private let blockSubscriptionAccepted: Bool
    private let subscriptionAcceptedRelease = DispatchSemaphore(value: 0)
    private var listenerDescriptor: Int32?
    private var clientDescriptors: Set<Int32> = []
    private var blockedSubscriptionAccepted = false
    private var didBlockSubscriptionAccepted = false

    init(
        blockSubscriptionAccepted: Bool = false,
        observe: @escaping @Sendable (String) -> Void
    ) {
        self.blockSubscriptionAccepted = blockSubscriptionAccepted
        self.observe = observe
    }

    var subscriptionAcceptedWriteBlocked: Bool {
        lock.withLock { blockedSubscriptionAccepted }
    }

    func releaseSubscriptionAcceptedWrite() {
        subscriptionAcceptedRelease.signal()
    }

    func effectiveUserID() -> uid_t { base.effectiveUserID() }
    func createStreamSocket() throws -> Int32 {
        let descriptor = try base.createStreamSocket()
        lock.withLock {
            if listenerDescriptor == nil { listenerDescriptor = descriptor }
        }
        return descriptor
    }
    func setCloseOnExec(_ descriptor: Int32) throws { try base.setCloseOnExec(descriptor) }
    func setNoSigPipe(_ descriptor: Int32) throws { try base.setNoSigPipe(descriptor) }
    func bind(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {
        try base.bind(descriptor, to: address)
    }
    func listen(_ descriptor: Int32, backlog: Int32) throws { try base.listen(descriptor, backlog: backlog) }
    func accept(_ descriptor: Int32) throws -> Int32 {
        let accepted = try base.accept(descriptor)
        lock.withLock { _ = clientDescriptors.insert(accepted) }
        return accepted
    }
    func connect(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {
        try base.connect(descriptor, to: address)
    }
    func pathStatus(_ path: String) throws -> UnixSocketPathStatus? { try base.pathStatus(path) }
    func makeDirectory(_ path: String, permissions: mode_t) throws {
        try base.makeDirectory(path, permissions: permissions)
    }
    func setPermissions(_ path: String, permissions: mode_t) throws {
        try base.setPermissions(path, permissions: permissions)
    }
    func unlink(_ path: String) throws { try base.unlink(path) }
    func close(_ descriptor: Int32) {
        base.close(descriptor)
        let event = lock.withLock { () -> String? in
            if descriptor == listenerDescriptor { return "listener-close" }
            if clientDescriptors.contains(descriptor) { return "client-close" }
            return nil
        }
        if let event { observe(event) }
    }
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try base.read(descriptor, into: buffer)
    }
    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int {
        let written = try base.write(descriptor, from: buffer)
        let blocks = lock.withLock { () -> Bool in
            guard blockSubscriptionAccepted,
                  !didBlockSubscriptionAccepted,
                  clientDescriptors.contains(descriptor),
                  written == buffer.count,
                  isSubscriptionAcceptedFrame(Data(buffer)) else {
                return false
            }
            didBlockSubscriptionAccepted = true
            blockedSubscriptionAccepted = true
            return true
        }
        if blocks { subscriptionAcceptedRelease.wait() }
        return written
    }
    func interruptHostDataPlaneDescriptor(_ descriptor: Int32) {
        base.interruptHostDataPlaneDescriptor(descriptor)
    }

    private func isSubscriptionAcceptedFrame(_ data: Data) -> Bool {
        var decoder = FrameDecoder()
        guard let frames = try? decoder.append(data),
              frames.count == 1,
              case let .fileTree(envelope) = try? HostDataPlaneMessages.decodeEnvelope(frames[0]),
              case .subscriptionAccepted? = envelope.payload else {
            return false
        }
        return true
    }
}

private final class ScriptedHostDataPlaneClientSocketCalls: UnixDomainSocketSystemCalls, HostDataPlaneDescriptorInterrupting, @unchecked Sendable {
    private let condition = NSCondition()
    private var input = Data()
    private var output = Data()
    private var frames: [Frame] = []
    private var closed = false
    private var interrupted = false
    private var closes = 0
    private var replacementCloses = 0
    private var descriptorReused = false
    private var releaseClosedReader = false
    private var activeReaders = 0
    private var maximumReaders = 0
    private var createdSockets = 0
    private var interrupts = 0
    private var replacementReads = 0
    var holdClosedRead = false
    var holdInterruptedRead = false
    var reuseDescriptorOnClose = false

    var writtenFrames: [Frame] {
        condition.withLock { frames }
    }
    var closeCount: Int { condition.withLock { closes } }
    var replacementCloseCount: Int { condition.withLock { replacementCloses } }
    var maximumConcurrentReaders: Int { condition.withLock { maximumReaders } }
    var activeReaderCount: Int { condition.withLock { activeReaders } }
    var unreadByteCount: Int { condition.withLock { input.count } }
    var createSocketCount: Int { condition.withLock { createdSockets } }
    var interruptCount: Int { condition.withLock { interrupts } }
    var replacementReadCount: Int { condition.withLock { replacementReads } }

    func enqueue(_ frame: Frame) {
        condition.lock()
        input.append(frame.encoded())
        condition.broadcast()
        condition.unlock()
    }

    func waitForWrittenFrames(_ count: Int) async throws {
        try await eventually { self.writtenFrames.count >= count }
    }

    func effectiveUserID() -> uid_t { geteuid() }
    func createStreamSocket() throws -> Int32 {
        condition.withLock {
            createdSockets += 1
            interrupted = false
        }
        return 71
    }
    func setCloseOnExec(_ descriptor: Int32) throws {}
    func setNoSigPipe(_ descriptor: Int32) throws {}
    func bind(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {}
    func listen(_ descriptor: Int32, backlog: Int32) throws {}
    func accept(_ descriptor: Int32) throws -> Int32 { throw UnixDomainSocketError.systemCall(function: "accept", errno: ECANCELED) }
    func connect(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {}
    func pathStatus(_ path: String) throws -> UnixSocketPathStatus? { nil }
    func makeDirectory(_ path: String, permissions: mode_t) throws {}
    func setPermissions(_ path: String, permissions: mode_t) throws {}
    func unlink(_ path: String) throws {}
    func close(_ descriptor: Int32) {
        condition.lock()
        if descriptorReused {
            replacementCloses += 1
        } else {
            closes += 1
            if reuseDescriptorOnClose { descriptorReused = true }
        }
        closed = true
        condition.broadcast()
        condition.unlock()
    }
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        condition.lock()
        activeReaders += 1
        maximumReaders = max(maximumReaders, activeReaders)
        defer {
            if descriptorReused { replacementReads += 1 }
            activeReaders -= 1
            condition.unlock()
        }
        while input.isEmpty, !closed, !interrupted { condition.wait() }
        while input.isEmpty, closed, holdClosedRead, !releaseClosedReader {
            condition.wait()
        }
        if input.isEmpty, closed || interrupted { return 0 }
        let count = min(buffer.count, input.count)
        input.copyBytes(to: buffer.bindMemory(to: UInt8.self), count: count)
        input.removeFirst(count)
        return count
    }
    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int {
        condition.withLock {
            output.append(buffer.bindMemory(to: UInt8.self))
            while output.count >= FrameHeader.encodedLength {
                guard let header = try? FrameHeader(decoding: output.prefix(FrameHeader.encodedLength)) else { break }
                let length = FrameHeader.encodedLength + Int(header.payloadLength)
                guard output.count >= length else { break }
                let payloadStart = output.index(
                    output.startIndex,
                    offsetBy: FrameHeader.encodedLength
                )
                let payloadEnd = output.index(output.startIndex, offsetBy: length)
                if let frame = try? Frame(
                    header: header,
                    payload: output.subdata(in: payloadStart..<payloadEnd)
                ) {
                    frames.append(frame)
                }
                output = Data(output.dropFirst(length))
            }
            condition.broadcast()
        }
        return buffer.count
    }
    func markDescriptorReused() {
        condition.withLock { descriptorReused = true }
    }
    func releaseClosedRead() {
        condition.withLock {
            releaseClosedReader = true
            condition.broadcast()
        }
    }
    func interruptHostDataPlaneDescriptor(_ descriptor: Int32) {
        condition.withLock {
            interrupts += 1
            if !holdInterruptedRead { interrupted = true }
            condition.broadcast()
        }
    }
    func releaseInterruptedRead() {
        condition.withLock {
            interrupted = true
            condition.broadcast()
        }
    }
}

private final class BlockingHostDataPlaneTicketProxy: NSObject, HostXPCProtocol, @unchecked Sendable {
    private let condition = NSCondition()
    private var issues = 0
    private var pendingReplies: [((Data?, NSError?) -> Void)] = []

    var issueCount: Int { condition.withLock { issues } }

    func waitForIssueAttempt() async throws {
        try await eventually { self.issueCount > 0 }
    }

    func releaseTicket() {
        let reply = condition.withLock { () -> ((Data?, NSError?) -> Void)? in
            guard !pendingReplies.isEmpty else { return nil }
            return pendingReplies.removeFirst()
        }
        var response = CPHostDataPlaneTicketResponse()
        response.socketPath = "/private/tmp/cockpit-test.sock"
        response.ticket = String(repeating: "A", count: 43)
        response.validForMilliseconds = 30_000
        reply?(try? response.serializedData(), nil)
    }

    func releaseTickets() {
        while condition.withLock({ !pendingReplies.isEmpty }) { releaseTicket() }
    }

    func issueHostDataPlaneTicket(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        condition.withLock {
            issues += 1
            pendingReplies.append(reply)
            condition.broadcast()
        }
    }

    func exchangeHandshake(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        reply(nil, CocoaError(.coderInvalidValue) as NSError)
    }

    func workspaceCommand(
        _ request: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        reply(nil, CocoaError(.coderInvalidValue) as NSError)
    }
}

private final class FixedHostDataPlaneTicketProxy: NSObject, HostXPCProtocol, @unchecked Sendable {
    private let socketPath: String
    private let ticket: String
    private let lock = NSLock()
    private var issues = 0
    init(socketPath: String = "/private/tmp/cockpit-test.sock", ticket: String = String(repeating: "A", count: 43)) {
        self.socketPath = socketPath
        self.ticket = ticket
    }
    var issueCount: Int { lock.withLock { issues } }
    func issueHostDataPlaneTicket(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        lock.withLock { issues += 1 }
        var response = CPHostDataPlaneTicketResponse()
        response.socketPath = socketPath
        response.ticket = ticket
        response.validForMilliseconds = 30_000
        reply(try? response.serializedData(), nil)
    }
    func exchangeHandshake(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, CocoaError(.coderInvalidValue) as NSError)
    }
    func workspaceCommand(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        reply(nil, CocoaError(.coderInvalidValue) as NSError)
    }
}

private final class SwitchingHostDataPlaneTicketProxy: NSObject, HostXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var export: HostXPCExport
    private var issues = 0
    private var successfulIssues = 0
    init(export: HostXPCExport) { self.export = export }
    var issueCount: Int { lock.withLock { issues } }
    var successfulIssueCount: Int { lock.withLock { successfulIssues } }
    func replaceExport(_ export: HostXPCExport) { lock.withLock { self.export = export } }
    func issueHostDataPlaneTicket(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        let current = lock.withLock { () -> HostXPCExport in
            issues += 1
            return export
        }
        current.issueHostDataPlaneTicket(request) { [weak self] data, error in
            if data != nil, error == nil {
                self?.lock.withLock { self?.successfulIssues += 1 }
            }
            reply(data, error)
        }
    }
    func exchangeHandshake(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        lock.withLock { export }.exchangeHandshake(request, withReply: reply)
    }
    func workspaceCommand(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        lock.withLock { export }.workspaceCommand(request, withReply: reply)
    }
}

private struct ScriptedHostDataPlaneClientHarness: Sendable {
    let calls: ScriptedHostDataPlaneClientSocketCalls
    let proxy: FixedHostDataPlaneTicketProxy
    let client: HostDataPlaneClient

    static func make(fixture: HostDataPlaneFixture) async throws -> Self {
        let calls = ScriptedHostDataPlaneClientSocketCalls()
        let proxy = FixedHostDataPlaneTicketProxy()
        var handshake = CPHandshakeResponse()
        handshake.protocolMajor = 1
        handshake.protocolMinor = 1
        handshake.connectionID = ConnectionID(uuid(24)).description
        handshake.acceptedFeatures = [ProtocolFeature.hostDataPlane.rawValue]
        handshake.serviceKind = "host-data-plane"
        var handshakeEnvelope = CPHostDataPlaneControlEnvelope()
        handshakeEnvelope.handshakeResponse = handshake
        calls.enqueue(try hostDataPlaneTestFrame(.control, 1, 1, handshakeEnvelope.serializedData()))
        var authenticated = CPHostDataPlaneAuthenticated()
        authenticated.binding = try HostDataPlaneMessages.encode(fixture.binding)
        var authenticatedEnvelope = CPHostDataPlaneControlEnvelope()
        authenticatedEnvelope.authenticated = authenticated
        calls.enqueue(try hostDataPlaneTestFrame(.control, 2, 2, authenticatedEnvelope.serializedData()))
        let xpc = HostXPCClient(connectionFactory: { _ in HostDataPlaneXPCConnection(proxy: proxy) })
        let client = HostDataPlaneClient(binding: fixture.binding, xpcClient: xpc, systemCalls: calls)
        try await client.connect()
        return Self(calls: calls, proxy: proxy, client: client)
    }
}

private struct ScriptedHostDataPlaneTreeHarness: Sendable {
    let calls: ScriptedHostDataPlaneClientSocketCalls
    let client: HostDataPlaneClient

    init(fixture: HostDataPlaneFixture) throws {
        let calls = ScriptedHostDataPlaneClientSocketCalls()
        var handshake = CPHandshakeResponse()
        handshake.protocolMajor = 1
        handshake.protocolMinor = 1
        handshake.connectionID = ConnectionID(uuid(24)).description
        handshake.acceptedFeatures = [ProtocolFeature.hostDataPlane.rawValue]
        handshake.serviceKind = "host-data-plane"
        var handshakeEnvelope = CPHostDataPlaneControlEnvelope()
        handshakeEnvelope.handshakeResponse = handshake
        calls.enqueue(try hostDataPlaneTestFrame(
            .control,
            1,
            1,
            handshakeEnvelope.serializedData()
        ))
        var authenticated = CPHostDataPlaneAuthenticated()
        authenticated.binding = try HostDataPlaneMessages.encode(fixture.binding)
        var authenticatedEnvelope = CPHostDataPlaneControlEnvelope()
        authenticatedEnvelope.authenticated = authenticated
        calls.enqueue(try hostDataPlaneTestFrame(
            .control,
            2,
            2,
            authenticatedEnvelope.serializedData()
        ))
        let proxy = FixedHostDataPlaneTicketProxy()
        let xpc = HostXPCClient(connectionFactory: { _ in
            HostDataPlaneXPCConnection(proxy: proxy)
        })
        self.calls = calls
        client = HostDataPlaneClient(
            binding: fixture.binding,
            xpcClient: xpc,
            systemCalls: calls
        )
    }
}

private func documentEnvelope(_ frame: Frame) throws -> CPDocumentEnvelope {
    guard case let .document(value) = try HostDataPlaneMessages.decodeEnvelope(frame) else {
        throw ProtocolMappingError.invalidValue("document_envelope")
    }
    return value
}

private func fileTreeEnvelope(_ frame: Frame) throws -> CPFileTreeEnvelope {
    guard case let .fileTree(value) = try HostDataPlaneMessages.decodeEnvelope(frame) else {
        throw ProtocolMappingError.invalidValue("file_tree_envelope")
    }
    return value
}

private func fileTreeSubscribeEnvelope(
    requestID: String,
    binding: HostDataPlaneBinding,
    after: UInt64
) throws -> CPFileTreeEnvelope {
    var request = CPFileTreeSubscribeRequest()
    request.afterRevision = after
    var envelope = CPFileTreeEnvelope()
    envelope.requestID = requestID
    envelope.binding = try HostDataPlaneMessages.encode(binding)
    envelope.subscribeRequest = request
    return envelope
}

private func documentSnapshotFrame(
    requestID: String,
    binding: HostDataPlaneBinding,
    snapshot: DocumentSnapshot,
    sequence: UInt64 = 1,
    acknowledgement: UInt64 = 1
) throws -> Frame {
    var envelope = CPDocumentEnvelope()
    envelope.requestID = requestID
    envelope.binding = try HostDataPlaneMessages.encode(binding)
    envelope.snapshotResult = try HostDataPlaneMessages.encode(snapshot)
    return try hostDataPlaneTestFrame(.documentEdits, sequence, acknowledgement, envelope.serializedData())
}

private func documentLeaseFrame(
    requestID: String,
    binding: HostDataPlaneBinding,
    lease: EditLease
) throws -> Frame {
    var envelope = CPDocumentEnvelope()
    envelope.requestID = requestID
    envelope.binding = try HostDataPlaneMessages.encode(binding)
    envelope.leaseResult = try HostDataPlaneMessages.encode(lease)
    return try hostDataPlaneTestFrame(.documentEdits, 1, 1, envelope.serializedData())
}

private func documentAcknowledgementFrame(
    requestID: String,
    binding: HostDataPlaneBinding,
    acknowledgementValue: EditAcknowledgement
) throws -> Frame {
    var envelope = CPDocumentEnvelope()
    envelope.requestID = requestID
    envelope.binding = try HostDataPlaneMessages.encode(binding)
    envelope.acknowledgementResult = try HostDataPlaneMessages.encode(acknowledgementValue)
    return try hostDataPlaneTestFrame(.documentEdits, 1, 1, envelope.serializedData())
}

private func documentErrorFrame(
    requestID: String,
    binding: HostDataPlaneBinding,
    error: CPDataPlaneError
) throws -> Frame {
    var envelope = CPDocumentEnvelope()
    envelope.requestID = requestID
    envelope.binding = try HostDataPlaneMessages.encode(binding)
    envelope.error = error
    return try hostDataPlaneTestFrame(.documentEdits, 1, 1, envelope.serializedData())
}

private func fileTreeSnapshotFrame(
    requestID: String,
    binding: HostDataPlaneBinding,
    snapshot: FileTreeSnapshot,
    sequence: UInt64 = 1,
    acknowledgement: UInt64 = 1
) throws -> Frame {
    var envelope = CPFileTreeEnvelope()
    envelope.requestID = requestID
    envelope.binding = try HostDataPlaneMessages.encode(binding)
    envelope.snapshotResult = try HostDataPlaneMessages.encode(snapshot)
    return try hostDataPlaneTestFrame(
        .fileTreeEvents,
        sequence,
        acknowledgement,
        envelope.serializedData()
    )
}

private func fileTreeSubscriptionAcceptedFrame(
    requestID: String,
    binding: HostDataPlaneBinding,
    revision: UInt64,
    sequence: UInt64 = 1,
    acknowledgement: UInt64 = 1
) throws -> Frame {
    var accepted = CPFileTreeSubscriptionAccepted()
    accepted.subscriptionID = requestID
    accepted.revision = revision
    var envelope = CPFileTreeEnvelope()
    envelope.requestID = requestID
    envelope.binding = try HostDataPlaneMessages.encode(binding)
    envelope.subscriptionAccepted = accepted
    return try hostDataPlaneTestFrame(
        .fileTreeEvents,
        sequence,
        acknowledgement,
        envelope.serializedData()
    )
}

private func fileTreeDeltaFrame(
    requestID: String,
    eventID: String? = nil,
    subscriptionID: String,
    binding: HostDataPlaneBinding,
    delta: FileTreeDelta,
    sequence: UInt64,
    acknowledgement: UInt64
) throws -> Frame {
    var event = CPFileTreeDeltaEvent()
    event.subscriptionID = subscriptionID
    event.eventID = eventID ?? requestID
    event.delta = try HostDataPlaneMessages.encode(delta)
    var envelope = CPFileTreeEnvelope()
    envelope.requestID = requestID
    envelope.binding = try HostDataPlaneMessages.encode(binding)
    envelope.deltaEvent = event
    return try hostDataPlaneTestFrame(
        .fileTreeEvents,
        sequence,
        acknowledgement,
        envelope.serializedData()
    )
}

private func fileTreeAckAcceptedFrame(
    requestID: String,
    subscriptionID: String,
    eventID: String,
    revision: UInt64,
    binding: HostDataPlaneBinding,
    sequence: UInt64,
    acknowledgement: UInt64
) throws -> Frame {
    var accepted = CPFileTreeAckAccepted()
    accepted.subscriptionID = subscriptionID
    accepted.eventID = eventID
    accepted.revision = revision
    var envelope = CPFileTreeEnvelope()
    envelope.requestID = requestID
    envelope.binding = try HostDataPlaneMessages.encode(binding)
    envelope.ackAccepted = accepted
    return try hostDataPlaneTestFrame(
        .fileTreeEvents,
        sequence,
        acknowledgement,
        envelope.serializedData()
    )
}

private func fileTreeCancelledFrame(
    requestID: String,
    subscriptionID: String,
    binding: HostDataPlaneBinding,
    sequence: UInt64,
    acknowledgement: UInt64
) throws -> Frame {
    var cancelled = CPFileTreeCancelled()
    cancelled.subscriptionID = subscriptionID
    var envelope = CPFileTreeEnvelope()
    envelope.requestID = requestID
    envelope.binding = try HostDataPlaneMessages.encode(binding)
    envelope.cancelled = cancelled
    return try hostDataPlaneTestFrame(
        .fileTreeEvents,
        sequence,
        acknowledgement,
        envelope.serializedData()
    )
}

private func hostDataPlaneTestFrame(
    _ channel: ChannelID,
    _ sequence: UInt64,
    _ acknowledgement: UInt64,
    _ payload: Data
) throws -> Frame {
    try Frame(
        header: FrameHeader(
            flags: 0,
            channel: channel,
            sequence: sequence,
            acknowledgement: acknowledgement,
            payloadLength: UInt32(payload.count)
        ),
        payload: payload
    )
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
    func setReceiveBuffer(byteCount: Int32) throws {
        var value = byteCount
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVBUF,
            &value,
            socklen_t(MemoryLayout.size(ofValue: value))
        ) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }
    func fillDocumentRequestsUntilWouldBlock(
        binding: HostDataPlaneBinding,
        documentID: DocumentID
    ) throws -> Int {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        var fullyWritten = 0
        for sequence in 1...100_000 {
            let request = try documentSnapshotRequest(
                binding: binding,
                documentID: documentID,
                requestID: RequestID(),
                sequence: UInt64(sequence),
                acknowledgement: 0
            )
            let completed = try request.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        return false
                    } else {
                        throw POSIXError(.init(rawValue: errno)!)
                    }
                }
                return true
            }
            guard completed else { return fullyWritten }
            fullyWritten += 1
        }
        throw CocoaError(.coderReadCorrupt)
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

private func hostDataPlaneTicket(
    from client: HostXPCClient,
    context: RequestContext,
    timeout: Duration
) async throws -> CPHostDataPlaneTicketResponse {
    try await withThrowingTaskGroup(of: CPHostDataPlaneTicketResponse.self) { group in
        group.addTask {
            try await client.issueHostDataPlaneTicket(context: context)
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw CocoaError(.coderReadCorrupt)
        }
        let response = try await group.next()!
        group.cancelAll()
        return response
    }
}

private struct HostDataPlaneLaunchctlResult {
    let status: Int32
    let output: String
}

private func runHostDataPlaneLaunchctl(
    _ arguments: [String]
) throws -> HostDataPlaneLaunchctlResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return HostDataPlaneLaunchctlResult(
        status: process.terminationStatus,
        output: String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    )
}

private func hostDataPlaneLaunchctlPID(_ output: String) throws -> pid_t {
    let expression = try NSRegularExpression(pattern: #"(?m)^\s*pid = ([0-9]+)$"#)
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    guard let match = expression.firstMatch(in: output, range: range),
          let valueRange = Range(match.range(at: 1), in: output),
          let value = pid_t(output[valueRange]) else {
        throw CocoaError(.coderReadCorrupt)
    }
    return value
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
    let candidate = repository
        .appendingPathComponent(".build/debug", isDirectory: true)
        .appendingPathComponent("CockpitHost")
    guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
        throw CocoaError(.fileNoSuchFile)
    }
    return candidate
}

private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

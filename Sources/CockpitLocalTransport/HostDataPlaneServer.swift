import Darwin
import Foundation
import CockpitHostCore
import CockpitProtocol
import CockpitTypes

struct HostDataPlaneSubscriptionLivenessState: Sendable {
    private var accepting = true
    private var liveSubscriptions: Set<String> = []

    mutating func register(_ subscriptionID: String) -> Bool {
        guard accepting else { return false }
        return liveSubscriptions.insert(subscriptionID).inserted
    }

    mutating func cancel(_ subscriptionID: String) {
        liveSubscriptions.remove(subscriptionID)
    }

    func admitsWaiter(for subscriptionID: String, taskIsCancelled: Bool) -> Bool {
        accepting && !taskIsCancelled && liveSubscriptions.contains(subscriptionID)
    }

    mutating func stop() {
        accepting = false
        liveSubscriptions.removeAll()
    }
}

public final class HostDataPlaneServer: @unchecked Sendable {
    private enum State {
        case idle
        case ready(listener: HostDataPlaneDescriptorOwner, path: String, identity: UnixSocketPathStatus)
        case stopped
    }

    private let namespace: String
    private let service: any HostDataPlaneServing
    private let ticketStore: HostDataPlaneTicketStore
    private let systemCalls: any UnixDomainSocketSystemCalls
    private let peerCredentials: any PeerCredentialReading
    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "dev.cockpit.host-data-plane.accept")
    private var state: State = .idle
    private var connections: [UUID: HostDataPlaneServerConnection] = [:]
    private let workers = DispatchGroup()

    public init(
        namespace: String,
        service: any HostDataPlaneServing,
        ticketStore: HostDataPlaneTicketStore,
        systemCalls: any UnixDomainSocketSystemCalls,
        peerCredentials: any PeerCredentialReading
    ) {
        self.namespace = namespace
        self.service = service
        self.ticketStore = ticketStore
        self.systemCalls = systemCalls
        self.peerCredentials = peerCredentials
    }

    public convenience init(
        namespace: String = "default",
        service: any HostDataPlaneServing,
        ticketStore: HostDataPlaneTicketStore
    ) {
        self.init(
            namespace: namespace,
            service: service,
            ticketStore: ticketStore,
            systemCalls: DarwinUnixDomainSocketSystemCalls(),
            peerCredentials: DarwinPeerCredentialReader()
        )
    }

    public func start() async throws {
        guard namespace.range(of: #"^[a-z0-9][a-z0-9._-]{0,31}$"#, options: .regularExpression) != nil else {
            throw UnixDomainSocketError.invalidNamespace
        }
        guard lock.withLock({ if case .idle = state { return true }; return false }) else {
            throw UnixDomainSocketError.serverAlreadyRunning
        }
        let uid = systemCalls.effectiveUserID()
        let root = "/private/tmp/cockpit.\(uid)"
        let host = root + "/host"
        let directory = host + "/\(namespace)"
        let path = directory + "/host.sock"
        _ = try UnixDomainSocketAddress(path: path)
        for component in [root, host, directory] {
            var status = try systemCalls.pathStatus(component)
            if status == nil {
                do {
                    try systemCalls.makeDirectory(component, permissions: 0o700)
                } catch let error as UnixDomainSocketError {
                    guard case let .systemCall(function, value) = error,
                          function == "mkdir", value == EEXIST
                    else { throw error }
                }
                status = try systemCalls.pathStatus(component)
            }
            guard let status,
                  status.kind == .directory,
                  status.owner == uid,
                  status.permissions == 0o700
            else { throw UnixDomainSocketError.unsafeDirectory }
        }
        if let existing = try systemCalls.pathStatus(path) {
            guard existing.kind == .socket,
                  existing.owner == uid,
                  existing.permissions == 0o600
            else { throw UnixDomainSocketError.unsafeSocket }
            let probe = try systemCalls.createStreamSocket()
            defer { systemCalls.close(probe) }
            try systemCalls.setCloseOnExec(probe)
            try systemCalls.setNoSigPipe(probe)
            let connectFailure: Int32
            do {
                try systemCalls.connect(probe, to: UnixDomainSocketAddress(path: path))
                throw UnixDomainSocketError.serverAlreadyRunning
            } catch let error as UnixDomainSocketError {
                guard case let .systemCall(function, value) = error,
                      function == "connect", value == ECONNREFUSED || value == ENOENT
                else { throw error }
                connectFailure = value
            }
            let rechecked = try systemCalls.pathStatus(path)
            if rechecked == nil, connectFailure == ECONNREFUSED || connectFailure == ENOENT {
                // Nothing remains to unlink; bind below still fails if the path reappears.
            } else if rechecked == existing {
                try systemCalls.unlink(path)
            } else {
                throw UnixDomainSocketError.staleSocketRace
            }
        }

        let descriptor = try systemCalls.createStreamSocket()
        var cleanupIdentity: UnixSocketPathStatus?
        do {
            try systemCalls.setCloseOnExec(descriptor)
            try systemCalls.setNoSigPipe(descriptor)
            try systemCalls.bind(descriptor, to: UnixDomainSocketAddress(path: path))
            if let status = try systemCalls.pathStatus(path),
               status.kind == .socket,
               status.owner == uid {
                cleanupIdentity = status
            }
            try systemCalls.setPermissions(path, permissions: 0o600)
            guard let identity = try systemCalls.pathStatus(path),
                  identity.kind == .socket,
                  identity.owner == uid,
                  identity.permissions == 0o600,
                  cleanupIdentity?.device == identity.device,
                  cleanupIdentity?.inode == identity.inode
            else { throw UnixDomainSocketError.permissionMismatch }
            cleanupIdentity = identity
            try systemCalls.listen(descriptor, backlog: 32)
            let listener = HostDataPlaneDescriptorOwner(descriptor, calls: systemCalls)
            lock.withLock { state = .ready(listener: listener, path: path, identity: identity) }
        } catch {
            systemCalls.close(descriptor)
            if let cleanupIdentity,
               let current = try? systemCalls.pathStatus(path),
               current.kind == .socket,
               current.owner == uid,
               current.device == cleanupIdentity.device,
               current.inode == cleanupIdentity.inode {
                try? systemCalls.unlink(path)
            }
            throw error
        }
        workers.enter()
        acceptQueue.async { [weak self] in
            defer { self?.workers.leave() }
            self?.acceptLoop(descriptor: descriptor, uid: uid)
        }
    }

    public func waitUntilReady() async throws {
        guard lock.withLock({ if case .ready = state { return true }; return false }) else {
            throw HostDataPlaneTicketIssueError.serverNotReady
        }
    }

    func readySocketPath() async throws -> String {
        try await waitUntilReady()
        return try lock.withLock {
            guard case let .ready(_, path, _) = state else {
                throw HostDataPlaneTicketIssueError.serverNotReady
            }
            return path
        }
    }

    public func shutdown() async {
        let snapshot = lock.withLock { () -> (HostDataPlaneDescriptorOwner, String, UnixSocketPathStatus, [HostDataPlaneServerConnection])? in
            guard case let .ready(listener, path, identity) = state else {
                state = .stopped
                return nil
            }
            state = .stopped
            let clients = Array(connections.values)
            connections.removeAll()
            return (listener, path, identity, clients)
        }
        guard let snapshot else { return }
        wakeAcceptLoop(path: snapshot.1)
        for client in snapshot.3 { client.beginShutdownClose() }
        for client in snapshot.3 { await client.cancelSubscriptionsForShutdown() }
        await withCheckedContinuation { continuation in
            workers.notify(queue: .global()) { continuation.resume() }
        }
        snapshot.0.close()
        if let current = try? systemCalls.pathStatus(snapshot.1), current == snapshot.2 {
            try? systemCalls.unlink(snapshot.1)
        }
    }

    private func wakeAcceptLoop(path: String) {
        guard let descriptor = try? systemCalls.createStreamSocket() else { return }
        defer { systemCalls.close(descriptor) }
        try? systemCalls.setCloseOnExec(descriptor)
        try? systemCalls.setNoSigPipe(descriptor)
        try? systemCalls.connect(descriptor, to: UnixDomainSocketAddress(path: path))
    }

    private func acceptLoop(descriptor: Int32, uid: uid_t) {
        while true {
            let accepted: Int32
            do { accepted = try systemCalls.accept(descriptor) }
            catch { return }
            guard lock.withLock({
                if case .ready = state { return true }
                return false
            }) else {
                systemCalls.close(accepted)
                return
            }
            do {
                try systemCalls.setCloseOnExec(accepted)
                try systemCalls.setNoSigPipe(accepted)
                let credentials = try peerCredentials.peerCredentials(for: accepted)
                guard credentials.uid == uid else {
                    systemCalls.close(accepted)
                    continue
                }
            } catch {
                systemCalls.close(accepted)
                continue
            }
            let id = UUID()
            let connection = HostDataPlaneServerConnection(
                descriptor: accepted,
                systemCalls: systemCalls,
                service: service,
                ticketStore: ticketStore,
                peerUID: uid
            )
            let retained = lock.withLock { () -> Bool in
                guard case .ready = state else { return false }
                connections[id] = connection
                workers.enter()
                return true
            }
            guard retained else {
                connection.closeAfterWorkerExit()
                return
            }
            Task.detached { [self] in
                defer {
                    connection.closeAfterWorkerExit()
                    self.lock.withLock { _ = self.connections.removeValue(forKey: id) }
                    self.workers.leave()
                }
                await connection.run()
            }
        }
    }
}

private final class HostDataPlaneServerConnection: @unchecked Sendable {
    private struct ChannelState {
        var expectedIncoming: UInt64 = 1
        var lastOutgoing: UInt64 = 0
        var lastAcknowledged: UInt64 = 0
        var lastOutgoingAcknowledgement: UInt64 = 0
    }
    private let descriptorOwner: HostDataPlaneDescriptorOwner
    private let calls: any UnixDomainSocketSystemCalls
    private let service: any HostDataPlaneServing
    private let ticketStore: HostDataPlaneTicketStore
    private let peerUID: uid_t
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let readQueue = DispatchQueue(label: "dev.cockpit.host-data-plane.server-read")
    private var channels: [UInt32: ChannelState] = [:]
    private var binding: HostDataPlaneBinding?
    private var requestIDs: Set<String> = []
    private var shuttingDown = false
    private var subscriptionTasks: [String: Task<Void, Never>] = [:]
    private var subscriptionLiveness = HostDataPlaneSubscriptionLivenessState()
    private struct AcknowledgementWaiter {
        let subscriptionID: String
        let revision: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var acknowledgementWaiters: [String: AcknowledgementWaiter] = [:]

    init(descriptor: Int32, systemCalls: any UnixDomainSocketSystemCalls, service: any HostDataPlaneServing, ticketStore: HostDataPlaneTicketStore, peerUID: uid_t) {
        descriptorOwner = HostDataPlaneDescriptorOwner(descriptor, calls: systemCalls)
        calls = systemCalls; self.service = service; self.ticketStore = ticketStore; self.peerUID = peerUID
    }

    func beginShutdownClose() {
        lock.withLock { shuttingDown = true }
        descriptorOwner.interrupt()
    }

    func cancelSubscriptionsForShutdown() async {
        for task in cancelSubscriptions() {
            await task.value
        }
    }

    func closeAfterWorkerExit() { descriptorOwner.close() }

    func run() async {
        defer {
            if !lock.withLock({ shuttingDown }) { _ = cancelSubscriptions() }
        }
        do {
            let handshake: Frame
            do {
                handshake = try await readServerFrameAsync(calls, descriptorOwner, queue: readQueue)
            } catch is HostDataPlaneMalformedFrameError {
                try? sendControlError(.malformedMessage)
                return
            }
            guard handshake.header.channel == .control else {
                try sendControlError(.wrongChannel)
                return
            }
            guard handshake.header.flags == 0 else {
                try sendControlError(.malformedMessage)
                return
            }
            guard handshake.header.sequence == 1 else {
                try sendControlError(.sequenceViolation)
                return
            }
            guard handshake.header.acknowledgement == 0 else {
                try sendControlError(.ackViolation)
                return
            }
            let control: CPHostDataPlaneControlEnvelope
            do {
                guard case let .control(value) = try HostDataPlaneMessages.decodeEnvelope(handshake) else {
                    throw HostDataPlaneServerProtocolError(.malformedMessage)
                }
                control = value
            } catch {
                try sendControlError(.malformedMessage)
                return
            }
            guard case .handshakeRequest? = control.payload else {
                try sendControlError(.malformedMessage)
                return
            }
            var response = CPHandshakeResponse()
            response.protocolMajor = 1; response.protocolMinor = 1
            response.connectionID = ConnectionID().description
            response.acceptedFeatures = [ProtocolFeature.hostDataPlane.rawValue]
            response.serviceKind = "host-data-plane"
            var envelope = CPHostDataPlaneControlEnvelope(); envelope.handshakeResponse = response
            try send(channel: .control, acknowledgement: 1, payload: envelope.serializedData())

            let authentication: Frame
            do {
                authentication = try await readServerFrameAsync(calls, descriptorOwner, queue: readQueue)
            } catch is HostDataPlaneMalformedFrameError {
                try? sendControlError(.malformedMessage, acknowledgement: 1)
                return
            }
            guard authentication.header.channel == .control else {
                try sendControlError(.wrongChannel, acknowledgement: 1)
                return
            }
            guard authentication.header.flags == 0 else {
                try sendControlError(.malformedMessage, acknowledgement: 1)
                return
            }
            guard authentication.header.sequence == 2 else {
                try sendControlError(.sequenceViolation, acknowledgement: 1)
                return
            }
            guard authentication.header.acknowledgement == 1 else {
                try sendControlError(.ackViolation, acknowledgement: 1)
                return
            }
            let authEnvelope: CPHostDataPlaneControlEnvelope
            do {
                guard case let .control(value) = try HostDataPlaneMessages.decodeEnvelope(authentication) else {
                    throw HostDataPlaneServerProtocolError(.malformedMessage)
                }
                authEnvelope = value
            } catch {
                try sendControlError(.malformedMessage, acknowledgement: 1)
                return
            }
            guard case let .authenticate(auth)? = authEnvelope.payload else {
                try sendControlError(.malformedMessage, acknowledgement: 1)
                return
            }
            let suppliedBinding = try HostDataPlaneMessages.decode(auth.binding)
            do {
                binding = try await ticketStore.consume(wireValue: auth.ticket, binding: suppliedBinding, peerUID: peerUID)
            } catch {
                let code: CPDataPlaneErrorCode
                switch error {
                case HostDataPlaneTicketError.expired: code = .ticketExpired
                case HostDataPlaneTicketError.replay: code = .ticketReplay
                case HostDataPlaneTicketError.bindingMismatch:
                    if let issued = await ticketStore.binding(forCanonicalWireValue: auth.ticket) {
                        if issued.workspaceContextID != suppliedBinding.workspaceContextID { code = .contextMismatch }
                        else if issued.environmentID != suppliedBinding.environmentID { code = .environmentMismatch }
                        else if issued.activeContextGeneration != suppliedBinding.activeContextGeneration {
                            try sendControlError(
                                .generationMismatch,
                                expected: issued.activeContextGeneration,
                                actual: suppliedBinding.activeContextGeneration,
                                acknowledgement: 2
                            )
                            return
                        }
                        else { code = .invalidTicket }
                    } else { code = .invalidTicket }
                default: code = .invalidTicket
                }
                try sendControlError(code, acknowledgement: 2)
                return
            }
            var accepted = CPHostDataPlaneAuthenticated(); accepted.binding = try HostDataPlaneMessages.encode(suppliedBinding)
            var acceptedEnvelope = CPHostDataPlaneControlEnvelope(); acceptedEnvelope.authenticated = accepted
            try send(channel: .control, acknowledgement: 2, payload: acceptedEnvelope.serializedData())

            while true {
                let frame: Frame
                do {
                    frame = try await readServerFrameAsync(calls, descriptorOwner, queue: readQueue)
                } catch let error as HostDataPlaneMalformedFrameError {
                    if let channel = error.channel,
                       channel == .documentEdits || channel == .fileTreeEvents {
                        let acknowledgement = lock.withLock {
                            (channels[channel.rawValue]?.expectedIncoming ?? 1) - 1
                        }
                        try? sendError(
                            .malformedMessage,
                            channel: channel,
                            requestID: nil,
                            acknowledgement: acknowledgement
                        )
                    } else {
                        try? sendControlError(.malformedMessage, acknowledgement: 2)
                    }
                    return
                }
                guard frame.header.channel == .documentEdits || frame.header.channel == .fileTreeEvents else {
                    try sendControlError(.wrongChannel, acknowledgement: 2)
                    return
                }
                let channelSnapshot = lock.withLock {
                    channels[frame.header.channel.rawValue] ?? ChannelState()
                }
                guard frame.header.flags == 0 else {
                    try sendError(
                        .malformedMessage,
                        channel: frame.header.channel,
                        requestID: nil,
                        acknowledgement: channelSnapshot.expectedIncoming - 1
                    )
                    return
                }
                let headerError: (CPDataPlaneErrorCode, UInt64)? = {
                    let channel = channelSnapshot
                    guard frame.header.sequence == channel.expectedIncoming else {
                        return (.sequenceViolation, channel.expectedIncoming - 1)
                    }
                    guard frame.header.acknowledgement >= channel.lastAcknowledged,
                          frame.header.acknowledgement <= channel.lastOutgoing else {
                        return (.ackViolation, channel.expectedIncoming - 1)
                    }
                    return nil
                }()
                if let headerError {
                    try sendError(
                        headerError.0,
                        channel: frame.header.channel,
                        requestID: nil,
                        acknowledgement: headerError.1
                    )
                    return
                }
                let decoded: HostDataPlaneDecodedEnvelope
                do {
                    decoded = try HostDataPlaneMessages.decodeEnvelope(frame)
                } catch {
                    try sendError(
                        .malformedMessage,
                        channel: frame.header.channel,
                        requestID: nil,
                        acknowledgement: channelSnapshot.expectedIncoming - 1
                    )
                    return
                }
                try lock.withLock {
                    var channel = channels[frame.header.channel.rawValue] ?? ChannelState()
                    guard case let .value(next) = hostDataPlaneAdvanceSequence(channel.expectedIncoming) else {
                        throw HostDataPlaneServerProtocolError(.sequenceViolation)
                    }
                    channel.expectedIncoming = next
                    channel.lastAcknowledged = frame.header.acknowledgement
                    channels[frame.header.channel.rawValue] = channel
                }
                switch decoded {
                case let .document(envelope): try await processDocument(envelope, incomingSequence: frame.header.sequence)
                case let .fileTree(envelope): try await processTree(envelope, incomingSequence: frame.header.sequence)
                case .control:
                    try sendControlError(.wrongChannel, acknowledgement: 2)
                    return
                }
            }
        } catch {}
    }

    private func validate(_ supplied: CPDataPlaneBinding) throws -> HostDataPlaneBinding {
        let decoded = try HostDataPlaneMessages.decode(supplied)
        guard let binding else { throw HostDataPlaneServerProtocolError(.unauthorizedPeer) }
        guard decoded == binding else {
            if decoded.workspaceContextID != binding.workspaceContextID { throw HostDataPlaneServerProtocolError(.contextMismatch) }
            if decoded.environmentID != binding.environmentID { throw HostDataPlaneServerProtocolError(.environmentMismatch) }
            if decoded.activeContextGeneration != binding.activeContextGeneration { throw HostDataPlaneServerProtocolError(.generationMismatch) }
            throw HostDataPlaneServerProtocolError(.invalidTicket)
        }
        return binding
    }

    private func reserve(_ requestID: String) -> Bool { lock.withLock { requestIDs.insert(requestID).inserted } }

    private func processDocument(_ envelope: CPDocumentEnvelope, incomingSequence: UInt64) async throws {
        guard reserve(envelope.requestID) else { try sendDocumentError(.requestIDReuse, requestID: envelope.requestID, acknowledgement: incomingSequence); return }
        do {
            let binding = try validate(envelope.binding)
            var response = CPDocumentEnvelope(); response.requestID = envelope.requestID; response.binding = envelope.binding
            switch envelope.payload {
            case let .openRequest(value): response.snapshotResult = try HostDataPlaneMessages.encode(try await service.openDocument(binding: binding, at: RelativePath(value.relativePath)))
            case let .snapshotRequest(value): response.snapshotResult = try HostDataPlaneMessages.encode(try await service.snapshot(binding: binding, documentID: decodeID(value.documentID)))
            case let .acquireLeaseRequest(value): response.leaseResult = try HostDataPlaneMessages.encode(try await service.acquireEditLease(binding: binding, documentID: decodeID(value.documentID)))
            case let .transferLeaseRequest(value): response.leaseResult = try HostDataPlaneMessages.encode(try await service.transferEditLease(binding: binding, documentID: decodeID(value.documentID), from: decodeID(value.fromEditLeaseID), to: decodeID(value.targetClientInstanceID)))
            case let .applyRequest(value): response.acknowledgementResult = try HostDataPlaneMessages.encode(try await service.apply(binding: binding, transaction: HostDataPlaneMessages.decode(value)))
            case let .flushRequest(value): var result = CPDocumentFlushResult(); result.documentVersion = try await service.flush(binding: binding, documentID: decodeID(value.documentID), through: value.throughClientSequence); response.flushResult = result
            case let .saveRequest(value): response.snapshotResult = try HostDataPlaneMessages.encode(try await service.save(binding: binding, documentID: decodeID(value.documentID), expectedFingerprint: HostDataPlaneMessages.decode(value.expectedFingerprint)))
            case let .discardRequest(value): response.snapshotResult = try HostDataPlaneMessages.encode(try await service.discard(binding: binding, documentID: decodeID(value.documentID)))
            default: throw HostDataPlaneServerProtocolError(.malformedMessage)
            }
            try send(channel: .documentEdits, acknowledgement: incomingSequence, payload: response.serializedData())
        } catch {
            try sendDocumentError(map(error), requestID: envelope.requestID, acknowledgement: incomingSequence, source: error)
        }
    }

    private func processTree(_ envelope: CPFileTreeEnvelope, incomingSequence: UInt64) async throws {
        do {
            let binding = try validate(envelope.binding)
            switch envelope.payload {
            case let .childrenRequest(value):
                guard reserve(envelope.requestID) else { throw HostDataPlaneServerProtocolError(.requestIDReuse) }
                var response = CPFileTreeEnvelope(); response.requestID = envelope.requestID; response.binding = envelope.binding
                response.snapshotResult = try HostDataPlaneMessages.encode(try await service.fileTreeChildren(binding: binding, at: HostDataPlaneMessages.decode(value.directory)))
                try send(channel: .fileTreeEvents, acknowledgement: incomingSequence, payload: response.serializedData())
            case let .subscribeRequest(value):
                guard reserve(envelope.requestID) else { throw HostDataPlaneServerProtocolError(.requestIDReuse) }
                let subscriptionID = envelope.requestID
                var accepted = CPFileTreeSubscriptionAccepted(); accepted.subscriptionID = subscriptionID; accepted.revision = value.afterRevision
                var response = CPFileTreeEnvelope(); response.requestID = envelope.requestID; response.binding = envelope.binding; response.subscriptionAccepted = accepted
                try send(channel: .fileTreeEvents, acknowledgement: incomingSequence, payload: response.serializedData())
                lock.withLock {
                    guard !shuttingDown, subscriptionLiveness.register(subscriptionID) else { return }
                    subscriptionTasks[subscriptionID] = Task { [weak self] in
                        guard let self else { return }
                        await self.streamTree(binding: binding, bindingMessage: envelope.binding, subscriptionID: subscriptionID, after: value.afterRevision)
                    }
                }
            case let .deltaAck(value):
                guard reserve(envelope.requestID) else { throw HostDataPlaneServerProtocolError(.requestIDReuse) }
                let waiter = lock.withLock { () -> AcknowledgementWaiter? in
                    let byEvent = acknowledgementWaiters[value.eventID]
                    guard let waiter = byEvent,
                          waiter.subscriptionID == value.subscriptionID,
                          waiter.revision == value.revision
                    else { return nil }
                    return acknowledgementWaiters.removeValue(forKey: value.eventID)
                }
                guard let waiter else {
                    cancelSubscription(value.subscriptionID)
                    throw HostDataPlaneServerProtocolError(.treeBackpressure)
                }
                waiter.continuation.resume()
                var ack = CPFileTreeAckAccepted(); ack.subscriptionID = value.subscriptionID; ack.eventID = value.eventID; ack.revision = value.revision
                var response = CPFileTreeEnvelope(); response.requestID = envelope.requestID; response.binding = envelope.binding; response.ackAccepted = ack
                try send(channel: .fileTreeEvents, acknowledgement: incomingSequence, payload: response.serializedData())
            case let .cancelRequest(value):
                guard reserve(envelope.requestID) else { throw HostDataPlaneServerProtocolError(.requestIDReuse) }
                cancelSubscription(value.subscriptionID)
                var cancelled = CPFileTreeCancelled(); cancelled.subscriptionID = value.subscriptionID
                var response = CPFileTreeEnvelope(); response.requestID = envelope.requestID; response.binding = envelope.binding; response.cancelled = cancelled
                try send(channel: .fileTreeEvents, acknowledgement: incomingSequence, payload: response.serializedData())
            default: throw HostDataPlaneServerProtocolError(.malformedMessage)
            }
        } catch {
            try sendTreeError(map(error), requestID: envelope.requestID, binding: envelope.binding, acknowledgement: incomingSequence, source: error)
        }
    }

    private func streamTree(binding: HostDataPlaneBinding, bindingMessage: CPDataPlaneBinding, subscriptionID: String, after: UInt64) async {
        do {
            var iterator = service.fileTreeChanges(binding: binding, after: after).makeAsyncIterator()
            while !Task.isCancelled, let delta = try await iterator.next() {
                let eventID = RequestID().description
                var event = CPFileTreeDeltaEvent(); event.subscriptionID = subscriptionID; event.eventID = eventID; event.delta = try HostDataPlaneMessages.encode(delta)
                var envelope = CPFileTreeEnvelope(); envelope.requestID = eventID; envelope.binding = bindingMessage; envelope.deltaEvent = event
                let acknowledgement = lock.withLock {
                    (channels[ChannelID.fileTreeEvents.rawValue]?.expectedIncoming ?? 1) - 1
                }
                try await withCheckedThrowingContinuation { continuation in
                    let installed = lock.withLock { () -> Bool in
                        guard subscriptionLiveness.admitsWaiter(
                            for: subscriptionID,
                            taskIsCancelled: Task.isCancelled
                        ) else { return false }
                        acknowledgementWaiters[eventID] = AcknowledgementWaiter(
                            subscriptionID: subscriptionID,
                            revision: delta.revision,
                            continuation: continuation
                        )
                        return true
                    }
                    guard installed else {
                        continuation.resume(throwing: HostDataPlaneClientError.requestCancelled)
                        return
                    }
                    do {
                        try send(
                            channel: .fileTreeEvents,
                            acknowledgement: acknowledgement,
                            payload: envelope.serializedData()
                        )
                    } catch {
                        let waiter = lock.withLock {
                            acknowledgementWaiters.removeValue(forKey: eventID)
                        }
                        waiter?.continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            if Task.isCancelled { return }
            let acknowledgement = lock.withLock {
                (channels[ChannelID.fileTreeEvents.rawValue]?.expectedIncoming ?? 1) - 1
            }
            try? sendTreeError(
                map(error),
                requestID: subscriptionID,
                binding: bindingMessage,
                acknowledgement: acknowledgement,
                source: error
            )
        }
        lock.withLock {
            _ = subscriptionTasks.removeValue(forKey: subscriptionID)
            subscriptionLiveness.cancel(subscriptionID)
        }
    }

    private func sendControlError(
        _ code: CPDataPlaneErrorCode,
        expected: UInt64? = nil,
        actual: UInt64? = nil,
        acknowledgement: UInt64 = 0
    ) throws {
        var error = makeError(code)
        if let expected, let actual { error.expected = expected; error.actual = actual }
        var envelope = CPHostDataPlaneControlEnvelope(); envelope.error = error
        try send(
            channel: .control,
            acknowledgement: acknowledgement,
            payload: envelope.serializedData()
        )
    }
    private func sendDocumentError(_ code: CPDataPlaneErrorCode, requestID: String?, acknowledgement: UInt64, source: (any Error)? = nil) throws {
        var envelope = CPDocumentEnvelope(); envelope.requestID = requestID ?? RequestID().description
        if let binding { envelope.binding = try HostDataPlaneMessages.encode(binding) }
        envelope.error = makeError(code, source: source)
        try send(channel: .documentEdits, acknowledgement: acknowledgement, payload: envelope.serializedData())
    }
    private func sendTreeError(_ code: CPDataPlaneErrorCode, requestID: String, binding: CPDataPlaneBinding, acknowledgement: UInt64, source: (any Error)? = nil) throws {
        var envelope = CPFileTreeEnvelope(); envelope.requestID = requestID; envelope.binding = binding; envelope.error = makeError(code, source: source)
        try send(channel: .fileTreeEvents, acknowledgement: acknowledgement, payload: envelope.serializedData())
    }
    private func sendError(_ code: CPDataPlaneErrorCode, channel: ChannelID, requestID: String?, acknowledgement: UInt64) throws {
        if channel == .documentEdits { try sendDocumentError(code, requestID: requestID, acknowledgement: acknowledgement) }
        else if channel == .fileTreeEvents, let binding { try sendTreeError(code, requestID: requestID ?? RequestID().description, binding: HostDataPlaneMessages.encode(binding), acknowledgement: acknowledgement) }
        else { try sendControlError(code) }
    }
    private func send(channel: ChannelID, acknowledgement: UInt64, payload: Data) throws {
        try writeLock.withLock {
            let frameState = try lock.withLock { () -> (UInt64, UInt64) in
                var state = channels[channel.rawValue] ?? ChannelState()
                guard case let .value(sequence) = hostDataPlaneAdvanceSequence(
                    state.lastOutgoing
                ) else {
                    throw HostDataPlaneServerProtocolError(.sequenceViolation)
                }
                state.lastOutgoing = sequence
                state.lastOutgoingAcknowledgement = max(
                    state.lastOutgoingAcknowledgement,
                    acknowledgement
                )
                channels[channel.rawValue] = state
                return (sequence, state.lastOutgoingAcknowledgement)
            }
            try descriptorOwner.withDescriptor { descriptor in
                try writeFrame(
                    calls,
                    descriptor,
                    channel: channel,
                    sequence: frameState.0,
                    acknowledgement: frameState.1,
                    payload: payload
                )
            }
        }
    }
    private func cancelSubscription(_ subscriptionID: String) {
        let snapshot = lock.withLock { () -> (Task<Void, Never>?, [CheckedContinuation<Void, any Error>]) in
            let task = subscriptionTasks.removeValue(forKey: subscriptionID)
            subscriptionLiveness.cancel(subscriptionID)
            let matching = acknowledgementWaiters.filter {
                $0.value.subscriptionID == subscriptionID
            }
            for key in matching.keys { acknowledgementWaiters.removeValue(forKey: key) }
            return (task, matching.values.map(\.continuation))
        }
        snapshot.0?.cancel()
        snapshot.1.forEach {
            $0.resume(throwing: HostDataPlaneClientError.requestCancelled)
        }
    }
    private func cancelSubscriptions() -> [Task<Void, Never>] {
        let snapshot = lock.withLock { () -> ([Task<Void, Never>], [CheckedContinuation<Void, any Error>]) in
            let tasks = Array(subscriptionTasks.values)
            let waiters = acknowledgementWaiters.values.map(\.continuation)
            subscriptionTasks.removeAll()
            subscriptionLiveness.stop()
            acknowledgementWaiters.removeAll()
            return (tasks, waiters)
        }
        snapshot.0.forEach { $0.cancel() }
        snapshot.1.forEach {
            $0.resume(throwing: HostDataPlaneClientError.requestCancelled)
        }
        return snapshot.0
    }
}

private struct HostDataPlaneServerProtocolError: Error { let code: CPDataPlaneErrorCode; init(_ code: CPDataPlaneErrorCode) { self.code = code } }

private func decodeID<Scope>(_ value: String) throws -> CockpitID<Scope> {
    guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { throw HostDataPlaneServerProtocolError(.malformedMessage) }
    return CockpitID<Scope>(uuid)
}

private func map(_ error: any Error) -> CPDataPlaneErrorCode {
    if let error = error as? HostDataPlaneServerProtocolError { return error.code }
    switch error {
    case HostDataPlaneServiceError.contextMismatch: return .contextMismatch
    case HostDataPlaneServiceError.environmentMismatch: return .environmentMismatch
    case HostDataPlaneServiceError.documentNotOpen: return .documentNotOpen
    case DocumentProtocolError.invalidValue, DocumentProtocolError.unknownFields: return .documentInvalidValue
    case DocumentProtocolError.invalidLease: return .documentInvalidLease
    case DocumentProtocolError.leaseHeld: return .documentLeaseHeld
    case DocumentProtocolError.baseVersionMismatch: return .documentBaseVersionMismatch
    case DocumentProtocolError.sequenceGap: return .documentSequenceGap
    case DocumentProtocolError.duplicateMismatch: return .documentDuplicateMismatch
    case DocumentProtocolError.staleSequence: return .documentStaleSequence
    case DocumentProtocolError.recoveryRequired: return .internal
    case DocumentProtocolError.resynchronizing: return .documentResynchronizing
    case DocumentProtocolError.readOnly: return .documentReadOnly
    case DocumentProtocolError.fileMissing: return .documentFileMissing
    case HostDataPlaneDocumentError.committedRecoveryRequired: return .documentRecoveryRequired
    case DocumentStorageError.fingerprintMismatch: return .documentFingerprintMismatch
    case FileTreeProviderError.environmentMismatch: return .environmentMismatch
    case FileTreeProviderError.zeroGeneration: return .treeZeroGeneration
    case FileTreeProviderError.symbolicLinkTraversal: return .treeSymbolicLink
    case FileTreeProviderError.revisionUnavailable: return .treeRevisionUnavailable
    case FileTreeProviderError.eventSourceUnavailable: return .treeEventSourceUnavailable
    case FileTreeProviderError.filesystemEnumerationFailed: return .treeEnumerationFailed
    default: return .internal
    }
}

private func makeError(_ code: CPDataPlaneErrorCode, source: (any Error)? = nil) -> CPDataPlaneError {
    var value = CPDataPlaneError(); value.code = code
    switch source {
    case let error as DocumentProtocolError:
        switch error {
        case let .baseVersionMismatch(expected, actual), let .sequenceGap(expected, actual): value.expected = expected; value.actual = actual
        default: break
        }
    case let error as FileTreeProviderError:
        if case let .revisionUnavailable(requested, current) = error { value.expected = current; value.actual = requested }
    case let error as HostDataPlaneDocumentError:
        if case let .committedRecoveryRequired(ack) = error { value.committedAcknowledgement = try! HostDataPlaneMessages.encode(ack) }
    default: break
    }
    return value
}

func readFrame(_ calls: any UnixDomainSocketSystemCalls, _ descriptor: Int32) throws -> Frame {
    let headerData = try readExactly(calls, descriptor, count: FrameHeader.encodedLength)
    let header = try FrameHeader(decoding: headerData)
    return try Frame(header: header, payload: readExactly(calls, descriptor, count: Int(header.payloadLength)))
}

func readFrameAsync(
    _ calls: any UnixDomainSocketSystemCalls,
    _ descriptor: Int32,
    queue: DispatchQueue
) async throws -> Frame {
    try await withCheckedThrowingContinuation { continuation in
        queue.async {
            do { continuation.resume(returning: try readFrame(calls, descriptor)) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

func readFrameAsync(
    _ calls: any UnixDomainSocketSystemCalls,
    _ descriptorOwner: HostDataPlaneDescriptorOwner,
    queue: DispatchQueue
) async throws -> Frame {
    try await withCheckedThrowingContinuation { continuation in
        queue.async {
            do {
                continuation.resume(returning: try descriptorOwner.withDescriptor { descriptor in
                    try readFrame(calls, descriptor)
                })
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private struct HostDataPlaneMalformedFrameError: Error {
    let channel: ChannelID?
}

private func readServerFrameAsync(
    _ calls: any UnixDomainSocketSystemCalls,
    _ descriptorOwner: HostDataPlaneDescriptorOwner,
    queue: DispatchQueue
) async throws -> Frame {
    try await withCheckedThrowingContinuation { continuation in
        queue.async {
            do {
                let frame = try descriptorOwner.withDescriptor { descriptor in
                    let headerData = try readExactly(
                        calls,
                        descriptor,
                        count: FrameHeader.encodedLength
                    )
                    let rawChannel = headerData.withUnsafeBytes {
                        UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
                    }
                    let channel = ChannelID(rawValue: rawChannel)
                    let header: FrameHeader
                    do {
                        header = try FrameHeader(decoding: headerData)
                    } catch {
                        throw HostDataPlaneMalformedFrameError(channel: channel)
                    }
                    let payload: Data
                    do {
                        payload = try readExactly(
                            calls,
                            descriptor,
                            count: Int(header.payloadLength)
                        )
                    } catch {
                        throw HostDataPlaneMalformedFrameError(channel: channel)
                    }
                    do {
                        return try Frame(header: header, payload: payload)
                    } catch {
                        throw HostDataPlaneMalformedFrameError(channel: channel)
                    }
                }
                continuation.resume(returning: frame)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func readExactly(_ calls: any UnixDomainSocketSystemCalls, _ descriptor: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { bytes in
        var offset = 0
        while offset < count {
            let received = try calls.read(descriptor, into: UnsafeMutableRawBufferPointer(start: bytes.baseAddress!.advanced(by: offset), count: count - offset))
            guard received > 0 else { throw HostDataPlaneClientError.disconnected }
            offset += received
        }
    }
    return data
}

func writeFrame(_ calls: any UnixDomainSocketSystemCalls, _ descriptor: Int32, channel: ChannelID, sequence: UInt64, acknowledgement: UInt64, payload: Data) throws {
    let frame = try Frame(header: FrameHeader(flags: 0, channel: channel, sequence: sequence, acknowledgement: acknowledgement, payloadLength: UInt32(payload.count)), payload: payload).encoded()
    try frame.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = try calls.write(descriptor, from: UnsafeRawBufferPointer(start: bytes.baseAddress!.advanced(by: offset), count: bytes.count - offset))
            guard written > 0 else { throw HostDataPlaneClientError.disconnected }
            offset += written
        }
    }
}

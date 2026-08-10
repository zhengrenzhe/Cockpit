import Darwin
import Foundation
import CockpitProtocol
import CockpitTerminalCore
import CockpitTypes

struct KeeperStreamHandshake: Hashable, Codable, Sendable {
    let version: ProtocolVersion
}

struct KeeperSupervisorAuthentication: Hashable, Codable, Sendable {
    let endpoint: KeeperEndpoint
    let nonce: Data
    let proofMAC: Data
}

struct KeeperSupervisorAuthenticated: Hashable, Codable, Sendable {
    let endpoint: KeeperEndpoint
}

enum KeeperViewerRequest: Hashable, Codable, Sendable {
    case attach(AttachRequest)
    case nextOutput
    case visible(Bool)
    case signalInput(Data)
    case signal(TerminalSignal, InputLeaseID)
    case terminate(Bool, InputLeaseID)
    case detach
}

enum KeeperViewerResponse: Hashable, Codable, Sendable {
    case attached(TerminalAttachCapabilities)
    case outputPage(KeeperOutputPage)
    case inputAcknowledged(UInt64)
    case signalDelivered(Int32)
    case acknowledged
    case failure(KeeperStreamFailure)
}

struct KeeperOutputPage: Hashable, Codable, Sendable {
    static let maximumPayloadBytes = 4 * 1_024 * 1_024

    let firstOutputSequence: UInt64
    let outputSequence: UInt64
    let kind: TerminalStreamFrameKind
    let fragmentIndex: UInt32
    let fragmentCount: UInt32
    let pageIndex: UInt32
    let pageCount: UInt32
    let payload: Data

    init(
        firstOutputSequence: UInt64,
        outputSequence: UInt64,
        kind: TerminalStreamFrameKind,
        fragmentIndex: UInt32,
        fragmentCount: UInt32,
        pageIndex: UInt32,
        pageCount: UInt32,
        payload: Data
    ) throws {
        guard firstOutputSequence > 0,
              firstOutputSequence <= outputSequence,
              fragmentCount > 0,
              fragmentIndex < fragmentCount,
              pageCount > 0,
              pageIndex < pageCount,
              payload.count <= Self.maximumPayloadBytes else {
            throw TerminalStreamError.malformedMessage
        }
        self.firstOutputSequence = firstOutputSequence
        self.outputSequence = outputSequence
        self.kind = kind
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.payload = payload
    }

    static func pages(for frame: TerminalOutputFrame) -> [KeeperOutputPage] {
        let fragmentCount = UInt32(frame.fragments.count)
        return frame.fragments.enumerated().flatMap { fragmentIndex, fragment in
            let count = max(1, (fragment.count + maximumPayloadBytes - 1) / maximumPayloadBytes)
            return (0..<count).map { pageIndex in
                let lower = pageIndex * maximumPayloadBytes
                let upper = min(fragment.count, lower + maximumPayloadBytes)
                return try! KeeperOutputPage(
                    firstOutputSequence: frame.firstOutputSequence,
                    outputSequence: frame.outputSequence,
                    kind: frame.kind,
                    fragmentIndex: UInt32(fragmentIndex),
                    fragmentCount: fragmentCount,
                    pageIndex: UInt32(pageIndex),
                    pageCount: UInt32(count),
                    payload: fragment.subdata(in: lower..<upper)
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case firstOutputSequence, outputSequence, kind
        case fragmentIndex, fragmentCount, pageIndex, pageCount, payload
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            firstOutputSequence: container.decode(UInt64.self, forKey: .firstOutputSequence),
            outputSequence: container.decode(UInt64.self, forKey: .outputSequence),
            kind: container.decode(TerminalStreamFrameKind.self, forKey: .kind),
            fragmentIndex: container.decode(UInt32.self, forKey: .fragmentIndex),
            fragmentCount: container.decode(UInt32.self, forKey: .fragmentCount),
            pageIndex: container.decode(UInt32.self, forKey: .pageIndex),
            pageCount: container.decode(UInt32.self, forKey: .pageCount),
            payload: container.decode(Data.self, forKey: .payload)
        )
    }
}

enum KeeperStreamFailure: String, Hashable, Codable, Sendable {
    case authenticationFailed
    case invalidCanonicalTicket
    case invalidRegistration
    case invalidCapabilities
    case expired
    case replay
    case bindingMismatch
    case capabilityEscalation
    case inputLeaseRequired
    case leaseHeld
    case invalidInputLease
    case nonMonotonicInputSequence
    case capabilityDenied
    case viewerNotAttached
    case sessionMismatch
    case malformedMessage
    case disconnected
    case internalFailure

    var error: any Error {
        switch self {
        case .authenticationFailed: KeeperControlError.authenticationFailed
        case .invalidCanonicalTicket: TerminalAttachTicketError.invalidCanonicalTicket
        case .invalidRegistration: TerminalAttachTicketError.invalidRegistration
        case .invalidCapabilities: TerminalAttachTicketError.invalidCapabilities
        case .expired: TerminalAttachTicketError.expired
        case .replay: TerminalAttachTicketError.replay
        case .bindingMismatch: TerminalAttachTicketError.bindingMismatch
        case .capabilityEscalation: TerminalAttachTicketError.capabilityEscalation
        case .inputLeaseRequired: TerminalStreamError.inputLeaseRequired
        case .leaseHeld: TerminalStreamError.leaseHeld
        case .invalidInputLease: TerminalStreamError.invalidInputLease
        case .nonMonotonicInputSequence: TerminalStreamError.nonMonotonicInputSequence
        case .capabilityDenied: TerminalStreamError.capabilityDenied
        case .viewerNotAttached: TerminalStreamError.viewerNotAttached
        case .sessionMismatch: TerminalStreamError.sessionMismatch
        case .malformedMessage: TerminalStreamError.malformedMessage
        case .disconnected: TerminalStreamError.disconnected
        case .internalFailure: TerminalStreamError.internalFailure
        }
    }

    static func map(_ error: any Error) -> KeeperStreamFailure {
        if let value = error as? TerminalAttachTicketError {
            return switch value {
            case .invalidCanonicalTicket: .invalidCanonicalTicket
            case .invalidRegistration: .invalidRegistration
            case .invalidCapabilities: .invalidCapabilities
            case .expired: .expired
            case .replay: .replay
            case .bindingMismatch: .bindingMismatch
            case .capabilityEscalation: .capabilityEscalation
            case .randomGenerationFailed, .digestCollision: .internalFailure
            }
        }
        if let value = error as? TerminalStreamError {
            return switch value {
            case .authenticationFailed: .authenticationFailed
            case .inputLeaseRequired: .inputLeaseRequired
            case .leaseHeld: .leaseHeld
            case .invalidInputLease: .invalidInputLease
            case .nonMonotonicInputSequence: .nonMonotonicInputSequence
            case .capabilityDenied: .capabilityDenied
            case .viewerNotAttached, .viewerAlreadyAttached: .viewerNotAttached
            case .sessionMismatch: .sessionMismatch
            case .malformedMessage, .protocolVersionMismatch, .wrongChannel: .malformedMessage
            case .disconnected: .disconnected
            case .internalFailure: .internalFailure
            }
        }
        if let value = error as? KeeperControlError,
           value == .authenticationFailed {
            return .authenticationFailed
        }
        if error is ProtocolMappingError {
            return .malformedMessage
        }
        return .internalFailure
    }
}

final class KeeperStreamConnection: @unchecked Sendable {
    private struct ChannelState {
        var sentSequence: UInt64 = 0
        var receivedSequence: UInt64 = 0
        var peerAcknowledgement: UInt64 = 0
    }

    private let owner: KeeperSocketDescriptorOwner
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let readLock = NSLock()
    private var channelStates: [ChannelID: ChannelState] = [:]

    init(descriptor: Int32, ownsDescriptor: Bool = true) {
        owner = KeeperSocketDescriptorOwner(descriptor: descriptor, ownsDescriptor: ownsDescriptor)
    }

    func performClientHandshake(role: PeerRole) throws {
        try write(KeeperStreamHandshake(version: .current), channel: .control)
        let response = try read(KeeperStreamHandshake.self, expectedChannel: .control)
        guard response.version == .current else {
            throw TerminalStreamError.protocolVersionMismatch
        }
        try write(role, channel: .control)
    }

    func performServerHandshake() throws -> PeerRole {
        let request = try read(KeeperStreamHandshake.self, expectedChannel: .control)
        guard request.version == .current,
              request.version.major == 1,
              request.version.minor >= 1 else {
            throw TerminalStreamError.protocolVersionMismatch
        }
        try write(KeeperStreamHandshake(version: .current), channel: .control)
        return try read(PeerRole.self, expectedChannel: .control)
    }

    func write<Value: Encodable>(_ value: Value, channel: ChannelID) throws {
        let payload = try JSONEncoder().encode(value)
        try writePayload(payload, channel: channel)
    }

    func writePayload(_ payload: Data, channel: ChannelID) throws {
        guard payload.count <= Int(FrameHeader.maximumPayloadLength) else {
            throw TerminalStreamError.malformedMessage
        }
        try writeLock.withLock {
            let state = stateLock.withLock { channelStates[channel, default: ChannelState()] }
            let (next, overflow) = state.sentSequence.addingReportingOverflow(1)
            guard !overflow else { throw TerminalStreamError.disconnected }
            let header = FrameHeader(
                flags: 0,
                channel: channel,
                sequence: next,
                acknowledgement: state.receivedSequence,
                payloadLength: UInt32(payload.count)
            )
            try owner.withDescriptor { descriptor in
                try writeAll(header.encoded(), to: descriptor)
                try writeAll(payload, to: descriptor)
            }
            stateLock.withLock {
                var current = channelStates[channel, default: ChannelState()]
                current.sentSequence = next
                channelStates[channel] = current
            }
        }
    }

    func read<Value: Decodable>(
        _ type: Value.Type,
        expectedChannel: ChannelID
    ) throws -> Value {
        let value: (ChannelID, Value) = try read(type)
        guard value.0 == expectedChannel else { throw TerminalStreamError.wrongChannel }
        return value.1
    }

    func read<Value: Decodable>(_ type: Value.Type) throws -> (ChannelID, Value) {
        let (channel, payload) = try readPayload()
        let decoded: Value
        do { decoded = try JSONDecoder().decode(type, from: payload) }
        catch { throw TerminalStreamError.malformedMessage }
        return (channel, decoded)
    }

    func readPayload() throws -> (ChannelID, Data) {
        try readLock.withLock {
            try owner.withDescriptor { descriptor in
                var headerBytes = Data(count: FrameHeader.encodedLength)
                try headerBytes.withUnsafeMutableBytes { try readAll($0, from: descriptor) }
                let header = try FrameHeader(decoding: headerBytes)
                let state = stateLock.withLock {
                    channelStates[header.channel, default: ChannelState()]
                }
                let (expectedSequence, overflow) = state.receivedSequence.addingReportingOverflow(1)
                guard header.flags == 0,
                      !overflow,
                      header.sequence == expectedSequence,
                      header.acknowledgement >= state.peerAcknowledgement,
                      header.acknowledgement <= state.sentSequence else {
                    throw TerminalStreamError.malformedMessage
                }
                var payload = Data(count: Int(header.payloadLength))
                try payload.withUnsafeMutableBytes { try readAll($0, from: descriptor) }
                stateLock.withLock {
                    var current = channelStates[header.channel, default: ChannelState()]
                    current.receivedSequence = header.sequence
                    current.peerAcknowledgement = header.acknowledgement
                    channelStates[header.channel] = current
                }
                return (header.channel, payload)
            }
        }
    }

    func close() {
        owner.interruptAndClose()
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TerminalStreamError.disconnected }
                offset += count
            }
        }
    }

    private func readAll(_ bytes: UnsafeMutableRawBufferPointer, from descriptor: Int32) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw TerminalStreamError.disconnected }
            offset += count
        }
    }
}

private final class KeeperSocketDescriptorOwner: @unchecked Sendable {
    private let condition = NSCondition()
    private let ownsDescriptor: Bool
    private var descriptor: Int32?
    private var acceptsOperations = true
    private var activeOperations = 0

    init(descriptor: Int32, ownsDescriptor: Bool) {
        self.descriptor = descriptor
        self.ownsDescriptor = ownsDescriptor
    }

    func withDescriptor<Result>(_ operation: (Int32) throws -> Result) throws -> Result {
        let value = try condition.withLock { () throws -> Int32 in
            guard acceptsOperations, let descriptor else {
                throw TerminalStreamError.disconnected
            }
            activeOperations += 1
            return descriptor
        }
        defer {
            condition.withLock {
                activeOperations -= 1
                if activeOperations == 0 { condition.broadcast() }
            }
        }
        return try operation(value)
    }

    func interruptAndClose() {
        condition.lock()
        guard acceptsOperations || descriptor != nil else {
            condition.unlock()
            return
        }
        acceptsOperations = false
        if let descriptor { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        while activeOperations != 0 { condition.wait() }
        if ownsDescriptor, let descriptor { _ = Darwin.close(descriptor) }
        descriptor = nil
        condition.broadcast()
        condition.unlock()
    }
}

public struct KeeperUDSClient: Sendable {
    public let endpoint: KeeperEndpoint

    public init(endpoint: KeeperEndpoint) { self.endpoint = endpoint }

    public func attach(_ request: AttachRequest) async throws -> KeeperViewerConnection {
        do {
            return try await Task.detached {
                let descriptor = try Self.connect(to: endpoint)
                let stream = KeeperStreamConnection(descriptor: descriptor)
                do {
                    try stream.performClientHandshake(role: .viewer)
                    try stream.write(KeeperViewerRequest.attach(request), channel: .control)
                    let response = try stream.read(KeeperViewerResponse.self, expectedChannel: .control)
                    switch response {
                    case let .attached(capabilities):
                        let connection = KeeperViewerConnection(
                            stream: stream,
                            viewerID: request.viewerID,
                            capabilities: capabilities
                        )
                        await connection.startReading()
                        return connection
                    case let .failure(failure): throw failure.error
                    default: throw TerminalStreamError.malformedMessage
                    }
                } catch {
                    stream.close()
                    throw error
                }
            }.value
        } catch TerminalStreamError.disconnected {
            throw KeeperControlError.authenticationFailed
        }
    }

    private static func connect(to endpoint: KeeperEndpoint) throws -> Int32 {
        let calls = DarwinUnixDomainSocketSystemCalls()
        let descriptor = try calls.createStreamSocket()
        do {
            try calls.setCloseOnExec(descriptor)
            try calls.setNoSigPipe(descriptor)
            try calls.connect(descriptor, to: UnixDomainSocketAddress(path: endpoint.path))
            return descriptor
        } catch {
            calls.close(descriptor)
            throw error
        }
    }
}

public actor KeeperViewerConnection {
    private struct PendingRequest {
        let id: UUID
        let continuation: CheckedContinuation<Result<KeeperViewerResponse, any Error>, Never>
    }

    private struct OutputAssembly {
        let firstOutputSequence: UInt64
        let outputSequence: UInt64
        let kind: TerminalStreamFrameKind
        let fragmentCount: UInt32
        var nextFragmentIndex: UInt32 = 0
        var nextPageIndex: UInt32 = 0
        var currentPageCount: UInt32 = 0
        var currentParts: [Data] = []
        var fragments: [Data] = []

        init(first page: KeeperOutputPage) throws {
            guard page.fragmentIndex == 0, page.pageIndex == 0 else {
                throw TerminalStreamError.malformedMessage
            }
            firstOutputSequence = page.firstOutputSequence
            outputSequence = page.outputSequence
            kind = page.kind
            fragmentCount = page.fragmentCount
        }

        mutating func append(_ page: KeeperOutputPage) throws -> TerminalOutputFrame? {
            guard page.firstOutputSequence == firstOutputSequence,
                  page.outputSequence == outputSequence,
                  page.kind == kind,
                  page.fragmentCount == fragmentCount,
                  page.fragmentIndex == nextFragmentIndex,
                  page.pageIndex == nextPageIndex,
                  nextPageIndex == 0 || page.pageCount == currentPageCount else {
                throw TerminalStreamError.malformedMessage
            }
            if nextPageIndex == 0 { currentPageCount = page.pageCount }
            currentParts.append(page.payload)
            nextPageIndex += 1
            guard nextPageIndex == currentPageCount else { return nil }

            var fragment = Data()
            for part in currentParts { fragment.append(part) }
            fragments.append(fragment)
            currentParts.removeAll(keepingCapacity: false)
            nextFragmentIndex += 1
            nextPageIndex = 0
            currentPageCount = 0
            guard nextFragmentIndex == fragmentCount else { return nil }
            return try TerminalOutputFrame(
                firstOutputSequence: firstOutputSequence,
                outputSequence: outputSequence,
                kind: kind,
                fragments: fragments
            )
        }
    }

    public let viewerID: ViewerID
    public let capabilities: TerminalAttachCapabilities
    private let stream: KeeperStreamConnection
    private let writeQueue = DispatchQueue(label: "dev.cockpit.keeper-viewer-write")
    private var readerTask: Task<Void, Never>?
    private var pendingRequests: [ChannelID: [PendingRequest]] = [:]
    private var bufferedOutput: [TerminalOutputFrame] = []
    private var outputAssembly: OutputAssembly?
    private var outputWaiters: [
        CheckedContinuation<Result<TerminalOutputFrame?, any Error>, Never>
    ] = []
    private var terminalError: (any Error)?
    private var detached = false
    private var detaching = false

    init(
        stream: KeeperStreamConnection,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) {
        self.stream = stream
        self.viewerID = viewerID
        self.capabilities = capabilities
    }

    deinit { stream.close() }

    func startReading() {
        guard readerTask == nil else { return }
        let stream = self.stream
        readerTask = Task.detached { [weak self, stream] in
            do {
                while !Task.isCancelled {
                    let message = try stream.read(KeeperViewerResponse.self)
                    guard let self else {
                        stream.close()
                        return
                    }
                    await self.receive(message.1, channel: message.0)
                }
            } catch {
                await self?.connectionFailed(error)
            }
        }
    }

    public func nextOutput() async throws -> TerminalOutputFrame? {
        if !bufferedOutput.isEmpty { return bufferedOutput.removeFirst() }
        if let terminalError { throw terminalError }
        if detached { return nil }
        let result: Result<TerminalOutputFrame?, any Error> = await withCheckedContinuation {
            outputWaiters.append($0)
        }
        return try result.get()
    }

    public func send(_ input: TerminalInput) async throws -> UInt64 {
        if case .signal = input.payload {
            let message = try TerminalMessages.encode(
                input,
                channelID: .control,
                negotiatedVersion: .current
            )
            let data = try message.serializedData()
            return try await request(.signalInput(data), channel: .control) { response in
                if case let .inputAcknowledged(sequence) = response { return sequence }
                throw Self.responseError(response)
            }
        }
        let message = try TerminalMessages.encode(
            input,
            channelID: .terminalInput,
            negotiatedVersion: .current
        )
        let data = try message.serializedData()
        return try await requestPayload(data, channel: .terminalInput) { response in
            if case let .inputAcknowledged(sequence) = response { return sequence }
            throw Self.responseError(response)
        }
    }

    public func setVisible(_ visible: Bool) async throws {
        _ = try await request(.visible(visible), channel: .control) {
            response -> Bool in
            if case .acknowledged = response { return true }
            throw Self.responseError(response)
        }
    }

    public func signal(
        _ signal: TerminalSignal,
        leaseID: InputLeaseID
    ) async throws -> Int32 {
        try await request(.signal(signal, leaseID), channel: .control) { response in
            if case let .signalDelivered(group) = response { return group }
            throw Self.responseError(response)
        }
    }

    public func terminate(force: Bool, leaseID: InputLeaseID) async throws {
        _ = try await request(.terminate(force, leaseID), channel: .control) {
            response -> Bool in
            if case .acknowledged = response { return true }
            throw Self.responseError(response)
        }
    }

    public func detach() async {
        guard !detached, !detaching else { return }
        detaching = true
        _ = try? await request(.detach, channel: .control) {
            response -> Bool in
            if case .acknowledged = response { return true }
            throw Self.responseError(response)
        }
        finish()
    }

    private func request<Result: Sendable>(
        _ request: KeeperViewerRequest,
        channel: ChannelID,
        transform: @escaping @Sendable (KeeperViewerResponse) throws -> Result
    ) async throws -> Result {
        let payload = try JSONEncoder().encode(request)
        return try await requestPayload(
            payload,
            channel: channel,
            allowDuringDetaching: request == .detach,
            transform: transform
        )
    }

    private func requestPayload<Result: Sendable>(
        _ payload: Data,
        channel: ChannelID,
        allowDuringDetaching: Bool = false,
        transform: @escaping @Sendable (KeeperViewerResponse) throws -> Result
    ) async throws -> Result {
        guard !detached, !detaching || allowDuringDetaching else {
            throw TerminalStreamError.disconnected
        }
        if let terminalError { throw terminalError }
        let id = UUID()
        let response: Swift.Result<KeeperViewerResponse, any Error> = await withCheckedContinuation {
            continuation in
            pendingRequests[channel, default: []].append(
                PendingRequest(id: id, continuation: continuation)
            )
            let stream = self.stream
            writeQueue.async { [weak self, stream] in
                do { try stream.writePayload(payload, channel: channel) }
                catch {
                    Task { await self?.requestWriteFailed(id: id, error: error) }
                }
            }
        }
        return try transform(try response.get())
    }

    private func receive(_ response: KeeperViewerResponse, channel: ChannelID) {
        if channel == .terminalOutput {
            guard case let .outputPage(page) = response else {
                connectionFailed(TerminalStreamError.malformedMessage)
                return
            }
            do {
                var assembly = try outputAssembly ?? OutputAssembly(first: page)
                if let frame = try assembly.append(page) {
                    outputAssembly = nil
                    enqueueOutput(frame)
                } else {
                    outputAssembly = assembly
                }
            } catch {
                connectionFailed(error)
            }
            return
        }
        guard channel == .control || channel == .terminalInput,
              var pending = pendingRequests[channel],
              !pending.isEmpty else {
            connectionFailed(TerminalStreamError.malformedMessage)
            return
        }
        let request = pending.removeFirst()
        pendingRequests[channel] = pending
        request.continuation.resume(returning: .success(response))
    }

    private func enqueueOutput(_ frame: TerminalOutputFrame) {
        if !outputWaiters.isEmpty {
            outputWaiters.removeFirst().resume(returning: .success(frame))
            return
        }
        TerminalOutputFrame.enqueueBounded(frame, into: &bufferedOutput)
    }

    private func requestWriteFailed(id: UUID, error: any Error) {
        let stillPending = pendingRequests.values.contains { requests in
            requests.contains { $0.id == id }
        }
        if stillPending { connectionFailed(error) }
    }

    private func connectionFailed(_ error: any Error) {
        guard terminalError == nil, !detached else { return }
        terminalError = error
        detached = true
        readerTask?.cancel()
        stream.close()
        resumeAllPending(with: .failure(error))
        for waiter in outputWaiters { waiter.resume(returning: .failure(error)) }
        outputWaiters.removeAll(keepingCapacity: false)
        bufferedOutput.removeAll(keepingCapacity: false)
        outputAssembly = nil
    }

    private func finish() {
        guard !detached else { return }
        detached = true
        detaching = false
        readerTask?.cancel()
        stream.close()
        resumeAllPending(with: .failure(TerminalStreamError.disconnected))
        for waiter in outputWaiters { waiter.resume(returning: .success(nil)) }
        outputWaiters.removeAll(keepingCapacity: false)
        bufferedOutput.removeAll(keepingCapacity: false)
        outputAssembly = nil
    }

    private func resumeAllPending(
        with result: Swift.Result<KeeperViewerResponse, any Error>
    ) {
        let requests = pendingRequests.values.flatMap { $0 }
        pendingRequests.removeAll(keepingCapacity: false)
        for request in requests { request.continuation.resume(returning: result) }
    }

    private static func responseError(_ response: KeeperViewerResponse) -> any Error {
        if case let .failure(error) = response { return error.error }
        return TerminalStreamError.malformedMessage
    }
}

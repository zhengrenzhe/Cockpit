import Darwin
import Foundation
import Security
import CockpitTerminalCore
import CockpitTypes

enum KeeperControlEnvelope: Hashable, Codable, Sendable {
    case ready(KeeperReady)
    case inspect(KeeperInspectRequest)
    case start(AuthenticatedStartRequest)
    case terminate(KeeperTerminateRequest)
    case identity(KeeperIdentity)
    case started(CLIProcessIdentity)
    case acknowledged
    case registerAttachTicket(TerminalAttachTicketRegistration)
    case registerInputLease(InputLeaseGrant)
    case revokeInputLease(InputLeaseID)
    case takeLeaseRevocations
    case leaseRevocations([InputLeaseID])
    case failure(KeeperControlWireError)
}

enum KeeperControlWireError: String, Hashable, Codable, Sendable {
    case authenticationFailed
    case identityMismatch
    case startRequestMismatch
    case malformedMessage
    case noRunningProcess
    case internalFailure

    var error: KeeperControlError {
        switch self {
        case .authenticationFailed: .authenticationFailed
        case .identityMismatch: .identityMismatch
        case .startRequestMismatch: .startRequestMismatch
        case .malformedMessage: .malformedMessage
        case .noRunningProcess: .noRunningProcess
        case .internalFailure: .disconnected
        }
    }
}

enum KeeperControlFraming {
    static let maximumPayloadLength = 1_048_576

    static func makeSocketPair() throws -> (parent: Int32, child: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw KeeperLaunchFailure(operation: "socketpair", code: errno)
        }
        do {
            for descriptor in descriptors {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                    throw KeeperLaunchFailure(operation: "fcntl(FD_CLOEXEC)", code: errno)
                }
                guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
                    throw KeeperLaunchFailure(operation: "fcntl(F_SETNOSIGPIPE)", code: errno)
                }
            }
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }
        return (descriptors[0], descriptors[1])
    }

    static func write<Value: Encodable>(_ value: Value, to descriptor: Int32) throws {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maximumPayloadLength else {
            throw KeeperControlError.malformedMessage
        }
        var length = UInt32(payload.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll($0, to: descriptor) }
        try payload.withUnsafeBytes { try writeAll($0, to: descriptor) }
    }

    static func read<Value: Decodable>(_ type: Value.Type, from descriptor: Int32) throws -> Value {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        try lengthBytes.withUnsafeMutableBytes { try readAll($0, from: descriptor) }
        let length = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maximumPayloadLength else {
            throw KeeperControlError.malformedMessage
        }
        var payload = Data(count: Int(length))
        try payload.withUnsafeMutableBytes { try readAll($0, from: descriptor) }
        do { return try JSONDecoder().decode(type, from: payload) }
        catch { throw KeeperControlError.malformedMessage }
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw KeeperControlError.disconnected }
            offset += count
        }
    }

    private static func readAll(_ bytes: UnsafeMutableRawBufferPointer, from descriptor: Int32) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw KeeperControlError.disconnected }
            offset += count
        }
    }
}

public enum KeeperBootstrapChannel {
    public static func receiveBootstrap(
        from descriptor: Int32 = KeeperBootstrap.inheritedFileDescriptor
    ) throws -> KeeperBootstrap {
        try KeeperControlFraming.read(KeeperBootstrap.self, from: descriptor)
    }

    public static func sendReady(
        _ ready: KeeperReady,
        to descriptor: Int32 = KeeperBootstrap.inheritedFileDescriptor
    ) throws {
        try KeeperControlFraming.write(KeeperControlEnvelope.ready(ready), to: descriptor)
    }

    public static func receiveStart(
        from descriptor: Int32 = KeeperBootstrap.inheritedFileDescriptor
    ) throws -> AuthenticatedStartRequest {
        let envelope = try KeeperControlFraming.read(KeeperControlEnvelope.self, from: descriptor)
        guard case let .start(request) = envelope else {
            throw KeeperControlError.malformedMessage
        }
        return request
    }

    public static func sendStarted(
        _ identity: CLIProcessIdentity,
        to descriptor: Int32 = KeeperBootstrap.inheritedFileDescriptor
    ) throws {
        try KeeperControlFraming.write(KeeperControlEnvelope.started(identity), to: descriptor)
    }

    public static func sendFailure(
        _ error: KeeperControlError,
        to descriptor: Int32 = KeeperBootstrap.inheritedFileDescriptor
    ) throws {
        let wire: KeeperControlWireError = switch error {
        case .authenticationFailed, .invalidProof: .authenticationFailed
        case .identityMismatch: .identityMismatch
        case .startRequestMismatch: .startRequestMismatch
        case .malformedMessage: .malformedMessage
        case .noRunningProcess: .noRunningProcess
        default: .internalFailure
        }
        try KeeperControlFraming.write(KeeperControlEnvelope.failure(wire), to: descriptor)
    }
}

public actor KeeperControlClient: KeeperControlling {
    public typealias SecretProvider = @Sendable (
        TerminalSessionID,
        WorkerInstanceID
    ) async throws -> Data

    private let secretProvider: SecretProvider
    private var bootstrapDescriptors: [KeeperEndpoint: Int32] = [:]

    public init(secretProvider: @escaping SecretProvider) {
        self.secretProvider = secretProvider
    }

    deinit {
        for descriptor in bootstrapDescriptors.values { Darwin.close(descriptor) }
    }

    public func awaitReady(_ keeper: LaunchedKeeper) async throws -> KeeperReady {
        let descriptor = keeper.bootstrapControlDescriptor
        let envelope = try await blocking {
            try KeeperControlFraming.read(KeeperControlEnvelope.self, from: descriptor)
        }
        guard case let .ready(ready) = envelope,
              ready.sessionID == keeper.sessionID,
              ready.workerID == keeper.workerID else {
            Darwin.close(descriptor)
            throw KeeperControlError.identityMismatch
        }
        let secret = try await secretProvider(ready.sessionID, ready.workerID)
        guard KeeperAuthentication.verifyReadyProof(
            ready.proofMAC,
            secret: secret,
            endpoint: ready.endpoint,
            sessionID: ready.sessionID,
            workerID: ready.workerID,
            readyNonce: ready.readyNonce
        ) else {
            Darwin.close(descriptor)
            throw KeeperControlError.authenticationFailed
        }
        bootstrapDescriptors[ready.endpoint] = descriptor
        return ready
    }

    public func authenticatedStart(
        _ request: AuthenticatedStartRequest
    ) async throws -> CLIProcessIdentity {
        let secret = try await secretProvider(request.sessionID, request.workerID)
        guard KeeperAuthentication.verifyStartProof(
            request.proofMAC,
            secret: secret,
            endpoint: request.endpoint,
            sessionID: request.sessionID,
            workerID: request.workerID,
            startNonce: request.startNonce
        ) else {
            throw KeeperControlError.authenticationFailed
        }
        if let descriptor = bootstrapDescriptors.removeValue(forKey: request.endpoint) {
            defer { Darwin.close(descriptor) }
            return try await blocking {
                try KeeperControlFraming.write(KeeperControlEnvelope.start(request), to: descriptor)
                return try Self.startedIdentity(
                    KeeperControlFraming.read(KeeperControlEnvelope.self, from: descriptor)
                )
            }
        }
        return try await requestOverUDS(
            endpoint: request.endpoint,
            request: .start(request),
            response: Self.startedIdentity
        )
    }

    public func inspect(_ endpoint: KeeperEndpoint) async throws -> KeeperIdentity {
        let secret = try await secretProvider(endpoint.sessionID, endpoint.workerID)
        let nonce = try randomNonce()
        let request = KeeperInspectRequest(
            endpoint: endpoint,
            nonce: nonce,
            proofMAC: KeeperAuthentication.inspectProof(
                secret: secret,
                endpoint: endpoint,
                nonce: nonce
            )
        )
        return try await requestOverUDS(
            endpoint: endpoint,
            request: .inspect(request)
        ) { envelope in
            if case let .identity(value) = envelope { return value }
            throw Self.responseError(envelope)
        }
    }

    public func terminate(_ endpoint: KeeperEndpoint, force: Bool) async throws {
        let secret = try await secretProvider(endpoint.sessionID, endpoint.workerID)
        let nonce = try randomNonce()
        let request = KeeperTerminateRequest(
            endpoint: endpoint,
            force: force,
            nonce: nonce,
            proofMAC: KeeperAuthentication.terminateProof(
                secret: secret,
                endpoint: endpoint,
                force: force,
                nonce: nonce
            )
        )
        _ = try await requestOverUDS(
            endpoint: endpoint,
            request: .terminate(request)
        ) { envelope -> Bool in
            if case .acknowledged = envelope { return true }
            throw Self.responseError(envelope)
        }
    }

    public func registerAttachTicket(
        _ registration: TerminalAttachTicketRegistration,
        at endpoint: KeeperEndpoint
    ) async throws {
        try validate(endpoint: endpoint)
        _ = try await requestOverUDS(
            endpoint: endpoint,
            request: .registerAttachTicket(registration)
        ) { envelope -> Bool in
            if case .acknowledged = envelope { return true }
            throw Self.responseError(envelope)
        }
    }

    public func registerInputLease(
        _ grant: InputLeaseGrant,
        at endpoint: KeeperEndpoint
    ) async throws {
        try validate(endpoint: endpoint)
        _ = try await requestOverUDS(
            endpoint: endpoint,
            request: .registerInputLease(grant)
        ) { envelope -> Bool in
            if case .acknowledged = envelope { return true }
            throw Self.responseError(envelope)
        }
    }

    public func revokeInputLease(
        _ leaseID: InputLeaseID,
        at endpoint: KeeperEndpoint
    ) async throws {
        try validate(endpoint: endpoint)
        _ = try await requestOverUDS(
            endpoint: endpoint,
            request: .revokeInputLease(leaseID)
        ) { envelope -> Bool in
            if case .acknowledged = envelope { return true }
            throw Self.responseError(envelope)
        }
    }

    public func takeLeaseRevocations(at endpoint: KeeperEndpoint) async throws -> [InputLeaseID] {
        try validate(endpoint: endpoint)
        return try await requestOverUDS(
            endpoint: endpoint,
            request: .takeLeaseRevocations
        ) { envelope in
            if case let .leaseRevocations(values) = envelope { return values }
            throw Self.responseError(envelope)
        }
    }

    private func requestOverUDS<Result: Sendable>(
        endpoint: KeeperEndpoint,
        request: KeeperControlEnvelope,
        response: @escaping @Sendable (KeeperControlEnvelope) throws -> Result
    ) async throws -> Result {
        let secret = try await secretProvider(endpoint.sessionID, endpoint.workerID)
        let nonce = try randomNonce()
        return try await blocking {
            let calls = DarwinUnixDomainSocketSystemCalls()
            let descriptor = try calls.createStreamSocket()
            defer { calls.close(descriptor) }
            try calls.setCloseOnExec(descriptor)
            try calls.setNoSigPipe(descriptor)
            try calls.connect(descriptor, to: UnixDomainSocketAddress(path: endpoint.path))
            let stream = KeeperStreamConnection(descriptor: descriptor)
            try stream.performClientHandshake(role: .supervisorControl)
            try stream.write(
                KeeperSupervisorAuthentication(
                    endpoint: endpoint,
                    nonce: nonce,
                    proofMAC: KeeperAuthentication.supervisorProof(
                        secret: secret,
                        endpoint: endpoint,
                        nonce: nonce
                    )
                ),
                channel: .control
            )
            let authenticated = try stream.read(
                KeeperSupervisorAuthenticated.self,
                expectedChannel: .control
            )
            guard authenticated.endpoint == endpoint else {
                throw KeeperControlError.identityMismatch
            }
            try stream.write(request, channel: .control)
            return try response(
                stream.read(KeeperControlEnvelope.self, expectedChannel: .control)
            )
        }
    }

    private func validate(endpoint: KeeperEndpoint) throws {
        _ = try KeeperEndpoint(
            path: endpoint.path,
            sessionID: endpoint.sessionID,
            workerID: endpoint.workerID
        )
    }

    private static func startedIdentity(_ envelope: KeeperControlEnvelope) throws -> CLIProcessIdentity {
        if case let .started(identity) = envelope { return identity }
        throw responseError(envelope)
    }

    private static func responseError(_ envelope: KeeperControlEnvelope) -> any Error {
        if case let .failure(error) = envelope { return error.error }
        return KeeperControlError.malformedMessage
    }

    private func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeeperControlError.authenticationFailed
        }
        return Data(bytes)
    }
}

private func blocking<Result: Sendable>(
    _ operation: @escaping @Sendable () throws -> Result
) async throws -> Result {
    try await Task.detached(priority: nil, operation: operation).value
}

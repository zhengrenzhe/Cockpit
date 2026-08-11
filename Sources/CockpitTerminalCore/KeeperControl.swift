import CryptoKit
import Foundation
import CockpitTypes

public enum KeeperControlError: Error, Equatable, Sendable {
    case invalidEndpoint
    case invalidNonce
    case invalidProof
    case authenticationFailed
    case identityMismatch
    case startRequestMismatch
    case noRunningProcess
    case malformedMessage
    case disconnected
}

public struct KeeperEndpoint: Hashable, Codable, Sendable {
    public let path: String
    public let sessionID: TerminalSessionID
    public let workerID: WorkerInstanceID

    public init(
        path: String,
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID
    ) throws {
        guard LaunchSpec.isCanonicalAbsolutePath(path),
              path.utf8.count < 104 else {
            throw KeeperControlError.invalidEndpoint
        }
        self.path = path
        self.sessionID = sessionID
        self.workerID = workerID
    }

    public static func runtime(
        directory: String,
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID
    ) throws -> KeeperEndpoint {
        var material = Data()
        var sessionBytes = sessionID.rawValue.uuid
        var workerBytes = workerID.rawValue.uuid
        withUnsafeBytes(of: &sessionBytes) { material.append(contentsOf: $0) }
        withUnsafeBytes(of: &workerBytes) { material.append(contentsOf: $0) }
        let digest = SHA256.hash(data: material).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return try KeeperEndpoint(
            path: URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("k\(digest)").path,
            sessionID: sessionID,
            workerID: workerID
        )
    }

    private enum CodingKeys: String, CodingKey { case path, sessionID, workerID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: container.decode(String.self, forKey: .path),
            sessionID: container.decode(TerminalSessionID.self, forKey: .sessionID),
            workerID: container.decode(WorkerInstanceID.self, forKey: .workerID)
        )
    }
}

public struct KeeperReady: Hashable, Codable, Sendable {
    public let endpoint: KeeperEndpoint
    public let sessionID: TerminalSessionID
    public let workerID: WorkerInstanceID
    public let readyNonce: Data
    public let proofMAC: Data

    public init(
        endpoint: KeeperEndpoint,
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        readyNonce: Data,
        proofMAC: Data
    ) {
        self.endpoint = endpoint
        self.sessionID = sessionID
        self.workerID = workerID
        self.readyNonce = readyNonce
        self.proofMAC = proofMAC
    }
}

public struct AuthenticatedStartRequest: Hashable, Codable, Sendable {
    public let endpoint: KeeperEndpoint
    public let sessionID: TerminalSessionID
    public let workerID: WorkerInstanceID
    public let startNonce: Data
    public let proofMAC: Data

    public init(
        endpoint: KeeperEndpoint,
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        startNonce: Data,
        proofMAC: Data
    ) {
        self.endpoint = endpoint
        self.sessionID = sessionID
        self.workerID = workerID
        self.startNonce = startNonce
        self.proofMAC = proofMAC
    }
}

public struct KeeperIdentity: Hashable, Codable, Sendable {
    public let endpoint: KeeperEndpoint
    public let sessionID: TerminalSessionID
    public let workerID: WorkerInstanceID
    public let processIdentity: CLIProcessIdentity?

    public init(
        endpoint: KeeperEndpoint,
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        processIdentity: CLIProcessIdentity?
    ) {
        self.endpoint = endpoint
        self.sessionID = sessionID
        self.workerID = workerID
        self.processIdentity = processIdentity
    }
}

public struct KeeperInspectRequest: Hashable, Codable, Sendable {
    public let endpoint: KeeperEndpoint
    public let nonce: Data
    public let proofMAC: Data

    public init(endpoint: KeeperEndpoint, nonce: Data, proofMAC: Data) {
        self.endpoint = endpoint
        self.nonce = nonce
        self.proofMAC = proofMAC
    }
}

public struct KeeperTerminateRequest: Hashable, Codable, Sendable {
    public let endpoint: KeeperEndpoint
    public let force: Bool
    public let nonce: Data
    public let proofMAC: Data

    public init(endpoint: KeeperEndpoint, force: Bool, nonce: Data, proofMAC: Data) {
        self.endpoint = endpoint
        self.force = force
        self.nonce = nonce
        self.proofMAC = proofMAC
    }
}

public protocol KeeperControlling: Sendable {
    func awaitReady(_ keeper: LaunchedKeeper) async throws -> KeeperReady
    func authenticatedStart(_ request: AuthenticatedStartRequest) async throws
        -> CLIProcessIdentity
    func inspect(_ endpoint: KeeperEndpoint) async throws -> KeeperIdentity
    func terminate(_ endpoint: KeeperEndpoint, force: Bool) async throws
}

public extension KeeperControlling {
    func terminate(_ endpoint: KeeperEndpoint, force: Bool) async throws {
        throw KeeperControlError.disconnected
    }
}

public enum KeeperAuthentication {
    public static func readyProof(
        secret: Data,
        endpoint: KeeperEndpoint,
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        readyNonce: Data
    ) -> Data {
        proof(
            secret: secret,
            domain: "cockpit-keeper-ready-v1",
            endpoint: endpoint,
            sessionID: sessionID,
            workerID: workerID,
            payload: readyNonce
        )
    }

    public static func verifyReadyProof(
        _ candidate: Data,
        secret: Data,
        endpoint: KeeperEndpoint,
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        readyNonce: Data
    ) -> Bool {
        verify(
            candidate,
            secret: secret,
            expected: readyProof(
                secret: secret,
                endpoint: endpoint,
                sessionID: sessionID,
                workerID: workerID,
                readyNonce: readyNonce
            )
        )
    }

    public static func startProof(
        secret: Data,
        endpoint: KeeperEndpoint,
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        startNonce: Data
    ) -> Data {
        proof(
            secret: secret,
            domain: "cockpit-keeper-start-v1",
            endpoint: endpoint,
            sessionID: sessionID,
            workerID: workerID,
            payload: startNonce
        )
    }

    public static func verifyStartProof(
        _ candidate: Data,
        secret: Data,
        endpoint: KeeperEndpoint,
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        startNonce: Data
    ) -> Bool {
        verify(
            candidate,
            secret: secret,
            expected: startProof(
                secret: secret,
                endpoint: endpoint,
                sessionID: sessionID,
                workerID: workerID,
                startNonce: startNonce
            )
        )
    }

    public static func inspectProof(
        secret: Data,
        endpoint: KeeperEndpoint,
        nonce: Data
    ) -> Data {
        proof(
            secret: secret,
            domain: "cockpit-keeper-inspect-v1",
            endpoint: endpoint,
            sessionID: endpoint.sessionID,
            workerID: endpoint.workerID,
            payload: nonce
        )
    }

    public static func terminateProof(
        secret: Data,
        endpoint: KeeperEndpoint,
        force: Bool,
        nonce: Data
    ) -> Data {
        var payload = Data([force ? 1 : 0])
        payload.append(nonce)
        return proof(
            secret: secret,
            domain: "cockpit-keeper-terminate-v1",
            endpoint: endpoint,
            sessionID: endpoint.sessionID,
            workerID: endpoint.workerID,
            payload: payload
        )
    }

    public static func supervisorProof(
        secret: Data,
        endpoint: KeeperEndpoint,
        nonce: Data
    ) -> Data {
        proof(
            secret: secret,
            domain: "cockpit-keeper-supervisor-v1",
            endpoint: endpoint,
            sessionID: endpoint.sessionID,
            workerID: endpoint.workerID,
            payload: nonce
        )
    }

    public static func verifySupervisorProof(
        _ candidate: Data,
        secret: Data,
        endpoint: KeeperEndpoint,
        nonce: Data
    ) -> Bool {
        verify(
            candidate,
            secret: secret,
            expected: supervisorProof(secret: secret, endpoint: endpoint, nonce: nonce)
        )
    }

    private static func proof(
        secret: Data,
        domain: String,
        endpoint: KeeperEndpoint,
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        payload: Data
    ) -> Data {
        var message = Data()
        append(Data(domain.utf8), to: &message)
        append(Data(endpoint.path.utf8), to: &message)
        append(uuidData(sessionID.rawValue), to: &message)
        append(uuidData(workerID.rawValue), to: &message)
        append(payload, to: &message)
        let key = SymmetricKey(data: secret)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    private static func verify(_ candidate: Data, secret: Data, expected: Data) -> Bool {
        guard secret.count == 32, candidate.count == 32 else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(candidate, expected) { difference |= left ^ right }
        return difference == 0
    }

    private static func append(_ component: Data, to data: inout Data) {
        var length = UInt32(component.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(component)
    }

    private static func uuidData(_ value: UUID) -> Data {
        var uuid = value.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }
}

import Darwin
import Foundation
import CryptoKit
import Security
import CockpitProtocol
import CockpitTypes

public enum HostDataPlaneTicketError: Error, Hashable, Sendable {
    case randomGenerationFailed
    case invalidCanonicalTicket
    case expired
    case replay
    case bindingMismatch
}

public protocol HostDataPlaneClock: Sendable {
    func now() -> ContinuousClock.Instant
}

public struct ContinuousHostDataPlaneClock: HostDataPlaneClock {
    public init() {}
    public func now() -> ContinuousClock.Instant { ContinuousClock().now }
}

public protocol HostDataPlaneRandomBytes: Sendable {
    func bytes(count: Int) throws -> [UInt8]
}

public struct SecurityHostDataPlaneRandomBytes: HostDataPlaneRandomBytes {
    public init() {}
    public func bytes(count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw HostDataPlaneTicketError.randomGenerationFailed }
        if count == 0 { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw HostDataPlaneTicketError.randomGenerationFailed
        }
        return bytes
    }
}

public struct HostDataPlaneIssuedTicket: Hashable, Sendable {
    public let wireValue: String
    public let validForMilliseconds: UInt32
}

enum HostDataPlaneTicketIssueError: Error {
    case serverNotReady
    case stopped
}

public actor HostDataPlaneTicketStore {
    private struct Entry: Sendable {
        let binding: HostDataPlaneBinding
        let expectedPeerUID: uid_t
        let issuedAt: ContinuousClock.Instant
        let expiry: ContinuousClock.Instant
        var consumed: Bool
    }

    private let clock: any HostDataPlaneClock
    private let randomBytes: any HostDataPlaneRandomBytes
    private var entries: [Data: Entry] = [:]

    public init(
        clock: any HostDataPlaneClock,
        randomBytes: any HostDataPlaneRandomBytes
    ) {
        self.clock = clock
        self.randomBytes = randomBytes
    }

    public init() {
        clock = ContinuousHostDataPlaneClock()
        randomBytes = SecurityHostDataPlaneRandomBytes()
    }

    public func issue(
        binding: HostDataPlaneBinding,
        expectedPeerUID: uid_t
    ) throws -> HostDataPlaneIssuedTicket {
        let raw: [UInt8]
        do {
            raw = try randomBytes.bytes(count: 32)
        } catch {
            throw HostDataPlaneTicketError.randomGenerationFailed
        }
        guard raw.count == 32 else {
            throw HostDataPlaneTicketError.randomGenerationFailed
        }

        let wireValue = Self.encode(raw)
        guard wireValue.utf8.count == 43 else {
            throw HostDataPlaneTicketError.randomGenerationFailed
        }

        let issuedAt = clock.now()
        entries[Self.digest(raw)] = Entry(
            binding: binding,
            expectedPeerUID: expectedPeerUID,
            issuedAt: issuedAt,
            expiry: issuedAt.advanced(by: .seconds(30)),
            consumed: false
        )
        return HostDataPlaneIssuedTicket(wireValue: wireValue, validForMilliseconds: 30_000)
    }

    public func consume(
        wireValue: String,
        binding: HostDataPlaneBinding,
        peerUID: uid_t
    ) throws -> HostDataPlaneBinding {
        guard let raw = Self.decodeCanonical(wireValue) else {
            throw HostDataPlaneTicketError.invalidCanonicalTicket
        }

        let key = Self.digest(raw)
        guard var entry = entries[key] else {
            throw HostDataPlaneTicketError.invalidCanonicalTicket
        }
        if clock.now() >= entry.expiry {
            entries.removeValue(forKey: key)
            throw HostDataPlaneTicketError.expired
        }
        if entry.consumed {
            throw HostDataPlaneTicketError.replay
        }
        guard entry.expectedPeerUID == peerUID, entry.binding == binding else {
            throw HostDataPlaneTicketError.bindingMismatch
        }

        entry.consumed = true
        entries[key] = entry
        return entry.binding
    }

    func binding(forCanonicalWireValue wireValue: String) -> HostDataPlaneBinding? {
        guard let raw = Self.decodeCanonical(wireValue) else { return nil }
        return entries[Self.digest(raw)]?.binding
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeCanonical(_ wireValue: String) -> [UInt8]? {
        let bytes = Array(wireValue.utf8)
        guard bytes.count == 43,
              bytes.allSatisfy({ byte in
                  (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || (48...57).contains(byte)
                      || byte == 45
                      || byte == 95
              }) else {
            return nil
        }

        let base64 = wireValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + "="
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        let raw = [UInt8](data)
        return encode(raw) == wireValue ? raw : nil
    }

    private static func digest(_ bytes: [UInt8]) -> Data {
        Data(SHA256.hash(data: Data(bytes)))
    }
}

public actor HostDataPlaneTicketIssuer {
    private let server: HostDataPlaneServer
    private let store: HostDataPlaneTicketStore
    private let effectiveUserID: uid_t
    private var accepting = true
    private var activeIssues = 0
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        server: HostDataPlaneServer,
        store: HostDataPlaneTicketStore,
        effectiveUserID: uid_t
    ) {
        self.server = server
        self.store = store
        self.effectiveUserID = effectiveUserID
    }

    public func issue(
        for validatedContext: RequestContext,
        deliver: @escaping @Sendable (CPHostDataPlaneTicketResponse) throws -> Void
    ) async throws {
        guard accepting else { throw HostDataPlaneTicketIssueError.stopped }
        activeIssues += 1
        defer {
            activeIssues -= 1
            if activeIssues == 0 {
                let waiters = stopWaiters
                stopWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        do {
            try await server.waitUntilReady()
        } catch {
            throw HostDataPlaneTicketIssueError.serverNotReady
        }
        let binding = try HostDataPlaneBinding(
            validatingClientInstanceID: validatedContext.clientInstanceID,
            windowID: validatedContext.windowID,
            workspaceContextID: validatedContext.workspaceContextID,
            environmentID: validatedContext.environmentID,
            activeContextGeneration: validatedContext.activeContextGeneration
        )
        let ticket = try await store.issue(binding: binding, expectedPeerUID: effectiveUserID)
        var response = CPHostDataPlaneTicketResponse()
        response.socketPath = try await server.readySocketPath()
        response.ticket = ticket.wireValue
        response.validForMilliseconds = ticket.validForMilliseconds
        try deliver(response)
    }

    public func stopIssuingTickets() async {
        accepting = false
        guard activeIssues > 0 else { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }
}

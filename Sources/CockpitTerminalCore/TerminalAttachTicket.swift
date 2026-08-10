import Foundation
import CryptoKit
import CockpitTypes

public struct TerminalAttachCapabilities: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let view = Self(rawValue: 1)
    public static let input = Self(rawValue: 2)
    public static let resize = Self(rawValue: 4)
    public static let signal = Self(rawValue: 8)
    public static let terminate = Self(rawValue: 16)
    public static let all: Self = [.view, .input, .resize, .signal, .terminate]
}

public struct TerminalAttachBinding: Hashable, Codable, Sendable {
    public let sessionID: TerminalSessionID
    public let workerID: WorkerInstanceID
    public let clientInstanceID: ClientInstanceID

    public init(
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        clientInstanceID: ClientInstanceID
    ) {
        self.sessionID = sessionID
        self.workerID = workerID
        self.clientInstanceID = clientInstanceID
    }
}

public struct TerminalAttachTicketRegistration: Hashable, Codable, Sendable {
    public let ticketDigest: Data
    public let binding: TerminalAttachBinding
    public let capabilities: TerminalAttachCapabilities
    public let expiresAt: Date

    public init(
        ticketDigest: Data,
        binding: TerminalAttachBinding,
        capabilities: TerminalAttachCapabilities,
        expiresAt: Date
    ) throws {
        guard ticketDigest.count == 32 else {
            throw TerminalAttachTicketError.invalidRegistration
        }
        guard !capabilities.isEmpty, capabilities.isSubset(of: .all) else {
            throw TerminalAttachTicketError.invalidCapabilities
        }
        guard expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw TerminalAttachTicketError.invalidRegistration
        }
        self.ticketDigest = ticketDigest
        self.binding = binding
        self.capabilities = capabilities
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case ticketDigest
        case binding
        case capabilities
        case expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            ticketDigest: container.decode(Data.self, forKey: .ticketDigest),
            binding: container.decode(TerminalAttachBinding.self, forKey: .binding),
            capabilities: container.decode(TerminalAttachCapabilities.self, forKey: .capabilities),
            expiresAt: container.decode(Date.self, forKey: .expiresAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ticketDigest, forKey: .ticketDigest)
        try container.encode(binding, forKey: .binding)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(expiresAt, forKey: .expiresAt)
    }
}

public struct IssuedTerminalAttachTicket: Hashable, Sendable {
    public let wireValue: String
    public let validForMilliseconds: UInt32
    public let registration: TerminalAttachTicketRegistration

    public init(
        wireValue: String,
        validForMilliseconds: UInt32,
        registration: TerminalAttachTicketRegistration
    ) {
        self.wireValue = wireValue
        self.validForMilliseconds = validForMilliseconds
        self.registration = registration
    }
}

public struct TerminalAttachAuthorization: Hashable, Codable, Sendable {
    public let endpoint: KeeperEndpoint
    public let wireTicket: String
    public let binding: TerminalAttachBinding
    public let viewerID: ViewerID
    public let capabilities: TerminalAttachCapabilities

    public init(
        endpoint: KeeperEndpoint,
        wireTicket: String,
        binding: TerminalAttachBinding,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) {
        self.endpoint = endpoint
        self.wireTicket = wireTicket
        self.binding = binding
        self.viewerID = viewerID
        self.capabilities = capabilities
    }
}

public enum TerminalAttachTicketError: Error, Equatable, Sendable {
    case randomGenerationFailed
    case invalidCanonicalTicket
    case invalidRegistration
    case invalidCapabilities
    case digestCollision
    case expired
    case replay
    case bindingMismatch
    case capabilityEscalation
}

public protocol AttachTicketPolicy: Sendable {
    func issue(
        binding: TerminalAttachBinding,
        capabilities: TerminalAttachCapabilities
    ) async throws -> IssuedTerminalAttachTicket
    func register(_ registration: TerminalAttachTicketRegistration) async throws
    func acknowledgeConsumption(ticketDigest: Data) async throws
    func invalidateAll() async
    func consume(
        wireValue: String,
        binding: TerminalAttachBinding,
        capabilities: TerminalAttachCapabilities
    ) async throws -> TerminalAttachTicketRegistration
}

public actor TerminalAttachTicketStore: AttachTicketPolicy {
    private let clock: any TerminalSecurityClock
    private let randomBytes: any TerminalSecurityRandomBytes
    private var registrations: [Data: TerminalAttachTicketRegistration] = [:]
    private var replayTombstones: [Data: Date] = [:]

    public init(
        clock: any TerminalSecurityClock,
        randomBytes: any TerminalSecurityRandomBytes
    ) {
        self.clock = clock
        self.randomBytes = randomBytes
    }

    public func issue(
        binding: TerminalAttachBinding,
        capabilities: TerminalAttachCapabilities
    ) throws -> IssuedTerminalAttachTicket {
        guard !capabilities.isEmpty, capabilities.isSubset(of: .all) else {
            throw TerminalAttachTicketError.invalidCapabilities
        }
        purgeExpiredState()
        for _ in 0..<8 {
            let raw: [UInt8]
            do {
                raw = try randomBytes.bytes(count: 32)
            } catch {
                throw TerminalAttachTicketError.randomGenerationFailed
            }
            guard raw.count == 32 else {
                throw TerminalAttachTicketError.randomGenerationFailed
            }
            let digest = Self.digest(raw)
            if let current = registrations[digest], clock.now() < current.expiresAt {
                continue
            }
            if let replayExpiry = replayTombstones[digest], clock.now() < replayExpiry {
                continue
            }
            registrations.removeValue(forKey: digest)
            replayTombstones.removeValue(forKey: digest)
            let wireValue = Self.encode(raw)
            guard wireValue.utf8.count == 43 else {
                throw TerminalAttachTicketError.randomGenerationFailed
            }
            let registration = try TerminalAttachTicketRegistration(
                ticketDigest: digest,
                binding: binding,
                capabilities: capabilities,
                expiresAt: clock.now().addingTimeInterval(30)
            )
            registrations[digest] = registration
            return IssuedTerminalAttachTicket(
                wireValue: wireValue,
                validForMilliseconds: 30_000,
                registration: registration
            )
        }
        throw TerminalAttachTicketError.randomGenerationFailed
    }

    public func register(_ registration: TerminalAttachTicketRegistration) throws {
        let now = clock.now()
        guard now < registration.expiresAt else {
            throw TerminalAttachTicketError.expired
        }
        guard registration.ticketDigest.count == 32 else {
            throw TerminalAttachTicketError.invalidRegistration
        }
        guard !registration.capabilities.isEmpty,
              registration.capabilities.isSubset(of: .all)
        else {
            throw TerminalAttachTicketError.invalidCapabilities
        }
        guard registration.expiresAt.timeIntervalSinceReferenceDate.isFinite,
              registration.expiresAt.timeIntervalSince(now) <= 30
        else {
            throw TerminalAttachTicketError.invalidRegistration
        }
        purgeExpiredState()
        if let existing = registrations[registration.ticketDigest] {
            guard existing == registration else {
                throw TerminalAttachTicketError.digestCollision
            }
            return
        }
        guard replayTombstones[registration.ticketDigest] == nil else {
            throw TerminalAttachTicketError.replay
        }
        registrations[registration.ticketDigest] = registration
    }

    public func acknowledgeConsumption(ticketDigest: Data) throws {
        guard ticketDigest.count == 32 else {
            throw TerminalAttachTicketError.invalidRegistration
        }
        purgeExpiredState()
        if replayTombstones[ticketDigest] != nil {
            return
        }
        guard let registration = registrations.removeValue(forKey: ticketDigest) else { return }
        replayTombstones[ticketDigest] = registration.expiresAt
    }

    @_spi(CockpitTerminalSupervisorComposition)
    public func discardIssuedRegistration(ticketDigest: Data) {
        guard ticketDigest.count == 32 else { return }
        registrations.removeValue(forKey: ticketDigest)
    }

    public func invalidateAll() {
        registrations.removeAll(keepingCapacity: false)
        replayTombstones.removeAll(keepingCapacity: false)
    }

    public func consume(
        wireValue: String,
        binding: TerminalAttachBinding,
        capabilities: TerminalAttachCapabilities
    ) throws -> TerminalAttachTicketRegistration {
        guard let raw = Self.decodeCanonical(wireValue) else {
            throw TerminalAttachTicketError.invalidCanonicalTicket
        }
        let digest = Self.digest(raw)
        let requestedRegistration = registrations[digest]
        purgeExpiredState()
        if let replayExpiry = replayTombstones[digest], clock.now() < replayExpiry {
            throw TerminalAttachTicketError.replay
        }
        guard let registration = requestedRegistration else {
            throw TerminalAttachTicketError.invalidCanonicalTicket
        }
        guard clock.now() < registration.expiresAt else {
            registrations.removeValue(forKey: digest)
            throw TerminalAttachTicketError.expired
        }
        guard registration.binding == binding else {
            throw TerminalAttachTicketError.bindingMismatch
        }
        guard !capabilities.isEmpty, capabilities.isSubset(of: .all) else {
            throw TerminalAttachTicketError.invalidCapabilities
        }
        guard capabilities.isSubset(of: registration.capabilities) else {
            throw TerminalAttachTicketError.capabilityEscalation
        }

        registrations.removeValue(forKey: digest)
        replayTombstones[digest] = registration.expiresAt
        return registration
    }

    func activeRegistrationCount() -> Int {
        purgeExpiredState()
        return registrations.count
    }

    private func purgeExpiredState() {
        let now = clock.now()
        registrations = registrations.filter { now < $0.value.expiresAt }
        replayTombstones = replayTombstones.filter { now < $0.value }
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
              })
        else {
            return nil
        }
        let base64 = wireValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        let raw = [UInt8](data)
        return encode(raw) == wireValue ? raw : nil
    }

    private static func digest(_ bytes: [UInt8]) -> Data {
        Data(SHA256.hash(data: Data(bytes)))
    }
}

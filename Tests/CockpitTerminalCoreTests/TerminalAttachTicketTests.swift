import Foundation
import Testing
import CockpitTypes
@_spi(CockpitTerminalSupervisorComposition) @testable import CockpitTerminalCore

@Suite("TerminalAttachTicketTests")
struct TerminalAttachTicketTests {
    @Test func ticketIsCanonicalRegisteredByDigestAndConsumedOnce() async throws {
        let clock = AdjustableTerminalSecurityClock(Date(timeIntervalSince1970: 1_000))
        let random = FixedTerminalSecurityRandomBytes(Array(0..<32))
        let supervisor = TerminalAttachTicketStore(clock: clock, randomBytes: random)
        let keeper = TerminalAttachTicketStore(clock: clock, randomBytes: random)
        let binding = makeBinding(session: 0x11, worker: 0x21, client: 0x31)
        let capabilities: TerminalAttachCapabilities = [.view, .input, .resize]

        let issued = try await supervisor.issue(binding: binding, capabilities: capabilities)
        #expect(issued.wireValue == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        #expect(issued.wireValue.utf8.count == 43)
        #expect(issued.validForMilliseconds == 30_000)
        #expect(issued.registration.ticketDigest.count == 32)
        #expect(issued.registration.binding == binding)
        #expect(issued.registration.capabilities == capabilities)
        #expect(issued.registration.expiresAt == Date(timeIntervalSince1970: 1_030))

        try await keeper.register(issued.registration)
        let consumed = try await keeper.consume(
            wireValue: issued.wireValue,
            binding: binding,
            capabilities: [.view, .input]
        )
        #expect(consumed == issued.registration)
        await #expect(throws: TerminalAttachTicketError.replay) {
            _ = try await keeper.consume(
                wireValue: issued.wireValue,
                binding: binding,
                capabilities: [.view]
            )
        }
    }

    @Test func wrongBindingAndCapabilityEscalationDoNotConsumeTicket() async throws {
        let clock = AdjustableTerminalSecurityClock(Date(timeIntervalSince1970: 2_000))
        let store = TerminalAttachTicketStore(
            clock: clock,
            randomBytes: FixedTerminalSecurityRandomBytes(Array(repeating: 0xA5, count: 32))
        )
        let binding = makeBinding(session: 0x41, worker: 0x42, client: 0x43)
        let issued = try await store.issue(binding: binding, capabilities: [.view, .input])

        for wrong in [
            makeBinding(session: 0x44, worker: 0x42, client: 0x43),
            makeBinding(session: 0x41, worker: 0x45, client: 0x43),
            makeBinding(session: 0x41, worker: 0x42, client: 0x46),
        ] {
            await #expect(throws: TerminalAttachTicketError.bindingMismatch) {
                _ = try await store.consume(
                    wireValue: issued.wireValue,
                    binding: wrong,
                    capabilities: [.view]
                )
            }
        }

        await #expect(throws: TerminalAttachTicketError.capabilityEscalation) {
            _ = try await store.consume(
                wireValue: issued.wireValue,
                binding: binding,
                capabilities: [.view, .signal]
            )
        }

        #expect(
            try await store.consume(
                wireValue: issued.wireValue,
                binding: binding,
                capabilities: [.view]
            ).binding == binding
        )
    }

    @Test func expiredUnknownAndRestartedTicketsFailClosed() async throws {
        let clock = AdjustableTerminalSecurityClock(Date(timeIntervalSince1970: 3_000))
        let bytes = Array(repeating: UInt8(0x7C), count: 32)
        let store = TerminalAttachTicketStore(
            clock: clock,
            randomBytes: FixedTerminalSecurityRandomBytes(bytes)
        )
        let binding = makeBinding(session: 0x51, worker: 0x52, client: 0x53)
        let issued = try await store.issue(binding: binding, capabilities: .all)

        clock.advance(by: 30)
        await #expect(throws: TerminalAttachTicketError.expired) {
            _ = try await store.consume(
                wireValue: issued.wireValue,
                binding: binding,
                capabilities: [.terminate]
            )
        }

        let restarted = TerminalAttachTicketStore(
            clock: clock,
            randomBytes: FixedTerminalSecurityRandomBytes(bytes)
        )
        await #expect(throws: TerminalAttachTicketError.invalidCanonicalTicket) {
            _ = try await restarted.consume(
                wireValue: issued.wireValue,
                binding: binding,
                capabilities: [.view]
            )
        }
        await #expect(throws: TerminalAttachTicketError.invalidCanonicalTicket) {
            _ = try await restarted.consume(
                wireValue: issued.wireValue + "=",
                binding: binding,
                capabilities: [.view]
            )
        }
    }

    @Test func capabilityBitsAreFrozen() {
        #expect(TerminalAttachCapabilities.view.rawValue == 1)
        #expect(TerminalAttachCapabilities.input.rawValue == 2)
        #expect(TerminalAttachCapabilities.resize.rawValue == 4)
        #expect(TerminalAttachCapabilities.signal.rawValue == 8)
        #expect(TerminalAttachCapabilities.terminate.rawValue == 16)
        #expect(TerminalAttachCapabilities.all.rawValue == 31)
    }

    @Test func registrationDecodingAndKeeperBoundaryRejectMalformedOrExcessivePolicy() async throws {
        let clock = AdjustableTerminalSecurityClock(Date(timeIntervalSince1970: 4_000))
        let binding = makeBinding(session: 0x61, worker: 0x62, client: 0x63)
        let valid = try TerminalAttachTicketRegistration(
            ticketDigest: Data(repeating: 0xD1, count: 32),
            binding: binding,
            capabilities: [.view, .input],
            expiresAt: clock.now().addingTimeInterval(30)
        )
        let encoded = try JSONEncoder().encode(valid)
        let root = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        var shortDigest = root
        shortDigest["ticketDigest"] = Data([0xD1]).base64EncodedString()
        #expect(throws: TerminalAttachTicketError.invalidRegistration) {
            _ = try JSONDecoder().decode(
                TerminalAttachTicketRegistration.self,
                from: JSONSerialization.data(withJSONObject: shortDigest)
            )
        }

        var unknownCapabilities = root
        unknownCapabilities["capabilities"] = 33
        #expect(throws: TerminalAttachTicketError.invalidCapabilities) {
            _ = try JSONDecoder().decode(
                TerminalAttachTicketRegistration.self,
                from: JSONSerialization.data(withJSONObject: unknownCapabilities)
            )
        }

        let excessive = try TerminalAttachTicketRegistration(
            ticketDigest: Data(repeating: 0xD2, count: 32),
            binding: binding,
            capabilities: [.view],
            expiresAt: clock.now().addingTimeInterval(31)
        )
        let keeper = TerminalAttachTicketStore(
            clock: clock,
            randomBytes: FixedTerminalSecurityRandomBytes(Array(repeating: 0xD2, count: 32))
        )
        await #expect(throws: TerminalAttachTicketError.invalidRegistration) {
            try await keeper.register(excessive)
        }
    }

    @Test func consumptionAcknowledgementRestartInvalidationAndExpiryCleanupBoundTicketState() async throws {
        let clock = AdjustableTerminalSecurityClock(Date(timeIntervalSince1970: 5_000))
        let random = IncrementingTerminalSecurityRandomBytes(startingAt: 0x10)
        let supervisor = TerminalAttachTicketStore(clock: clock, randomBytes: random)
        let keeper = TerminalAttachTicketStore(
            clock: clock,
            randomBytes: FixedTerminalSecurityRandomBytes(Array(repeating: 0xA0, count: 32))
        )
        let binding = makeBinding(session: 0x71, worker: 0x72, client: 0x73)

        let consumedTicket = try await supervisor.issue(binding: binding, capabilities: [.view, .input])
        try await keeper.register(consumedTicket.registration)
        _ = try await keeper.consume(
            wireValue: consumedTicket.wireValue,
            binding: binding,
            capabilities: [.view]
        )
        try await supervisor.acknowledgeConsumption(
            ticketDigest: consumedTicket.registration.ticketDigest
        )
        await #expect(throws: TerminalAttachTicketError.replay) {
            _ = try await supervisor.consume(
                wireValue: consumedTicket.wireValue,
                binding: binding,
                capabilities: [.view]
            )
        }

        let keeperRestartTicket = try await supervisor.issue(binding: binding, capabilities: [.view])
        try await keeper.register(keeperRestartTicket.registration)
        await keeper.invalidateAll()
        await #expect(throws: TerminalAttachTicketError.invalidCanonicalTicket) {
            _ = try await keeper.consume(
                wireValue: keeperRestartTicket.wireValue,
                binding: binding,
                capabilities: [.view]
            )
        }

        let supervisorRestartTicket = try await supervisor.issue(binding: binding, capabilities: [.view])
        await supervisor.invalidateAll()
        await #expect(throws: TerminalAttachTicketError.invalidCanonicalTicket) {
            _ = try await supervisor.consume(
                wireValue: supervisorRestartTicket.wireValue,
                binding: binding,
                capabilities: [.view]
            )
        }

        let cleanup = TerminalAttachTicketStore(
            clock: clock,
            randomBytes: IncrementingTerminalSecurityRandomBytes(startingAt: 0x40)
        )
        _ = try await cleanup.issue(binding: binding, capabilities: [.view])
        _ = try await cleanup.issue(binding: binding, capabilities: [.view])
        _ = try await cleanup.issue(binding: binding, capabilities: [.view])
        #expect(await cleanup.activeRegistrationCount() == 3)
        clock.advance(by: 30)
        _ = try await cleanup.issue(binding: binding, capabilities: [.view])
        #expect(await cleanup.activeRegistrationCount() == 1)
    }

    @Test func ambiguousRegistrationDiscardsOnlyItsDigestAndMissingConsumptionIsIdempotent() async throws {
        let clock = AdjustableTerminalSecurityClock(Date(timeIntervalSince1970: 6_000))
        let store = TerminalAttachTicketStore(
            clock: clock,
            randomBytes: IncrementingTerminalSecurityRandomBytes(startingAt: 0x70)
        )
        let binding = makeBinding(session: 0x81, worker: 0x82, client: 0x83)
        let ambiguous = try await store.issue(binding: binding, capabilities: [.view])
        let unrelated = try await store.issue(binding: binding, capabilities: [.view])

        await store.discardIssuedRegistration(
            ticketDigest: ambiguous.registration.ticketDigest
        )
        #expect(await store.activeRegistrationCount() == 1)
        await #expect(throws: TerminalAttachTicketError.invalidCanonicalTicket) {
            _ = try await store.consume(
                wireValue: ambiguous.wireValue,
                binding: binding,
                capabilities: [.view]
            )
        }
        #expect(
            try await store.consume(
                wireValue: unrelated.wireValue,
                binding: binding,
                capabilities: [.view]
            ) == unrelated.registration
        )

        try await store.acknowledgeConsumption(ticketDigest: Data(repeating: 0xEE, count: 32))
        let expiring = try await store.issue(binding: binding, capabilities: [.view])
        clock.advance(by: 31)
        try await store.acknowledgeConsumption(
            ticketDigest: expiring.registration.ticketDigest
        )
    }
}

private func makeBinding(session: UInt8, worker: UInt8, client: UInt8) -> TerminalAttachBinding {
    TerminalAttachBinding(
        sessionID: TerminalSessionID(ticketUUID(session)),
        workerID: WorkerInstanceID(ticketUUID(worker)),
        clientInstanceID: ClientInstanceID(ticketUUID(client))
    )
}

private func ticketUUID(_ lastByte: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, lastByte))
}

private final class AdjustableTerminalSecurityClock: TerminalSecurityClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date { lock.withLock { value } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

private struct FixedTerminalSecurityRandomBytes: TerminalSecurityRandomBytes {
    let value: [UInt8]

    init(_ value: [UInt8]) { self.value = value }

    func bytes(count: Int) throws -> [UInt8] {
        Array(value.prefix(count))
    }
}

private final class IncrementingTerminalSecurityRandomBytes: TerminalSecurityRandomBytes, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt8

    init(startingAt: UInt8) {
        next = startingAt
    }

    func bytes(count: Int) throws -> [UInt8] {
        lock.withLock {
            defer { next &+= 1 }
            return Array(repeating: next, count: count)
        }
    }
}

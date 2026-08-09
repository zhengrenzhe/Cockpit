import Foundation
import Testing
import CockpitTypes
@testable import CockpitTerminalCore

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

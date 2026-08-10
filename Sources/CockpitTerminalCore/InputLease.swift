import Foundation
import CockpitTypes

public struct KeeperSupervisorGeneration: Hashable, Sendable {
    public let epoch: UInt64
    public let rawValue: UUID

    public init(epoch: UInt64, nonce: UUID = UUID()) throws {
        guard epoch > 0 else { throw KeeperControlError.malformedMessage }
        var bytes = nonce.uuid
        var encodedEpoch = epoch.bigEndian
        withUnsafeBytes(of: &encodedEpoch) { source in
            withUnsafeMutableBytes(of: &bytes) { destination in
                destination[0..<MemoryLayout<UInt64>.size].copyBytes(from: source)
            }
        }
        self.epoch = epoch
        rawValue = UUID(uuid: bytes)
    }

    public init(validating rawValue: UUID) throws {
        let epoch = withUnsafeBytes(of: rawValue.uuid) { bytes in
            bytes.prefix(MemoryLayout<UInt64>.size).reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
        }
        guard epoch > 0 else { throw KeeperControlError.malformedMessage }
        self.epoch = epoch
        self.rawValue = rawValue
    }
}

public struct InputLeaseGrant: Hashable, Codable, Sendable {
    public let leaseID: InputLeaseID
    public let holderViewerID: ViewerID
    public let sequenceBase: UInt64
    public let capabilities: TerminalAttachCapabilities

    public init(
        validatingLeaseID leaseID: InputLeaseID,
        holderViewerID: ViewerID,
        sequenceBase: UInt64,
        capabilities: TerminalAttachCapabilities
    ) throws {
        let allowed: TerminalAttachCapabilities = [.input, .resize, .signal, .terminate]
        guard sequenceBase > 0 else { throw TerminalStreamError.invalidInputLease }
        guard !capabilities.isEmpty,
              capabilities.isSubset(of: allowed),
              !capabilities.contains(.view)
        else {
            throw TerminalStreamError.invalidInputLease
        }
        self.leaseID = leaseID
        self.holderViewerID = holderViewerID
        self.sequenceBase = sequenceBase
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case leaseID, holderViewerID, sequenceBase, capabilities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validatingLeaseID: container.decode(InputLeaseID.self, forKey: .leaseID),
            holderViewerID: container.decode(ViewerID.self, forKey: .holderViewerID),
            sequenceBase: container.decode(UInt64.self, forKey: .sequenceBase),
            capabilities: container.decode(TerminalAttachCapabilities.self, forKey: .capabilities)
        )
    }
}

public struct KeeperInputLeaseState: Hashable, Codable, Sendable {
    public let grant: InputLeaseGrant
    public let nextSequence: UInt64

    public init(grant: InputLeaseGrant, nextSequence: UInt64) throws {
        guard nextSequence >= grant.sequenceBase else {
            throw TerminalStreamError.invalidInputLease
        }
        self.grant = grant
        self.nextSequence = nextSequence
    }
}

public struct KeeperSupervisorLeaseSnapshot: Hashable, Codable, Sendable {
    public let currentLease: KeeperInputLeaseState?
    public let nextInputSequence: UInt64

    public init(
        currentLease: KeeperInputLeaseState?,
        nextInputSequence: UInt64
    ) throws {
        guard nextInputSequence > 0,
              currentLease?.nextSequence == nil
                || currentLease?.nextSequence == nextInputSequence else {
            throw TerminalStreamError.invalidInputLease
        }
        self.currentLease = currentLease
        self.nextInputSequence = nextInputSequence
    }
}

public enum KeeperSupervisorEventPayload: Hashable, Codable, Sendable {
    case leaseRevoked(InputLeaseID, nextSequence: UInt64)
    case attachTicketConsumed(Data)
}

public struct KeeperSupervisorEvent: Hashable, Codable, Sendable {
    public let sequence: UInt64
    public let payload: KeeperSupervisorEventPayload

    public init(sequence: UInt64, payload: KeeperSupervisorEventPayload) {
        self.sequence = sequence
        self.payload = payload
    }
}

public struct KeeperSupervisorSyncRequest: Hashable, Codable, Sendable {
    public let supervisorGeneration: UUID
    public let acknowledgedThrough: UInt64
    public let afterSequence: UInt64
    public let waitForEvents: Bool

    public init(
        supervisorGeneration: UUID,
        acknowledgedThrough: UInt64,
        afterSequence: UInt64,
        waitForEvents: Bool
    ) {
        self.supervisorGeneration = supervisorGeneration
        self.acknowledgedThrough = acknowledgedThrough
        self.afterSequence = afterSequence
        self.waitForEvents = waitForEvents
    }
}

public struct KeeperSupervisorSyncResponse: Hashable, Codable, Sendable {
    public let supervisorGeneration: UUID
    public let currentLease: KeeperInputLeaseState?
    public let nextInputSequence: UInt64
    public let events: [KeeperSupervisorEvent]
    public let latestEventSequence: UInt64

    public init(
        supervisorGeneration: UUID,
        currentLease: KeeperInputLeaseState?,
        nextInputSequence: UInt64,
        events: [KeeperSupervisorEvent],
        latestEventSequence: UInt64
    ) {
        self.supervisorGeneration = supervisorGeneration
        self.currentLease = currentLease
        self.nextInputSequence = nextInputSequence
        self.events = events
        self.latestEventSequence = latestEventSequence
    }
}

public actor InputLeaseRevocationBuffer {
    private struct Waiter {
        let generation: UUID
        let afterSequence: UInt64
        let continuation: CheckedContinuation<[KeeperSupervisorEvent], Never>
    }

    private var supervisorGeneration: UUID?
    private var supervisorEpoch: UInt64?
    private var nextEventSequence: UInt64 = 1
    private var pending: [KeeperSupervisorEvent] = []
    private var waiters: [UUID: Waiter] = [:]

    public init() {}

    public func beginSupervisorGeneration(_ generation: UUID) throws -> Bool {
        guard supervisorGeneration != generation else { return false }
        let incoming = try KeeperSupervisorGeneration(validating: generation)
        guard supervisorEpoch == nil || incoming.epoch > supervisorEpoch! else {
            throw KeeperControlError.identityMismatch
        }
        supervisorGeneration = generation
        supervisorEpoch = incoming.epoch
        nextEventSequence = 1
        pending.removeAll(keepingCapacity: false)
        let stale = waiters.values.map(\.continuation)
        waiters.removeAll(keepingCapacity: false)
        for continuation in stale { continuation.resume(returning: []) }
        return true
    }

    public func recordLeaseRevocation(
        _ leaseID: InputLeaseID,
        nextSequence: UInt64
    ) {
        record(.leaseRevoked(leaseID, nextSequence: nextSequence))
    }

    public func recordAttachTicketConsumption(_ digest: Data) {
        record(.attachTicketConsumed(digest))
    }

    public func events(
        generation: UUID,
        acknowledgedThrough: UInt64,
        afterSequence: UInt64,
        waitForEvents: Bool
    ) async -> [KeeperSupervisorEvent] {
        guard supervisorGeneration == generation else { return [] }
        pending.removeAll { $0.sequence <= acknowledgedThrough }
        let available = pending.filter { $0.sequence > afterSequence }
        guard available.isEmpty, waitForEvents else { return available }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            waiters[waiterID] = Waiter(
                generation: generation,
                afterSequence: afterSequence,
                continuation: continuation
            )
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.timeout(waiterID)
            }
        }
    }

    public func latestSequence(for generation: UUID) -> UInt64 {
        guard supervisorGeneration == generation else { return 0 }
        return nextEventSequence - 1
    }

    private func record(_ payload: KeeperSupervisorEventPayload) {
        guard supervisorGeneration != nil, nextEventSequence < UInt64.max else { return }
        let event = KeeperSupervisorEvent(sequence: nextEventSequence, payload: payload)
        nextEventSequence += 1
        pending.append(event)
        let resumptions = waiters.compactMap { id, waiter -> (UUID, CheckedContinuation<[KeeperSupervisorEvent], Never>, [KeeperSupervisorEvent])? in
            guard waiter.generation == supervisorGeneration else {
                return (id, waiter.continuation, [])
            }
            let available = pending.filter { $0.sequence > waiter.afterSequence }
            guard !available.isEmpty else { return nil }
            return (id, waiter.continuation, available)
        }
        for (id, continuation, events) in resumptions {
            waiters.removeValue(forKey: id)
            continuation.resume(returning: events)
        }
    }

    private func timeout(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        let available = supervisorGeneration == waiter.generation
            ? pending.filter { $0.sequence > waiter.afterSequence }
            : []
        waiter.continuation.resume(returning: available)
    }
}

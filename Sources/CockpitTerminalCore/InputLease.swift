import Foundation
import CockpitTypes

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

public actor InputLeaseRevocationBuffer {
    private var pending: [InputLeaseID] = []

    public init() {}

    public func record(_ leaseID: InputLeaseID) {
        if !pending.contains(leaseID) { pending.append(leaseID) }
    }

    public func takeAll() -> [InputLeaseID] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}

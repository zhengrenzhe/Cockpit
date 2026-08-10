import Foundation
import CockpitProtocol
import CockpitTypes

public enum PeerRole: String, Hashable, Codable, Sendable {
    case supervisorControl
    case viewer
}

public enum TerminalStreamError: String, Error, Hashable, Codable, Sendable {
    case authenticationFailed
    case malformedMessage
    case protocolVersionMismatch
    case wrongChannel
    case viewerAlreadyAttached
    case viewerNotAttached
    case inputLeaseRequired
    case invalidInputLease
    case nonMonotonicInputSequence
    case capabilityDenied
    case sessionMismatch
    case disconnected
    case internalFailure
}

public enum TerminalStreamFrameKind: String, Hashable, Codable, Sendable {
    case snapshot
    case delta
    case scrollback
}

public struct TerminalStreamPage: Hashable, Codable, Sendable {
    public static let maximumPayloadBytes = FrameHeader.maximumPayloadLength

    public let kind: TerminalStreamFrameKind
    public let index: UInt32
    public let count: UInt32
    public let payload: Data

    public static func paginate(
        _ payload: Data,
        kind: TerminalStreamFrameKind
    ) -> [TerminalStreamPage] {
        let limit = Int(maximumPayloadBytes)
        guard !payload.isEmpty else {
            return [TerminalStreamPage(kind: kind, index: 0, count: 1, payload: Data())]
        }
        let pageCount = (payload.count + limit - 1) / limit
        return (0..<pageCount).map { index in
            let lower = index * limit
            let upper = min(payload.count, lower + limit)
            return TerminalStreamPage(
                kind: kind,
                index: UInt32(index),
                count: UInt32(pageCount),
                payload: payload.subdata(in: lower..<upper)
            )
        }
    }
}

public struct TerminalOutputFrame: Hashable, Codable, Sendable {
    public let firstOutputSequence: UInt64
    public let outputSequence: UInt64
    public let kind: TerminalStreamFrameKind
    public let fragments: [Data]

    public init(
        firstOutputSequence: UInt64,
        outputSequence: UInt64,
        kind: TerminalStreamFrameKind = .snapshot,
        fragments: [Data]
    ) throws {
        guard firstOutputSequence > 0,
              firstOutputSequence <= outputSequence,
              !fragments.isEmpty,
              fragments.count <= Int(UInt32.max)
        else {
            throw TerminalStreamError.malformedMessage
        }
        self.firstOutputSequence = firstOutputSequence
        self.outputSequence = outputSequence
        self.kind = kind
        self.fragments = fragments
    }

    static func coalescing(
        _ first: TerminalOutputFrame,
        _ second: TerminalOutputFrame
    ) -> TerminalOutputFrame {
        let fragments: [Data]
        if second.kind == .snapshot, let latest = second.fragments.last {
            fragments = [latest]
        } else {
            fragments = first.fragments + second.fragments
        }
        return try! TerminalOutputFrame(
            firstOutputSequence: first.firstOutputSequence,
            outputSequence: second.outputSequence,
            kind: second.kind,
            fragments: fragments
        )
    }
}

public struct AttachRequest: Hashable, Codable, Sendable {
    public let viewerID: ViewerID
    public let wireTicket: String
    public let binding: TerminalAttachBinding
    public let requestedCapabilities: TerminalAttachCapabilities
    public let lastAcknowledgedOutputSequence: UInt64?

    public init(
        viewerID: ViewerID,
        wireTicket: String,
        binding: TerminalAttachBinding,
        requestedCapabilities: TerminalAttachCapabilities,
        lastAcknowledgedOutputSequence: UInt64?
    ) {
        self.viewerID = viewerID
        self.wireTicket = wireTicket
        self.binding = binding
        self.requestedCapabilities = requestedCapabilities
        self.lastAcknowledgedOutputSequence = lastAcknowledgedOutputSequence
    }
}

public struct TerminalFrameSubscription: AsyncSequence, Sendable {
    public typealias Element = TerminalOutputFrame

    public struct AsyncIterator: AsyncIteratorProtocol {
        let nextValue: @Sendable () async -> TerminalOutputFrame?

        public mutating func next() async -> TerminalOutputFrame? {
            await nextValue()
        }
    }

    let nextValue: @Sendable () async -> TerminalOutputFrame?

    init(nextValue: @escaping @Sendable () async -> TerminalOutputFrame?) {
        self.nextValue = nextValue
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(nextValue: nextValue)
    }
}

public struct Attachment: Sendable {
    public let viewerID: ViewerID
    public let capabilities: TerminalAttachCapabilities
    public let frames: TerminalFrameSubscription

    init(
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities,
        frames: TerminalFrameSubscription
    ) {
        self.viewerID = viewerID
        self.capabilities = capabilities
        self.frames = frames
    }
}

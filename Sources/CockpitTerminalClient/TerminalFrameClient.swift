import Foundation
import CockpitTerminalCore

public enum TerminalFrameDecision: Sendable {
    case accepted(TerminalOutputFrame)
    case ignored
    case requiresSnapshot
}

public actor TerminalFrameClient {
    private var latestSequence: UInt64
    private var hasBaseline: Bool

    public init(lastAcknowledgedSequence: UInt64? = nil) {
        latestSequence = lastAcknowledgedSequence ?? 0
        hasBaseline = (lastAcknowledgedSequence ?? 0) != 0
    }

    public func accept(_ frame: TerminalOutputFrame) -> TerminalFrameDecision {
        guard frame.outputSequence > latestSequence else { return .ignored }
        if frame.kind == .delta {
            guard hasBaseline else { return .requiresSnapshot }
            let (next, overflow) = latestSequence.addingReportingOverflow(1)
            guard !overflow, frame.firstOutputSequence <= next else {
                return .requiresSnapshot
            }
        }
        latestSequence = frame.outputSequence
        if frame.kind != .scrollback { hasBaseline = true }
        return .accepted(frame)
    }

    public func reset() {
        latestSequence = 0
        hasBaseline = false
    }
    public func acknowledgedSequence() -> UInt64? { latestSequence == 0 ? nil : latestSequence }
}

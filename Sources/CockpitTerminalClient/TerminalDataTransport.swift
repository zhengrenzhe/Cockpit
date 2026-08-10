import CockpitTerminalCore
import CockpitTypes

public protocol TerminalDataConnection: Sendable {
    func nextOutput() async throws -> TerminalOutputFrame?
    func send(_ input: TerminalInput) async throws -> UInt64
    func setVisible(_ visible: Bool) async throws
    func detach() async
}

public protocol TerminalDataTransport: Sendable {
    func attach(
        authorization: TerminalAttachAuthorization,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> any TerminalDataConnection
}

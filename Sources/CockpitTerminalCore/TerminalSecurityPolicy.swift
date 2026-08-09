import Foundation
import CockpitTypes

public enum TerminalSecurityError: Error, Equatable, Sendable {
    case invalidMasterKeyLength
    case randomGenerationFailed
}

public protocol InstallationMasterKeyProviding: Sendable {
    func masterKey() async throws -> Data
}

public protocol WorkerSecretDeriving: Sendable {
    func derive(sessionID: TerminalSessionID, workerID: WorkerInstanceID) async throws -> Data
}

public protocol TerminalSecurityClock: Sendable {
    func now() -> Date
}

public struct SystemTerminalSecurityClock: TerminalSecurityClock {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol TerminalSecurityRandomBytes: Sendable {
    func bytes(count: Int) throws -> [UInt8]
}

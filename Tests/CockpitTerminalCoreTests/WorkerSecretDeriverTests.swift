import Foundation
import Testing
import CockpitTypes
@testable import CockpitTerminalCore

@Suite("WorkerSecretDeriverTests")
struct WorkerSecretDeriverTests {
    @Test func hkdfSHA256MatchesTheFrozenVector() async throws {
        let provider = FixedInstallationMasterKeyProvider(Data((0..<32).map(UInt8.init)))
        let deriver = WorkerSecretDeriver(masterKeyProvider: provider)
        let sessionID = TerminalSessionID(try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")))
        let workerID = WorkerInstanceID(try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")))

        let secret = try await deriver.derive(sessionID: sessionID, workerID: workerID)

        #expect(secret.count == 32)
        #expect(secret.hex == "ce728c13c488c5f0c8998b4333cb16c82f5cca9fee384bddb55f94c4a6c61bf4")
    }

    @Test func bindingChangesSecretAndInvalidMasterKeyFailsClosed() async throws {
        let valid = WorkerSecretDeriver(
            masterKeyProvider: FixedInstallationMasterKeyProvider(Data(repeating: 0x5A, count: 32))
        )
        let session = TerminalSessionID(try #require(UUID(uuidString: "10000000-0000-0000-0000-000000000001")))
        let firstWorker = WorkerInstanceID(try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000001")))
        let secondWorker = WorkerInstanceID(try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000002")))

        let first = try await valid.derive(sessionID: session, workerID: firstWorker)
        let repeated = try await valid.derive(sessionID: session, workerID: firstWorker)
        let second = try await valid.derive(sessionID: session, workerID: secondWorker)
        #expect(first == repeated)
        #expect(first != second)

        let invalid = WorkerSecretDeriver(
            masterKeyProvider: FixedInstallationMasterKeyProvider(Data(repeating: 0, count: 31))
        )
        await #expect(throws: TerminalSecurityError.invalidMasterKeyLength) {
            _ = try await invalid.derive(sessionID: session, workerID: firstWorker)
        }
    }
}

private struct FixedInstallationMasterKeyProvider: InstallationMasterKeyProviding {
    let value: Data

    init(_ value: Data) { self.value = value }

    func masterKey() async throws -> Data { value }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

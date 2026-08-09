import Foundation
import CryptoKit
import CockpitTypes

public struct WorkerSecretDeriver: WorkerSecretDeriving {
    private let masterKeyProvider: any InstallationMasterKeyProviding

    public init(masterKeyProvider: any InstallationMasterKeyProviding) {
        self.masterKeyProvider = masterKeyProvider
    }

    public func derive(
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID
    ) async throws -> Data {
        let masterKey = try await masterKeyProvider.masterKey()
        guard masterKey.count == 32 else {
            throw TerminalSecurityError.invalidMasterKeyLength
        }
        let inputKey = SymmetricKey(data: masterKey)
        let salt = uuidBytes(sessionID.rawValue)
        var info = Data("cockpit-worker-v1".utf8)
        info.append(uuidBytes(workerID.rawValue))
        let secret = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return secret.withUnsafeBytes { Data($0) }
    }
}

private func uuidBytes(_ value: UUID) -> Data {
    var bytes = value.uuid
    return withUnsafeBytes(of: &bytes) { Data($0) }
}
